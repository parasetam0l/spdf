import Foundation
import PDFCore
import PDFEditing
import PDFFixtures

/// AUT-01/AUT-02 test fixtures: synthetic documents whose content, comment,
/// form, bookmark and metadata sources are exact and deterministic.
enum SearchTestSupport {
  static func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-aut46-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  static func write(_ data: Data, to directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  /// Minimal synthetic document with exact ASCII page text lines.
  static func textDocument(pages: [String]) throws -> Data {
    precondition(!pages.isEmpty)
    let pageIDs = (0..<pages.count).map { PDFObjectID(4 + $0 * 2) }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(pages.count)),
        PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
      ]),
    ]
    for (index, pageID) in pageIDs.enumerated() {
      let contentID = PDFObjectID(pageID.number + 1)
      let content = "BT /F1 18 Tf 42 710 Td (\(escape(pages[index]))) Tj ET\n"
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([0, 0, 612, 792].map { .integer(Int64($0)) }),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
    }
    return try PDFWriter.write(
      PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))]))
  }

  /// Two content pages plus one comment, one form value, one bookmark and
  /// title/subject/keywords metadata. Query "zebra" hits only the structured
  /// sources; query "fixture" hits only page text.
  static func multiSourceDocument() throws -> Data {
    var graph = PDFFixtures.graph(pages: 2)
    let pageIDs = try PDFParser.parse(try PDFWriter.write(graph)).pageIDs
    graph = try AddBookmarkCommand(title: "Zebra appendix", pageID: pageIDs[1])
      .apply(to: graph)
    graph = try AddNoteCommand(
      pageID: pageIDs[0], at: [72, 700], contents: "Review zebra comment",
      author: "Robin")
      .apply(to: graph)
    graph = try AddTextFieldCommand(
      pageID: pageIDs[0], rect: [72, 560, 340, 585], name: "Client",
      defaultValue: "Zebra Client")
      .apply(to: graph)
    graph = try SetDocumentMetadataCommand(metadata: DocumentMetadata(
      title: "Zebra Handbook", subject: "quokka review",
      keywords: "zebra quokka"))
      .apply(to: graph)
    return try PDFWriter.write(graph)
  }

  /// An AES-256 encrypted copy of a one-page document with the given text.
  /// Permissions default to none granted (copy/extraction denied).
  static func encryptedDocument(
    text: String, permissions: Int32 = 0
  ) throws -> Data {
    let plain = try PDFParser.parse(try textDocument(pages: [text])).graph
    return try PDFWriter.write(
      plain,
      encryption: PDFEncryptionOptions(
        userPassword: "user", ownerPassword: "owner", permissions: permissions))
  }

  static func escape(_ text: String) -> String {
    var result = ""
    for character in text {
      switch character {
      case "(", ")", "\\":
        result.append("\\")
        result.append(character)
      default:
        result.append(character)
      }
    }
    return result
  }
}
