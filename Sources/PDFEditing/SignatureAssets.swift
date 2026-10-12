import Foundation
import PDFCore

/// P29-003–P29-009: one reusable graphical mark. Pixels are plain 8-bit RGB
/// with an optional 8-bit alpha channel; nothing here touches the network or
/// writes logs.
public struct SignatureAsset: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    /// Drawn on the capture surface.
    case drawn
    /// Imported through the public image APIs.
    case imported
    /// Typed text rendered as a graphical mark.
    case typed
  }

  public let id: String
  public let kind: Kind
  public let width: Int
  public let height: Int
  /// Row-major 8-bit RGB (`width * height * 3` bytes).
  public let rgb8: Data
  /// Row-major 8-bit alpha (`width * height` bytes) or nil when opaque.
  public let alpha8: Data?
  public let createdAt: Date?

  public init(
    id: String, kind: Kind, width: Int, height: Int, rgb8: Data, alpha8: Data? = nil,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.alpha8 = alpha8
    self.createdAt = createdAt
  }

  public var hasTransparency: Bool { alpha8 != nil }
  public var isWellFormed: Bool {
    width > 0 && height > 0 && rgb8.count >= width * height * 3
      && (alpha8 == nil || alpha8!.count >= width * height)
  }

  /// P29-005: crop to the smallest rectangle that contains any pixel with
  /// non-zero alpha (opaque assets are returned unchanged).
  public func cropped() -> SignatureAsset {
    guard let alpha8, isWellFormed else { return self }
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width where alpha8[y * width + x] > 0 {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return self }
    let cropWidth = maxX - minX + 1
    let cropHeight = maxY - minY + 1
    if cropWidth == width, cropHeight == height { return self }
    var rgb = Data(capacity: cropWidth * cropHeight * 3)
    var alpha = Data(capacity: cropWidth * cropHeight)
    for y in minY...maxY {
      let rowStart = (y * width + minX) * 3
      rgb.append(rgb8.subdata(in: rowStart..<(rowStart + cropWidth * 3)))
      alpha.append(alpha8.subdata(in: (y * width + minX)..<(y * width + minX + cropWidth)))
    }
    return SignatureAsset(
      id: id, kind: kind, width: cropWidth, height: cropHeight, rgb8: rgb, alpha8: alpha,
      createdAt: createdAt)
  }

  /// P29-024: a stable identity from the pixels and kind (duplicates collapse).
  public static func identifier(kind: Kind, width: Int, height: Int, rgb8: Data, alpha8: Data?)
    -> String
  {
    var hasher = StableHasher()
    hasher.combine(kind.rawValue)
    hasher.combine(width)
    hasher.combine(height)
    hasher.combine(rgb8)
    if let alpha8 { hasher.combine(alpha8) }
    return hasher.hexDigest
  }
}

/// A tiny deterministic hasher (FNV-1a 64) so asset identities are stable and
/// do not depend on CryptoKit availability in callers.
struct StableHasher {
  private var value: UInt64 = 0xcbf2_9ce4_8422_2325
  mutating func combine(_ text: String) { combine(Data(text.utf8)) }
  mutating func combine(_ number: Int) {
    var big = UInt64(bitPattern: Int64(number))
    withUnsafeBytes(of: &big) { combine(Data($0)) }
  }
  mutating func combine(_ data: Data) {
    for byte in data {
      value ^= UInt64(byte)
      value = value &* 0x0000_0100_0000_01B3
    }
  }
  var hexDigest: String { String(format: "%016llx", value) }
}

/// P29-014: optional name/date text drawn with the mark.
public struct SignatureStampOptions: Sendable, Equatable {
  public var opacity: Double
  public var includeName: String?
  public var includeDate: String?
  public var author: String?
  public var subject: String?
  /// P29-013: preserve the asset's aspect ratio (default true).
  public var preserveAspectRatio: Bool

  public init(
    opacity: Double = 1, includeName: String? = nil, includeDate: String? = nil,
    author: String? = nil, subject: String? = nil, preserveAspectRatio: Bool = true
  ) {
    self.opacity = opacity
    self.includeName = includeName
    self.includeDate = includeDate
    self.author = author
    self.subject = subject
    self.preserveAspectRatio = preserveAspectRatio
  }

  /// The placement rectangle after aspect-ratio fitting.
  func fittedRect(_ rect: [Double], asset: SignatureAsset) -> [Double] {
    guard preserveAspectRatio, asset.width > 0, asset.height > 0 else { return rect }
    let targetWidth = rect[2] - rect[0]
    let targetHeight = rect[3] - rect[1]
    let assetRatio = Double(asset.width) / Double(asset.height)
    let targetRatio = targetWidth / max(targetHeight, 1)
    if assetRatio > targetRatio {
      let height = targetWidth / assetRatio
      let inset = (targetHeight - height) / 2
      return [rect[0], rect[1] + inset, rect[2], rect[1] + inset + height]
    }
    let width = targetHeight * assetRatio
    let inset = (targetWidth - width) / 2
    return [rect[0] + inset, rect[1], rect[0] + inset + width, rect[3]]
  }

  /// The disclosure every graphical mark carries (P29-017/P29-028).
  static let disclosure = "Graphical signature (not a digital signature)"

  func contentsText(asset: SignatureAsset) -> String {
    var parts = [Self.disclosure]
    if let includeName, !includeName.isEmpty { parts.append("Signed by: \(includeName)") }
    if let includeDate, !includeDate.isEmpty { parts.append("Date: \(includeDate)") }
    return parts.joined(separator: " — ")
  }
}

/// P29-010/P29-012/P29-013/P29-014/P29-017/P29-019/P29-021/P29-028: place a
/// graphical mark as a **stamp annotation** with an image appearance. The mark
/// is editable until deliberately flattened and never claims digital-signature
/// validity.
public struct PlaceSignatureStampCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let asset: SignatureAsset
  public let options: SignatureStampOptions

  public init(
    pageID: PDFObjectID, rect: [Double], asset: SignatureAsset,
    options: SignatureStampOptions = SignatureStampOptions()
  ) {
    self.pageID = pageID
    self.rect = rect
    self.asset = asset
    self.options = options
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Place Graphical Signature" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    try AnnotationSupport.validateOpacity(options.opacity)
    guard asset.isWellFormed else {
      throw PDFError(.malformed, "The signature asset is empty or malformed")
    }
    try SignaturePlacementPolicy.validate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let fitted = options.fittedRect(rect, asset: asset)
    let allocation = try AnnotationSupport.allocate(in: graph)
    let imageID = PDFObjectID(allocation.next)
    let maskID = asset.alpha8 != nil ? PDFObjectID(allocation.next + 1) : nil
    let fontID = PDFObjectID(allocation.next + (maskID == nil ? 1 : 2))
    let highest = fontID.number

    graph.objects[imageID] = .stream(SignatureRendering.imageStream(asset, maskID: maskID))
    if let maskID {
      graph.objects[maskID] = .stream(SignatureRendering.alphaStream(asset))
    }
    graph.objects[fontID] = .dictionary(AnnotationSupport.helveticaFontDictionary())

    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Stamp"), rect: fitted, color: [0, 0, 0], opacity: options.opacity,
      contents: options.contentsText(asset: asset), author: options.author,
      modified: options.includeDate, subject: options.subject ?? "Graphical signature",
      appearance: allocation.appearance)
    // A custom stamp name keeps the mark identifiable without a validity claim.
    dictionary[PDFName("Name")] = .name(PDFName("SPDFGraphicalSignature"))
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      SignatureRendering.stampAppearance(
        rect: fitted, asset: asset, imageID: imageID, fontID: fontID, options: options))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }
}

/// P29-011: place the mark as real page content (explicit choice), preserving
/// transparency through a soft mask.
public struct PlaceSignatureContentCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let asset: SignatureAsset
  public let options: SignatureStampOptions

  public init(
    pageID: PDFObjectID, rect: [Double], asset: SignatureAsset,
    options: SignatureStampOptions = SignatureStampOptions()
  ) {
    self.pageID = pageID
    self.rect = rect
    self.asset = asset
    self.options = options
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Place Graphical Signature (content)" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    try AnnotationSupport.validateOpacity(options.opacity)
    guard asset.isWellFormed else {
      throw PDFError(.malformed, "The signature asset is empty or malformed")
    }
    try SignaturePlacementPolicy.validate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let fitted = options.fittedRect(rect, asset: asset)
    let reusable = SignatureRendering.existingImageID(for: asset, in: graph)
    let imageID = reusable ?? AddedContent.nextObjectID(in: graph)
    let maskID = reusable != nil ? nil : (asset.alpha8 != nil ? PDFObjectID(imageID.number + 1) : nil)
    if reusable == nil {
      graph.objects[imageID] = .stream(SignatureRendering.imageStream(asset, maskID: maskID))
      if let maskID {
        graph.objects[maskID] = .stream(SignatureRendering.alphaStream(asset))
      }
    }
    var existing: Set<String> = []
    if case .dictionary(let objects)? = (try AddedContent.pageResources(pageID: pageID, in: graph))?[
      PDFName("XObject")]
    {
      existing = Set(objects.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
    }
    var counter = 1
    var name = PDFName("SPDFSig\(counter)")
    while existing.contains(String(decoding: name.bytes, as: UTF8.self)) {
      counter += 1
      name = PDFName("SPDFSig\(counter)")
    }
    try AddedContent.addResources(
      [name: .reference(imageID)], kind: "XObject", pageID: pageID, in: &graph)
    let opacityName = try AddedContent.registerOpacity(
      options.opacity, pageID: pageID, in: &graph)
    var block = "q\n"
    if let opacityName {
      block += "/\(String(decoding: opacityName.bytes, as: UTF8.self)) gs\n"
    }
    block +=
      "\(AddedContent.number(fitted[2] - fitted[0])) 0 0 \(AddedContent.number(fitted[3] - fitted[1])) "
      + "\(AddedContent.number(fitted[0])) \(AddedContent.number(fitted[1])) cm\n"
    block += "/\(String(decoding: name.bytes, as: UTF8.self)) Do\nQ\n"
    try AddedContent.append(block, pageID: pageID, toFront: true, in: &graph)
    return graph
  }
}

/// P29-004: a typed graphical signature drawn with a standard-14 font (no
/// rasterization, no font embedding).
public struct PlaceTypedSignatureCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let text: String
  public let options: SignatureStampOptions

  public init(
    pageID: PDFObjectID, rect: [Double], text: String,
    options: SignatureStampOptions = SignatureStampOptions()
  ) {
    self.pageID = pageID
    self.rect = rect
    self.text = text
    self.options = options
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Place Typed Signature" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    try AnnotationSupport.validateOpacity(options.opacity)
    guard !text.isEmpty, text.utf8.count <= 10_000 else {
      throw PDFError(.malformed, "The typed signature text is empty or too long")
    }
    try SignaturePlacementPolicy.validate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let fontID = PDFObjectID(allocation.next)
    graph.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Times-Italic")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Stamp"), rect: rect, color: [0, 0, 0], opacity: options.opacity,
      contents: options.contentsText(asset: SignatureAsset(
        id: "typed", kind: .typed, width: 1, height: 1, rgb8: Data([0, 0, 0]))),
      author: options.author, modified: options.includeDate,
      subject: options.subject ?? "Graphical signature", appearance: allocation.appearance)
    dictionary[PDFName("Name")] = .name(PDFName("SPDFGraphicalSignature"))
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      SignatureRendering.typedAppearance(
        rect: rect, text: text, fontID: fontID, options: options))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, highest: allocation.next)
    return graph
  }
}

/// P29-015/P29-016: a reusable stamp template (asset or typed text plus
/// placement defaults) for a personal palette.
public struct SignatureStampTemplate: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let asset: SignatureAsset?
  public let typedText: String?
  public let options: SignatureStampOptions

  public init(
    id: String? = nil, name: String, asset: SignatureAsset? = nil, typedText: String? = nil,
    options: SignatureStampOptions = SignatureStampOptions()
  ) {
    self.id = id ?? SignatureAsset.identifier(
      kind: asset?.kind ?? .typed, width: asset?.width ?? 0, height: asset?.height ?? 0,
      rgb8: Data(name.utf8), alpha8: nil)
    self.name = name
    self.asset = asset
    self.typedText = typedText
    self.options = options
  }
}

/// P29-021: placement policy for protected and signed documents.
public enum SignaturePlacementPolicy {
  /// Graphical marks refuse on encrypted (locked) and signed documents: a
  /// signature covers the bytes, and placement would invalidate it silently.
  public static func validate(in graph: PDFGraph) throws {
    if graph.trailer[PDFName("Encrypt")] != nil {
      throw PDFError(
        .unsupported,
        "This document is encrypted; unlock it before placing a graphical signature")
    }
    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    if !signatures.isEmpty {
      throw PDFError(
        .unsupported,
        "This document carries a digital signature; placing content would invalidate it")
    }
  }
}

/// Shared rendering for image and typed signature marks.
enum SignatureRendering {
  /// P29-024/P29-029: an existing image object for the same asset identity.
  static func existingImageID(for asset: SignatureAsset, in graph: PDFGraph) -> PDFObjectID? {
    for (id, value) in graph.objects {
      guard case .stream(let stream) = value,
        case .string(let marker)? = stream.dictionary[PDFName("SPDFAssetID")],
        String(decoding: marker, as: UTF8.self) == asset.id
      else { continue }
      return id
    }
    return nil
  }

  static func imageStream(_ asset: SignatureAsset, maskID: PDFObjectID?) -> PDFStream {
    let encoded = (try? PDFFilters.encodeFlate(Data(asset.rgb8.prefix(asset.width * asset.height * 3))))
      ?? Data()
    var dictionary: [PDFName: PDFValue] = [
      PDFName("SPDFAssetID"): .string(Data(asset.id.utf8)),
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("Width"): .integer(Int64(asset.width)),
      PDFName("Height"): .integer(Int64(asset.height)),
      PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
      PDFName("BitsPerComponent"): .integer(8),
      PDFName("Filter"): .name(PDFName("FlateDecode")),
      PDFName("Length"): .integer(Int64(encoded.count)),
    ]
    if let maskID {
      dictionary[PDFName("SMask")] = .reference(maskID)
    }
    return PDFStream(dictionary: dictionary, bytes: encoded)
  }

  static func alphaStream(_ asset: SignatureAsset) -> PDFStream {
    let alpha = asset.alpha8 ?? Data(repeating: 255, count: asset.width * asset.height)
    let encoded = (try? PDFFilters.encodeFlate(Data(alpha.prefix(asset.width * asset.height))))
      ?? Data()
    return PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(Int64(asset.width)),
        PDFName("Height"): .integer(Int64(asset.height)),
        PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
        PDFName("BitsPerComponent"): .integer(8),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
        PDFName("Length"): .integer(Int64(encoded.count)),
      ], bytes: encoded)
  }

  static func stampAppearance(
    rect: [Double], asset: SignatureAsset, imageID: PDFObjectID, fontID: PDFObjectID,
    options: SignatureStampOptions
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    var content = "q\n\(AnnotationSupport.number(width)) 0 0 "
      + "\(AnnotationSupport.number(height)) 0 0 cm\n/Im0 Do\nQ\n"
    content += textOverlay(rect: rect, fontID: fontID, options: options)
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: [
        PDFName("XObject"): .dictionary([PDFName("Im0"): .reference(imageID)]),
        PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)]),
      ])
  }

  static func typedAppearance(
    rect: [Double], text: String, fontID: PDFObjectID, options: SignatureStampOptions
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    let fontSize = min(max(height * 0.45, 8), 72)
    let textWidth = AnnotationSupport.approximateTextWidth(text, fontSize: fontSize)
    let x = max(2, (width - textWidth) / 2)
    let y = (height - fontSize) / 2 + fontSize * 0.2
    var content = "q\nBT\n/F1 \(AnnotationSupport.number(fontSize)) Tf\n0 0 0 rg\n"
    content += "\(AnnotationSupport.number(x)) \(AnnotationSupport.number(y)) Td\n"
    content += "(\(AnnotationSupport.escapedLiteral(text) ?? "()")) Tj\nET\nQ\n"
    content += textOverlay(rect: rect, fontID: fontID, options: options)
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: [PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])])
  }

  static func textOverlay(
    rect: [Double], fontID: PDFObjectID, options: SignatureStampOptions
  ) -> String {
    var lines: [String] = []
    if let name = options.includeName, !name.isEmpty { lines.append(name) }
    if let date = options.includeDate, !date.isEmpty { lines.append(date) }
    guard !lines.isEmpty else { return "" }
    let fontSize = 7.0
    var content = "q\nBT\n/F1 \(AnnotationSupport.number(fontSize)) Tf\n0 0 0 rg\n"
    for (index, line) in lines.enumerated() {
      let y = 4 + Double(lines.count - 1 - index) * (fontSize + 1)
      content += "4 \(AnnotationSupport.number(y)) Td\n"
      content += "(\(AnnotationSupport.escapedLiteral(line) ?? "()")) Tj\n"
      content += "0 0 Td\n"
    }
    content += "ET\nQ\n"
    return content
  }
}
