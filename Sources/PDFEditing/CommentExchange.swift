import Foundation
import PDFCore

/// REV-01: one review comment in the portable XFDF shape. Geometry stays in
/// page space, exactly as it is stored in the annotation dictionary.
public struct CommentExchangeEntry: Sendable, Equatable {
  public let identity: String
  public let pageIndex: Int
  public let subtype: PDFName
  public let rect: [Double]
  public let quadPoints: [Double]?
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let creationDate: String?
  public let subject: String?
  public let state: PDFName?
  public let stateModel: PDFName?
  public let color: [Double]?
  public let opacity: Double?
  public let flags: Int?
  public let iconName: PDFName?
  public let inReplyTo: String?
  public let borderWidth: Double?
  public let inkStrokes: [[Double]]?
  public let defaultAppearance: String?
  public let lineStart: [Double]?
  public let lineEnd: [Double]?
  public let startEnding: PDFName?
  public let endEnding: PDFName?
  public let vertices: [Double]?

  public init(
    identity: String, pageIndex: Int, subtype: PDFName, rect: [Double],
    quadPoints: [Double]? = nil, contents: String? = nil, author: String? = nil,
    modified: String? = nil, creationDate: String? = nil, subject: String? = nil,
    state: PDFName? = nil, stateModel: PDFName? = nil, color: [Double]? = nil,
    opacity: Double? = nil, flags: Int? = nil, iconName: PDFName? = nil,
    inReplyTo: String? = nil, borderWidth: Double? = nil, inkStrokes: [[Double]]? = nil,
    defaultAppearance: String? = nil, lineStart: [Double]? = nil, lineEnd: [Double]? = nil,
    startEnding: PDFName? = nil, endEnding: PDFName? = nil, vertices: [Double]? = nil
  ) {
    self.identity = identity
    self.pageIndex = pageIndex
    self.subtype = subtype
    self.rect = rect
    self.quadPoints = quadPoints
    self.contents = contents
    self.author = author
    self.modified = modified
    self.creationDate = creationDate
    self.subject = subject
    self.state = state
    self.stateModel = stateModel
    self.color = color
    self.opacity = opacity
    self.flags = flags
    self.iconName = iconName
    self.inReplyTo = inReplyTo
    self.borderWidth = borderWidth
    self.inkStrokes = inkStrokes
    self.defaultAppearance = defaultAppearance
    self.lineStart = lineStart
    self.lineEnd = lineEnd
    self.startEnding = startEnding
    self.endEnding = endEnding
    self.vertices = vertices
  }
}

public struct CommentExportResult: Sendable {
  public let data: Data
  public let exported: Int
  public let skipped: [String]

  public init(data: Data, exported: Int, skipped: [String]) {
    self.data = data
    self.exported = exported
    self.skipped = skipped
  }
}

public struct CommentParseResult: Sendable {
  public let entries: [CommentExchangeEntry]
  public let issues: [String]

  public init(entries: [CommentExchangeEntry], issues: [String]) {
    self.entries = entries
    self.issues = issues
  }
}

/// The commands and accounting for one XFDF import. Existing comments are
/// updated in place; new comments are inserted in one undoable transaction.
public struct CommentMergePlan: Sendable {
  public let commands: [any PDFEditCommand]
  public let added: Int
  public let updated: Int
  public let unchanged: Int
  public let skipped: [String]

  public init(
    commands: [any PDFEditCommand], added: Int, updated: Int, unchanged: Int,
    skipped: [String]
  ) {
    self.commands = commands
    self.added = added
    self.updated = updated
    self.unchanged = unchanged
    self.skipped = skipped
  }
}

/// REV-01: XFDF review-comment exchange. Comments carry their native /NM
/// identity, author, dates, review state, thread parent and page geometry.
/// Unsupported annotation types are reported rather than silently dropped.
public enum CommentExchange {
  public static let supportedSubtypes: Set<PDFName> = [
    PDFName("Text"), PDFName("Highlight"), PDFName("Underline"), PDFName("StrikeOut"),
    PDFName("Squiggly"), PDFName("Square"), PDFName("Circle"), PDFName("Ink"),
    PDFName("FreeText"), PDFName("Stamp"), PDFName("Line"), PDFName("Polygon"),
    PDFName("PolyLine"),
  ]

  /// Identity used in XFDF. Generated annotations carry /NM; older comments
  /// fall back to their object number (or page/index for direct entries), so
  /// importing the same file again merges instead of duplicating.
  public static func identity(for comment: Comment) -> String {
    if let name = comment.annotation.name, !name.isEmpty { return name }
    if let objectID = comment.annotation.objectID { return "spdf-\(objectID.number)" }
    return "spdf-p\(comment.pageIndex)-a\(comment.annotation.index)"
  }

  // MARK: - Export

  public static func export(comments: [Comment]) throws -> CommentExportResult {
    var entriesByObjectID: [PDFObjectID: String] = [:]
    for comment in comments {
      if let objectID = comment.annotation.objectID {
        entriesByObjectID[objectID] = identity(for: comment)
      }
    }
    var xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
      <annots>

      """
    var exported = 0
    var skipped: [String] = []
    for comment in comments {
      guard let tag = tagName(for: comment.subtype) else {
        skipped.append(
          "Page \(comment.pageIndex + 1): \(typeName(comment.subtype)) has no XFDF representation.")
        continue
      }
      guard let rect = comment.annotation.rect ?? comment.bounds, valid(rect: rect) else {
        skipped.append(
          "Page \(comment.pageIndex + 1): \(typeName(comment.subtype)) has no usable geometry.")
        continue
      }
      let subtype = comment.subtype ?? PDFName("Text")
      let id = identity(for: comment)
      var attributes: [(String, String)] = [
        ("page", String(comment.pageIndex)),
        ("rect", numbers(rect)),
        ("name", id),
      ]
      if let title = comment.author, !title.isEmpty { attributes.append(("title", title)) }
      if let subject = comment.subject, !subject.isEmpty {
        attributes.append(("subject", subject))
      }
      if let modified = comment.annotation.modified, !modified.isEmpty {
        attributes.append(("date", modified))
      }
      if let creation = text(comment.annotation.dictionary[PDFName("CreationDate")]),
        !creation.isEmpty
      {
        attributes.append(("creationdate", creation))
      }
      if let color = comment.annotation.color
        ?? (subtype == PDFName("FreeText")
          ? freeTextColor(from: text(comment.annotation.dictionary[PDFName("DA")]))
          : nil)
      {
        attributes.append(("color", hexColor(color)))
      }
      if let opacity = comment.annotation.opacity {
        attributes.append(("opacity", number(opacity)))
      }
      if case .integer(let flags)? = comment.annotation.dictionary[PDFName("F")] {
        attributes.append(("flags", String(flags)))
      }
      if let icon = comment.annotation.iconName {
        attributes.append(("icon", String(decoding: icon.bytes, as: UTF8.self)))
      }
      if let state = comment.annotation.state {
        attributes.append(("state", String(decoding: state.bytes, as: UTF8.self)))
      }
      if let stateModel = comment.annotation.dictionary[PDFName("StateModel")],
        case .name(let name) = stateModel
      {
        attributes.append(("stateModel", String(decoding: name.bytes, as: UTF8.self)))
      }
      if let parent = comment.replyTo {
        attributes.append(("inreplyto", entriesByObjectID[parent] ?? "spdf-\(parent.number)"))
        attributes.append(("replyType", "R"))
      }
      if let quads = comment.annotation.quadPoints, !quads.isEmpty {
        attributes.append(("coords", numbers(quads.flatMap { $0 })))
      }
      if let strokes = inkStrokes(comment.annotation), !strokes.isEmpty {
        attributes.append(("width", number(borderWidth(comment.annotation) ?? 2)))
      } else if subtype == PDFName("Square") || subtype == PDFName("Circle")
        || subtype == PDFName("Line") || subtype == PDFName("Polygon")
        || subtype == PDFName("PolyLine")
      {
        attributes.append(("width", number(borderWidth(comment.annotation) ?? 1)))
      }
      if subtype == PDFName("Polygon") || subtype == PDFName("PolyLine") {
        guard let points = vertices(comment.annotation), points.count >= 4 else {
          skipped.append("Page \(comment.pageIndex + 1): \(typeName(subtype)) has no vertices.")
          continue
        }
        attributes.append(("vertices", numbers(points)))
      }
      if subtype == PDFName("Line") {
        guard let points = linePoints(comment.annotation), points.count == 4 else {
          skipped.append("Page \(comment.pageIndex + 1): Line has no endpoints.")
          continue
        }
        attributes.append(("start", numbers([points[0], points[1]])))
        attributes.append(("end", numbers([points[2], points[3]])))
        let endings = lineEndings(comment.annotation)
        attributes.append(("head", endings.0))
        attributes.append(("tail", endings.1))
      }
      if subtype == PDFName("Ink"), inkStrokes(comment.annotation)?.isEmpty ?? true {
        skipped.append("Page \(comment.pageIndex + 1): Ink has no stroke data.")
        continue
      }

      xml += "<\(tag)"
      for (key, value) in attributes {
        xml += " \(key)=\"\(escapeXML(value))\""
      }
      xml += ">"
      if let contents = comment.contents {
        xml += "<contents>\(escapeXML(contents))</contents>"
      }
      if let appearance = text(comment.annotation.dictionary[PDFName("DA")]),
        !appearance.isEmpty
      {
        xml += "<defaultappearance>\(escapeXML(appearance))</defaultappearance>"
      }
      if subtype == PDFName("Ink"), let strokes = inkStrokes(comment.annotation) {
        xml += "<inklist>"
        for stroke in strokes {
          xml += "<gesture>\(numbers(stroke))</gesture>"
        }
        xml += "</inklist>"
      }
      xml += "</\(tag)>\n"
      exported += 1
    }
    xml += "</annots>\n</xfdf>\n"
    return CommentExportResult(data: Data(xml.utf8), exported: exported, skipped: skipped)
  }

  // MARK: - Parse

  public static func parse(_ data: Data) throws -> CommentParseResult {
    final class Delegate: NSObject, XMLParserDelegate {
      var entries: [CommentExchangeEntry] = []
      var issues: [String] = []
      var sawXFDF = false
      var sawAnnots = false
      var current: Pending?
      var contents = ""
      var inContents = false
      var defaultAppearance = ""
      var inDefaultAppearance = false
      var gesture = ""
      var inGesture = false

      func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
      ) {
        let name =
          elementName.lowercased().split(separator: ":").last.map(String.init)
          ?? elementName.lowercased()
        if name == "xfdf" { sawXFDF = true }
        if name == "annots" { sawAnnots = true }
        if let subtype = CommentExchange.subtype(forTag: name), current == nil {
          current = Pending(
            subtype: subtype,
            attributes: Dictionary(
              attributes.map { ($0.key.lowercased(), $0.value) },
              uniquingKeysWith: { first, _ in first }))
          contents = ""
          inContents = false
          defaultAppearance = ""
          inDefaultAppearance = false
          gesture = ""
          inGesture = false
          return
        }
        guard current != nil else { return }
        if name == "contents" {
          inContents = true
          contents = ""
        } else if name == "defaultappearance" {
          inDefaultAppearance = true
          defaultAppearance = ""
        } else if name == "gesture" {
          inGesture = true
          gesture = ""
        }
      }

      func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inContents { contents += string }
        if inDefaultAppearance { defaultAppearance += string }
        if inGesture { gesture += string }
      }

      func parser(
        _ parser: XMLParser, foundCDATA CDATABlock: Data
      ) {
        let string = String(decoding: CDATABlock, as: UTF8.self)
        if inContents { contents += string }
        if inDefaultAppearance { defaultAppearance += string }
        if inGesture { gesture += string }
      }

      func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
      ) {
        let name =
          elementName.lowercased().split(separator: ":").last.map(String.init)
          ?? elementName.lowercased()
        if name == "contents" { inContents = false }
        if name == "defaultappearance" { inDefaultAppearance = false }
        if name == "gesture" {
          if let points = CommentExchange.parseNumbers(gesture), points.count >= 4,
            points.count % 2 == 0
          {
            current?.inkStrokes.append(points)
          }
          inGesture = false
          gesture = ""
        }
        guard let pending = current else { return }
        if let tag = CommentExchange.tagName(for: pending.subtype), name == tag {
          if let entry = pending.entry(
            contents: contents.isEmpty ? nil : contents,
            defaultAppearance: defaultAppearance.isEmpty ? nil : defaultAppearance)
          {
            entries.append(entry)
          } else {
            issues.append("Page \(pending.attributes["page"] ?? "?"): invalid geometry.")
          }
          current = nil
          contents = ""
          inContents = false
          defaultAppearance = ""
          inDefaultAppearance = false
        }
      }

      func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        issues.append(error.localizedDescription)
      }
    }

    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.sawXFDF, delegate.sawAnnots else {
      throw PDFError(.malformed, "The XFDF file does not contain a readable annotation set.")
    }
    return CommentParseResult(entries: delegate.entries, issues: delegate.issues)
  }

  // MARK: - Merge planning

  public static func plan(
    entries: [CommentExchangeEntry], issues: [String] = [], into graph: PDFGraph,
    pageIDs: [PDFObjectID]
  ) throws -> CommentMergePlan {
    let existing = CommentList.comments(in: graph, pageIDs: pageIDs)
    var existingByIdentity: [String: Comment] = [:]
    var existingParents: [String: PDFObjectID] = [:]
    for comment in existing {
      let id = identity(for: comment)
      if existingByIdentity[id] == nil { existingByIdentity[id] = comment }
      if let objectID = comment.annotation.objectID {
        existingParents[id] = objectID
      }
    }
    var seen = Set(existingByIdentity.keys)
    var commands: [any PDFEditCommand] = []
    var newEntries: [CommentExchangeEntry] = []
    var skipped = issues
    var updated = 0
    var unchanged = 0
    for entry in entries {
      let id = entry.identity.isEmpty ? derivedIdentity(entry) : entry.identity
      guard pageIDs.indices.contains(entry.pageIndex) else {
        skipped.append("A comment on page \(entry.pageIndex + 1) is outside this document.")
        continue
      }
      guard valid(rect: entry.rect) else {
        skipped.append("Page \(entry.pageIndex + 1): invalid rectangle was skipped.")
        continue
      }
      if let comment = existingByIdentity[id] {
        guard comment.subtype == entry.subtype else {
          skipped.append(
            "Page \(entry.pageIndex + 1): identifier \(id) belongs to a different comment type.")
          continue
        }
        guard comment.pageIndex == entry.pageIndex else {
          skipped.append(
            "Page \(entry.pageIndex + 1): moving an existing comment to another page is not merged.")
          continue
        }
        guard supportedSubtypes.contains(entry.subtype) else {
          // An annotation type this importer cannot author stays exactly as
          // it is when the same file is round-tripped; new entries of that
          // type are reported below.
          unchanged += 1
          continue
        }
        if entry.subtype == PDFName("FreeText"), let issue = newEntryIssue(entry) {
          skipped.append("Page \(entry.pageIndex + 1): \(issue)")
          continue
        }
        if let command = updateCommand(
          for: comment, entry: entry, identity: id, pageID: comment.pageID)
        {
          commands.append(command)
          updated += 1
        } else {
          unchanged += 1
        }
        continue
      }
      guard !seen.contains(id) else {
        skipped.append("Page \(entry.pageIndex + 1): duplicate comment identifier \(id).")
        continue
      }
      guard supportedSubtypes.contains(entry.subtype) else {
        skipped.append(
          "Page \(entry.pageIndex + 1): \(typeName(entry.subtype)) is not editable here.")
        continue
      }
      let normalizedEntry = normalized(entry, identity: id)
      if let issue = newEntryIssue(normalizedEntry) {
        skipped.append("Page \(entry.pageIndex + 1): \(issue)")
        continue
      }
      seen.insert(id)
      newEntries.append(normalizedEntry)
    }

    // A reply may point at an existing comment or at another new comment.
    // A reply whose parent is unavailable is still imported as a root so no
    // reviewer text is lost; the plan reports the broken thread link.
    let newIdentities = Set(newEntries.map(\.identity))
    var resolved: [CommentExchangeEntry] = []
    for entry in newEntries {
      guard let parent = entry.inReplyTo, !parent.isEmpty else {
        resolved.append(entry)
        continue
      }
      if existingParents[parent] != nil || newIdentities.contains(parent) {
        resolved.append(entry)
      } else {
        skipped.append(
          "Page \(entry.pageIndex + 1): reply parent \(parent) was not found; imported as a root.")
        resolved.append(
          CommentExchangeEntry(
            identity: entry.identity, pageIndex: entry.pageIndex, subtype: entry.subtype,
            rect: entry.rect, quadPoints: entry.quadPoints, contents: entry.contents,
            author: entry.author, modified: entry.modified,
            creationDate: entry.creationDate, subject: entry.subject, state: entry.state,
            stateModel: entry.stateModel, color: entry.color, opacity: entry.opacity,
            flags: entry.flags, iconName: entry.iconName, inReplyTo: nil,
            borderWidth: entry.borderWidth, inkStrokes: entry.inkStrokes,
            defaultAppearance: entry.defaultAppearance, lineStart: entry.lineStart,
            lineEnd: entry.lineEnd, startEnding: entry.startEnding,
            endEnding: entry.endEnding, vertices: entry.vertices))
      }
    }
    if !resolved.isEmpty {
      commands.append(
        ImportCommentsCommand(
          entries: resolved, pageIDs: pageIDs, existingParents: existingParents))
    }
    return CommentMergePlan(
      commands: commands, added: resolved.count, updated: updated, unchanged: unchanged,
      skipped: skipped)
  }

  // MARK: - Export helpers

  static func tagName(for subtype: PDFName?) -> String? {
    guard let subtype else { return "text" }
    switch subtype {
    case PDFName("Text"): return "text"
    case PDFName("Highlight"): return "highlight"
    case PDFName("Underline"): return "underline"
    case PDFName("StrikeOut"): return "strikeout"
    case PDFName("Squiggly"): return "squiggly"
    case PDFName("Square"): return "square"
    case PDFName("Circle"): return "circle"
    case PDFName("Ink"): return "ink"
    case PDFName("Line"): return "line"
    case PDFName("Stamp"): return "stamp"
    case PDFName("FreeText"): return "freetext"
    case PDFName("Polygon"): return "polygon"
    case PDFName("PolyLine"): return "polyline"
    case PDFName("Caret"): return "caret"
    case PDFName("FileAttachment"): return "fileattachment"
    default: return nil
    }
  }

  static func subtype(forTag tag: String) -> PDFName? {
    switch tag {
    case "text": return PDFName("Text")
    case "highlight": return PDFName("Highlight")
    case "underline": return PDFName("Underline")
    case "strikeout": return PDFName("StrikeOut")
    case "squiggly": return PDFName("Squiggly")
    case "square": return PDFName("Square")
    case "circle": return PDFName("Circle")
    case "ink": return PDFName("Ink")
    case "line": return PDFName("Line")
    case "stamp": return PDFName("Stamp")
    case "freetext": return PDFName("FreeText")
    case "polygon": return PDFName("Polygon")
    case "polyline": return PDFName("PolyLine")
    case "caret": return PDFName("Caret")
    case "fileattachment": return PDFName("FileAttachment")
    default: return nil
    }
  }

  static func typeName(_ subtype: PDFName?) -> String {
    guard let subtype else { return "Annotation" }
    return String(decoding: subtype.bytes, as: UTF8.self)
  }

  static func freeTextColor(from defaultAppearance: String?) -> [Double]? {
    guard let defaultAppearance else { return nil }
    let tokens = defaultAppearance.split(whereSeparator: \.isWhitespace)
    for (index, token) in tokens.enumerated() where token == "rg" && index >= 3 {
      let values = tokens[(index - 3)..<index].compactMap { Double($0) }
      guard values.count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
      else { continue }
      return values
    }
    return nil
  }

  static func freeTextFontSize(_ defaultAppearance: String?) -> Double {
    guard let defaultAppearance else { return 12 }
    let tokens = defaultAppearance.split(whereSeparator: \.isWhitespace)
    for (index, token) in tokens.enumerated() where token == "Tf" && index > 0 {
      if let size = Double(tokens[index - 1]), size.isFinite, size >= 6, size <= 72 {
        return size
      }
    }
    return 12
  }

  static func stampLabel(_ name: PDFName?) -> String {
    let raw = name.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "Draft"
    switch raw {
    case "Approved": return "Approved"
    case "NotApproved": return "Not Approved"
    case "Draft": return "Draft"
    case "Confidential": return "Confidential"
    case "Final": return "Final"
    case "Experimental": return "Experimental"
    case "Expired": return "Expired"
    case "AsIs": return "As Is"
    case "ForComment": return "For Comment"
    case "ForPublicRelease": return "For Public Release"
    default:
      var label = ""
      for scalar in raw.unicodeScalars {
        if CharacterSet.uppercaseLetters.contains(scalar), !label.isEmpty {
          label.append(" ")
        }
        label.append(Character(scalar))
      }
      return label.isEmpty ? "Stamp" : label
    }
  }

  static func colorsEqual(_ lhs: [Double], _ rhs: [Double]?) -> Bool {
    guard let rhs, lhs.count == 3, rhs.count == 3 else { return false }
    return zip(lhs, rhs).allSatisfy { left, right in
      guard left.isFinite, right.isFinite else { return false }
      let a = Int((min(max(left, 0), 1) * 255).rounded())
      let b = Int((min(max(right, 0), 1) * 255).rounded())
      return a == b
    }
  }

  static func appearancesEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    if lhs == rhs { return true }
    guard let lhs, let rhs else { return false }
    guard freeTextFontSize(lhs) == freeTextFontSize(rhs) else { return false }
    let leftColor = freeTextColor(from: lhs)
    let rightColor = freeTextColor(from: rhs)
    if let leftColor, let rightColor {
      return colorsEqual(leftColor, rightColor)
    }
    return lhs == rhs
  }

  static func text(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  static func inkStrokes(_ annotation: Annotation) -> [[Double]]? {
    guard case .array(let strokes)? = annotation.dictionary[PDFName("InkList")] else {
      return nil
    }
    var result: [[Double]] = []
    for stroke in strokes {
      guard case .array(let values) = stroke else { return nil }
      let points = values.compactMap(numberValue)
      guard points.count == values.count, points.count >= 4, points.count % 2 == 0 else {
        return nil
      }
      result.append(points)
    }
    return result
  }

  static func linePoints(_ annotation: Annotation) -> [Double]? {
    guard case .array(let values)? = annotation.dictionary[PDFName("L")] else { return nil }
    let points = values.compactMap(numberValue)
    guard points.count == 4, points.allSatisfy(\.isFinite) else { return nil }
    return points
  }

  static func lineEndings(_ annotation: Annotation) -> (String, String) {
    guard case .array(let values)? = annotation.dictionary[PDFName("LE")], values.count >= 2
    else { return ("None", "None") }
    func name(_ value: PDFValue) -> String {
      guard case .name(let name) = value else { return "None" }
      return String(decoding: name.bytes, as: UTF8.self)
    }
    return (name(values[0]), name(values[1]))
  }

  static func vertices(_ annotation: Annotation) -> [Double]? {
    guard case .array(let values)? = annotation.dictionary[PDFName("Vertices")] else {
      return nil
    }
    let points = values.compactMap(numberValue)
    guard points.count == values.count, points.count >= 4, points.count % 2 == 0
    else { return nil }
    return points
  }

  static func borderWidth(_ annotation: Annotation) -> Double? {
    if case .dictionary(let border)? = annotation.dictionary[PDFName("BS")],
      let width = numberValue(border[PDFName("W")] ?? .null)
    {
      return width
    }
    if case .array(let values)? = annotation.dictionary[PDFName("Border")],
      values.count >= 3, let width = numberValue(values[2])
    {
      return width
    }
    return nil
  }

  static func numberValue(_ value: PDFValue) -> Double? {
    switch value {
    case .integer(let raw): return Double(raw)
    case .real(let raw): return raw
    default: return nil
    }
  }

  static func valid(rect: [Double]) -> Bool {
    rect.count == 4 && rect.allSatisfy(\.isFinite)
      && rect[2] > rect[0] && rect[3] > rect[1]
  }

  static func numbers(_ values: [Double]) -> String {
    values.map(number).joined(separator: ",")
  }

  static func number(_ value: Double) -> String {
    String(value)
  }

  static func hexColor(_ color: [Double]) -> String {
    let components: [Double]
    switch color.count {
    case 1: components = [color[0], color[0], color[0]]
    case 3: components = color
    default: return "#000000"
    }
    return "#" + components.map {
      String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded()))
    }.joined()
  }

  static func parseColor(_ raw: String?) -> [Double]? {
    guard let raw, !raw.isEmpty else { return nil }
    if raw.hasPrefix("#") {
      let hex = String(raw.dropFirst())
      guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
      return [
        Double((value >> 16) & 0xFF) / 255,
        Double((value >> 8) & 0xFF) / 255,
        Double(value & 0xFF) / 255,
      ]
    }
    let parts = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
    guard parts.count == 1 || parts.count == 3 else { return nil }
    let values = parts.compactMap { Double($0) }
    guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
    else { return nil }
    return values.count == 1 ? [values[0], values[0], values[0]] : values
  }

  static func escapeXML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  // MARK: - Merge helpers

  static func newEntryIssue(_ entry: CommentExchangeEntry) -> String? {
    guard valid(rect: entry.rect) else { return "invalid rectangle was skipped." }
    if let quads = entry.quadPoints {
      guard !quads.isEmpty, quads.count % 8 == 0, quads.allSatisfy(\.isFinite) else {
        return "invalid text-markup quadrilaterals were skipped."
      }
    } else if entry.subtype == PDFName("Highlight") || entry.subtype == PDFName("Underline")
      || entry.subtype == PDFName("StrikeOut") || entry.subtype == PDFName("Squiggly")
    {
      return "text markup has no quadrilaterals."
    }
    if entry.subtype == PDFName("Ink") {
      guard let strokes = entry.inkStrokes, !strokes.isEmpty else {
        return "ink has no stroke data."
      }
      for stroke in strokes {
        guard stroke.count >= 4, stroke.count % 2 == 0, stroke.allSatisfy(\.isFinite) else {
          return "ink has an invalid stroke."
        }
      }
    }
    if entry.subtype == PDFName("FreeText") {
      guard let text = entry.contents,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return "free text has no text." }
      guard AnnotationSupport.escapedLiteral(text) != nil else {
        return "free text is outside the supported WinAnsi character set."
      }
    }
    if entry.subtype == PDFName("Stamp") {
      let width = entry.borderWidth ?? 2
      guard width > 0,
        width <= min(entry.rect[2] - entry.rect[0], entry.rect[3] - entry.rect[1]) / 2
      else { return "stamp border is too wide for its rectangle." }
    }
    if entry.subtype == PDFName("Line") {
      guard let start = entry.lineStart, let end = entry.lineEnd,
        start.count == 2, end.count == 2, start.allSatisfy(\.isFinite),
        end.allSatisfy(\.isFinite), start != end
      else { return "line endpoints are invalid." }
      let supported: Set<PDFName> = [PDFName("None"), PDFName("ClosedArrow")]
      if let head = entry.startEnding, !supported.contains(head) {
        return "line start ending \(typeName(head)) is unsupported."
      }
      if let tail = entry.endEnding, !supported.contains(tail) {
        return "line end ending \(typeName(tail)) is unsupported."
      }
    }
    if entry.subtype == PDFName("Polygon") || entry.subtype == PDFName("PolyLine") {
      guard let points = entry.vertices, points.count >= 4, points.count % 2 == 0,
        points.allSatisfy(\.isFinite)
      else { return "polygon or polyline vertices are invalid." }
      if entry.subtype == PDFName("Polygon"), points.count < 6 {
        return "polygon needs at least three vertices."
      }
    }
    if let color = entry.color {
      guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
        return "color is invalid."
      }
    }
    if let opacity = entry.opacity {
      guard opacity.isFinite, opacity >= 0, opacity <= 1 else { return "opacity is invalid." }
    }
    if let width = entry.borderWidth {
      guard width.isFinite, width > 0, width <= 24 else { return "border width is invalid." }
    }
    if let state = entry.state, state.bytes.isEmpty { return "review state is empty." }
    if let model = entry.stateModel, model.bytes.isEmpty { return "review state model is empty." }
    return nil
  }

  static func updateCommand(
    for comment: Comment, entry: CommentExchangeEntry, identity: String, pageID: PDFObjectID
  ) -> UpdateCommentCommand? {
    let existingState = comment.reviewState == PDFName("None") ? nil : comment.reviewState
    let incomingState = entry.state.flatMap {
      $0 == PDFName("None") ? nil : $0
    }
    var changed = false
    if let contents = entry.contents, contents != (comment.contents ?? "") { changed = true }
    if let author = entry.author, author != (comment.author ?? "") { changed = true }
    if let modified = entry.modified, modified != (comment.annotation.modified ?? "") {
      changed = true
    }
    if let subject = entry.subject, subject != (comment.subject ?? "") { changed = true }
    if entry.state != nil, incomingState != existingState { changed = true }
    if comment.annotation.name == nil { changed = true }
    let existingAppearance = text(comment.annotation.dictionary[PDFName("DA")])
    if comment.subtype == PDFName("FreeText") {
      if let appearance = entry.defaultAppearance,
        !appearancesEqual(appearance, existingAppearance)
      {
        changed = true
      }
      let existingColor =
        comment.annotation.color ?? freeTextColor(from: existingAppearance)
      if let color = entry.color, !colorsEqual(color, existingColor) { changed = true }
    }
    guard changed else { return nil }
    return UpdateCommentCommand(
      pageID: pageID, annotationIndex: comment.annotation.index, contents: entry.contents,
      author: entry.author, modified: entry.modified, subject: entry.subject,
      state: entry.state, stateModel: entry.stateModel, identity: identity,
      color: comment.subtype == PDFName("FreeText") ? entry.color : nil,
      defaultAppearance: comment.subtype == PDFName("FreeText") ? entry.defaultAppearance : nil)
  }

  static func normalized(_ entry: CommentExchangeEntry, identity: String) -> CommentExchangeEntry {
    let quads: [Double]?
    if let points = entry.quadPoints, !points.isEmpty {
      quads = points
    } else if entry.subtype == PDFName("Highlight") || entry.subtype == PDFName("Underline")
      || entry.subtype == PDFName("StrikeOut") || entry.subtype == PDFName("Squiggly")
    {
      quads = quadPoints(from: entry.rect)
    } else {
      quads = nil
    }
    return CommentExchangeEntry(
      identity: identity, pageIndex: entry.pageIndex, subtype: entry.subtype,
      rect: entry.rect, quadPoints: quads, contents: entry.contents, author: entry.author,
      modified: entry.modified, creationDate: entry.creationDate, subject: entry.subject,
      state: entry.state, stateModel: entry.stateModel, color: entry.color,
      opacity: entry.opacity, flags: entry.flags, iconName: entry.iconName,
      inReplyTo: entry.inReplyTo, borderWidth: entry.borderWidth,
      inkStrokes: entry.inkStrokes, defaultAppearance: entry.defaultAppearance,
      lineStart: entry.lineStart, lineEnd: entry.lineEnd,
      startEnding: entry.startEnding, endEnding: entry.endEnding,
      vertices: entry.vertices)
  }

  static func quadPoints(from rect: [Double]) -> [Double] {
    [
      rect[0], rect[3], rect[2], rect[3],
      rect[0], rect[1], rect[2], rect[1],
    ]
  }

  static func derivedIdentity(_ entry: CommentExchangeEntry) -> String {
    let seed = [
      String(entry.pageIndex), typeName(entry.subtype), numbers(entry.rect),
      numbers(entry.quadPoints ?? []), entry.contents ?? "", entry.author ?? "",
      entry.modified ?? "", entry.defaultAppearance ?? "",
      numbers(entry.lineStart ?? []), numbers(entry.lineEnd ?? []),
      numbers(entry.vertices ?? []),
    ].joined(separator: "|")
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in seed.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return "spdf-xfdf-\(String(hash, radix: 16))"
  }

  static func parseNumbers(_ raw: String) -> [Double]? {
    let parts = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
    let values = parts.compactMap { Double($0) }
    guard !values.isEmpty, values.count == parts.count, values.allSatisfy(\.isFinite)
    else { return nil }
    return values
  }
}

/// Mutable parser state for one annotation element.
private final class Pending {
  let subtype: PDFName
  let attributes: [String: String]
  var inkStrokes: [[Double]] = []

  init(subtype: PDFName, attributes: [String: String]) {
    self.subtype = subtype
    self.attributes = attributes
  }

  func entry(contents: String?, defaultAppearance: String?) -> CommentExchangeEntry? {
    guard let page = Int(attributes["page"] ?? ""), page >= 0,
      let rect = CommentExchange.parseNumbers(attributes["rect"] ?? "")
    else { return nil }
    let normalizedRect = [
      min(rect[0], rect[2]), min(rect[1], rect[3]),
      max(rect[0], rect[2]), max(rect[1], rect[3]),
    ]
    guard CommentExchange.valid(rect: normalizedRect) else { return nil }
    let coords = attributes["coords"].flatMap(CommentExchange.parseNumbers)
    let state = nonEmpty(attributes["state"]).map { PDFName($0) }
    let stateModel = nonEmpty(attributes["statemodel"]).map { PDFName($0) }
    let color = CommentExchange.parseColor(attributes["color"])
    let opacity = attributes["opacity"].flatMap(Double.init).flatMap {
      $0.isFinite && $0 >= 0 && $0 <= 1 ? $0 : nil
    }
    let flags = attributes["flags"].flatMap(Int.init)
    let width = attributes["width"].flatMap(Double.init).flatMap {
      $0.isFinite && $0 > 0 ? $0 : nil
    }
    let identity = (attributes["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let parent = (attributes["inreplyto"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let lineStart = attributes["start"].flatMap(CommentExchange.parseNumbers).flatMap {
      $0.count == 2 ? $0 : nil
    }
    let lineEnd = attributes["end"].flatMap(CommentExchange.parseNumbers).flatMap {
      $0.count == 2 ? $0 : nil
    }
    let vertices = attributes["vertices"].flatMap(CommentExchange.parseNumbers)
    let result = CommentExchangeEntry(
      identity: identity, pageIndex: page, subtype: subtype, rect: normalizedRect,
      quadPoints: coords, contents: contents, author: nonEmpty(attributes["title"]),
      modified: nonEmpty(attributes["date"]),
      creationDate: nonEmpty(attributes["creationdate"]),
      subject: nonEmpty(attributes["subject"]), state: state, stateModel: stateModel,
      color: color, opacity: opacity, flags: flags,
      iconName: nonEmpty(attributes["icon"]).map { PDFName($0) },
      inReplyTo: parent.isEmpty ? nil : parent, borderWidth: width,
      inkStrokes: inkStrokes.isEmpty ? nil : inkStrokes,
      defaultAppearance: nonEmpty(defaultAppearance), lineStart: lineStart,
      lineEnd: lineEnd, startEnding: nonEmpty(attributes["head"]).map { PDFName($0) },
      endEnding: nonEmpty(attributes["tail"]).map { PDFName($0) }, vertices: vertices)
    return result.identity.isEmpty
      ? CommentExchangeEntry(
        identity: CommentExchange.derivedIdentity(result), pageIndex: result.pageIndex,
        subtype: result.subtype, rect: result.rect, quadPoints: result.quadPoints,
        contents: result.contents, author: result.author, modified: result.modified,
        creationDate: result.creationDate, subject: result.subject, state: result.state,
        stateModel: result.stateModel, color: result.color, opacity: result.opacity,
        flags: result.flags, iconName: result.iconName, inReplyTo: result.inReplyTo,
        borderWidth: result.borderWidth, inkStrokes: result.inkStrokes,
        defaultAppearance: result.defaultAppearance, lineStart: result.lineStart,
        lineEnd: result.lineEnd, startEnding: result.startEnding,
        endEnding: result.endEnding, vertices: result.vertices)
      : result
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

/// REV-01: insert imported comments in one undoable step. Imported /NM
/// identities and /IRT thread links are preserved.
public struct ImportCommentsCommand: PDFEditCommand, Sendable {
  public let entries: [CommentExchangeEntry]
  public let pageIDs: [PDFObjectID]
  public let existingParents: [String: PDFObjectID]

  public init(
    entries: [CommentExchangeEntry], pageIDs: [PDFObjectID],
    existingParents: [String: PDFObjectID] = [:]
  ) {
    self.entries = entries
    self.pageIDs = pageIDs
    self.existingParents = existingParents
  }

  public var name: String { "Import Comments" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    var ids: [PDFObjectID] = []
    for entry in entries where pageIDs.indices.contains(entry.pageIndex) {
      let id = pageIDs[entry.pageIndex]
      if !ids.contains(id) { ids.append(id) }
    }
    return ids
  }

  public func validate(in graph: PDFGraph) throws {
    guard !entries.isEmpty else {
      throw PDFError(.malformed, "There are no comments to import")
    }
    guard entries.count <= 10_000 else {
      throw PDFError(.limitExceeded, "Too many comments in one import")
    }
    var identities = Set(existingParents.keys)
    for entry in entries {
      guard pageIDs.indices.contains(entry.pageIndex) else {
        throw PDFError(.malformed, "An imported comment is outside the page range")
      }
      guard CommentExchange.supportedSubtypes.contains(entry.subtype) else {
        throw PDFError(.unsupported, "\(CommentExchange.typeName(entry.subtype)) import is unsupported")
      }
      guard !entry.identity.isEmpty, identities.insert(entry.identity).inserted else {
        throw PDFError(.malformed, "Imported comments have a duplicate identifier")
      }
      guard CommentExchange.valid(rect: entry.rect) else {
        throw PDFError(.malformed, "An imported comment has invalid geometry")
      }
      if let quads = entry.quadPoints {
        guard !quads.isEmpty, quads.count % 8 == 0, quads.allSatisfy(\.isFinite) else {
          throw PDFError(.malformed, "An imported comment has invalid quadrilaterals")
        }
      } else if entry.subtype == PDFName("Highlight") || entry.subtype == PDFName("Underline")
        || entry.subtype == PDFName("StrikeOut") || entry.subtype == PDFName("Squiggly")
      {
        throw PDFError(.malformed, "An imported text markup has no quadrilaterals")
      }
      if entry.subtype == PDFName("Ink") {
        guard let strokes = entry.inkStrokes, !strokes.isEmpty else {
          throw PDFError(.malformed, "An imported ink comment has no strokes")
        }
        for stroke in strokes {
          guard stroke.count >= 4, stroke.count % 2 == 0, stroke.allSatisfy(\.isFinite) else {
            throw PDFError(.malformed, "An imported ink stroke is invalid")
          }
        }
      }
      if entry.subtype == PDFName("Line") {
        guard let start = entry.lineStart, let end = entry.lineEnd,
          start.count == 2, end.count == 2, start.allSatisfy(\.isFinite),
          end.allSatisfy(\.isFinite), start != end
        else {
          throw PDFError(.malformed, "An imported line has invalid endpoints")
        }
        let supported: Set<PDFName> = [PDFName("None"), PDFName("ClosedArrow")]
        if let head = entry.startEnding, !supported.contains(head) {
          throw PDFError(.unsupported, "An imported line has an unsupported start ending")
        }
        if let tail = entry.endEnding, !supported.contains(tail) {
          throw PDFError(.unsupported, "An imported line has an unsupported end ending")
        }
      }
      if entry.subtype == PDFName("Polygon") || entry.subtype == PDFName("PolyLine") {
        guard let points = entry.vertices, points.count >= 4, points.count % 2 == 0,
          points.allSatisfy(\.isFinite)
        else {
          throw PDFError(.malformed, "An imported polygon or polyline has invalid vertices")
        }
        if entry.subtype == PDFName("Polygon"), points.count < 6 {
          throw PDFError(.malformed, "An imported polygon needs at least three vertices")
        }
      }
      if let color = entry.color {
        guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
          throw PDFError(.malformed, "An imported comment color is invalid")
        }
      }
      if let opacity = entry.opacity {
        guard opacity.isFinite, opacity >= 0, opacity <= 1 else {
          throw PDFError(.malformed, "An imported comment opacity is invalid")
        }
      }
      if let width = entry.borderWidth {
        guard width.isFinite, width > 0, width <= 24 else {
          throw PDFError(.malformed, "An imported comment border is invalid")
        }
      }
      if let parent = entry.inReplyTo, !parent.isEmpty,
        existingParents[parent] == nil,
        !entries.contains(where: { $0.identity == parent })
      {
        throw PDFError(.malformed, "An imported reply has no parent")
      }
    }
    let base = graph.objects.keys.map(\.number).max() ?? 0
    let needsFont = entries.contains {
      $0.subtype == PDFName("FreeText") || $0.subtype == PDFName("Stamp")
    }
    guard base + entries.count * 2 + (needsFont ? 1 : 0) <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for imported comments")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let base = graph.objects.keys.map(\.number).max() ?? 0
    var next = base + entries.count * 2 + 1
    let needsFont = entries.contains {
      $0.subtype == PDFName("FreeText") || $0.subtype == PDFName("Stamp")
    }
    var fontID: PDFObjectID?
    if needsFont {
      if let existing = AnnotationSupport.helveticaFontID(in: graph) {
        fontID = existing
      } else {
        fontID = PDFObjectID(next)
        graph.objects[PDFObjectID(next)] = .dictionary(
          AnnotationSupport.helveticaFontDictionary())
        next += 1
      }
    }
    var objectsByID = existingParents
    var allocated: [(entry: CommentExchangeEntry, annotationID: PDFObjectID)] = []
    for (index, entry) in entries.enumerated() {
      let annotationID = PDFObjectID(base + index * 2 + 1)
      objectsByID[entry.identity] = annotationID
      allocated.append((entry, annotationID))
    }
    for (index, pair) in allocated.enumerated() {
      let entry = pair.entry
      let appearanceID = PDFObjectID(base + index * 2 + 2)
      let color = entry.color ?? defaultColor(for: entry.subtype)
      let opacity = entry.opacity ?? defaultOpacity(for: entry.subtype)
      let width = entry.borderWidth ?? 1
      var dictionary = AnnotationSupport.annotationDictionary(
        subtype: entry.subtype, rect: entry.rect, color: color, opacity: opacity,
        contents: entry.contents, author: entry.author, modified: entry.modified,
        subject: entry.subject, appearance: appearanceID)
      dictionary[PDFName("F")] = .integer(Int64(entry.flags ?? 4))
      dictionary[PDFName("NM")] = .string(AnnotationText.encode(entry.identity))
      if let creation = entry.creationDate {
        dictionary[PDFName("CreationDate")] = .string(AnnotationText.encode(creation))
      }
      if let state = entry.state, state != PDFName("None") {
        dictionary[PDFName("State")] = .name(state)
        dictionary[PDFName("StateModel")] = .name(entry.stateModel ?? PDFName("Marked"))
      }
      if let parent = entry.inReplyTo, let parentID = objectsByID[parent] {
        dictionary[PDFName("IRT")] = .reference(parentID)
        dictionary[PDFName("RT")] = .name(PDFName("R"))
      }
      if let quads = entry.quadPoints,
        entry.subtype == PDFName("Highlight") || entry.subtype == PDFName("Underline")
          || entry.subtype == PDFName("StrikeOut") || entry.subtype == PDFName("Squiggly")
      {
        dictionary[PDFName("QuadPoints")] = .array(quads.map { .real($0) })
      }
      if entry.subtype == PDFName("Ink"), let strokes = entry.inkStrokes {
        dictionary[PDFName("InkList")] = .array(
          strokes.map { .array($0.map { .real($0) }) })
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
      }
      if entry.subtype == PDFName("Square") || entry.subtype == PDFName("Circle") {
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
        dictionary[PDFName("Border")] = .array([.integer(0), .integer(0), .real(width)])
      }
      if entry.subtype == PDFName("Text") {
        dictionary[PDFName("Name")] = .name(entry.iconName ?? PDFName("Comment"))
        dictionary[PDFName("Open")] = .boolean(false)
      }
      if entry.subtype == PDFName("Line"), let start = entry.lineStart,
        let end = entry.lineEnd
      {
        dictionary[PDFName("L")] = .array([start[0], start[1], end[0], end[1]].map { .real($0) })
        dictionary[PDFName("LE")] = .array([
          .name(Self.lineEnding(entry.startEnding).pdfName),
          .name(Self.lineEnding(entry.endEnding).pdfName),
        ])
        dictionary[PDFName("IC")] = .array(color.map { .real($0) })
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
      }
      if entry.subtype == PDFName("Polygon") || entry.subtype == PDFName("PolyLine"),
        let points = entry.vertices
      {
        dictionary[PDFName("Vertices")] = .array(points.map { .real($0) })
        dictionary[PDFName("IC")] = .array(color.map { .real($0) })
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
      }
      if entry.subtype == PDFName("FreeText"), let fontID {
        let size = CommentExchange.freeTextFontSize(entry.defaultAppearance)
        dictionary[PDFName("DA")] = .string(
          Data(
            AnnotationSupport.defaultAppearanceString(fontSize: size, color: color).utf8))
        dictionary[PDFName("DR")] = .dictionary([
          PDFName("Font"): .dictionary([PDFName("Helvetica"): .reference(fontID)])
        ])
        dictionary[PDFName("Q")] = .integer(0)
      }
      if entry.subtype == PDFName("Stamp") {
        dictionary[PDFName("Name")] = .name(entry.iconName ?? PDFName("Draft"))
        dictionary[PDFName("BS")] = .dictionary([
          PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(width),
        ])
      }
      graph.objects[pair.annotationID] = .dictionary(dictionary)
      graph.objects[appearanceID] = .stream(
        appearance(
          for: entry, color: color, opacity: opacity, width: width,
          quads: entry.quadPoints ?? CommentExchange.quadPoints(from: entry.rect),
          fontID: fontID))
      try AnnotationSupport.appendToAnnots(
        .reference(pair.annotationID), pageID: pageIDs[entry.pageIndex], in: &graph)
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(next))
    return graph
  }

  private func appearance(
    for entry: CommentExchangeEntry, color: [Double], opacity: Double, width: Double,
    quads: [Double], fontID: PDFObjectID?
  ) -> PDFStream {
    switch entry.subtype {
    case PDFName("Text"):
      let size = min(max(min(entry.rect[2] - entry.rect[0], entry.rect[3] - entry.rect[1]), 8), 72)
      return AddNoteCommand.appearance(size: size, color: color)
    case PDFName("Highlight"):
      return AddHighlightCommand.appearance(
        quads: quads, rect: entry.rect, color: color, opacity: opacity)
    case PDFName("Underline"):
      return AddTextMarkupCommand.appearance(
        style: .underline, quads: quads, rect: entry.rect, color: color, opacity: opacity)
    case PDFName("StrikeOut"):
      return AddTextMarkupCommand.appearance(
        style: .strikeout, quads: quads, rect: entry.rect, color: color, opacity: opacity)
    case PDFName("Squiggly"):
      return Self.squigglyAppearance(
        quads: quads, rect: entry.rect, color: color, opacity: opacity)
    case PDFName("Square"):
      return AddShapeCommand.appearance(
        kind: .square, rect: entry.rect, borderColor: color, fillColor: nil,
        borderWidth: width, opacity: opacity)
    case PDFName("Circle"):
      return AddShapeCommand.appearance(
        kind: .circle, rect: entry.rect, borderColor: color, fillColor: nil,
        borderWidth: width, opacity: opacity)
    case PDFName("Ink"):
      return AddInkCommand.appearance(
        strokes: entry.inkStrokes ?? [], rect: entry.rect, color: color,
        borderWidth: width, opacity: opacity)
    case PDFName("FreeText"):
      guard let fontID, let text = entry.contents else {
        return AddHighlightCommand.appearance(
          quads: quads, rect: entry.rect, color: color, opacity: opacity)
      }
      return AddFreeTextCommand.appearance(
        rect: entry.rect, text: text,
        fontSize: CommentExchange.freeTextFontSize(entry.defaultAppearance),
        textColor: color, fillColor: nil, borderColor: nil, borderWidth: 0,
        fontID: fontID)
    case PDFName("Stamp"):
      guard let fontID else {
        return AddHighlightCommand.appearance(
          quads: quads, rect: entry.rect, color: color, opacity: opacity)
      }
      return AddStampCommand.appearance(
        rect: entry.rect, label: CommentExchange.stampLabel(entry.iconName),
        color: color, borderWidth: width, fontID: fontID)
    case PDFName("Line"):
      guard let start = entry.lineStart, let end = entry.lineEnd else {
        return AddHighlightCommand.appearance(
          quads: quads, rect: entry.rect, color: color, opacity: opacity)
      }
      let geometry = AddLineCommand.geometry(
        from: start, to: end, borderWidth: width,
        startEnding: Self.lineEnding(entry.startEnding),
        endEnding: Self.lineEnding(entry.endEnding))
      return AddLineCommand.appearance(
        from: start, to: end, rect: geometry.rect, startArrow: geometry.startArrow,
        endArrow: geometry.endArrow, color: color, borderWidth: width, opacity: opacity)
    case PDFName("Polygon"), PDFName("PolyLine"):
      return Self.polygonAppearance(
        points: entry.vertices ?? [], rect: entry.rect, color: color,
        borderWidth: width, opacity: opacity,
        closed: entry.subtype == PDFName("Polygon"))
    default:
      return AddHighlightCommand.appearance(
        quads: quads, rect: entry.rect, color: color, opacity: opacity)
    }
  }

  private static func polygonAppearance(
    points: [Double], rect: [Double], color: [Double], borderWidth: Double,
    opacity: Double, closed: Bool
  ) -> PDFStream {
    guard points.count >= 4, points.count % 2 == 0 else {
      return AnnotationSupport.formAppearance(
        rect: rect, content: "q\nQ\n",
        resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
    }
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) rg\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) RG\n"
    content += "\(AnnotationSupport.number(borderWidth)) w\n"
    content += "/GS0 gs\n"
    func local(_ index: Int) -> String {
      let x = points[index] - rect[0]
      let y = points[index + 1] - rect[1]
      return "\(AnnotationSupport.number(x)) \(AnnotationSupport.number(y))"
    }
    content += "\(local(0)) m\n"
    var index = 2
    while index + 1 < points.count {
      content += "\(local(index)) l\n"
      index += 2
    }
    if closed {
      content += "h\n"
      content += borderWidth > 0 ? "B\n" : "f\n"
    } else if borderWidth > 0 {
      content += "S\n"
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
  }

  static func squigglyAppearance(
    quads: [Double], rect: [Double], color: [Double], opacity: Double
  ) -> PDFStream {    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) RG\n"
    content += "/GS0 gs\n"
    for index in stride(from: 0, to: quads.count, by: 8) {
      let ul = [quads[index], quads[index + 1]]
      let ur = [quads[index + 2], quads[index + 3]]
      let ll = [quads[index + 4], quads[index + 5]]
      let lr = [quads[index + 6], quads[index + 7]]
      let height = max(abs(ul[1] - ll[1]), abs(ur[1] - lr[1]))
      let thickness = max(0.75, height * 0.06)
      let amplitude = max(0.6, height * 0.10)
      let start = min(ll[0], lr[0]) - rect[0]
      let end = max(ll[0], lr[0]) - rect[0]
      let y = min(ll[1], lr[1]) + thickness / 2 - rect[1]
      let step = max(1.5, height * 0.12)
      content += "\(AnnotationSupport.number(thickness)) w\n"
      content += "\(AnnotationSupport.number(start)) \(AnnotationSupport.number(y)) m\n"
      var x = start + step
      var up = true
      while x < end {
        content += "\(AnnotationSupport.number(x)) "
        content += "\(AnnotationSupport.number(y + (up ? amplitude : -amplitude))) l\n"
        x += step
        up.toggle()
      }
      content += "\(AnnotationSupport.number(end)) \(AnnotationSupport.number(y)) l\nS\n"
    }
    content += "Q\n"
    return AnnotationSupport.formAppearance(
      rect: rect, content: content,
      resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false))
  }

  private func defaultColor(for subtype: PDFName) -> [Double] {
    switch subtype {
    case PDFName("Highlight"), PDFName("Text"), PDFName("Squiggly"):
      return [1, 0.84, 0]
    case PDFName("Underline"), PDFName("StrikeOut"):
      return [1, 0, 0]
    case PDFName("Stamp"):
      return [0.8, 0, 0]
    default:
      return [0, 0, 0]
    }
  }

  private func defaultOpacity(for subtype: PDFName) -> Double {
    subtype == PDFName("Highlight") ? 0.5 : 1
  }

  private static func lineEnding(_ name: PDFName?) -> LineEnding {
    name == PDFName("ClosedArrow") ? .closedArrow : .none
  }
}

public struct UpdateCommentCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let annotationIndex: Int
  public let contents: String?
  public let author: String?
  public let modified: String?
  public let subject: String?
  public let state: PDFName?
  public let stateModel: PDFName?
  public let identity: String?
  public let color: [Double]?
  public let defaultAppearance: String?

  public init(
    pageID: PDFObjectID, annotationIndex: Int, contents: String? = nil,
    author: String? = nil, modified: String? = nil, subject: String? = nil,
    state: PDFName? = nil, stateModel: PDFName? = nil, identity: String? = nil,
    color: [Double]? = nil, defaultAppearance: String? = nil
  ) {
    self.pageID = pageID
    self.annotationIndex = annotationIndex
    self.contents = contents
    self.author = author
    self.modified = modified
    self.subject = subject
    self.state = state
    self.stateModel = stateModel
    self.identity = identity
    self.color = color
    self.defaultAppearance = defaultAppearance
  }

  public var name: String { "Update Comment" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws {
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    if let subtype = Annotation.subtype(of: entry.dictionary) {
      guard subtype != PDFName("Link"), subtype != PDFName("Widget") else {
        throw PDFError(.unsupported, "This annotation is not a review comment")
      }
    }
    if let state {
      guard !state.bytes.isEmpty else {
        throw PDFError(.malformed, "Review state is empty")
      }
    }
    if let color {
      guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
        throw PDFError(.malformed, "Comment text color is invalid")
      }
    }
    if Annotation.subtype(of: entry.dictionary) == PDFName("FreeText"),
      let contents, AnnotationSupport.escapedLiteral(contents) == nil
    {
      throw PDFError(.unsupported, "Free text is outside the supported character set")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let entry = try AnnotationSupport.annotationEntry(
      in: graph, pageID: pageID, index: annotationIndex)
    var dictionary = entry.dictionary
    applyText(contents, key: "Contents", to: &dictionary)
    applyText(author, key: "T", to: &dictionary)
    applyText(modified, key: "M", to: &dictionary)
    applyText(subject, key: "Subj", to: &dictionary)
    if let state {
      if state == PDFName("None") {
        dictionary[PDFName("State")] = nil
        dictionary[PDFName("StateModel")] = nil
      } else {
        dictionary[PDFName("State")] = .name(state)
        dictionary[PDFName("StateModel")] = .name(stateModel ?? PDFName("Marked"))
      }
    }
    if let identity, !identity.isEmpty, dictionary[PDFName("NM")] == nil {
      dictionary[PDFName("NM")] = .string(AnnotationText.encode(identity))
    }
    if Annotation.subtype(of: dictionary) == PDFName("FreeText") {
      let existingAppearance = Self.text(dictionary[PDFName("DA")])
      let appearanceString =
        defaultAppearance ?? existingAppearance
        ?? AnnotationSupport.defaultAppearanceString(fontSize: 12, color: color ?? [0, 0, 0])
      let textColor = color ?? CommentExchange.freeTextColor(from: appearanceString) ?? [0, 0, 0]
      let fontSize = CommentExchange.freeTextFontSize(appearanceString)
      let text =
        contents ?? Self.text(dictionary[PDFName("Contents")]) ?? ""
      let fontID = try ensureHelveticaFont(in: &graph, dictionary: &dictionary)
      let appearanceID = try ensureAppearance(in: &graph, dictionary: &dictionary)
      if let color {
        dictionary[PDFName("C")] = .array(color.map { .real($0) })
      }
      graph.objects[appearanceID] = .stream(
        AddFreeTextCommand.appearance(
          rect: Self.rect(dictionary[PDFName("Rect")]) ?? [0, 0, 1, 1],
          text: text, fontSize: fontSize, textColor: textColor, fillColor: nil,
          borderColor: nil, borderWidth: 0, fontID: fontID))
      dictionary[PDFName("DA")] = .string(
        Data(
          AnnotationSupport.defaultAppearanceString(fontSize: fontSize, color: textColor).utf8))
      dictionary[PDFName("DR")] = .dictionary([
        PDFName("Font"): .dictionary([PDFName("Helvetica"): .reference(fontID)])
      ])
    }
    try AnnotationSupport.setAnnotation(dictionary, entry: entry, pageID: pageID, in: &graph)
    return graph
  }

  private static func text(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  private static func rect(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value, values.count == 4 else { return nil }
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let raw): return Double(raw)
      case .real(let raw): return raw
      default: return nil
      }
    }
    return numbers.count == 4 ? numbers : nil
  }

  private func ensureHelveticaFont(
    in graph: inout PDFGraph, dictionary: inout [PDFName: PDFValue]
  ) throws -> PDFObjectID {
    if case .dictionary(let resources)? = dictionary[PDFName("DR")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let id)? = fonts[PDFName("Helvetica")],
      graph.objects[id] != nil
    {
      return id
    }
    if let id = AnnotationSupport.helveticaFontID(in: graph) { return id }
    let id = try AnnotationSupport.allocateOne(in: graph)
    graph.objects[id] = .dictionary(AnnotationSupport.helveticaFontDictionary())
    graph.trailer[PDFName("Size")] = .integer(Int64(id.number + 1))
    return id
  }

  private func ensureAppearance(
    in graph: inout PDFGraph, dictionary: inout [PDFName: PDFValue]
  ) throws -> PDFObjectID {
    if case .dictionary(let appearance)? = dictionary[PDFName("AP")],
      case .reference(let id)? = appearance[PDFName("N")],
      graph.objects[id] != nil
    {
      return id
    }
    let id = try AnnotationSupport.allocateOne(in: graph)
    dictionary[PDFName("AP")] = .dictionary([PDFName("N"): .reference(id)])
    graph.trailer[PDFName("Size")] = .integer(Int64(id.number + 1))
    return id
  }

  private func applyText(
    _ value: String?, key: String, to dictionary: inout [PDFName: PDFValue]
  ) {
    guard let value else { return }
    if value.isEmpty {
      dictionary[PDFName(key)] = nil
    } else {
      dictionary[PDFName(key)] = .string(AnnotationText.encode(value))
    }
  }
}
