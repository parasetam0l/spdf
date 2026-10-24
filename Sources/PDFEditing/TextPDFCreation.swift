import Foundation
import PDFCore

/// PAG-08: create a new PDF from plain text. Lines are wrapped and paginated
/// with a conservative Helvetica estimate, then written through the existing
/// added-text command so the result is ordinary editable page content.
public enum TextPDFCreation {
  public enum PageLayout: String, Sendable, CaseIterable {
    case letter
    case a4

    public var title: String { self == .letter ? "Letter" : "A4" }
    public var size: [Double] { self == .letter ? [612, 792] : [595.276, 841.89] }
  }

  public static func make(
    text: String,
    layout: PageLayout = .letter,
    fontSize: Double = 12,
    margins: Double = 36,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The text is empty")
    }
    guard fontSize.isFinite, (6...72).contains(fontSize) else {
      throw PDFError(.malformed, "The font size must be between 6 and 72 points")
    }
    let page = layout.size
    guard margins.isFinite, margins >= 0,
      margins * 2 < min(page[0], page[1]) - 24
    else {
      throw PDFError(.malformed, "The margins leave no room for text")
    }
    let width = page[0] - margins * 2
    let height = page[1] - margins * 2
    let charactersPerLine = max(8, Int(width / (fontSize * 0.5)))
    let linesPerPage = max(1, Int(height / (fontSize * 1.2)))
    let lines = wrappedLines(text, charactersPerLine: charactersPerLine)
    let pages = stride(from: 0, to: max(lines.count, 1), by: linesPerPage).map { start in
      Array(lines[start..<min(lines.count, start + linesPerPage)])
    }
    guard !pages.isEmpty else {
      throw PDFError(.malformed, "The text produced no pages")
    }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ])
    ]
    var pageIDs: [PDFObjectID] = []
    for (index, _) in pages.enumerated() {
      let pageID = PDFObjectID(3 + index * 2)
      let contentID = PDFObjectID(pageID.number + 1)
      pageIDs.append(pageID)
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .real(page[0]), .real(page[1]),
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      objects[contentID] = .stream(
        PDFStream(dictionary: [PDFName("Length"): .integer(0)], bytes: Data()))
    }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pageIDs.count)),
      PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
    ])
    var graph = PDFGraph(
      objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    for (index, pageLines) in pages.enumerated() {
      graph = try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextObjectCommand(
            pageID: pageIDs[index],
            rect: [margins, margins, page[0] - margins, page[1] - margins],
            text: pageLines.joined(separator: "\n"),
            style: AddedTextStyle(
              size: fontSize, alignment: .left, lineSpacing: 1.2),
            clips: false)
        ]), to: graph, limits: limits)
    }
    return try PDFWriter.write(graph, limits: limits)
  }

  static func wrappedLines(_ text: String, charactersPerLine: Int) -> [String] {
    var result: [String] = []
    for paragraph in text.components(separatedBy: .newlines) {
      if paragraph.isEmpty {
        result.append("")
        continue
      }
      var line = ""
      for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
        let fragment = String(word)
        let candidate = line.isEmpty ? fragment : line + " " + fragment
        if candidate.count > charactersPerLine, !line.isEmpty {
          result.append(line)
          line = fragment
        } else {
          line = candidate
        }
      }
      result.append(line)
    }
    return result
  }
}
