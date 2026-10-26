import Foundation
import PDFCore

/// IMG-03: color, mask and codec semantics of one image XObject. Geometry-only
/// edits never touch the stream, so this is also the contract for what a
/// replacement may claim: either the pixels are replaced in the same semantic
/// space, or a separately named conversion is used.
public enum ImageColorFamily: Sendable, Equatable {
  case deviceGray
  case deviceRGB
  case deviceCMYK
  case calGray
  case calRGB
  case lab
  case iccBased(components: Int, alternate: String?)
  case indexed(base: String)
  case separation(name: String)
  case deviceN(names: [String])
  case unknown(String)

  public var components: Int {
    switch self {
    case .deviceGray, .calGray, .separation, .indexed: return 1
    case .deviceRGB, .calRGB, .lab: return 3
    case .deviceCMYK: return 4
    case .iccBased(let components, _): return max(1, components)
    case .deviceN(let names): return max(1, names.count)
    case .unknown: return 0
    }
  }

  public var isGrayOrRGB: Bool {
    switch self {
    case .deviceGray, .deviceRGB: return true
    default: return false
    }
  }

  public var description: String {
    switch self {
    case .deviceGray: return "DeviceGray"
    case .deviceRGB: return "DeviceRGB"
    case .deviceCMYK: return "DeviceCMYK"
    case .calGray: return "CalGray"
    case .calRGB: return "CalRGB"
    case .lab: return "Lab"
    case .iccBased(let components, let alternate):
      return "ICCBased(N=\(components)\(alternate.map { ", alt=\($0)" } ?? ""))"
    case .indexed(let base): return "Indexed(base=\(base))"
    case .separation(let name): return "Separation(\(name))"
    case .deviceN(let names): return "DeviceN(\(names.joined(separator: ",")))"
    case .unknown(let raw): return raw.isEmpty ? "unknown" : raw
    }
  }
}

/// IMG-03: how transparency/masking reaches the image samples.
public enum ImageMaskKind: Sendable, Equatable {
  /// No mask dictionary at all.
  case none
  /// A grayscale soft mask supplies per-pixel alpha.
  case softMask(PDFObjectID)
  /// A /Mask color-key array names sample values that are transparent.
  case colorKey([Double])
  /// A /Mask reference to another explicit (stencil) mask image.
  case explicitMask(PDFObjectID)
  /// An /ImageMask stencil paints with the current graphics-state color.
  case stencil

  public var description: String {
    switch self {
    case .none: return "none"
    case .softMask: return "SMask"
    case .colorKey: return "color-key Mask array"
    case .explicitMask: return "explicit Mask"
    case .stencil: return "ImageMask stencil"
    }
  }
}

/// IMG-03: what a caller may do when replacing pixels.
public enum ImageReplacementPolicy: Sendable, Equatable {
  /// The existing per-instance RGB8 replacement path preserves semantics.
  case directRGB8(transparencyRequired: Bool)
  /// A separately named RGB conversion is required; the reason is user-facing.
  case explicitConversion(reason: String)
  /// The semantics cannot be represented by this profile at all.
  case unsupported(reason: String)
}

/// IMG-03: how extraction can preserve the image's color/alpha semantics.
public enum ImageOriginalPreservation: Sendable, Equatable {
  /// The encoded bytes are usable as a standalone file with preserved color.
  case originalEncodedBytes(`extension`: String, note: String)
  /// Stored samples plus a decodable soft mask can be wrapped into an
  /// alpha-preserving PNG without resampling.
  case alphaPreservingExport(note: String)
  /// Only rendering preserves the appearance (masks, transforms, overlays).
  case renderedReconstruction(reason: String)
  /// A color-space/profile/decode conversion is required; the encoded samples
  /// must not be presented as a color-correct standalone file.
  case explicitColorConversion(reason: String)

  public var isOriginal: Bool {
    switch self {
    case .originalEncodedBytes, .alphaPreservingExport: return true
    case .renderedReconstruction, .explicitColorConversion: return false
    }
  }

  public var note: String {
    switch self {
    case .originalEncodedBytes(_, let note), .alphaPreservingExport(let note): return note
    case .renderedReconstruction(let reason), .explicitColorConversion(let reason):
      return reason
    }
  }
}

/// IMG-03: image color/mask/codec semantics resolved from the image dictionary.
public struct ImageColorSemantics: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let bitsPerComponent: Int
  public let family: ImageColorFamily
  public let filters: [String]
  public let mask: ImageMaskKind
  public let decode: [Double]?
  public let decodeIsIdentity: Bool
  public let hasDecodeParms: Bool
  public let colorSpaceDescription: String

  public init(
    width: Int, height: Int, bitsPerComponent: Int, family: ImageColorFamily,
    filters: [String], mask: ImageMaskKind, decode: [Double]?,
    decodeIsIdentity: Bool, hasDecodeParms: Bool, colorSpaceDescription: String
  ) {
    self.width = width
    self.height = height
    self.bitsPerComponent = bitsPerComponent
    self.family = family
    self.filters = filters
    self.mask = mask
    self.decode = decode
    self.decodeIsIdentity = decodeIsIdentity
    self.hasDecodeParms = hasDecodeParms
    self.colorSpaceDescription = colorSpaceDescription
  }

  public var isStencil: Bool {
    if case .stencil = mask { return true }
    return false
  }

  public var isDeviceRGB8: Bool {
    family == .deviceRGB && bitsPerComponent == 8
  }

  public var decodeArrayPresent: Bool { decode != nil }

  public var replacementPolicy: ImageReplacementPolicy {
    if isStencil {
      return .unsupported(
        reason: "Stencil masks carry no color samples; use the dedicated stencil replacement path")
    }
    switch mask {
    case .stencil:
      return .unsupported(
        reason: "Stencil masks carry no color samples; use the dedicated stencil replacement path")
    case .colorKey(let values):
      return .explicitConversion(
        reason: "This image uses a color-key mask (\(values.count) values); an RGB replacement must explicitly drop or convert that transparency")
    case .explicitMask:
      return .explicitConversion(
        reason: "This image uses an explicit mask; an RGB replacement must explicitly drop or convert that transparency")
    case .softMask:
      if isDeviceRGB8, decodeIsIdentity {
        return .directRGB8(transparencyRequired: true)
      }
      return .explicitConversion(
        reason: "This image uses a soft mask outside the direct RGB8 path; convert the color/alpha explicitly")
    case .none:
      break
    }
    if !decodeIsIdentity {
      return .explicitConversion(
        reason: "A non-identity /Decode array remaps the samples; an RGB replacement is a color conversion")
    }
    if isDeviceRGB8 {
      return .directRGB8(transparencyRequired: false)
    }
    let codec = filters.isEmpty ? "raw samples" : filters.joined(separator: "+")
    return .explicitConversion(
      reason: "This image stores \(colorSpaceDescription) \(codec) at \(bitsPerComponent) bpc; replacing it with RGB8 is an explicit color conversion")
  }
}

/// IMG-03: read-only inspection of image color, mask and codec semantics.
public enum ImageSemanticsInspector {
  public static func describe(imageID: PDFObjectID, in graph: PDFGraph) throws
    -> ImageColorSemantics
  {
    guard case .stream(let stream)? = graph.objects[imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    guard stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image")) else {
      throw PDFError(.malformed, "The object is not an image XObject")
    }
    return try describe(stream: stream, in: graph)
  }

  static func describe(stream: PDFStream, in graph: PDFGraph) throws -> ImageColorSemantics {
    let dictionary = stream.dictionary
    let family = colorFamily(dictionary[PDFName("ColorSpace")], in: graph)
    let bits = integer(dictionary[PDFName("BitsPerComponent")]) ?? 0
    let filters = ((try? PDFFilters.filterNames(in: dictionary)) ?? []).map {
      String(decoding: $0.bytes, as: UTF8.self)
    }
    let mask = maskKind(dictionary, in: graph)
    let decode = decodeArray(dictionary[PDFName("Decode")])
    let identity = decodeIsIdentity(decode, components: max(1, family.components))
    let colorSpaceDescription = family.description
    return ImageColorSemantics(
      width: integer(dictionary[PDFName("Width")]) ?? 0,
      height: integer(dictionary[PDFName("Height")]) ?? 0,
      bitsPerComponent: bits, family: family, filters: filters, mask: mask,
      decode: decode, decodeIsIdentity: identity,
      hasDecodeParms: dictionary[PDFName("DecodeParms")] != nil
        || dictionary[PDFName("DP")] != nil,
      colorSpaceDescription: colorSpaceDescription)
  }

  /// IMG-03: classify whether extraction can preserve color/alpha semantics.
  public static func preservation(for semantics: ImageColorSemantics)
    -> ImageOriginalPreservation
  {
    switch semantics.mask {
    case .stencil:
      return .renderedReconstruction(
        reason: "Stencil masks paint with the current graphics-state color and need rendering")
    case .colorKey(let values):
      return .renderedReconstruction(
        reason: "A PDF color-key mask (\(values.count) values) changes pixel visibility; encoded bytes would lose alpha semantics")
    case .explicitMask:
      return .renderedReconstruction(
        reason: "An explicit PDF mask changes pixel visibility; encoded bytes would lose alpha semantics")
    case .softMask:
      if semantics.decodeIsIdentity,
        semantics.family.isGrayOrRGB, semantics.bitsPerComponent == 8,
        semantics.filters.allSatisfy(Self.sampleFilters.contains)
      {
        return .alphaPreservingExport(
          note: "Stored 8-bit samples and their soft mask wrap into an alpha-preserving PNG without resampling")
      }
      return .renderedReconstruction(
        reason: "Soft-mask alpha on \(codecLabel(semantics.filters)) samples needs rendered reconstruction")
    case .none:
      break
    }
    if !semantics.decodeIsIdentity {
      return .explicitColorConversion(
        reason: "A non-identity /Decode array remaps sample values; encoded bytes would not preserve rendered color")
    }
    if semantics.filters == ["DCTDecode"] {
      switch semantics.family {
      case .deviceGray, .deviceRGB, .deviceCMYK:
        return .originalEncodedBytes(
          extension: "jpg",
          note: "Original JPEG bytes preserved byte-for-byte with \(semantics.family.description) color")
      default:
        return .explicitColorConversion(
          reason: "\(semantics.colorSpaceDescription) is described by the PDF dictionary; an extracted JPEG would lose the color profile")
      }
    }
    if semantics.filters == ["JPXDecode"] {
      switch semantics.family {
      case .deviceGray, .deviceRGB, .deviceCMYK:
        return .originalEncodedBytes(
          extension: "jp2",
          note: "Original JPEG 2000 bytes preserved byte-for-byte with \(semantics.family.description) color")
      default:
        return .explicitColorConversion(
          reason: "\(semantics.colorSpaceDescription) is described by the PDF dictionary; extracted JPEG 2000 bytes would lose the PDF color profile")
      }
    }
    if semantics.family.isGrayOrRGB, semantics.bitsPerComponent == 8,
      semantics.filters.allSatisfy(Self.sampleFilters.contains)
    {
      return .originalEncodedBytes(
        extension: "png",
        note: "Stored samples wrap into a PNG without resampling")
    }
    switch semantics.family {
    case .deviceCMYK, .calRGB, .calGray, .lab, .iccBased, .indexed, .separation, .deviceN:
      return .explicitColorConversion(
        reason: "\(semantics.colorSpaceDescription) samples need an explicit color conversion before they can be a color-correct standalone image")
    default:
      return .renderedReconstruction(
        reason: "The \(codecLabel(semantics.filters)) codec has no supported sample conversion; render for a color-correct standalone image")
    }
  }

  static let sampleFilters: Set<String> = [
    "", "FlateDecode", "LZWDecode", "ASCII85Decode", "ASCIIHexDecode", "RunLengthDecode",
  ]

  private static func codecLabel(_ filters: [String]) -> String {
    filters.isEmpty ? "raw" : filters.joined(separator: "+")
  }

  private static func integer(_ value: PDFValue?) -> Int? {
    guard case .integer(let raw)? = value else { return nil }
    return Int(exactly: raw)
  }

  private static func number(_ value: PDFValue) -> Double? {
    switch value {
    case .integer(let raw): return Double(raw)
    case .real(let raw): return raw
    default: return nil
    }
  }

  static func colorFamily(_ value: PDFValue?, in graph: PDFGraph) -> ImageColorFamily {
    switch value {
    case .name(let name)?:
      return namedFamily(String(decoding: name.bytes, as: UTF8.self))
    case .array(let values)?:
      guard case .name(let familyName)? = values.first else { return .unknown("") }
      let name = String(decoding: familyName.bytes, as: UTF8.self)
      switch name {
      case "ICCBased":
        var components = 0
        var alternate: String?
        if values.count >= 2 {
          switch values[1] {
          case .reference(let id):
            if case .stream(let profile)? = graph.objects[id] {
              components = integer(profile.dictionary[PDFName("N")]) ?? 0
              if case .name(let alternateName)? = profile.dictionary[PDFName("Alternate")] {
                alternate = String(decoding: alternateName.bytes, as: UTF8.self)
              }
            }
          case .dictionary(let profile):
            components = integer(profile[PDFName("N")]) ?? 0
          default:
            break
          }
        }
        if alternate == nil, values.count >= 3, case .name(let alternateName) = values[2] {
          alternate = String(decoding: alternateName.bytes, as: UTF8.self)
        }
        if components == 0, values.count >= 4, case .integer(let fallback) = values[3] {
          components = Int(fallback)
        }
        return .iccBased(components: components, alternate: alternate)
      case "Indexed":
        var base = "unknown"
        if values.count >= 2, case .name(let baseName) = values[1] {
          base = String(decoding: baseName.bytes, as: UTF8.self)
        }
        return .indexed(base: base)
      case "Separation":
        let colorant: String
        if values.count >= 2, case .name(let colorantName) = values[1] {
          colorant = String(decoding: colorantName.bytes, as: UTF8.self)
        } else {
          colorant = "unknown"
        }
        return .separation(name: colorant)
      case "DeviceN":
        var names: [String] = []
        if values.count >= 2, case .array(let components) = values[1] {
          names = components.compactMap { entry in
            guard case .name(let name) = entry else { return nil }
            return String(decoding: name.bytes, as: UTF8.self)
          }
        }
        return .deviceN(names: names)
      default:
        return .unknown(name)
      }
    default:
      return .unknown("")
    }
  }

  private static func namedFamily(_ name: String) -> ImageColorFamily {
    switch name {
    case "DeviceGray": return .deviceGray
    case "DeviceRGB": return .deviceRGB
    case "DeviceCMYK": return .deviceCMYK
    case "CalGray": return .calGray
    case "CalRGB": return .calRGB
    case "Lab": return .lab
    default: return .unknown(name)
    }
  }

  private static func maskKind(
    _ dictionary: [PDFName: PDFValue], in graph: PDFGraph
  ) -> ImageMaskKind {
    if dictionary[PDFName("ImageMask")] == .boolean(true) { return .stencil }
    switch dictionary[PDFName("SMask")] {
    case .reference(let id)?: return .softMask(id)
    default: break
    }
    switch dictionary[PDFName("Mask")] {
    case .array(let values)?:
      return .colorKey(values.compactMap(number))
    case .reference(let id)?:
      return .explicitMask(id)
    default:
      return .none
    }
  }

  private static func decodeArray(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value else { return nil }
    let parsed = values.compactMap(number)
    return parsed.count == values.count ? parsed : nil
  }

  private static func decodeIsIdentity(_ decode: [Double]?, components: Int) -> Bool {
    guard let decode else { return true }
    guard decode.count == components * 2 else { return false }
    return stride(from: 0, to: decode.count, by: 2).allSatisfy { index in
      abs(decode[index]) < 1e-9 && abs(decode[index + 1] - 1) < 1e-9
    }
  }
}

/// IMG-03: explicit, separately named RGB conversion for one image instance.
/// The command exists exactly so a CMYK/ICC/JPEG/JPX/gray image can be replaced
/// without pretending the color/codec space was preserved. Transparency is
/// never dropped silently: a soft mask requires replacement alpha (or an
/// explicit `discardSoftMask`), and color-key/explicit masks must be
/// discarded explicitly.
public struct ReplaceImageInstanceWithConversionCommand: PDFEditCommand, Equatable,
  Sendable
{
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let width: Int
  public let height: Int
  public let rgb8: Data
  public let alpha8: Data?
  public let discardSoftMask: Bool
  public let discardColorKeyMask: Bool

  public init(
    pageID: PDFObjectID, placementIndex: Int, width: Int, height: Int, rgb8: Data,
    alpha8: Data? = nil, discardSoftMask: Bool = false, discardColorKeyMask: Bool = false
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.alpha8 = alpha8
    self.discardSoftMask = discardSoftMask
    self.discardColorKeyMask = discardColorKeyMask
  }

  public var name: String { "Replace Image with RGB Conversion" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolved(in: graph)
  }

  private struct Context {
    let path: ImageInstancePath
    let stream: PDFStream
    let semantics: ImageColorSemantics
  }

  private func resolved(in graph: PDFGraph) throws -> Context {
    guard width >= 1, width <= 10_000, height >= 1, height <= 10_000,
      rgb8.count == width * height * 3
    else {
      throw PDFError(.malformed, "Replacement image dimensions do not match its pixel data")
    }
    if let alpha8, alpha8.count != width * height {
      throw PDFError(.malformed, "Replacement image alpha does not match its dimensions")
    }
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard path.refusal == nil else {
      throw PDFError(.unsupported, path.refusal ?? "This image instance cannot be replaced safely")
    }
    guard case .stream(let stream)? = graph.objects[path.imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    let semantics = try ImageSemanticsInspector.describe(stream: stream, in: graph)
    if semantics.isStencil {
      throw PDFError(
        .unsupported,
        "Stencil masks are replaced through the dedicated stencil path, not with RGB conversion")
    }
    switch semantics.mask {
    case .colorKey, .explicitMask:
      guard discardColorKeyMask else {
        throw PDFError(
          .unsupported,
          "This image has a \(semantics.mask.description). Use Replace Image with RGB Conversion only with the explicit color-key-mask discard option")
      }
    case .softMask:
      if alpha8 == nil && !discardSoftMask {
        throw PDFError(
          .unsupported,
          "This image carries a soft mask. Provide replacement alpha, or set the explicit soft-mask discard option")
      }
    case .none, .stencil:
      break
    }
    return Context(path: path, stream: stream, semantics: semantics)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let context = try resolved(in: graph)
    let isolated = try ImageInstanceIsolation.isolate(context.path, in: graph)
    var graph = isolated.graph
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    func allocate() -> PDFObjectID {
      let id = PDFObjectID(nextNumber)
      nextNumber += 1
      return id
    }
    let imageID = allocate()
    let encoded = try PDFFilters.encodeFlate(rgb8)
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("Width"): .integer(Int64(width)),
      PDFName("Height"): .integer(Int64(height)),
      PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
      PDFName("BitsPerComponent"): .integer(8),
      PDFName("Filter"): .name(PDFName("FlateDecode")),
      PDFName("Length"): .integer(Int64(encoded.count)),
    ]
    if let alpha8 {
      let encodedMask = try PDFFilters.encodeFlate(alpha8)
      let maskID = allocate()
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
            PDFName("Length"): .integer(Int64(encodedMask.count)),
          ], bytes: encodedMask))
      dictionary[PDFName("SMask")] = .reference(maskID)
    }
    graph.objects[imageID] = .stream(PDFStream(dictionary: dictionary, bytes: encoded))
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))

    let path = context.path
    let freshName: PDFName
    if let formID = isolated.targetFormID {
      let existing = try existingXObjectNames(formID: formID, in: graph)
      freshName = ImageInstanceIsolation.uniqueResourceName(
        base: path.resourceName, existing: existing)
      try ImageInstanceIsolation.addFormXObject(
        formID: formID, name: freshName, objectID: imageID, in: &graph)
      graph = try replaceTargetDrawName(
        isolated: graph, rawTargetFormID: formID, instructionIndex: path.instructionIndex,
        name: freshName)
    } else {
      guard case .dictionary(let page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "Page is missing")
      }
      let resources = ImageInstanceEditingSupport.resourceDictionary(
        page[PDFName("Resources")], in: graph)
      let existing = Set(
        (ImageInstanceEditingSupport.xobjects(in: resources, in: graph) ?? [:]).keys)
      freshName = ImageInstanceIsolation.uniqueResourceName(
        base: path.resourceName, existing: existing)
      try ImageInstanceIsolation.addPageXObject(
        pageID: pageID, name: freshName, objectID: imageID, in: &graph)
      let content = try PageContent.load(pageID: pageID, in: graph)
      guard path.instructionIndex < content.instructions.count,
        let operand = content.instructions[path.instructionIndex].operands.first,
        case .name = operand.value
      else {
        throw PDFError(.malformed, "The image draw lost its resource operand")
      }
      let nameBytes = Array(("/" + String(decoding: freshName.bytes, as: UTF8.self)).utf8)
      graph = try content.replacing(range: operand.span, with: nameBytes, in: graph)
    }
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placements.count >= path.placementIndex + 1,
      placements[path.placementIndex].imageID == imageID,
      ImageInstanceEditingSupport.approxEqual(
        placements[path.placementIndex].matrix, path.matrix)
    else {
      throw PDFError(.malformed, "The converted image placement did not match its geometry")
    }
    return graph
  }

  private func existingXObjectNames(formID: PDFObjectID, in graph: PDFGraph) throws
    -> Set<PDFName>
  {
    guard case .stream(let stream)? = graph.objects[formID] else {
      throw PDFError(.malformed, "The isolated form XObject is missing")
    }
    let resources = ImageInstanceEditingSupport.resourceDictionary(
      stream.dictionary[PDFName("Resources")], in: graph)
    return Set(
      (ImageInstanceEditingSupport.xobjects(in: resources, in: graph) ?? [:]).keys)
  }

  private func replaceTargetDrawName(
    isolated graph: PDFGraph, rawTargetFormID: PDFObjectID, instructionIndex: Int,
    name: PDFName
  ) throws -> PDFGraph {
    guard case .stream(var stream)? = graph.objects[rawTargetFormID] else {
      throw PDFError(.malformed, "The isolated form XObject is missing")
    }
    var bytes = [UInt8](stream.bytes)
    let instructions = try ContentParser.instructions(in: bytes)
    guard instructionIndex < instructions.count,
      let operand = instructions[instructionIndex].operands.first,
      case .name = operand.value
    else {
      throw PDFError(.malformed, "The image draw lost its resource operand")
    }
    let nameBytes = Array(("/" + String(decoding: name.bytes, as: UTF8.self)).utf8)
    bytes.replaceSubrange(operand.span, with: nameBytes)
    stream.bytes = Data(bytes)
    stream.dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    var graph = graph
    graph.objects[rawTargetFormID] = .stream(stream)
    return graph
  }
}
