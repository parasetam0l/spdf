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
  public let matrix: [Double]
  public let bounds: [Double]
  /// True when the placement is a page-level `q … cm /Name Do …` pattern with
  /// an identity outer transform, so commands can rewrite its matrix
  /// operands in place.
  public let isDirectlyEditable: Bool
  /// Nesting depth: 0 for page content, >0 inside form XObjects.
  public let depth: Int
  /// The form XObject stream containing a nested draw; nil for page content.
  public let containerObjectID: PDFObjectID?
  let operandSpans: [Range<Int>]

  /// P20-003: exact hit test through the inverse placement matrix, valid for
  /// rotated and skewed placements while the matrix stays invertible.
  public func contains(point: [Double]) -> Bool {
    guard matrix.count == 6 else { return false }
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
      visited: Set<PDFObjectID>
    ) throws {
      var transform = initial
      var stack: [[Double]] = []
      for (index, instruction) in instructions.enumerated() {
        try Task.checkCancellation()
        switch instruction.operatorName {
        case "q":
          guard stack.count < limits.nesting else {
            throw PDFError(.limitExceeded, "Graphics state stack exceeds the configured limit")
          }
          stack.append(transform)
        case "Q":
          if let saved = stack.popLast() { transform = saved }
        case "cm":
          guard instruction.operands.count == 6 else { break }
          let values = instruction.operands.compactMap { ImageInventory.number(of: $0.value) }
          guard values.count == 6 else { break }
          transform = ImageInventory.concat(transform, values)
        case "Do":
          guard case .name(let name)? = instruction.operands.first?.value,
            let entry = resources?[PDFName("XObject")],
            case .dictionary(let xobjects) = entry,
            case .reference(let objectID)? = xobjects[name],
            case .stream(let stream)? = graph.objects[objectID]
          else { continue }
          let subtype = stream.dictionary[PDFName("Subtype")]
          if subtype == .name(PDFName("Image")) {
            var spans: [Range<Int>] = []
            var simple = false
            if index > 0 {
              let candidate = instructions[index - 1]
              if candidate.operatorName == "cm", candidate.operands.count == 6 {
                let local = candidate.operands.compactMap {
                  ImageInventory.number(of: $0.value)
                }
                if local.count == 6 {
                  spans = candidate.operands.map(\.span)
                  if index - 1 == 0 {
                    simple = true
                  } else if instructions[index - 2].operatorName == "q" {
                    simple = true
                  }
                  if simple, !ImageInventory.matricesEqual(transform, local) {
                    simple = false
                  }
                }
              }
            }
            placements.append(
              ImagePlacement(
                pageID: pageID, instructionIndex: index, resourceName: name, imageID: objectID,
                matrix: transform, bounds: ImageInventory.bounds(of: transform),
                isDirectlyEditable: depth == 0 && simple, depth: depth,
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
            if case .dictionary(let formResources)? = stream.dictionary[PDFName("Resources")] {
              childResources = formResources
            }
            var formMatrix: [Double] = [1, 0, 0, 1, 0, 0]
            if case .array(let values)? = stream.dictionary[PDFName("Matrix")], values.count == 6 {
              let parsed = values.compactMap { ImageInventory.number(of: $0) }
              if parsed.count == 6 { formMatrix = parsed }
            }
            var childVisited = visited
            childVisited.insert(objectID)
            try walk(
              instructions: childInstructions, resources: childResources,
              transform: ImageInventory.concat(transform, formMatrix), depth: depth + 1,
              container: objectID, visited: childVisited)
          }
        default:
          break
        }
      }
    }
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

  static func matricesEqual(_ lhs: [Double], _ rhs: [Double]) -> Bool {
    guard lhs.count == 6, rhs.count == 6 else { return false }
    return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1e-9 }
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
    let e = ImageInventory.numberToken(placement.matrix[4] + dx)
    let f = ImageInventory.numberToken(placement.matrix[5] + dy)
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
    _ = try editableImagePlacement(pageID: pageID, placementIndex: placementIndex, in: graph)
    guard scaleX > 0, scaleY > 0, scaleX.isFinite, scaleY.isFinite else {
      throw PDFError(.malformed, "Image scale factors must be positive finite numbers")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let a = ImageInventory.numberToken(placement.matrix[0] * scaleX)
    let d = ImageInventory.numberToken(placement.matrix[3] * scaleY)
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
    let result = [rotated[0], rotated[1], rotated[2], rotated[3], e, f]
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

  public init(pageID: PDFObjectID, placementIndex: Int, width: Int, height: Int, rgb8: Data) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.width = width
    self.height = height
    self.rgb8 = rgb8
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
    let bytes = try PDFFilters.encodeFlate(rgb8, limits: limits)
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    let newImageID = PDFObjectID(nextNumber)
    nextNumber += 1
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
    case .reference(let resourcesID, let resources):
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
    for key in ["ImageMask", "Mask", "SMask", "Decode"] where imageDictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This profile cannot replace images with masks or decode arrays")
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

  public init(pageID: PDFObjectID, placementIndex: Int, width: Int, height: Int, rgb8: Data) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.width = width
    self.height = height
    self.rgb8 = rgb8
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
    let bytes = try PDFFilters.encodeFlate(rgb8, limits: limits)
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    graph.objects[imageID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))
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
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "Image placement index is outside the page")
    }
    let placement = placements[placementIndex]
    guard case .stream(let image)? = graph.objects[placement.imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    for key in ["ImageMask", "Mask", "SMask", "Decode"] where image.dictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This profile cannot replace images with masks or decode arrays")
    }
    guard image.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")),
      image.dictionary[PDFName("BitsPerComponent")] == .integer(8)
    else {
      throw PDFError(.unsupported, "Only 8-bit DeviceRGB images can be replaced in this profile")
    }
    return placement.imageID
  }
}
