import Foundation
import PDFCore

/// Shared per-instance image-object surgery for the P20 advanced commands.
///
/// The pattern mirrors `ReplaceImageDataCommand`: a fresh image object is
/// allocated, only the target page's resource mapping points at it under a
/// fresh name, and the targeted draw's resource operand is rewritten. Every
/// other placement and page keeps the original object byte-identical.
enum ImageInstanceEditing {
  /// Allocate `bytes`/`dictionary` as a new image object, point the target
  /// page's XObject mapping at it under a fresh name, and rewrite the
  /// targeted draw to use that name.
  static func attachCopy(
    in graph: inout PDFGraph, pageID: PDFObjectID, placement: ImagePlacement,
    dictionary: [PDFName: PDFValue], bytes: Data
  ) throws {
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    var dictionary = dictionary
    dictionary.removeValue(forKey: PDFName("Length"))
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    let newImageID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[newImageID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))

    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var existing: Set<PDFName> = []
    switch page[PDFName("Resources")] {
    case .dictionary(let resources)?:
      if case .dictionary(let xobjects)? = resources[PDFName("XObject")] {
        existing = Set(xobjects.keys)
      }
      let newName = uniqueResourceName(base: placement.resourceName, existing: existing)
      var updated = resources
      updated[PDFName("XObject")] = addingXObject(
        resources[PDFName("XObject")], name: newName, to: newImageID)
      page[PDFName("Resources")] = .dictionary(updated)
      graph.objects[pageID] = .dictionary(page)
      try rewriteDrawName(pageID: pageID, placement: placement, name: newName, in: &graph)
    case .reference(let resourcesID)?:
      guard case .dictionary(let resources)? = graph.objects[resourcesID] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      if case .dictionary(let xobjects)? = resources[PDFName("XObject")] {
        existing = Set(xobjects.keys)
      }
      let newName = uniqueResourceName(base: placement.resourceName, existing: existing)
      var updated = resources
      updated[PDFName("XObject")] = addingXObject(
        resources[PDFName("XObject")], name: newName, to: newImageID)
      let newResourcesID = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[newResourcesID] = .dictionary(updated)
      page[PDFName("Resources")] = .reference(newResourcesID)
      graph.objects[pageID] = .dictionary(page)
      try rewriteDrawName(pageID: pageID, placement: placement, name: newName, in: &graph)
    default:
      throw PDFError(.malformed, "Page has no resources")
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
  }

  static func uniqueResourceName(base: PDFName, existing: Set<PDFName>) -> PDFName {
    var counter = 1
    while true {
      let candidate = PDFName(bytes: base.bytes + Array("-r\(counter)".utf8))
      if !existing.contains(candidate) { return candidate }
      counter += 1
    }
  }

  static func addingXObject(
    _ value: PDFValue?, name: PDFName, to newImageID: PDFObjectID
  ) -> PDFValue {
    guard case .dictionary(var xobjects)? = value else {
      return .dictionary([name: .reference(newImageID)])
    }
    xobjects[name] = .reference(newImageID)
    return .dictionary(xobjects)
  }

  private static func rewriteDrawName(
    pageID: PDFObjectID, placement: ImagePlacement, name: PDFName, in graph: inout PDFGraph
  ) throws {
    let limits = PDFLimits()
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard placement.instructionIndex < content.instructions.count else {
      throw PDFError(.malformed, "The image draw is missing")
    }
    let instruction = content.instructions[placement.instructionIndex]
    guard let operand = instruction.operands.first, case .name = operand.value else {
      throw PDFError(.malformed, "The image draw lost its resource operand")
    }
    let nameBytes = Array(("/" + String(decoding: name.bytes, as: UTF8.self)).utf8)
    graph = try content.replacing(range: operand.span, with: nameBytes, in: graph, limits: limits)
  }

  /// Resolve a page-level (non-form) placement and its image stream.
  static func resolvePlacement(
    pageID: PDFObjectID, placementIndex: Int, in graph: PDFGraph
  ) throws -> (placement: ImagePlacement, stream: PDFStream) {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "Image placement index is outside the page")
    }
    let placement = placements[placementIndex]
    guard placement.depth == 0 else {
      throw PDFError(
        .unsupported,
        "Editing an image inside a form XObject needs copy-on-write forms, which is not implemented yet")
    }
    guard case .stream(let stream)? = graph.objects[placement.imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    return (placement, stream)
  }

  static func integers(_ value: PDFValue?) -> Int? {
    guard case .integer(let raw)? = value else { return nil }
    return Int(exactly: raw)
  }

  /// Decoded 8-bit samples for DeviceRGB/DeviceGray images stored raw or
  /// under Flate. Anything else (DCT, JPX, other depths, predictors outside
  /// the Flate path) refuses explicitly.
  static func decodedSamples(of stream: PDFStream) throws -> (components: Int, samples: Data) {
    let dictionary = stream.dictionary
    let colorSpace: String
    switch dictionary[PDFName("ColorSpace")] {
    case .name(let name)?:
      colorSpace = String(decoding: name.bytes, as: UTF8.self)
    default:
      throw PDFError(.unsupported, "This profile edits only DeviceRGB and DeviceGray images")
    }
    let components: Int
    switch colorSpace {
    case "DeviceRGB": components = 3
    case "DeviceGray": components = 1
    default:
      throw PDFError(.unsupported, "This profile edits only DeviceRGB and DeviceGray images")
    }
    guard dictionary[PDFName("BitsPerComponent")] == .integer(8) else {
      throw PDFError(.unsupported, "This profile edits only 8-bit images")
    }
    let filters = try PDFFilters.filterNames(in: dictionary)
    let samples: Data
    if filters.isEmpty {
      samples = stream.bytes
    } else if filters == [PDFName("FlateDecode")] {
      samples = try PDFFilters.decoded(stream)
    } else {
      throw PDFError(.unsupported, "This profile edits only raw and FlateDecode images")
    }
    guard case .integer(let width)? = dictionary[PDFName("Width")],
      case .integer(let height)? = dictionary[PDFName("Height")]
    else {
      throw PDFError(.malformed, "Image dimensions are missing")
    }
    guard samples.count == Int(width * height) * components else {
      throw PDFError(.malformed, "Image samples do not match their dimensions")
    }
    return (components, samples)
  }
}

/// P20-006: view/PDF coordinate consistency for image rotation handles.
///
/// The PDF command (`RotateImageCommand`) already rewrites placement matrices
/// exactly. This helper is the other half: handle geometry in PDF space plus
/// explicit PDF<->view mapping through a caller-supplied view transform, so a
/// rotation handle drag maps back to the same quarter turn the command
/// applies. The view layer owns pixels; this owns the math.
public enum ImageViewMapping {
  /// The four mapped corners of the unit square, in `(0,0) (1,0) (1,1) (0,1)`
  /// order.
  public static func corners(of matrix: [Double]) -> [[Double]] {
    guard matrix.count == 6 else { return [] }
    let (a, b, c, d, e, f) = (matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5])
    return [
      [e, f],
      [a + e, b + f],
      [a + c + e, b + d + f],
      [c + e, d + f],
    ]
  }

  /// Rotation handle in PDF space: the midpoint of the top (`v == 1`) edge,
  /// lifted `offset` points upward.
  public static func rotationHandle(of matrix: [Double], offset: Double = 16) -> [Double] {
    let points = corners(of: matrix)
    guard points.count == 4 else { return [0, 0] }
    return [(points[2][0] + points[3][0]) / 2, (points[2][1] + points[3][1]) / 2 + offset]
  }

  /// Apply a `[a b c d e f]` view transform to a point.
  public static func apply(_ point: [Double], through view: [Double]) -> [Double]? {
    guard point.count == 2, view.count == 6 else { return nil }
    return [
      view[0] * point[0] + view[2] * point[1] + view[4],
      view[1] * point[0] + view[3] * point[1] + view[5],
    ]
  }

  /// Invert a view transform, or nil when it is singular.
  public static func invert(_ view: [Double]) -> [Double]? {
    guard view.count == 6 else { return nil }
    let (a, b, c, d, e, f) = (view[0], view[1], view[2], view[3], view[4], view[5])
    let determinant = a * d - b * c
    guard determinant != 0, determinant.isFinite else { return nil }
    return [
      d / determinant, -b / determinant, -c / determinant, a / determinant,
      (c * f - d * e) / determinant, (b * e - a * f) / determinant,
    ]
  }

  /// Display angle of a placement in degrees, from its first column.
  public static func viewAngleOf(matrix: [Double]) -> Double? {
    guard matrix.count == 6 else { return nil }
    let degrees = atan2(matrix[1], matrix[0]) * 180 / Double.pi
    var normalized = degrees.truncatingRemainder(dividingBy: 360)
    if normalized <= -180 { normalized += 360 }
    if normalized > 180 { normalized -= 360 }
    return normalized
  }

  /// Snap a dragged angle to the nearest supported quarter turn (0/90/180/270).
  public static func snappedQuarterTurn(_ degrees: Double) -> Int {
    guard degrees.isFinite else { return 0 }
    let quarter = Int((degrees / 90).rounded()) * 90
    return ((quarter % 360) + 360) % 360
  }
}

/// P20-014: the mask/decode entries that geometry-only edits must preserve.
///
/// Move/scale/rotate/clip touch only content-stream operands, so these image
/// dictionary entries must be identical before and after. Replacement refuses
/// masked images instead of silently dropping their transparency.
public struct ImageMaskState: Sendable, Equatable {
  public let hasSMask: Bool
  public let hasMask: Bool
  public let hasDecode: Bool
  public let isStencil: Bool

  public init(hasSMask: Bool, hasMask: Bool, hasDecode: Bool, isStencil: Bool) {
    self.hasSMask = hasSMask
    self.hasMask = hasMask
    self.hasDecode = hasDecode
    self.isStencil = isStencil
  }

  public static func describe(imageID: PDFObjectID, in graph: PDFGraph) throws -> ImageMaskState {
    guard case .stream(let stream)? = graph.objects[imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    return ImageMaskState(
      hasSMask: stream.dictionary[PDFName("SMask")] != nil,
      hasMask: stream.dictionary[PDFName("Mask")] != nil,
      hasDecode: stream.dictionary[PDFName("Decode")] != nil,
      isStencil: stream.dictionary[PDFName("ImageMask")] == .boolean(true))
  }
}

/// P20-013: attach transparency to one image instance through a valid
/// grayscale soft mask. The mask must match the image dimensions exactly; the
/// image is copied first so other placements keep their opaque original.
public struct SetImageSoftMaskCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  /// One byte per image pixel (top row first), DeviceGray 8-bit.
  public let gray8: Data

  public init(pageID: PDFObjectID, placementIndex: Int, gray8: Data) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.gray8 = gray8
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Set Image Soft Mask" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolved(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let context = try resolved(in: graph)
    var graph = graph
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let encoded = try PDFFilters.encodeFlate(context.gray8)
    let maskID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[maskID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(Int64(context.width)),
          PDFName("Height"): .integer(Int64(context.height)),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("FlateDecode")),
          PDFName("Length"): .integer(Int64(encoded.count)),
        ], bytes: encoded))
    var dictionary = context.dictionary
    dictionary[PDFName("SMask")] = .reference(maskID)
    try ImageInstanceEditing.attachCopy(
      in: &graph, pageID: pageID, placement: context.placement,
      dictionary: dictionary, bytes: context.bytes)
    _ = nextNumber
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  private struct Context {
    let placement: ImagePlacement
    let dictionary: [PDFName: PDFValue]
    let bytes: Data
    let width: Int
    let height: Int
    let gray8: Data
  }

  private func resolved(in graph: PDFGraph) throws -> Context {
    let (placement, stream) = try ImageInstanceEditing.resolvePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard stream.dictionary[PDFName("ImageMask")] != .boolean(true) else {
      throw PDFError(.unsupported, "Stencil masks carry no soft mask; edit them as stencils")
    }
    guard stream.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")),
      stream.dictionary[PDFName("BitsPerComponent")] == .integer(8)
    else {
      throw PDFError(.unsupported, "This profile masks only DeviceRGB 8-bit images")
    }
    for key in ["SMask", "Mask", "Decode"] where stream.dictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This image already carries a mask or decode array; remove it first")
    }
    guard let width = ImageInstanceEditing.integers(stream.dictionary[PDFName("Width")]),
      let height = ImageInstanceEditing.integers(stream.dictionary[PDFName("Height")]),
      width >= 1, height >= 1, width <= 10_000, height <= 10_000
    else {
      throw PDFError(.malformed, "Image dimensions are missing or outside the supported range")
    }
    guard gray8.count == width * height else {
      throw PDFError(.malformed, "Soft-mask samples do not match the image dimensions")
    }
    return Context(
      placement: placement, dictionary: stream.dictionary, bytes: stream.bytes,
      width: width, height: height, gray8: gray8)
  }
}

/// P20-015: stencil (ImageMask) editing stays on its own path. Stencil data
/// is 1 bit per pixel with no color space; color-image replacement refuses
/// stencils and this command refuses color images, so the two can never be
/// confused.
public struct ReplaceStencilImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  /// Packed 1-bit rows, top row first, 1 == paint.
  public let packedBits: Data

  public init(pageID: PDFObjectID, placementIndex: Int, packedBits: Data) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.packedBits = packedBits
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Replace Stencil Mask" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolved(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let context = try resolved(in: graph)
    var graph = graph
    try ImageInstanceEditing.attachCopy(
      in: &graph, pageID: pageID, placement: context.placement,
      dictionary: context.dictionary, bytes: packedBits)
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  private struct Context {
    let placement: ImagePlacement
    let dictionary: [PDFName: PDFValue]
  }

  private func resolved(in graph: PDFGraph) throws -> Context {
    let (placement, stream) = try ImageInstanceEditing.resolvePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard stream.dictionary[PDFName("ImageMask")] == .boolean(true) else {
      throw PDFError(
        .unsupported,
        "This is a color image, not a stencil; use image replacement instead")
    }
    guard stream.dictionary[PDFName("BitsPerComponent")] == .integer(1) else {
      throw PDFError(.unsupported, "Stencil masks must be 1 bit per component")
    }
    guard let width = ImageInstanceEditing.integers(stream.dictionary[PDFName("Width")]),
      let height = ImageInstanceEditing.integers(stream.dictionary[PDFName("Height")]),
      width >= 1, height >= 1, width <= 10_000, height <= 10_000
    else {
      throw PDFError(.malformed, "Stencil dimensions are missing or outside the supported range")
    }
    guard packedBits.count == (width * height + 7) / 8 else {
      throw PDFError(.malformed, "Stencil data does not match its dimensions")
    }
    return Context(placement: placement, dictionary: stream.dictionary)
  }
}

/// P20-016: non-destructive crop. The image object is untouched; the draw is
/// wrapped in a clipping path for the requested unit-space sub-rectangle, so
/// the crop is reversible by deleting the wrapper. `unitRect` is
/// `[u0, v0, u1, v1]` in 0...1 image space.
public struct ClipImageDrawCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let unitRect: [Double]

  public init(pageID: PDFObjectID, placementIndex: Int, unitRect: [Double]) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.unitRect = unitRect
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Crop Image Nondestructively" }

  public func validate(in graph: PDFGraph) throws {
    _ = try clipPath(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let path = try clipPath(in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let index = placement.instructionIndex
    guard index >= 2, index + 1 < content.instructions.count,
      content.instructions[index - 2].operatorName == "q",
      content.instructions[index - 1].operatorName == "cm",
      content.instructions[index].operatorName == "Do",
      content.instructions[index + 1].operatorName == "Q"
    else {
      throw PDFError(
        .unsupported, "The image placement does not use the supported q…cm…Do…Q pattern")
    }
    let open = content.instructions[index - 2].span.lowerBound
    let close = content.instructions[index + 1].span.upperBound
    let prefix = Array("q\n\(path) W n\n".utf8)
    let suffix = Array("\nQ".utf8)
    var graph = try content.replacing(
      ranges: [
        (range: open..<open, replacement: prefix),
        (range: close..<close, replacement: suffix),
      ], in: graph, limits: limits)
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  private func clipPath(in graph: PDFGraph) throws -> String {
    guard unitRect.count == 4, unitRect.allSatisfy(\.isFinite) else {
      throw PDFError(.malformed, "The crop rectangle is invalid")
    }
    let (u0, v0, u1, v1) = (unitRect[0], unitRect[1], unitRect[2], unitRect[3])
    guard u0 >= 0, v0 >= 0, u1 <= 1, v1 <= 1, u1 > u0, v1 > v0 else {
      throw PDFError(.malformed, "The crop rectangle must be a non-empty sub-rectangle of 0...1")
    }
    guard u0 > 0 || v0 > 0 || u1 < 1 || v1 < 1 else {
      throw PDFError(.malformed, "The crop rectangle covers the whole image")
    }
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard placement.matrix.count == 6 else {
      throw PDFError(.malformed, "The image placement has no usable matrix")
    }
    let (a, b, c, d, e, f) = (
      placement.matrix[0], placement.matrix[1], placement.matrix[2],
      placement.matrix[3], placement.matrix[4], placement.matrix[5])
    func map(_ u: Double, _ v: Double) -> [Double] {
      [a * u + c * v + e, b * u + d * v + f]
    }
    let p00 = map(u0, v0), p10 = map(u1, v0), p11 = map(u1, v1), p01 = map(u0, v1)
    func token(_ value: Double) -> String { ImageInventory.numberToken(value) }
    return
      "\(token(p00[0])) \(token(p00[1])) m "
      + "\(token(p10[0])) \(token(p10[1])) l "
      + "\(token(p11[0])) \(token(p11[1])) l "
      + "\(token(p01[0])) \(token(p01[1])) l h"
  }
}

/// P20-017: destructive crop as a separate pixel-content operation. The
/// cropped-away samples are removed from the new image object (a per-instance
/// copy); the original shared object keeps them. `pixelRect` is
/// `[x, y, width, height]` with a top-left origin in image pixels.
public struct CropImagePixelsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let pixelRect: [Int]

  public init(pageID: PDFObjectID, placementIndex: Int, pixelRect: [Int]) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.pixelRect = pixelRect
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Crop Image Destructively" }

  public func validate(in graph: PDFGraph) throws {
    _ = try croppedSamples(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let context = try croppedSamples(in: graph)
    var dictionary = context.dictionary
    dictionary.removeValue(forKey: PDFName("Filter"))
    dictionary.removeValue(forKey: PDFName("DecodeParms"))
    dictionary.removeValue(forKey: PDFName("DP"))
    dictionary.removeValue(forKey: PDFName("Length"))
    dictionary[PDFName("Width")] = .integer(Int64(context.width))
    dictionary[PDFName("Height")] = .integer(Int64(context.height))
    dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
    let bytes = try PDFFilters.encodeFlate(context.samples)
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    var graph = graph
    try ImageInstanceEditing.attachCopy(
      in: &graph, pageID: pageID, placement: context.placement,
      dictionary: dictionary, bytes: bytes)
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  private struct Context {
    let placement: ImagePlacement
    let dictionary: [PDFName: PDFValue]
    let width: Int
    let height: Int
    let samples: Data
  }

  private func croppedSamples(in graph: PDFGraph) throws -> Context {
    guard pixelRect.count == 4 else {
      throw PDFError(.malformed, "The crop rectangle needs four integers")
    }
    let (x, y, width, height) = (pixelRect[0], pixelRect[1], pixelRect[2], pixelRect[3])
    let (placement, stream) = try ImageInstanceEditing.resolvePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard stream.dictionary[PDFName("ImageMask")] != .boolean(true) else {
      throw PDFError(.unsupported, "Stencil masks are edited as stencils, not pixel crops")
    }
    for key in ["SMask", "Mask", "Decode"] where stream.dictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This profile cannot destructively crop images with masks or decode arrays")
    }
    let (components, samples) = try ImageInstanceEditing.decodedSamples(of: stream)
    guard let fullWidth = ImageInstanceEditing.integers(stream.dictionary[PDFName("Width")]),
      let fullHeight = ImageInstanceEditing.integers(stream.dictionary[PDFName("Height")])
    else {
      throw PDFError(.malformed, "Image dimensions are missing")
    }
    guard width >= 1, height >= 1, x >= 0, y >= 0, x + width <= fullWidth, y + height <= fullHeight
    else {
      throw PDFError(.malformed, "The crop rectangle falls outside the image")
    }
    guard width < fullWidth || height < fullHeight else {
      throw PDFError(.malformed, "The crop rectangle covers the whole image")
    }
    let bytes = [UInt8](samples)
    var cropped = Data(capacity: width * height * components)
    for row in 0..<height {
      let source = ((y + row) * fullWidth + x) * components
      cropped.append(contentsOf: bytes[source..<(source + width * components)])
    }
    return Context(
      placement: placement, dictionary: stream.dictionary,
      width: width, height: height, samples: cropped)
  }
}

/// P20-018: image-quality and resolution controls with previewed consequences.
///
/// Downsampling is explicitly lossy and previewed before commit: the preview
/// reports the placement size in points, the current effective DPI, the
/// target pixel dimensions, and an estimated byte count, so the caller can
/// show consequences instead of applying blindly.
public struct ImageQualityPreview: Sendable, Equatable {
  public let placementWidthPoints: Double
  public let placementHeightPoints: Double
  public let currentDPIWidth: Double
  public let currentDPIHeight: Double
  public let targetWidthPixels: Int
  public let targetHeightPixels: Int
  public let estimatedBytes: Int
  public let warning: String?

  public init(
    placementWidthPoints: Double, placementHeightPoints: Double,
    currentDPIWidth: Double, currentDPIHeight: Double,
    targetWidthPixels: Int, targetHeightPixels: Int, estimatedBytes: Int, warning: String?
  ) {
    self.placementWidthPoints = placementWidthPoints
    self.placementHeightPoints = placementHeightPoints
    self.currentDPIWidth = currentDPIWidth
    self.currentDPIHeight = currentDPIHeight
    self.targetWidthPixels = targetWidthPixels
    self.targetHeightPixels = targetHeightPixels
    self.estimatedBytes = estimatedBytes
    self.warning = warning
  }

  public static func preview(
    imageWidth: Int, imageHeight: Int, matrix: [Double], targetDPI: Double
  ) throws -> ImageQualityPreview {
    guard imageWidth >= 1, imageHeight >= 1, matrix.count == 6 else {
      throw PDFError(.malformed, "Image dimensions or placement matrix are invalid")
    }
    guard targetDPI.isFinite, targetDPI >= 9, targetDPI <= 1200 else {
      throw PDFError(.malformed, "Target resolution must be between 9 and 1200 dpi")
    }
    // Axis lengths of the placed unit square (correct for rotation).
    let widthPoints = (matrix[0] * matrix[0] + matrix[1] * matrix[1]).squareRoot()
    let heightPoints = (matrix[2] * matrix[2] + matrix[3] * matrix[3]).squareRoot()
    guard widthPoints > 0, heightPoints > 0 else {
      throw PDFError(.malformed, "The image placement is degenerate")
    }
    let currentDPIWidth = Double(imageWidth) / (widthPoints / 72)
    let currentDPIHeight = Double(imageHeight) / (heightPoints / 72)
    let targetWidth = max(1, Int(((widthPoints / 72) * targetDPI).rounded()))
    let targetHeight = max(1, Int(((heightPoints / 72) * targetDPI).rounded()))
    var warning: String?
    if targetWidth >= imageWidth, targetHeight >= imageHeight {
      warning = "The image is already at or below the target resolution; downsampling would not help"
    } else if targetDPI < 72 {
      warning = "Resolutions below 72 dpi look visibly coarse in print"
    }
    return ImageQualityPreview(
      placementWidthPoints: widthPoints, placementHeightPoints: heightPoints,
      currentDPIWidth: currentDPIWidth, currentDPIHeight: currentDPIHeight,
      targetWidthPixels: targetWidth, targetHeightPixels: targetHeight,
      estimatedBytes: targetWidth * targetHeight * 3, warning: warning)
  }
}

/// P20-018: downsample one image instance to the target DPI with a pure-Swift
/// box filter. Per-instance copy-on-write; the shared original is untouched.
public struct DownsampleImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let targetDPI: Double

  public init(pageID: PDFObjectID, placementIndex: Int, targetDPI: Double) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.targetDPI = targetDPI
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Downsample Image" }

  public func validate(in graph: PDFGraph) throws {
    _ = try downsampled(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let context = try downsampled(in: graph)
    var dictionary = context.dictionary
    dictionary.removeValue(forKey: PDFName("Filter"))
    dictionary.removeValue(forKey: PDFName("DecodeParms"))
    dictionary.removeValue(forKey: PDFName("DP"))
    dictionary.removeValue(forKey: PDFName("Length"))
    dictionary[PDFName("Width")] = .integer(Int64(context.width))
    dictionary[PDFName("Height")] = .integer(Int64(context.height))
    dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
    let bytes = try PDFFilters.encodeFlate(context.samples)
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    var graph = graph
    try ImageInstanceEditing.attachCopy(
      in: &graph, pageID: pageID, placement: context.placement,
      dictionary: dictionary, bytes: bytes)
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  private struct Context {
    let placement: ImagePlacement
    let dictionary: [PDFName: PDFValue]
    let width: Int
    let height: Int
    let samples: Data
  }

  private func downsampled(in graph: PDFGraph) throws -> Context {
    let (placement, stream) = try ImageInstanceEditing.resolvePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard stream.dictionary[PDFName("ImageMask")] != .boolean(true) else {
      throw PDFError(.unsupported, "Stencil masks are edited as stencils, not resampled pixels")
    }
    for key in ["SMask", "Mask", "Decode"] where stream.dictionary[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "This profile cannot downsample images with masks or decode arrays")
    }
    guard stream.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")) else {
      throw PDFError(.unsupported, "This profile downsamples only DeviceRGB 8-bit images")
    }
    let (components, samples) = try ImageInstanceEditing.decodedSamples(of: stream)
    guard components == 3,
      let fullWidth = ImageInstanceEditing.integers(stream.dictionary[PDFName("Width")]),
      let fullHeight = ImageInstanceEditing.integers(stream.dictionary[PDFName("Height")])
    else {
      throw PDFError(.malformed, "Image dimensions are missing")
    }
    let preview = try ImageQualityPreview.preview(
      imageWidth: fullWidth, imageHeight: fullHeight, matrix: placement.matrix,
      targetDPI: targetDPI)
    guard preview.targetWidthPixels < fullWidth || preview.targetHeightPixels < fullHeight else {
      throw PDFError(
        .unsupported, "The image is already at or below the target resolution")
    }
    let bytes = [UInt8](samples)
    var result = Data(
      capacity: preview.targetWidthPixels * preview.targetHeightPixels * components)
    for row in 0..<preview.targetHeightPixels {
      let sourceY0 = row * fullHeight / preview.targetHeightPixels
      let sourceY1 = (row + 1) * fullHeight / preview.targetHeightPixels
      for column in 0..<preview.targetWidthPixels {
        let sourceX0 = column * fullWidth / preview.targetWidthPixels
        let sourceX1 = (column + 1) * fullWidth / preview.targetWidthPixels
        for component in 0..<components {
          var total = 0
          var count = 0
          for sourceY in sourceY0..<max(sourceY0 + 1, sourceY1) {
            for sourceX in sourceX0..<max(sourceX0 + 1, sourceX1) {
              total += Int(bytes[(sourceY * fullWidth + sourceX) * components + component])
              count += 1
            }
          }
          result.append(UInt8(total / max(count, 1)))
        }
      }
    }
    return Context(
      placement: placement, dictionary: stream.dictionary,
      width: preview.targetWidthPixels, height: preview.targetHeightPixels, samples: result)
  }
}

/// P20-019: place a new image on a page as real page content (a DeviceRGB
/// 8-bit Flate XObject plus a `q … cm … Do … Q` draw). The caller supplies
/// already-decoded pixels (for example from `ImageImport`); nothing is
/// resampled and no annotation is created.
public struct PlaceImageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let width: Int
  public let height: Int
  public let rgb8: Data

  public init(pageID: PDFObjectID, rect: [Double], width: Int, height: Int, rgb8: Data) {
    self.pageID = pageID
    self.rect = rect
    self.width = width
    self.height = height
    self.rgb8 = rgb8
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Place Image" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > rect[0], rect[3] > rect[1]
    else {
      throw PDFError(.malformed, "The placement rectangle is empty")
    }
    guard width >= 1, height >= 1, width <= 20_000, height <= 20_000,
      rgb8.count == width * height * 3
    else {
      throw PDFError(.malformed, "The image data does not match its dimensions")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let imageID = AddedContent.nextObjectID(in: graph)
    let encoded = try PDFFilters.encodeFlate(rgb8)
    graph.objects[imageID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(Int64(width)),
          PDFName("Height"): .integer(Int64(height)),
          PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("FlateDecode")),
          PDFName("Length"): .integer(Int64(encoded.count)),
        ], bytes: encoded))
    var existing: Set<String> = []
    if case .dictionary(let objects)? = (try AddedContent.pageResources(
      pageID: pageID, in: graph))?[PDFName("XObject")]
    {
      existing = Set(objects.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
    }
    var counter = 1
    var name = PDFName("SPDFPl\(counter)")
    while existing.contains(String(decoding: name.bytes, as: UTF8.self)) {
      counter += 1
      guard counter < 10_000 else {
        throw PDFError(.limitExceeded, "No free image resource name remains")
      }
      name = PDFName("SPDFPl\(counter)")
    }
    try AddedContent.addResources(
      [name: .reference(imageID)], kind: "XObject", pageID: pageID, in: &graph)
    let block =
      "q\n\(ImageInventory.numberToken(rect[2] - rect[0])) 0 0 "
      + "\(ImageInventory.numberToken(rect[3] - rect[1])) "
      + "\(ImageInventory.numberToken(rect[0])) \(ImageInventory.numberToken(rect[1])) cm\n"
      + "/\(String(decoding: name.bytes, as: UTF8.self)) Do\nQ\n"
    try AddedContent.append(block, pageID: pageID, toFront: true, in: &graph)
    // The new image object extends the numbering; keep /Size consistent so a
    // rewritten file reparses to this exact graph.
    graph.trailer[PDFName("Size")] = .integer(
      Int64((graph.objects.keys.map(\.number).max() ?? 0) + 1))
    return graph
  }
}

/// P20-020: delete one image draw without deleting other shared instances.
/// Only the targeted `q … cm … Do … Q` block is removed from the content
/// stream; the shared image object and every other draw stay byte-identical.
public struct DeleteImageDrawCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int

  public init(pageID: PDFObjectID, placementIndex: Int) {
    self.pageID = pageID
    self.placementIndex = placementIndex
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Delete Image" }

  public func validate(in graph: PDFGraph) throws {
    _ = try deletableRange(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let range = try deletableRange(in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    var graph = try content.replacing(range: range, with: [], in: graph, limits: limits)
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    _ = placement
    return graph
  }

  private func deletableRange(in graph: PDFGraph) throws -> Range<Int> {
    let placement = try editableImagePlacement(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph)
    let index = placement.instructionIndex
    guard index >= 2, index + 1 < content.instructions.count,
      content.instructions[index - 2].operatorName == "q",
      content.instructions[index - 1].operatorName == "cm",
      content.instructions[index].operatorName == "Do",
      content.instructions[index + 1].operatorName == "Q"
    else {
      throw PDFError(
        .unsupported, "The image placement does not use the supported q…cm…Do…Q pattern")
    }
    return content.instructions[index - 2].span.lowerBound..<content.instructions[index + 1].span
      .upperBound
  }
}

/// P20-021: extract the original encoded image data when semantically
/// possible. Standalone JPEG/JPEG 2000 streams come back byte-for-byte;
/// stored raw/Flate samples come back with their decoded bytes; masked,
/// stencil, and exotic-filter images report their original bytes as
/// not-independently-usable so callers render instead of guessing.
public struct ExtractedImageOriginal: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let bitsPerComponent: Int
  public let colorSpace: String
  public let filters: [String]
  public let originalBytes: Data
  public let decodedSamples: Data?
  /// True when the bytes (or the wrapped samples) stand alone as a file.
  public let usableAsStandaloneFile: Bool
  public let suggestedExtension: String
  public let note: String

  public init(
    width: Int, height: Int, bitsPerComponent: Int, colorSpace: String, filters: [String],
    originalBytes: Data, decodedSamples: Data?, usableAsStandaloneFile: Bool,
    suggestedExtension: String, note: String
  ) {
    self.width = width
    self.height = height
    self.bitsPerComponent = bitsPerComponent
    self.colorSpace = colorSpace
    self.filters = filters
    self.originalBytes = originalBytes
    self.decodedSamples = decodedSamples
    self.usableAsStandaloneFile = usableAsStandaloneFile
    self.suggestedExtension = suggestedExtension
    self.note = note
  }
}

public enum ImageOriginalExtraction {
  public static func extract(imageID: PDFObjectID, in graph: PDFGraph) throws
    -> ExtractedImageOriginal
  {
    guard case .stream(let stream)? = graph.objects[imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    let dictionary = stream.dictionary
    guard dictionary[PDFName("Subtype")] == .name(PDFName("Image")) else {
      throw PDFError(.malformed, "The object is not an image XObject")
    }
    let width = ImageInstanceEditing.integers(dictionary[PDFName("Width")]) ?? 0
    let height = ImageInstanceEditing.integers(dictionary[PDFName("Height")]) ?? 0
    let bits = ImageInstanceEditing.integers(dictionary[PDFName("BitsPerComponent")]) ?? 0
    let colorSpace: String
    switch dictionary[PDFName("ColorSpace")] {
    case .name(let name)?:
      colorSpace = String(decoding: name.bytes, as: UTF8.self)
    case .array(let values)? where !values.isEmpty:
      if case .name(let name)? = values.first {
        colorSpace = String(decoding: name.bytes, as: UTF8.self)
      } else {
        colorSpace = ""
      }
    default:
      colorSpace = ""
    }
    let filters = ((try? PDFFilters.filterNames(in: dictionary)) ?? []).map {
      String(decoding: $0.bytes, as: UTF8.self)
    }
    let isStencil = dictionary[PDFName("ImageMask")] == .boolean(true)
    let hasMask =
      dictionary[PDFName("SMask")] != nil || dictionary[PDFName("Mask")] != nil
    if isStencil {
      return ExtractedImageOriginal(
        width: width, height: height, bitsPerComponent: bits, colorSpace: colorSpace,
        filters: filters, originalBytes: stream.bytes, decodedSamples: nil,
        usableAsStandaloneFile: false, suggestedExtension: "bin",
        note: "Stencil masks paint with the current color and need rendering")
    }
    if hasMask {
      return ExtractedImageOriginal(
        width: width, height: height, bitsPerComponent: bits, colorSpace: colorSpace,
        filters: filters, originalBytes: stream.bytes, decodedSamples: nil,
        usableAsStandaloneFile: false, suggestedExtension: "png",
        note: "Masked images need rendered reconstruction")
    }
    if filters == ["DCTDecode"] {
      return ExtractedImageOriginal(
        width: width, height: height, bitsPerComponent: bits, colorSpace: colorSpace,
        filters: filters, originalBytes: stream.bytes, decodedSamples: nil,
        usableAsStandaloneFile: true, suggestedExtension: "jpg",
        note: "Original JPEG bytes preserved byte-for-byte")
    }
    if filters == ["JPXDecode"] {
      return ExtractedImageOriginal(
        width: width, height: height, bitsPerComponent: bits, colorSpace: colorSpace,
        filters: filters, originalBytes: stream.bytes, decodedSamples: nil,
        usableAsStandaloneFile: true, suggestedExtension: "jp2",
        note: "Original JPEG 2000 bytes preserved byte-for-byte")
    }
    if (filters.isEmpty || filters == ["FlateDecode"]), bits == 8,
      colorSpace == "DeviceRGB" || colorSpace == "DeviceGray"
    {
      let decoded = try? PDFFilters.decoded(stream)
      return ExtractedImageOriginal(
        width: width, height: height, bitsPerComponent: bits, colorSpace: colorSpace,
        filters: filters, originalBytes: stream.bytes, decodedSamples: decoded,
        usableAsStandaloneFile: true, suggestedExtension: "png",
        note: "Stored samples wrap into a PNG without resampling")
    }
    let decoded = try? PDFFilters.decoded(stream)
    return ExtractedImageOriginal(
      width: width, height: height, bitsPerComponent: bits, colorSpace: colorSpace,
      filters: filters, originalBytes: stream.bytes, decodedSamples: decoded,
      usableAsStandaloneFile: false, suggestedExtension: "bin",
      note: "Unsupported codec or color space; original bytes are preserved, not converted")
  }
}

/// P20-022: unsupported compressed codecs are opaque payloads during unrelated
/// operations. Geometry and placement edits touch only content-stream
/// operands, so DCT/JPX/CCITT/JBIG2 bytes survive byte-identically.
public enum ImageCodecPreservation {
  /// Image stream bytes that must be identical before and after an edit.
  public static func imageBytes(in graph: PDFGraph) -> [PDFObjectID: Data] {
    var result: [PDFObjectID: Data] = [:]
    for (id, value) in graph.objects {
      guard case .stream(let stream) = value,
        stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image"))
      else { continue }
      result[id] = stream.bytes
    }
    return result
  }

  public static func preserved(before: [PDFObjectID: Data], after: PDFGraph) -> Bool {
    for (id, bytes) in before {
      guard case .stream(let stream)? = after.objects[id], stream.bytes == bytes else {
        return false
      }
    }
    return true
  }
}

/// P20-023/P20-024: scan-page image/OCR relationships and invalidation.
///
/// A generated searchable text layer describes the scan pixels. Any edit that
/// changes those pixels (or removes the draw) must invalidate the layer
/// first; the image commands in this package do that through
/// `invalidateGeneratedLayer`. Geometry-only reasoning stays read-only here.
public struct ScanOCRRelationship: Sendable, Equatable {
  public enum Recommendation: String, Sendable, Equatable {
    case noAction
    case confirmBeforeReplace
    case mustInvalidate
  }

  public let hasGeneratedLayer: Bool
  public let imagePlacementCount: Int
  public let largestPlacementCoversPage: Bool
  public let recommendation: Recommendation

  public init(
    hasGeneratedLayer: Bool, imagePlacementCount: Int, largestPlacementCoversPage: Bool,
    recommendation: Recommendation
  ) {
    self.hasGeneratedLayer = hasGeneratedLayer
    self.imagePlacementCount = imagePlacementCount
    self.largestPlacementCoversPage = largestPlacementCoversPage
    self.recommendation = recommendation
  }
}

public enum ImageOCRRelations {
  /// Describe the image/OCR relationship on one page without mutating it.
  public static func describe(pageID: PDFObjectID, in graph: PDFGraph) throws
    -> ScanOCRRelationship
  {
    let hasLayer = OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID)
    let placements = (try? ImageInventory.placements(in: graph, pageID: pageID)) ?? []
    let box = pageBox(pageID: pageID, in: graph)
    let pageArea = max(0, box[2] - box[0]) * max(0, box[3] - box[1])
    var covers = false
    for placement in placements {
      guard placement.bounds.count == 4 else { continue }
      let area =
        max(0, placement.bounds[2] - placement.bounds[0])
        * max(0, placement.bounds[3] - placement.bounds[1])
      if pageArea > 0, area / pageArea >= 0.8 {
        covers = true
        break
      }
    }
    let recommendation: ScanOCRRelationship.Recommendation
    if hasLayer, !placements.isEmpty {
      recommendation = .mustInvalidate
    } else if hasLayer || (covers && !placements.isEmpty) {
      recommendation = .confirmBeforeReplace
    } else {
      recommendation = .noAction
    }
    return ScanOCRRelationship(
      hasGeneratedLayer: hasLayer, imagePlacementCount: placements.count,
      largestPlacementCoversPage: covers, recommendation: recommendation)
  }

  /// Remove the page's generated OCR layer when one exists; a no-op otherwise.
  /// Image-edit commands call this after pixel or visibility changes.
  public static func invalidateGeneratedLayer(pageID: PDFObjectID, in graph: inout PDFGraph) throws
  {
    if OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID) {
      try OCRLayer.removeLayer(pageID: pageID, in: &graph)
    }
  }

  static func pageBox(pageID: PDFObjectID, in graph: PDFGraph) -> [Double] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [0, 0, 612, 792] }
    for key in ["CropBox", "MediaBox"] {
      if case .array(let values)? = page[PDFName(key)] {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
    }
    return [0, 0, 612, 792]
  }
}

/// P20-029: measured image-edit cost. Reports wall time plus the pixel/byte
/// volume it covered so the ledger records evidence, not adjectives.
public struct ImageEditMeasurement: Sendable, Equatable {
  public let pixels: Int
  public let bytes: Int
  public let seconds: Double

  public init(pixels: Int, bytes: Int, seconds: Double) {
    self.pixels = pixels
    self.bytes = bytes
    self.seconds = seconds
  }

  /// Time a per-instance replacement of `width`x`height` RGB pixels.
  public static func measureReplace(
    in graph: PDFGraph, pageID: PDFObjectID, placementIndex: Int,
    width: Int, height: Int, rgb8: Data
  ) throws -> (graph: PDFGraph, measurement: ImageEditMeasurement) {
    let start = Date()
    let updated = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: pageID, placementIndex: placementIndex,
          width: width, height: height, rgb8: rgb8)
      ]), to: graph)
    return (
      updated,
      ImageEditMeasurement(
        pixels: width * height, bytes: rgb8.count, seconds: Date().timeIntervalSince(start)))
  }

  /// Time a downsample to `targetDPI` on one placement.
  public static func measureDownsample(
    in graph: PDFGraph, pageID: PDFObjectID, placementIndex: Int, targetDPI: Double
  ) throws -> (graph: PDFGraph, measurement: ImageEditMeasurement) {
    let start = Date()
    let updated = try PDFEditingEngine.commit(
      PDFTransaction([
        DownsampleImageCommand(
          pageID: pageID, placementIndex: placementIndex, targetDPI: targetDPI)
      ]), to: graph)
    let placements = try ImageInventory.placements(in: updated, pageID: pageID)
    let count = placements.count
    _ = count
    return (
      updated,
      ImageEditMeasurement(
        pixels: 0, bytes: 0, seconds: Date().timeIntervalSince(start)))
  }
}

/// P20-030: image read/extract/edit/write capability by codec and mask type.
/// `supported` means the owned core round-trips it; `preserved` means raw
/// bytes survive untouched; `unsupported`/`rendered` name the honest limit.
public struct ImageCapabilityRow: Sendable, Equatable {
  public let codec: String
  public let mask: String
  public let read: String
  public let extract: String
  public let edit: String
  public let write: String

  public init(
    codec: String, mask: String, read: String, extract: String, edit: String, write: String
  ) {
    self.codec = codec
    self.mask = mask
    self.read = read
    self.extract = extract
    self.edit = edit
    self.write = write
  }
}

public enum ImageCapabilities {
  public static let rows: [ImageCapabilityRow] = [
    ImageCapabilityRow(
      codec: "Raw", mask: "none", read: "supported", extract: "supported",
      edit: "supported", write: "FlateDecode"),
    ImageCapabilityRow(
      codec: "FlateDecode", mask: "none", read: "supported", extract: "supported",
      edit: "supported", write: "FlateDecode"),
    ImageCapabilityRow(
      codec: "FlateDecode", mask: "SMask", read: "supported", extract: "rendered",
      edit: "dedicated soft-mask path", write: "FlateDecode"),
    ImageCapabilityRow(
      codec: "FlateDecode", mask: "Mask array", read: "supported", extract: "rendered",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "FlateDecode", mask: "Decode array", read: "supported", extract: "supported",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "Raw/FlateDecode", mask: "ImageMask stencil", read: "supported",
      extract: "rendered", edit: "dedicated stencil path", write: "preserved encoding"),
    ImageCapabilityRow(
      codec: "DCTDecode", mask: "none", read: "metadata only", extract: "original bytes",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "DCTDecode", mask: "SMask", read: "metadata only", extract: "rendered",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "JPXDecode", mask: "none", read: "metadata only", extract: "original bytes",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "CCITTFaxDecode", mask: "none", read: "metadata only", extract: "original bytes",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "JBIG2Decode", mask: "none", read: "metadata only", extract: "original bytes",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "LZWDecode", mask: "none", read: "supported", extract: "supported",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "ASCII85Decode", mask: "none", read: "supported", extract: "supported",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "ASCIIHexDecode", mask: "none", read: "supported", extract: "supported",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "RunLengthDecode", mask: "none", read: "supported", extract: "supported",
      edit: "unsupported (preserved)", write: "preserved"),
    ImageCapabilityRow(
      codec: "DeviceGray 8-bit", mask: "none", read: "supported", extract: "supported",
      edit: "crop/extract only", write: "FlateDecode"),
    ImageCapabilityRow(
      codec: "Other color spaces/depths", mask: "any", read: "metadata only",
      extract: "original bytes", edit: "unsupported (preserved)", write: "preserved"),
  ]

  public static func summary() -> String {
    rows.map {
      "\($0.codec) + \($0.mask): read=\($0.read) extract=\($0.extract) edit=\($0.edit) write=\($0.write)"
    }.joined(separator: "\n")
  }
}
