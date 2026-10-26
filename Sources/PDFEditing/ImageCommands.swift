import Foundation
import PDFCore

/// P20-001: one draw instance of an image XObject on a page. Instances are
/// distinct from the shared resource: several placements may point at the
/// same image object, and editing one instance must not disturb the others.
public struct ImagePlacement: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let instructionIndex: Int
  public let resourceName: PDFName
  public let imageID: PDFObjectID
  /// Complete page-space placement after all enclosing transforms.
  public let matrix: [Double]
  /// The `cm` operands immediately before the image draw.
  public let localMatrix: [Double]
  /// The enclosing page-space transform before those local operands.
  public let outerMatrix: [Double]
  public let bounds: [Double]
  /// Page-space rectangular clipping bounds active at the image draw. Nil
  /// means no rectangular clip bounds were captured; check the support flag.
  public let clippingBounds: [Double]?
  /// False when a clipping path affects this draw but is not an axis-aligned
  /// rectangle. The canvas must not guess at its visible hit region.
  public let hasSupportedClipping: Bool
  /// True when the placement is a page-level `q … cm /Name Do …` pattern with
  /// an axis-aligned enclosing scale, so commands can rewrite its local matrix
  /// operands while preserving page transformations and clipping.
  public let isDirectlyEditable: Bool
  /// Nesting depth: 0 for page content, >0 inside form XObjects.
  public let depth: Int
  /// The form XObject stream containing a nested draw; nil for page content.
  public let containerObjectID: PDFObjectID?
  let operandSpans: [Range<Int>]

  /// P20-003: exact hit test through the inverse placement matrix, valid for
  /// rotated and skewed placements while the matrix stays invertible.
  public func contains(point: [Double]) -> Bool {
    guard hasSupportedClipping, containsSourcePoint(point) else { return false }
    guard let clip = clippingBounds else { return true }
    return clip.count == 4 && clip[2] > clip[0] && clip[3] > clip[1]
      && point[0] >= clip[0] && point[0] <= clip[2]
      && point[1] >= clip[1] && point[1] <= clip[3]
  }

  /// Axis-aligned visible bounds suitable for rubber-band selection. The
  /// transform/edit rectangle remains `bounds`; this is only its hit region.
  public var canvasVisibleBounds: [Double]? {
    guard hasSupportedClipping, bounds.count == 4, bounds.allSatisfy(\.isFinite),
      bounds[2] > bounds[0], bounds[3] > bounds[1]
    else { return nil }
    guard let clip = clippingBounds else { return bounds }
    guard clip.count == 4 else { return nil }
    let visible = [max(bounds[0], clip[0]), max(bounds[1], clip[1]),
      min(bounds[2], clip[2]), min(bounds[3], clip[3])]
    return visible[2] > visible[0] && visible[3] > visible[1] ? visible : nil
  }

  /// Tests the image's transformed unit square, without considering a PDF
  /// clipping path. Used only to explain why an otherwise visible draw cannot
  /// be safely hit-tested by the canvas.
  public func containsSourcePoint(_ point: [Double]) -> Bool {
    guard point.count == 2, point.allSatisfy(\.isFinite),
      matrix.count == 6, matrix.allSatisfy(\.isFinite)
    else { return false }
    let (a, b, c, d, e, f) = (matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5])
    let determinant = a * d - b * c
    guard abs(determinant) > 1e-9 else { return false }
    let dx = point[0] - e
    let dy = point[1] - f
    let u = (d * dx - c * dy) / determinant
    let v = (-b * dx + a * dy) / determinant
    return u >= 0 && u <= 1 && v >= 0 && v <= 1
  }
}

public enum ImageInventory {
  /// P20-001/P20-002/P13-018/P13-019: enumerate image draw instances on one
  /// page, including draws inside nested form XObjects with inherited
  /// resources and composed matrices. Form recursion is depth-bounded and
  /// cycle-checked; nested draws are reported but not directly editable.
  public static func placements(
    in graph: PDFGraph, pageID: PDFObjectID, limits: PDFLimits = PDFLimits()
  ) throws -> [ImagePlacement] {
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let resources: [PDFName: PDFValue]?
    switch page[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      resources = dictionary
    case .reference(let resourcesID)?:
      guard case .dictionary(let dictionary)? = graph.objects[resourcesID] else { return [] }
      resources = dictionary
    default:
      resources = nil
    }
    var walker = Walker(graph: graph, limits: limits, pageID: pageID)
    try walker.walk(
      instructions: content.instructions, resources: resources,
      transform: [1, 0, 0, 1, 0, 0], depth: 0, container: nil, visited: [])
    return walker.placements
  }

  private struct Walker {
    let graph: PDFGraph
    let limits: PDFLimits
    let pageID: PDFObjectID
    var placements: [ImagePlacement] = []

    mutating func walk(
      instructions: [ContentInstruction], resources: [PDFName: PDFValue]?,
      transform initial: [Double], depth: Int, container: PDFObjectID?,
      visited: Set<PDFObjectID>, initialClip: ClipRegion = .unbounded
    ) throws {
      var transform = initial
      var clip = initialClip
      var stack: [([Double], ClipRegion)] = []
      var cmOuterTransform: [Double]?
      var pathRect: [Double]?
      var pathSupported = true
      var pathHasSegments = false
      var pendingClip = false
      for (index, instruction) in instructions.enumerated() {
        try Task.checkCancellation()
        switch instruction.operatorName {
        case "q":
          guard stack.count < limits.nesting else {
            throw PDFError(.limitExceeded, "Graphics state stack exceeds the configured limit")
          }
          stack.append((transform, clip))
        case "Q":
          if let saved = stack.popLast() {
            transform = saved.0
            clip = saved.1
          }
        case "cm":
          guard instruction.operands.count == 6 else { break }
          let values = instruction.operands.compactMap { ImageInventory.number(of: $0.value) }
          guard values.count == 6 else { break }
          cmOuterTransform = transform
          transform = ImageInventory.concat(transform, values)
        case "Do":
          if pendingClip { clip = .unsupported }
          guard case .name(let name)? = instruction.operands.first?.value,
            case .dictionary(let xobjects)? = FontValue.resolve(
              resources?[PDFName("XObject")], in: graph),
            case .reference(let objectID)? = xobjects[name],
            case .stream(let stream)? = graph.objects[objectID]
          else { continue }
          let subtype = stream.dictionary[PDFName("Subtype")]
          if subtype == .name(PDFName("Image")) {
            var spans: [Range<Int>] = []
            var simple = false
            var localMatrix = transform
            var outerMatrix = [1.0, 0, 0, 1, 0, 0]
            if index > 0 {
              let candidate = instructions[index - 1]
              if candidate.operatorName == "cm", candidate.operands.count == 6 {
                let local = candidate.operands.compactMap {
                  ImageInventory.number(of: $0.value)
                }
                if local.count == 6 {
                  spans = candidate.operands.map(\.span)
                  localMatrix = local
                  if let cmOuterTransform { outerMatrix = cmOuterTransform }
                  if index - 1 == 0 {
                    simple = true
                  } else if instructions[index - 2].operatorName == "q" {
                    simple = true
                  }
                }
              }
            }
            placements.append(
              ImagePlacement(
                pageID: pageID, instructionIndex: index, resourceName: name, imageID: objectID,
                matrix: transform, localMatrix: localMatrix, outerMatrix: outerMatrix,
                bounds: ImageInventory.bounds(of: transform),
                clippingBounds: clip.bounds,
                hasSupportedClipping: clip.isSupported,
                isDirectlyEditable: depth == 0 && simple
                  && ImageInventory.canvasSafeOuter(outerMatrix),
                depth: depth,
                containerObjectID: container, operandSpans: spans))
            continue
          }
          if subtype == .name(PDFName("Form")) {
            guard depth < limits.nesting else {
              throw PDFError(.limitExceeded, "Form XObject nesting exceeds the configured limit")
            }
            guard !visited.contains(objectID) else {
              throw PDFError(.malformed, "Form XObject cycle detected")
            }
            let decoded = [UInt8](try PDFFilters.decoded(stream, limits: limits))
            let childInstructions = try ContentParser.instructions(in: decoded, limits: limits)
            var childResources = resources
            if case .dictionary(let formResources)? = FontValue.resolve(
              stream.dictionary[PDFName("Resources")], in: graph) {
              childResources = formResources
            }
            var formMatrix: [Double] = [1, 0, 0, 1, 0, 0]
            if case .array(let values)? = stream.dictionary[PDFName("Matrix")], values.count == 6 {
              let parsed = values.compactMap { ImageInventory.number(of: $0) }
              if parsed.count == 6 { formMatrix = parsed }
            }
            var childVisited = visited
            childVisited.insert(objectID)
            let childTransform = ImageInventory.concat(transform, formMatrix)
            let formClip = ImageInventory.formClip(
              stream.dictionary[PDFName("BBox")], transform: childTransform, parent: clip)
            try walk(
              instructions: childInstructions, resources: childResources,
              transform: childTransform, depth: depth + 1,
              container: objectID, visited: childVisited, initialClip: formClip)
          }
        case "re":
          pathHasSegments = true
          guard pathRect == nil, instruction.operands.count == 4 else {
            pathSupported = false
            continue
          }
          let values = instruction.operands.compactMap { ImageInventory.number(of: $0.value) }
          guard values.count == 4,
            let transformed = ImageInventory.transformedRectangle(values, by: transform),
            transformed.axisAligned
          else {
            pathSupported = false
            continue
          }
          pathRect = transformed.bounds
        case "m", "l", "c", "v", "y", "h":
          pathHasSegments = true
          pathSupported = false
        case "W", "W*":
          pendingClip = true
        case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
          if pendingClip {
            if pathSupported, pathHasSegments, let pathRect {
              clip = ImageInventory.intersection(clip, with: pathRect)
            } else {
              clip = .unsupported
            }
          }
          pathRect = nil
          pathSupported = true
          pathHasSegments = false
          pendingClip = false
        default:
          break
        }
      }
    }
  }

  private enum ClipRegion {
    case unbounded
    case rectangle([Double])
    case unsupported

    var bounds: [Double]? {
      if case .rectangle(let bounds) = self { return bounds }
      return nil
    }

    var isSupported: Bool {
      if case .unsupported = self { return false }
      return true
    }
  }

  private static func intersection(_ clip: ClipRegion, with rect: [Double]) -> ClipRegion {
    switch clip {
    case .unbounded:
      return .rectangle(rect)
    case .rectangle(let existing):
      let result = [max(existing[0], rect[0]), max(existing[1], rect[1]),
        min(existing[2], rect[2]), min(existing[3], rect[3])]
      return .rectangle(result)
    case .unsupported:
      return .unsupported
    }
  }

  private static func formClip(
    _ value: PDFValue?, transform: [Double], parent: ClipRegion
  ) -> ClipRegion {
    guard case .array(let values)? = value, values.count == 4 else { return .unsupported }
    let bounds = values.compactMap(number(of:))
    guard bounds.count == 4,
      let transformed = transformedRectangle(bounds, by: transform), transformed.axisAligned
    else { return .unsupported }
    return intersection(parent, with: transformed.bounds)
  }

  private static func transformedRectangle(
    _ values: [Double], by matrix: [Double]
  ) -> (bounds: [Double], axisAligned: Bool)? {
    guard values.count == 4, matrix.count == 6,
      values.allSatisfy(\.isFinite), matrix.allSatisfy(\.isFinite)
    else { return nil }
    let x0 = min(values[0], values[0] + values[2])
    let x1 = max(values[0], values[0] + values[2])
    let y0 = min(values[1], values[1] + values[3])
    let y1 = max(values[1], values[1] + values[3])
    let points = [[x0, y0], [x1, y0], [x0, y1], [x1, y1]].map { point in
      [matrix[0] * point[0] + matrix[2] * point[1] + matrix[4],
        matrix[1] * point[0] + matrix[3] * point[1] + matrix[5]]
    }
    let xs = points.map { $0[0] }
    let ys = points.map { $0[1] }
    let axisAligned = (abs(matrix[1]) < 1e-9 && abs(matrix[2]) < 1e-9)
      || (abs(matrix[0]) < 1e-9 && abs(matrix[3]) < 1e-9)
    return ([xs.min()!, ys.min()!, xs.max()!, ys.max()!], axisAligned)
  }

  /// Affine composition in PDF's `[a b c d e f]` convention: the result
  /// applies `second` first and then `first`.
  static func concat(_ first: [Double], _ second: [Double]) -> [Double] {
    [
      first[0] * second[0] + first[2] * second[1],
      first[1] * second[0] + first[3] * second[1],
      first[0] * second[2] + first[2] * second[3],
      first[1] * second[2] + first[3] * second[3],
      first[0] * second[4] + first[2] * second[5] + first[4],
      first[1] * second[4] + first[3] * second[5] + first[5],
    ]
  }

  /// Canvas movement is expressed in page points. An axis-aligned enclosing
  /// scale lets the writer convert those deltas back to the local `cm`
  /// operands without replacing a page-level transform or clip.
  static func canvasSafeOuter(_ matrix: [Double]) -> Bool {
    matrix.count == 6 && matrix.allSatisfy(\.isFinite)
      && matrix[0] > 0 && matrix[3] > 0
      && abs(matrix[1]) < 1e-9 && abs(matrix[2]) < 1e-9
  }

  static func number(of value: PDFValue) -> Double? {
    switch value {
    case .integer(let raw): return Double(raw)
    case .real(let raw): return raw
    default: return nil
    }
  }

  /// P20-003: index of the topmost (last drawn) placement containing a point.
  public static func placementIndex(
    at point: [Double], in graph: PDFGraph, pageID: PDFObjectID, limits: PDFLimits = PDFLimits()
  ) throws -> Int? {
    let placements = try placements(in: graph, pageID: pageID, limits: limits)
    return placements.lastIndex { $0.contains(point: point) }
  }

  /// Axis-aligned bounds of the image's unit square under its matrix.
  static func bounds(of matrix: [Double]) -> [Double] {
    guard matrix.count == 6 else { return [0, 0, 0, 0] }
    let (a, b, c, d, e, f) = (matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5])
    let xs = [e, a + e, c + e, a + c + e]
    let ys = [f, b + f, d + f, b + d + f]
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
  }

  /// Canonical content-stream number without locale dependence.
  static func numberToken(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    if value.rounded() == value, value.magnitude < 9e15 {
      return String(Int64(value))
    }
    let text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    var trimmed = text
    while trimmed.contains("."), trimmed.hasSuffix("0") { trimmed.removeLast() }
    if trimmed.hasSuffix(".") { trimmed.removeLast() }
    return trimmed
  }
}

/// P20-004: move one image placement by rewriting the translation operands
/// of its immediately preceding `cm`. The matrix shape, scale, rotation,
/// page content around it, and every other placement stay byte-identical.
public struct MoveImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let dx: Double
  public let dy: Double

  public init(pageID: PDFObjectID, placementIndex: Int, dx: Double, dy: Double) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.dx = dx
    self.dy = dy
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Move Image" }

  public func validate(in graph: PDFGraph) throws {
    _ = try placement(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try placement(in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard let inverseOuter = ImageViewMapping.invert(placement.outerMatrix) else {
      throw PDFError(.unsupported, "The image has a singular enclosing transform")
    }
    let localDX = inverseOuter[0] * dx + inverseOuter[2] * dy
    let localDY = inverseOuter[1] * dx + inverseOuter[3] * dy
    let e = ImageInventory.numberToken(placement.localMatrix[4] + localDX)
    let f = ImageInventory.numberToken(placement.localMatrix[5] + localDY)
    var graph = try content.replacing(
      ranges: [
        (placement.operandSpans[4], Array(e.utf8)),
        (placement.operandSpans[5], Array(f.utf8)),
      ], in: graph, limits: limits)
    // P20-024: the OCR layer describes page-space boxes, so a moved image
    // leaves it stale.
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  func placement(in graph: PDFGraph) throws -> ImagePlacement {
    try editableImagePlacement(pageID: pageID, placementIndex: placementIndex, in: graph)
  }
}

/// Shared resolution for commands that must rewrite a simple placement's
/// matrix operands.
func editableImagePlacement(
  pageID: PDFObjectID, placementIndex: Int, in graph: PDFGraph
) throws -> ImagePlacement {
  let placements = try ImageInventory.placements(in: graph, pageID: pageID)
  guard placementIndex >= 0, placementIndex < placements.count else {
    throw PDFError(.malformed, "Image placement index is outside the page")
  }
  let placement = placements[placementIndex]
  guard placement.isDirectlyEditable else {
    throw PDFError(
      .unsupported,
      "The image placement does not use the supported q…cm…Do matrix pattern")
  }
  return placement
}

/// P20-005: resize one image placement by rewriting the scale operands of
/// its matrix. The translation, rotation components, other operands, and
/// every other placement stay byte-identical. Use the uniform initializer
/// to preserve the aspect ratio.
public struct ScaleImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let scaleX: Double
  public let scaleY: Double

  public init(pageID: PDFObjectID, placementIndex: Int, scaleX: Double, scaleY: Double) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.scaleX = scaleX
    self.scaleY = scaleY
  }

  public init(pageID: PDFObjectID, placementIndex: Int, uniformScale: Double) {
    self.init(pageID: pageID, placementIndex: placementIndex, scaleX: uniformScale,
      scaleY: uniformScale)
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Resize Image" }

  public func validate(in graph: PDFGraph) throws {
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard scaleX > 0, scaleY > 0, scaleX.isFinite, scaleY.isFinite else {
      throw PDFError(.malformed, "Image scale factors must be positive finite numbers")
    }
    guard abs(placement.localMatrix[1]) < 1e-9,
      abs(placement.localMatrix[2]) < 1e-9
    else {
      throw PDFError(
        .unsupported, "Resizing a rotated local image matrix needs a corner-specific transform")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let a = ImageInventory.numberToken(placement.localMatrix[0] * scaleX)
    let d = ImageInventory.numberToken(placement.localMatrix[3] * scaleY)
    var graph = try content.replacing(
      ranges: [
        (placement.operandSpans[0], Array(a.utf8)),
        (placement.operandSpans[3], Array(d.utf8)),
      ], in: graph, limits: limits)
    // P20-024: resizing moves every OCR box anchored to this image.
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }
}

/// P20-006: rotate one placement in 90-degree steps about its footprint
/// center by rewriting all six matrix operands. Right angles are exact;
/// every other byte of the page and image data stays identical. Centering
/// keeps the rotated picture where it was: pivoting about the placement
/// origin instead would swing images partly or fully off the page. The
/// view-coordinate half is `ImageViewMapping` (PDF-space handles plus
/// explicit PDF<->view mapping through the caller's view transform); a
/// snapped handle drag feeds the same `degrees` this command applies.
public struct RotateImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let degrees: Int

  public init(pageID: PDFObjectID, placementIndex: Int, degrees: Int) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.degrees = degrees
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Rotate Image" }

  public func validate(in graph: PDFGraph) throws {
    _ = try editableImagePlacement(pageID: pageID, placementIndex: placementIndex, in: graph)
    guard degrees % 90 == 0 else {
      throw PDFError(.malformed, "Image rotation must be a multiple of 90 degrees")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let rotation: [Double]
    switch ((degrees % 360) + 360) % 360 {
    case 0: rotation = [1, 0, 0, 1, 0, 0]
    case 90: rotation = [0, 1, -1, 0, 0, 0]
    case 180: rotation = [-1, 0, 0, -1, 0, 0]
    default: rotation = [0, -1, 1, 0, 0, 0]
    }
    let m = placement.matrix
    let local = [m[0], m[1], m[2], m[3], 0, 0]
    let rotated = ImageInventory.concat(rotation, local)
    // Keep the footprint centered: the unit square's center maps to the
    // footprint center before and after, so only orientation changes.
    let bounds = ImageInventory.bounds(of: m)
    let center = [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2]
    let e = center[0] - (rotated[0] + rotated[2]) / 2
    let f = center[1] - (rotated[1] + rotated[3]) / 2
    let desiredPage = [rotated[0], rotated[1], rotated[2], rotated[3], e, f]
    guard let inverseOuter = ImageViewMapping.invert(placement.outerMatrix) else {
      throw PDFError(.unsupported, "The image has a singular enclosing transform")
    }
    let result = ImageInventory.concat(inverseOuter, desiredPage)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let ranges = zip(placement.operandSpans, result).map {
      ($0.0, Array(ImageInventory.numberToken($0.1).utf8))
    }
    var graph = try content.replacing(ranges: ranges, in: graph, limits: limits)
    // P20-024: rotation reorients the image under its OCR boxes.
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }
}

/// IMG-01: mirror one image placement around its own footprint center. The
/// image data and every other placement stay byte-identical.
public struct FlipImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let horizontal: Bool

  public init(pageID: PDFObjectID, placementIndex: Int, horizontal: Bool) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.horizontal = horizontal
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { horizontal ? "Flip Image Horizontally" : "Flip Image Vertically" }

  public func validate(in graph: PDFGraph) throws {
    _ = try editableImagePlacement(pageID: pageID, placementIndex: placementIndex, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let mirror: [Double] = horizontal ? [-1, 0, 0, 1, 0, 0] : [1, 0, 0, -1, 0, 0]
    let m = placement.matrix
    let local = [m[0], m[1], m[2], m[3], 0, 0]
    let mirrored = ImageInventory.concat(mirror, local)
    // Keep the footprint centered: only the orientation changes.
    let bounds = ImageInventory.bounds(of: m)
    let center = [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2]
    let e = center[0] - (mirrored[0] + mirrored[2]) / 2
    let f = center[1] - (mirrored[1] + mirrored[3]) / 2
    let desiredPage = [mirrored[0], mirrored[1], mirrored[2], mirrored[3], e, f]
    guard let inverseOuter = ImageViewMapping.invert(placement.outerMatrix) else {
      throw PDFError(.unsupported, "The image has a singular enclosing transform")
    }
    let result = ImageInventory.concat(inverseOuter, desiredPage)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let ranges = zip(placement.operandSpans, result).map {
      ($0.0, Array(ImageInventory.numberToken($0.1).utf8))
    }
    var graph = try content.replacing(ranges: ranges, in: graph, limits: limits)
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }
}

/// P20-007: replace the pixel data of one image instance with new DeviceRGB
/// 8-bit samples. The image object is copied before it is changed and only
/// the target page's resource mapping points at the copy, so other pages or
/// placements that share the original image keep it byte-identical.
public struct ReplaceImageDataCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let width: Int
  public let height: Int
  public let rgb8: Data
  public let alpha8: Data?

  public init(
    pageID: PDFObjectID, placementIndex: Int, width: Int, height: Int, rgb8: Data,
    alpha8: Data? = nil
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.alpha8 = alpha8
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Replace Image" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolve(in: graph, limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let context = try resolve(in: graph, limits: limits)
    var graph = graph
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1

    var dictionary = context.imageDictionary
    dictionary.removeValue(forKey: PDFName("Filter"))
    dictionary.removeValue(forKey: PDFName("DecodeParms"))
    dictionary.removeValue(forKey: PDFName("DP"))
    dictionary.removeValue(forKey: PDFName("Length"))
    dictionary[PDFName("Width")] = .integer(Int64(width))
    dictionary[PDFName("Height")] = .integer(Int64(height))
    dictionary[PDFName("ColorSpace")] = .name(PDFName("DeviceRGB"))
    dictionary[PDFName("BitsPerComponent")] = .integer(8)
    dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
    dictionary.removeValue(forKey: PDFName("SMask"))
    let bytes = try PDFFilters.encodeFlate(rgb8, limits: limits)
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    let newImageID = PDFObjectID(nextNumber)
    nextNumber += 1
    if let alpha8 {
      let maskID = PDFObjectID(nextNumber)
      nextNumber += 1
      let maskBytes = try PDFFilters.encodeFlate(alpha8, limits: limits)
      graph.objects[maskID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(Int64(width)),
            PDFName("Height"): .integer(Int64(height)),
            PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("Filter"): .name(PDFName("FlateDecode")),
            PDFName("Length"): .integer(Int64(maskBytes.count)),
          ], bytes: maskBytes))
      dictionary[PDFName("SMask")] = .reference(maskID)
    }
    graph.objects[newImageID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))

    // Add a fresh resource name for this instance and point only the target
    // draw at it. Other draws and pages keep the original name and image.
    let newName = Self.uniqueResourceName(
      base: context.placement.resourceName, existing: context.xobjectNames)
    var page = context.page
    switch context.resources {
    case .direct(let resources):
      var updated = resources
      updated[PDFName("XObject")] = Self.addingXObject(
        resources[PDFName("XObject")], name: newName, to: newImageID)
      page[PDFName("Resources")] = .dictionary(updated)
      graph.objects[pageID] = .dictionary(page)
    case .reference(_, let resources):
      var updated = resources
      updated[PDFName("XObject")] = Self.addingXObject(
        resources[PDFName("XObject")], name: newName, to: newImageID)
      let newResourcesID = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[newResourcesID] = .dictionary(updated)
      page[PDFName("Resources")] = .reference(newResourcesID)
      graph.objects[pageID] = .dictionary(page)
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))

    // Rewrite the targeted draw's resource name in the content stream.
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let instruction = content.instructions[context.placement.instructionIndex]
    guard let operand = instruction.operands.first, case .name = operand.value else {
      throw PDFError(.malformed, "The image draw lost its resource operand")
    }
    let nameBytes = Array(("/" + String(decoding: newName.bytes, as: UTF8.self)).utf8)
    graph = try content.replacing(
      range: operand.span, with: nameBytes, in: graph, limits: limits)
    // P20-024: new pixels invalidate a generated OCR layer describing the old ones.
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  private enum ResourceResolution {
    case direct([PDFName: PDFValue])
    case reference(PDFObjectID, [PDFName: PDFValue])
  }

  private struct Context {
    let page: [PDFName: PDFValue]
    let resources: ResourceResolution
    let placement: ImagePlacement
    let imageDictionary: [PDFName: PDFValue]
    let xobjectNames: Set<PDFName>
  }

  private func resolve(in graph: PDFGraph, limits: PDFLimits) throws -> Context {
    guard width >= 1, width <= 10_000, height >= 1, height <= 10_000,
      rgb8.count == width * height * 3
    else {
      throw PDFError(.malformed, "Replacement image dimensions do not match its pixel data")
    }
    if let alpha8, alpha8.count != width * height {
      throw PDFError(.malformed, "Replacement image alpha does not match its dimensions")
    }
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "Image placement index is outside the page")
    }
    let placement = placements[placementIndex]
    guard placement.depth == 0 else {
      throw PDFError(
        .unsupported,
        "Replacing an image inside a form XObject needs copy-on-write forms, which is not implemented yet"
      )
    }
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .stream(let image)? = graph.objects[placement.imageID]
    else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    let imageDictionary = image.dictionary
    // IMG-03: a soft mask is replaced together with the image samples only
    // when replacement alpha is supplied. Dropping it silently would change
    // alpha semantics; the explicit conversion command can drop it on request.
    if imageDictionary[PDFName("SMask")] != nil, alpha8 == nil {
      throw PDFError(
        .unsupported,
        "This image carries a soft mask. Provide replacement alpha, or use Replace Image with RGB Conversion with the explicit discard option")
    }
    // Other masks change the meaning of the samples (stencil/color-key/decode),
    // so replacing those still needs an explicit workflow.
    for key in ["ImageMask", "Mask", "Decode"] where imageDictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This profile cannot replace stencil, color-key or decoded images")
    }
    guard imageDictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")),
      imageDictionary[PDFName("BitsPerComponent")] == .integer(8)
    else {
      throw PDFError(
        .unsupported, "This profile replaces only DeviceRGB 8-bit images")
    }
    let resources: ResourceResolution
    switch page[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      resources = .direct(dictionary)
    case .reference(let resourcesID)?:
      guard case .dictionary(let dictionary)? = graph.objects[resourcesID] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      resources = .reference(resourcesID, dictionary)
    default:
      throw PDFError(.malformed, "Page has no resources")
    }
    let resourcesDictionary: [PDFName: PDFValue]
    switch resources {
    case .direct(let dictionary): resourcesDictionary = dictionary
    case .reference(_, let dictionary): resourcesDictionary = dictionary
    }
    var xobjectNames: Set<PDFName> = []
    if case .dictionary(let xobjects)? = resourcesDictionary[PDFName("XObject")] {
      xobjectNames = Set(xobjects.keys)
    }
    return Context(
      page: page, resources: resources, placement: placement,
      imageDictionary: imageDictionary, xobjectNames: xobjectNames)
  }

  /// Fresh, collision-free resource name for a per-instance replacement.
  private static func uniqueResourceName(base: PDFName, existing: Set<PDFName>) -> PDFName {
    var counter = 1
    while true {
      let candidate = PDFName(bytes: base.bytes + Array("-r\(counter)".utf8))
      if !existing.contains(candidate) { return candidate }
      counter += 1
    }
  }

  private static func addingXObject(
    _ value: PDFValue?, name: PDFName, to newImageID: PDFObjectID
  ) -> PDFValue {
    guard case .dictionary(var xobjects)? = value else {
      return .dictionary([name: .reference(newImageID)])
    }
    xobjects[name] = .reference(newImageID)
    return .dictionary(xobjects)
  }
}

/// P20-008: deliberately replace the shared image object so every placement
/// and page that references it shows the new pixels. This is the explicit
/// "all instances" counterpart to the per-instance copy-on-write command.
public struct ReplaceSharedImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let width: Int
  public let height: Int
  public let rgb8: Data
  public let alpha8: Data?

  public init(
    pageID: PDFObjectID, placementIndex: Int, width: Int, height: Int, rgb8: Data,
    alpha8: Data? = nil
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.alpha8 = alpha8
  }

  /// P17-012/P17-022: replacing a shared image object changes every page that
  /// places it, so the change set covers them all (the edit is intentional,
  /// not accidental).
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    guard let imageID = try? resolveImage(in: graph),
      let pages = try? PDFPageTree.pageIDs(in: graph)
    else { return [pageID] }
    var result: [PDFObjectID] = []
    for id in pages {
      guard let placements = try? ImageInventory.placements(in: graph, pageID: id),
        placements.contains(where: { $0.imageID == imageID })
      else { continue }
      result.append(id)
    }
    return result.isEmpty ? [pageID] : result
  }
  public var name: String { "Replace Shared Image" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolveImage(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let imageID = try resolveImage(in: graph)
    guard case .stream(let image)? = graph.objects[imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    var graph = graph
    var dictionary = image.dictionary
    dictionary.removeValue(forKey: PDFName("Filter"))
    dictionary.removeValue(forKey: PDFName("DecodeParms"))
    dictionary.removeValue(forKey: PDFName("DP"))
    dictionary.removeValue(forKey: PDFName("Length"))
    dictionary[PDFName("Width")] = .integer(Int64(width))
    dictionary[PDFName("Height")] = .integer(Int64(height))
    dictionary[PDFName("ColorSpace")] = .name(PDFName("DeviceRGB"))
    dictionary[PDFName("BitsPerComponent")] = .integer(8)
    dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
    dictionary.removeValue(forKey: PDFName("SMask"))
    let bytes = try PDFFilters.encodeFlate(rgb8, limits: limits)
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    graph.objects[imageID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))
    if let alpha8 {
      let maskID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
      let maskBytes = try PDFFilters.encodeFlate(alpha8, limits: limits)
      graph.objects[maskID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(Int64(width)),
            PDFName("Height"): .integer(Int64(height)),
            PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("Filter"): .name(PDFName("FlateDecode")),
            PDFName("Length"): .integer(Int64(maskBytes.count)),
          ], bytes: maskBytes))
      var updated = dictionary
      updated[PDFName("SMask")] = .reference(maskID)
      graph.objects[imageID] = .stream(PDFStream(dictionary: updated, bytes: bytes))
      graph.trailer[PDFName("Size")] = .integer(Int64(maskID.number + 1))
    }
    // P20-024: new pixels invalidate generated OCR layers on every page that
    // shows the shared image.
    for page in affectedPageIDs(in: graph) {
      try ImageOCRRelations.invalidateGeneratedLayer(pageID: page, in: &graph)
    }
    return graph
  }

  /// Resolve the shared image object behind one placement.
  private func resolveImage(in graph: PDFGraph) throws -> PDFObjectID {
    guard width >= 1, width <= 10_000, height >= 1, height <= 10_000,
      rgb8.count == width * height * 3
    else {
      throw PDFError(.malformed, "Replacement image dimensions do not match its pixel data")
    }
    if let alpha8, alpha8.count != width * height {
      throw PDFError(.malformed, "Replacement image alpha does not match its dimensions")
    }
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "Image placement index is outside the page")
    }
    let placement = placements[placementIndex]
    guard case .stream(let image)? = graph.objects[placement.imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    // IMG-03: never drop a soft mask silently on the shared object either.
    if image.dictionary[PDFName("SMask")] != nil, alpha8 == nil {
      throw PDFError(
        .unsupported,
        "This shared image carries a soft mask. Provide replacement alpha, or use Replace Image with RGB Conversion with the explicit discard option")
    }
    // Stencil, color-key and decode semantics remain outside this profile.
    for key in ["ImageMask", "Mask", "Decode"] where image.dictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This profile cannot replace stencil, color-key or decoded images")
    }
    guard image.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")),
      image.dictionary[PDFName("BitsPerComponent")] == .integer(8)
    else {
      throw PDFError(.unsupported, "Only 8-bit DeviceRGB images can be replaced in this profile")
    }
    return placement.imageID
  }
}
