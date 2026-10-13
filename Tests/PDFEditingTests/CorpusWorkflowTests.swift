import Foundation
import PDFCore
import Testing

@testable import PDFEditing

/// P40-003: the owner-selected workflow matrix on the private corpus.
/// The corpus lives under ignored `Work/Corpus/` and is absent in CI, so
/// this test skips cleanly when the manifest is missing and only runs on
/// machines with owner-supplied documents. No filenames, content, or
/// hashes are recorded — only ids, counts, and outcome classes.
@Suite("Private corpus workflows")
struct CorpusWorkflowTests {
  private struct Entry: Decodable {
    var id: String
    var path: String
    var pages: Int
  }

  private struct Manifest: Decodable {
    var version: Int
    var documents: [Entry]
  }

  @Test func workflowMatrixOnPrivateCorpus() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let corpusRoot = root.appendingPathComponent("Work/Corpus")
    let manifestURL = corpusRoot.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: manifestURL))
    #expect(manifest.version == 1)
    #expect(!manifest.documents.isEmpty)
    var accepted = 0
    var limited = 0
    for entry in manifest.documents {
      let url = corpusRoot.appendingPathComponent(entry.path)
      let data = try Data(contentsOf: url, options: .alwaysMapped)
      let parsed: ParsedPDF
      do {
        parsed = try PDFParser.parse(data)
      } catch let error as PDFError {
        // Only explicit bounded refusals are acceptable on real
        // documents; anything else is a new compatibility finding.
        #expect(
          error.kind == .unsupported || error.kind == .limitExceeded,
          "\(entry.id): unexpected \(error.kind) (\(error.message))")
        limited += 1
        print("[P40-003] \(entry.id): refused (\(error.kind))")
        continue
      }
      #expect(
        parsed.pageIDs.count == entry.pages,
        "\(entry.id): parsed \(parsed.pageIDs.count) pages, manifest says \(entry.pages)")
      // Text extraction across every page.
      var before = ""
      for pageID in parsed.pageIDs {
        let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
        before += layout.clusters.map(\.text).joined(separator: "\n")
      }
      // Full-rewrite save, independent reopen, preservation check.
      let written = try PDFWriter.write(parsed.graph)
      let reopened = try PDFParser.parse(written)
      #expect(
        reopened.pageIDs.count == parsed.pageIDs.count,
        "\(entry.id): reopened page count changed")
      var after = ""
      for pageID in reopened.pageIDs {
        let layout = try PageTextLayout.build(pageID: pageID, in: reopened.graph)
        after += layout.clusters.map(\.text).joined(separator: "\n")
      }
      #expect(after == before, "\(entry.id): extracted text changed across save/reopen")
      accepted += 1
      print(
        "[P40-003] \(entry.id): \(parsed.pageIDs.count) pages, "
          + "\(before.count) text chars, rewrite \(written.count) bytes, preserved")
    }
    print("[P40-003] corpus workflows: \(accepted) accepted, \(limited) explicitly refused")
    #expect(accepted > 0, "corpus matrix ran but nothing was accepted")
  }
}
