import Foundation
import PDFCore

/// P22-005: free-text annotations with logical text plus a generated
/// appearance that draws the text with a standard-14 font resource.
public struct AddFreeTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let text: String
  public let fontSize: Double
  public let textColor: [Double]
  public let fillColor: [Double]?
  public let borderColor: [Double]?
  public let borderWidth: Double
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, rect: [Double], text: String, fontSize: Double = 12,
    textColor: [Double] = [0, 0, 0], fillColor: [Double]? = nil, borderColor: [Double]? = nil,
    borderWidth: Double = 0, opacity: Double = 1, contents: String? = nil,
    author: String? = nil, modified: String? = nil, subject: String? = nil
  ) {
    self.pageID = pageID
    self.rect = rect
    self.text = text
    self.fontSize = fontSize
    self.textColor = textColor
    self.fillColor = fillColor
    self.borderColor = borderColor
    self.borderWidth = borderWidth
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Free Text" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "Free text needs text")
    }
    guard fontSize.isFinite, fontSize >= 6, fontSize <= 72 else {
      throw PDFError(.malformed, "Free-text size must be in 6...72")
    }
    try AnnotationSupport.validateColor(textColor, label: "Text color")
    if let fillColor { try AnnotationSupport.validateColor(fillColor, label: "Fill color") }
    if let borderColor { try AnnotationSupport.validateColor(borderColor, label: "Border color") }
    try AnnotationSupport.validateBorderWidth(borderWidth)
    try AnnotationSupport.validateOpacity(opacity)
    guard borderWidth <= min(rect[2] - rect[0], rect[3] - rect[1]) else {
      throw PDFError(.malformed, "Free-text border is wider than the box")
    }
    guard AnnotationSupport.escapedLiteral(text) != nil else {
      throw PDFError(.unsupported, "Free text supports WinAnsi text in this profile")
    }
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let fontID: PDFObjectID
    let highest: Int
    if let existing = AnnotationSupport.helveticaFontID(in: graph) {
      fontID = existing
      highest = allocation.next - 1
    } else {
      fontID = PDFObjectID(allocation.next)
      graph.objects[fontID] = .dictionary(AnnotationSupport.helveticaFontDictionary())
      highest = allocation.next
    }
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("FreeText"), rect: rect, color: nil, opacity: opacity,
      contents: contents ?? text, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("DA")] = .string(
      Data(AnnotationSupport.defaultAppearanceString(fontSize: fontSize, color: textColor).utf8))
    dictionary[PDFName("DR")] = .dictionary([
      PDFName("Font"): .dictionary([PDFName("Helvetica"): .reference(fontID)])
    ])
    dictionary[PDFName("Q")] = .integer(0)
    dictionary[PDFName("NM")] = .string(
      AnnotationText.encode("spdf-\(allocation.annotation.number)"))
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(
        rect: rect, text: text, fontSize: fontSize, textColor: textColor, fillColor: fillColor,
        borderColor: borderColor, borderWidth: borderWidth, fontID: fontID))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  static func appearance(
    rect: [Double], text: String, fontSize: Double, textColor: [Double], fillColor: [Double]?,
    borderColor: [Double]?, borderWidth: Double, fontID: PDFObjectID, opacity: Double = 1
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    var content = "q\n"
    if opacity < 1 { content += "/GS0 gs\n" }
    if let fillColor {
      content += "\(AnnotationSupport.number(fillColor[0])) "
      content += "\(AnnotationSupport.number(fillColor[1])) "
      content += "\(AnnotationSupport.number(fillColor[2])) rg\n"
      content += "0 0 \(AnnotationSupport.number(width)) \(AnnotationSupport.number(height)) re f\n"
    }
    if let borderColor, borderWidth > 0 {
      let inset = borderWidth / 2
      content += "\(AnnotationSupport.number(borderColor[0])) "
      content += "\(AnnotationSupport.number(borderColor[1])) "
      content += "\(AnnotationSupport.number(borderColor[2])) RG\n"
      content += "\(AnnotationSupport.number(borderWidth)) w\n"
      content += "\(AnnotationSupport.number(inset)) \(AnnotationSupport.number(inset)) "
      content += "\(AnnotationSupport.number(width - borderWidth)) "
      content += "\(AnnotationSupport.number(height - borderWidth)) re S\n"
    }
    content += "BT\n"
    content += "/F1 \(AnnotationSupport.number(fontSize)) Tf\n"
    content += "\(AnnotationSupport.number(textColor[0])) "
    content += "\(AnnotationSupport.number(textColor[1])) "
    content += "\(AnnotationSupport.number(textColor[2])) rg\n"
    let leading = fontSize * 1.2
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      guard let escaped = AnnotationSupport.escapedLiteral(line) else { continue }
      let y = height - fontSize - 2 - Double(index) * leading
      content += "1 0 0 1 2 \(AnnotationSupport.number(y)) Tm \(escaped) Tj\n"
    }
    content += "ET\nQ\n"
    var resources: [PDFName: PDFValue] = [
      PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
    ]
    if opacity < 1 {
      for (key, value) in AnnotationSupport.stateResources(
        opacity: opacity, blendMultiply: false)
      {
        resources[key] = value
      }
    }
    return AnnotationSupport.formAppearance(
      rect: rect, content: content, resources: resources)
  }
}

/// P22-009: the supported standard stamp names.
public enum StampName: String, Sendable, CaseIterable {
  case approved
  case notApproved
  case draft
  case confidential
  case final
  case experimental
  case expired
  case asIs
  case forComment
  case forPublicRelease

  public var pdfName: PDFName {
    switch self {
    case .approved: return PDFName("Approved")
    case .notApproved: return PDFName("NotApproved")
    case .draft: return PDFName("Draft")
    case .confidential: return PDFName("Confidential")
    case .final: return PDFName("Final")
    case .experimental: return PDFName("Experimental")
    case .expired: return PDFName("Expired")
    case .asIs: return PDFName("AsIs")
    case .forComment: return PDFName("ForComment")
    case .forPublicRelease: return PDFName("ForPublicRelease")
    }
  }

  public var label: String {
    switch self {
    case .approved: return "Approved"
    case .notApproved: return "Not Approved"
    case .draft: return "Draft"
    case .confidential: return "Confidential"
    case .final: return "Final"
    case .experimental: return "Experimental"
    case .expired: return "Expired"
    case .asIs: return "As Is"
    case .forComment: return "For Comment"
    case .forPublicRelease: return "For Public Release"
    }
  }
}

/// P22-009: stamp annotations with a valid generated appearance resource
/// (border, label text, and a standard-14 font).
public struct AddStampCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let stampName: StampName
  public let color: [Double]
  public let borderWidth: Double
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, rect: [Double], stampName: StampName, color: [Double] = [0.8, 0, 0],
    borderWidth: Double = 2, opacity: Double = 1, contents: String? = nil, author: String? = nil,
    modified: String? = nil, subject: String? = nil
  ) {
    self.pageID = pageID
    self.rect = rect
    self.stampName = stampName
    self.color = color
    self.borderWidth = borderWidth
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Stamp" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    try AnnotationSupport.validateColor(color, label: "Stamp color")
    try AnnotationSupport.validateBorderWidth(borderWidth)
    try AnnotationSupport.validateOpacity(opacity)
    guard borderWidth > 0 else {
      throw PDFError(.malformed, "A stamp needs a visible border")
    }
    guard borderWidth <= min(rect[2] - rect[0], rect[3] - rect[1]) / 2 else {
      throw PDFError(.malformed, "Stamp border is too wide for the stamp")
    }
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let allocation = try AnnotationSupport.allocate(in: graph)
    let fontID: PDFObjectID
    let highest: Int
    if let existing = AnnotationSupport.helveticaFontID(in: graph) {
      fontID = existing
      highest = allocation.next - 1
    } else {
      fontID = PDFObjectID(allocation.next)
      graph.objects[fontID] = .dictionary(AnnotationSupport.helveticaFontDictionary())
      highest = allocation.next
    }
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: PDFName("Stamp"), rect: rect, color: color, opacity: opacity,
      contents: contents ?? stampName.label, author: author, modified: modified, subject: subject,
      appearance: allocation.appearance)
    dictionary[PDFName("Name")] = .name(stampName.pdfName)
    dictionary[PDFName("BS")] = .dictionary([
      PDFName("Type"): .name(PDFName("Border")),
      PDFName("W"): .real(borderWidth),
    ])
    dictionary[PDFName("NM")] = .string(
      AnnotationText.encode("spdf-\(allocation.annotation.number)"))
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      Self.appearance(
        rect: rect, label: stampName.label, color: color, borderWidth: borderWidth,
        fontID: fontID))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  static func appearance(
    rect: [Double], label: String, color: [Double], borderWidth: Double,
    fontID: PDFObjectID, opacity: Double = 1
  ) -> PDFStream {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    let inset = borderWidth / 2
    var fontSize = min(height * 0.5, width / max(1, AnnotationSupport.approximateTextWidth(label, fontSize: 1)))
    fontSize = min(max(fontSize, 6), 48)
    let textWidth = AnnotationSupport.approximateTextWidth(label, fontSize: fontSize)
    let x = max(2, (width - textWidth) / 2)
    let y = (height - fontSize) / 2 + fontSize * 0.2
    var content = "q\n"
    if opacity < 1 { content += "/GS0 gs\n" }
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) RG\n"
    content += "\(AnnotationSupport.number(borderWidth)) w\n"
    content += "\(AnnotationSupport.number(inset)) \(AnnotationSupport.number(inset)) "
    content += "\(AnnotationSupport.number(width - borderWidth)) "
    content += "\(AnnotationSupport.number(height - borderWidth)) re S\n"
    content += "BT\n"
    content += "/F1 \(AnnotationSupport.number(fontSize)) Tf\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) rg\n"
    let escaped = AnnotationSupport.escapedLiteral(label) ?? "()"
    content += "1 0 0 1 \(AnnotationSupport.number(x)) \(AnnotationSupport.number(y)) Tm "
    content += "\(escaped) Tj\n"
    content += "ET\nQ\n"
    var resources: [PDFName: PDFValue] = [
      PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
    ]
    if opacity < 1 {
      for (key, value) in AnnotationSupport.stateResources(
        opacity: opacity, blendMultiply: false)
      {
        resources[key] = value
      }
    }
    return AnnotationSupport.formAppearance(
      rect: rect, content: content, resources: resources)
  }
}

/// P22-010: supported link targets: external http/https/mailto URIs and
/// internal destinations by flattened page index.
public enum LinkTarget: Equatable, Sendable {
  case uri(String)
  case page(Int)
}

/// P22-010: link annotations with URI actions or internal destinations.
/// Links are interactive geometry, so no appearance stream is generated;
/// activation policy is deliberately separate (P22-024).
public struct AddLinkCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let target: LinkTarget
  public let borderColor: [Double]?
  public let borderWidth: Double
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?

  public init(
    pageID: PDFObjectID, rect: [Double], target: LinkTarget, borderColor: [Double]? = nil,
    borderWidth: Double = 0, contents: String? = nil, author: String? = nil, modified: String? = nil,
    subject: String? = nil
  ) {
    self.pageID = pageID
    self.rect = rect
    self.target = target
    self.borderColor = borderColor
    self.borderWidth = borderWidth
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Link" }

  public static let supportedSchemes: Set<String> = ["http", "https", "mailto"]

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    if let borderColor { try AnnotationSupport.validateColor(borderColor, label: "Link color") }
    try AnnotationSupport.validateBorderWidth(borderWidth)
    switch target {
    case .uri(let string):
      guard string.utf8.count <= 2_048,
        let url = URL(string: string), let scheme = url.scheme?.lowercased(),
        Self.supportedSchemes.contains(scheme)
      else {
        throw PDFError(.unsupported, "Only http, https, and mailto links are supported")
      }
      guard string.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
        throw PDFError(.unsupported, "Link URIs must be ASCII in this profile")
      }
    case .page(let index):
      let view = try PageTreeView(graph: graph)
      guard index >= 0, index < view.pages.count else {
        throw PDFError(.malformed, "Link destination page is outside the document")
      }
    }
    _ = try AnnotationSupport.allocateOne(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let annotationID = try AnnotationSupport.allocateOne(in: graph)
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Link")),
      PDFName("Rect"): .array(rect.map { .real($0) }),
      PDFName("F"): .integer(4),
      PDFName("Border"): .array([.integer(0), .integer(0), .real(borderWidth)]),
    ]
    if let borderColor {
      dictionary[PDFName("C")] = .array(borderColor.map { .real($0) })
    }
    if let contents { dictionary[PDFName("Contents")] = .string(AnnotationText.encode(contents)) }
    if let author { dictionary[PDFName("T")] = .string(AnnotationText.encode(author)) }
    if let modified { dictionary[PDFName("M")] = .string(AnnotationText.encode(modified)) }
    if let subject { dictionary[PDFName("Subj")] = .string(AnnotationText.encode(subject)) }
    switch target {
    case .uri(let string):
      dictionary[PDFName("A")] = .dictionary([
        PDFName("S"): .name(PDFName("URI")),
        PDFName("URI"): .string(Data(string.utf8)),
      ])
    case .page(let index):
      let view = try PageTreeView(graph: graph)
      dictionary[PDFName("Dest")] = .array([
        .reference(view.pages[index]), .name(PDFName("Fit")),
      ])
    }
    graph.objects[annotationID] = .dictionary(dictionary)
    try AnnotationSupport.appendToAnnots(.reference(annotationID), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, highest: annotationID.number)
    return graph
  }
}
