import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// AUT-02: the local full-text index. Covered: explicit locations, incremental
/// refresh (unchanged/added/updated/moved/missing), protected-plaintext
/// exclusion, accuracy after edits/deletions, persistence and validation.
struct LocalSearchIndexTests {
  private struct Fixture {
    let root: URL
    let vault: URL
    var index: LocalSearchIndex
    let one: URL
    let two: URL
    let rich: URL
    let indexURL: URL
  }

  private func makeFixture() throws -> Fixture {
    let root = try SearchTestSupport.tempDirectory("index")
    let vault = root.appendingPathComponent("vault", isDirectory: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    let one = try SearchTestSupport.write(
      try SearchTestSupport.textDocument(pages: ["Zebra meadow notes"]),
      to: vault, name: "one.pdf")
    let two = try SearchTestSupport.write(
      try SearchTestSupport.textDocument(pages: ["Quokka harbor notes"]),
      to: vault, name: "two.pdf")
    try SearchTestSupport.write(
      try SearchTestSupport.textDocument(pages: ["Zebra mountain notes"]),
      to: vault, name: "sub/three.pdf")
    let rich = try SearchTestSupport.write(
      try SearchTestSupport.multiSourceDocument(), to: vault, name: "rich.pdf")
    try SearchTestSupport.write(
      try SearchTestSupport.encryptedDocument(text: "ZebraSecretPlain"),
      to: vault, name: "locked.pdf")
    try SearchTestSupport.write(try PDFFixtures.scannedPages(), to: vault, name: "scan.pdf")
    try SearchTestSupport.write(try PDFFixtures.onePage(), to: root, name: "outside.pdf")
    let indexURL = root.appendingPathComponent("Index/FullTextIndex.json")
    var index = LocalSearchIndex()
    try index.addLocation(path: vault.path)
    _ = try index.refresh()
    return Fixture(
      root: root, vault: vault, index: index, one: one, two: two, rich: rich,
      indexURL: indexURL)
  }

  @Test func explicitLocationsAreValidated() throws {
    let root = try SearchTestSupport.tempDirectory("locations")
    let vault = root.appendingPathComponent("vault", isDirectory: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    #expect(throws: PDFError.self) {
      _ = try SearchIndexLocation.validated("relative/folder", includeSubfolders: true)
    }
    #expect(throws: PDFError.self) {
      _ = try SearchIndexLocation.validated("/", includeSubfolders: true)
    }
    #expect(throws: PDFError.self) {
      _ = try SearchIndexLocation.validated(
        FileManager.default.homeDirectoryForCurrentUser.path, includeSubfolders: true)
    }
    #expect(throws: PDFError.self) {
      _ = try SearchIndexLocation.validated(
        "/System/Library", includeSubfolders: true)
    }
    #expect(throws: PDFError.self) {
      _ = try SearchIndexLocation.validated(
        root.appendingPathComponent("missing").path, includeSubfolders: true)
    }
    let location = try SearchIndexLocation.validated(
      vault.path, includeSubfolders: true)
    #expect(location.path == vault.standardizedFileURL.resolvingSymlinksInPath().path)

    var index = LocalSearchIndex()
    try index.addLocation(path: vault.path)
    #expect(index.locations.count == 1)
    #expect(throws: PDFError.self) { try index.addLocation(path: vault.path) }

    var bounded = LocalSearchIndex(options: SearchIndexOptions(maximumLocations: 1))
    try bounded.addLocation(path: vault.path)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    #expect(throws: PDFError.self) { try bounded.addLocation(path: second.path) }
  }

  @Test func refreshIndexesUnprotectedFilesAndNeverStoresProtectedPlaintext() throws {
    var fixture = try makeFixture()
    let report = try fixture.index.refresh()
    #expect(report.scannedFiles == 6)
    #expect(report.addedFiles == 0)
    #expect(report.unchangedFiles == 6)
    #expect(fixture.index.entries.count == 6)
    #expect(fixture.index.indexedDocuments == 4)
    #expect(fixture.index.protectedDocuments == 1)
    let locked = try #require(fixture.index.entry(for: fixture.vault
      .appendingPathComponent("locked.pdf").path))
    #expect(locked.status == .protectedExcluded)
    #expect(locked.pages.isEmpty)
    #expect(locked.metadataValues.isEmpty)
    let scan = try #require(fixture.index.entry(for: fixture.vault
      .appendingPathComponent("scan.pdf").path))
    #expect(scan.status == .noSearchableContent)
    #expect(scan.pages.isEmpty)
    let one = try #require(fixture.index.entry(for: fixture.one.path))
    #expect(one.status == .indexed)
    #expect(one.pages.first?.documentText.contains("Zebra meadow") == true)
    let outsidePath = fixture.root.appendingPathComponent("outside.pdf").path
    #expect(fixture.index.entry(for: outsidePath) == nil)

    let data = try fixture.index.encoded()
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("ZebraSecretPlain"))
    #expect(json.contains("Zebra meadow"))

    let refreshed = try fixture.index.refresh()
    #expect(refreshed.addedFiles == 0)
    #expect(refreshed.updatedFiles == 0)
    #expect(refreshed.unchangedFiles == 6)
    let reencoded = try fixture.index.encoded()
    #expect(reencoded == data)
  }

  @Test func indexSearchKeepsFilePageAndSourceProvenance() throws {
    var fixture = try makeFixture()
    let report = try fixture.index.search("Zebra")
    #expect(report.totalHits == 7)
    #expect(report.hits.count == 7)
    #expect(report.indexedDocuments == 4)
    #expect(report.protectedDocuments == 1)
    #expect(report.noContentDocuments == 1)
    #expect(report.missingDocuments == 0)
    #expect(Set(report.hits.map(\.fileName)) == ["one.pdf", "three.pdf", "rich.pdf"])
    #expect(report.hits.allSatisfy { $0.source == .metadata || $0.pageLabel != nil })
    #expect(report.hits.allSatisfy { $0.context.lowercased().contains("zebra") })
    #expect(report.hits.allSatisfy { $0.matchedText.lowercased() == "zebra" })
    #expect(report.hits.contains { $0.source == .comment })
    #expect(report.hits.contains { $0.source == .formValue })
    #expect(report.hits.contains { $0.source == .bookmark })
    #expect(report.hits.contains { $0.source == .metadata && $0.pageIndex == nil })
    #expect(report.summary.contains("protected"))

    let quokka = try fixture.index.search("Quokka")
    #expect(quokka.totalHits == 3)
    #expect(quokka.hits.contains { $0.fileName == "two.pdf" })
    #expect(quokka.hits.contains { $0.fileName == "rich.pdf" && $0.source == .metadata })
    let none = try fixture.index.search("wombat")
    #expect(none.totalHits == 0)
    #expect(none.indexedDocuments == 4)
  }

  @Test func incrementalRefreshTracksEditsDeletionsAndMoves() throws {
    var fixture = try makeFixture()
    try SearchTestSupport.write(
      try SearchTestSupport.textDocument(pages: ["Emu valley notes"]),
      to: fixture.vault, name: "one.pdf")
    let edited = try fixture.index.refresh()
    #expect(edited.updatedFiles == 1)
    #expect(edited.addedFiles == 0)
    #expect(edited.unchangedFiles == 5)
    let afterEdit = try fixture.index.search("Zebra")
    #expect(!afterEdit.hits.contains { $0.fileName == "one.pdf" })
    let emu = try fixture.index.search("Emu")
    #expect(emu.totalHits == 1)
    #expect(emu.hits[0].fileName == "one.pdf")

    try FileManager.default.removeItem(at: fixture.two)
    let deleted = try fixture.index.refresh()
    #expect(deleted.removedFiles == 1)
    let missing = try #require(fixture.index.entry(for: fixture.two.path))
    #expect(missing.status == .missing)
    #expect(missing.pages.isEmpty)
    let quokka = try fixture.index.search("Quokka")
    #expect(!quokka.hits.contains { $0.fileName == "two.pdf" })
    #expect(quokka.missingDocuments == 1)
    #expect(quokka.summary.contains("missing"))

    let moved = fixture.vault.appendingPathComponent("moved-emu.pdf")
    try Data(contentsOf: fixture.one).write(to: moved)
    try FileManager.default.removeItem(at: fixture.one)
    let movedReport = try fixture.index.refresh()
    #expect(movedReport.movedFiles == 1)
    #expect(movedReport.addedFiles == 0)
    #expect(movedReport.removedFiles == 0)
    #expect(fixture.index.entry(for: fixture.one.path) == nil)
    let movedHits = try fixture.index.search("Emu")
    #expect(movedHits.totalHits == 1)
    #expect(movedHits.hits[0].path == moved.path)
  }

  @Test func persistenceRoundTripsAndRejectsTamperedIndexes() throws {
    var fixture = try makeFixture()
    try fixture.index.save(to: fixture.indexURL)
    let loaded = try LocalSearchIndex.load(from: fixture.indexURL)
    #expect(loaded == fixture.index)
    #expect(LocalSearchIndex.disclosure.contains("unencrypted"))
    let missing = try LocalSearchIndex.load(
      from: fixture.root.appendingPathComponent("missing-index.json"))
    #expect(missing.entries.isEmpty)

    let data = try fixture.index.encoded()
    var object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["version"] = 99
    let versionTampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: PDFError.self) { _ = try LocalSearchIndex(data: versionTampered) }

    var duplicated = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var entries = try #require(duplicated["entries"] as? [[String: Any]])
    entries[1]["path"] = entries[0]["path"]
    duplicated["entries"] = entries
    let duplicateData = try JSONSerialization.data(withJSONObject: duplicated)
    #expect(throws: PDFError.self) { _ = try LocalSearchIndex(data: duplicateData) }

    var plaintext = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var protectedEntries = try #require(plaintext["entries"] as? [[String: Any]])
    let protectedIndex = try #require(protectedEntries.firstIndex {
      ($0["status"] as? String) == "protectedExcluded"
    })
    protectedEntries[protectedIndex]["pages"] = [[
      "pageIndex": 0,
      "documentText": "LeakedProtectedText",
      "comments": [String](),
      "formValues": [String](),
      "bookmarks": [String](),
    ]]
    plaintext["entries"] = protectedEntries
    let plaintextData = try JSONSerialization.data(withJSONObject: plaintext)
    #expect(throws: PDFError.self) { _ = try LocalSearchIndex(data: plaintextData) }
  }

  @Test func searchLimitsAndLocationRemovalAreExplicit() throws {
    var fixture = try makeFixture()
    let limited = try fixture.index.search(
      "Zebra", options: SearchIndexSearchOptions(maximumResults: 1))
    #expect(limited.hits.count == 1)
    #expect(limited.totalHits > 1)
    #expect(throws: PDFError.self) { _ = try fixture.index.search("   ") }
    #expect(throws: PDFError.self) {
      _ = try fixture.index.search(
        "Zebra", options: SearchIndexSearchOptions(contextCharacters: 1))
    }
    let before = fixture.index.entries.count
    let removed = try fixture.index.removeLocation(path: fixture.vault.path)
    #expect(removed == before)
    #expect(fixture.index.entries.isEmpty)
    #expect(fixture.index.locations.isEmpty)
    #expect(throws: PDFError.self) { _ = try fixture.index.refresh() }
    #expect(throws: PDFError.self) {
      try fixture.index.removeLocation(path: fixture.vault.path)
    }
  }
}
