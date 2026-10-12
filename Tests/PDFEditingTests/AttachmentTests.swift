import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P34-017–P34-020/P34-028: attachment inventory, byte-exact extraction,
/// path-traversal refusal, and add/remove with safe file specifications.
@Suite("Attachments")
struct AttachmentTests {
  @Test func inventoryListsNamesTypesAndSizes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.attachmentPages())
    let attachments = PDFAttachmentInventory.attachments(in: parsed.graph)
    #expect(attachments.count == 2)
    let notes = try #require(attachments.first { $0.name == "notes.txt" })
    #expect(notes.fileName == "notes.txt")
    #expect(notes.description == "Release notes")
    #expect(notes.mimeType == "text/plain")
    #expect(notes.size == "Attachment payload one.\n".utf8.count)
    #expect(
      try PDFAttachmentInventory.data(of: notes, in: parsed.graph)
        == Data("Attachment payload one.\n".utf8))
    #expect(notes.streamObjectID == PDFObjectID(20))

    let unsafe = try #require(attachments.first { $0.name == "../unsafe name.txt" })
    #expect(unsafe.fileName == "../unsafe name.txt")
    #expect(unsafe.size == "Compressed payload two.\n".utf8.count)
    // The stream is Flate-compressed; extraction returns the decoded bytes.
    #expect(
      try PDFAttachmentInventory.data(of: unsafe, in: parsed.graph)
        == Data("Compressed payload two.\n".utf8))
  }

  @Test func extractionPreservesBytesAndSanitizesPaths() throws {
    let parsed = try PDFParser.parse(PDFFixtures.attachmentPages())
    let attachments = PDFAttachmentInventory.attachments(in: parsed.graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-attachments-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = try PDFAttachmentExport.extract(attachments, from: parsed.graph, to: directory)
    #expect(urls.count == 2)
    let names = urls.map { $0.lastPathComponent }.sorted()
    #expect(names == ["notes.txt", "unsafe name.txt"])
    let base = directory.standardizedFileURL.path + "/"
    for url in urls {
      #expect(url.standardizedFileURL.path.hasPrefix(base))
      #expect(!url.path.contains(".."))
    }
    let unsafeURL = try #require(urls.first { $0.lastPathComponent == "unsafe name.txt" })
    let extracted = try String(contentsOf: unsafeURL, encoding: .utf8)
    #expect(extracted == "Compressed payload two.\n")
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents.count == 2)
  }

  @Test func safeFileNamesNeverTraverse() {
    #expect(PDFAttachmentExport.safeFileName("../../evil.txt") == "evil.txt")
    #expect(PDFAttachmentExport.safeFileName("a/b\\c.txt") == "c.txt")
    #expect(PDFAttachmentExport.safeFileName("") == "attachment")
    #expect(PDFAttachmentExport.safeFileName("..") == "attachment")
    #expect(PDFAttachmentExport.safeFileName("na:me.txt") == "na_me.txt")
    #expect(PDFAttachmentExport.safeFileName("line\nbreak.txt") == "line_break.txt")
    #expect(PDFAttachmentExport.safeFileName("plain.txt") == "plain.txt")
  }

  @Test func duplicateNamesGetDeterministicSuffixes() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    var edited = graph
    for name in ["first", "second"] {
      edited = try PDFEditingEngine.commit(
        PDFTransaction([
          AddAttachmentCommand(
            name: name, fileName: "report.txt", mimeType: "text/plain",
            data: Data("payload \(name)".utf8))
        ]), to: edited)
    }
    let attachments = PDFAttachmentInventory.attachments(in: edited)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-attachments-dup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = try PDFAttachmentExport.extract(attachments, from: edited, to: directory)
    #expect(urls.map { $0.lastPathComponent }.sorted() == ["report-1.txt", "report.txt"])
  }

  @Test func addAndRemoveRoundTrip() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let payload = Data("Attached through the canonical core.\n".utf8)
    let added = try PDFEditingEngine.commit(
      PDFTransaction([
        AddAttachmentCommand(
          name: "readme.txt", fileName: "readme.txt", mimeType: "text/plain",
          description: "Read me", data: payload)
      ]), to: parsed.graph)
    let attachments = PDFAttachmentInventory.attachments(in: added)
    #expect(attachments.count == 1)
    #expect(attachments[0].name == "readme.txt")
    #expect(attachments[0].description == "Read me")
    #expect(try PDFAttachmentInventory.data(of: attachments[0], in: added) == payload)

    // Round-trip through the writer and reparse.
    let reparsed = try PDFParser.parse(try PDFWriter.write(added))
    let reAttachments = PDFAttachmentInventory.attachments(in: reparsed.graph)
    #expect(reAttachments.count == 1)
    #expect(
      try PDFAttachmentInventory.data(of: reAttachments[0], in: reparsed.graph) == payload)

    let removed = try PDFEditingEngine.commit(
      PDFTransaction([RemoveAttachmentCommand(name: "readme.txt")]), to: reparsed.graph)
    #expect(PDFAttachmentInventory.attachments(in: removed).isEmpty)
    guard case .dictionary(let catalog)? = removed.objects[PDFObjectID(1)] else {
      Issue.record("Catalog missing after removal")
      return
    }
    #expect(catalog[PDFName("Names")] == nil)
    // The filespec and stream objects are gone (nothing references them).
    #expect(removed.objects.count == reparsed.graph.objects.count - 2)
  }

  @Test func addRefusalsAreExplicit() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([AddAttachmentCommand(name: "  ", fileName: "a.txt", data: Data())]),
        to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([AddAttachmentCommand(name: "a", fileName: "", data: Data())]), to: graph)
    }
    let once = try PDFEditingEngine.commit(
      PDFTransaction([AddAttachmentCommand(name: "a", fileName: "a.txt", data: Data("a".utf8))]),
      to: graph)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([AddAttachmentCommand(name: "a", fileName: "b.txt", data: Data("b".utf8))]),
        to: once)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RemoveAttachmentCommand(name: "missing")]), to: once)
    }
  }

  @Test func removalKeepsSharedStreams() throws {
    // Two filespecs sharing one embedded stream: removing one keeps the bytes
    // for the other, and removing both drops the stream.
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let shared = Data("shared bytes\n".utf8)
    graph.objects[PDFObjectID(90)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("EmbeddedFile")),
          PDFName("Subtype"): .name(PDFName("text/plain")),
        ], bytes: shared))
    for (index, name) in ["one.txt", "two.txt"].enumerated() {
      graph.objects[PDFObjectID(91 + index)] = .dictionary([
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data(name.utf8)),
        PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(90))]),
      ])
    }
    graph.objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
      PDFName("Names"): .dictionary([
        PDFName("EmbeddedFiles"): .dictionary([
          PDFName("Names"): .array([
            .string(Data("one.txt".utf8)), .reference(PDFObjectID(91)),
            .string(Data("two.txt".utf8)), .reference(PDFObjectID(92)),
          ])
        ])
      ]),
    ])
    let afterFirst = try PDFEditingEngine.commit(
      PDFTransaction([RemoveAttachmentCommand(name: "one.txt")]), to: graph)
    #expect(afterFirst.objects[PDFObjectID(90)] != nil)
    #expect(afterFirst.objects[PDFObjectID(92)] != nil)
    let remaining = PDFAttachmentInventory.attachments(in: afterFirst)
    #expect(remaining.count == 1)
    #expect(try PDFAttachmentInventory.data(of: remaining[0], in: afterFirst) == shared)
    let afterBoth = try PDFEditingEngine.commit(
      PDFTransaction([RemoveAttachmentCommand(name: "two.txt")]), to: afterFirst)
    #expect(afterBoth.objects[PDFObjectID(90)] == nil)
    #expect(PDFAttachmentInventory.attachments(in: afterBoth).isEmpty)
  }
}
