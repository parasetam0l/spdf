import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// AUT-01: advanced search scopes across multiple documents/folders, with
/// file/page/context provenance, permission awareness and the unsearchable vs
/// no-match distinction.
struct AdvancedSearchScopeTests {
  private func document(
    _ name: String, _ data: Data, password: String? = nil
  ) -> AdvancedSearchDocument {
    AdvancedSearchDocument(
      displayName: name, url: URL(fileURLWithPath: "/tmp/\(name)"), data: data,
      password: password)
  }

  @Test func multiSourceScopesIdentifyFilePageAndProvenance() throws {
    let data = try SearchTestSupport.multiSourceDocument()
    let report = try AdvancedSearch.search(
      query: "zebra", documents: [document("handbook.pdf", data)])
    #expect(report.files.count == 1)
    let file = report.files[0]
    #expect(file.status == .searched)
    #expect(file.totalHits == 5)
    #expect(file.searchedSources == [
      .documentText, .comment, .formValue, .bookmark, .metadata,
    ])
    #expect(report.totalHits == 5)
    #expect(report.filesWithHits == 1)
    #expect(report.filesWithoutMatches == 0)

    let comment = try #require(file.hits.first { $0.source == .comment })
    #expect(comment.pageIndex == 0)
    #expect(comment.pageLabel == "Page 1")
    #expect(comment.matchedText == "zebra")
    #expect(comment.context?.contains("Review zebra comment") == true)
    #expect(comment.context?.contains("Robin") == true)
    #expect(comment.isPermissionRestricted == false)

    let form = try #require(file.hits.first { $0.source == .formValue })
    #expect(form.pageIndex == 0)
    #expect(form.context?.contains("Client: Zebra Client") == true)
    #expect(form.matchedText == "Zebra")

    let bookmark = try #require(file.hits.first { $0.source == .bookmark })
    #expect(bookmark.pageIndex == 1)
    #expect(bookmark.pageLabel == "Page 2")
    #expect(bookmark.context?.contains("Zebra appendix") == true)

    let metadata = try #require(file.hits.first { $0.source == .metadata })
    #expect(metadata.pageIndex == nil)
    #expect(metadata.pageLabel == nil)
    #expect(metadata.context?.contains("Title: Zebra Handbook") == true)
    let keywordHit = file.hits.contains {
      $0.source == .metadata && $0.context?.contains("Keywords") == true
    }
    #expect(keywordHit)
  }

  @Test func documentTextSearchKeepsPageContext() throws {
    let data = try PDFFixtures.threePages()
    let report = try AdvancedSearch.search(
      query: "fixture", documents: [document("three.pdf", data)])
    let file = report.files[0]
    #expect(file.status == .searched)
    #expect(file.totalHits == 3)
    #expect(file.searchedSources == [.documentText])
    #expect(file.hits.map(\.pageIndex) == [0, 1, 2])
    #expect(file.hits.allSatisfy { $0.pageLabel != nil })
    #expect(file.hits.allSatisfy { $0.context?.contains("fixture") == true })
    #expect(file.hits.allSatisfy { $0.matchedText == "fixture" })
  }

  @Test func scopeTogglesExcludeUnselectedSources() throws {
    let data = try SearchTestSupport.multiSourceDocument()
    var options = AdvancedSearchOptions()
    options.includeComments = false
    var report = try AdvancedSearch.search(
      query: "zebra", documents: [document("handbook.pdf", data)], options: options)
    #expect(!report.files[0].hits.contains { $0.source == .comment })
    #expect(report.files[0].hits.contains { $0.source == .formValue })

    options.includeComments = true
    options.includeMetadata = false
    report = try AdvancedSearch.search(
      query: "zebra", documents: [document("handbook.pdf", data)], options: options)
    #expect(!report.files[0].hits.contains { $0.source == .metadata })
    #expect(report.files[0].hits.contains { $0.source == .bookmark })

    options = AdvancedSearchOptions(includeComments: false, includeFormValues: false,
      includeBookmarks: false, includeMetadata: false)
    report = try AdvancedSearch.search(
      query: "fixture", documents: [document("handbook.pdf", data)], options: options)
    #expect(report.files[0].hits.allSatisfy { $0.source == .documentText })
    #expect(report.files[0].hits.allSatisfy { $0.source != .comment })
  }

  @Test func caseAndResultLimitOptionsAreApplied() throws {
    let data = try PDFFixtures.threePages()
    var report = try AdvancedSearch.search(
      query: "FIXTURE", documents: [document("three.pdf", data)])
    #expect(report.totalHits == 3)
    var options = AdvancedSearchOptions(textOptions: TextSearchOptions(caseSensitive: true))
    report = try AdvancedSearch.search(
      query: "FIXTURE", documents: [document("three.pdf", data)], options: options)
    #expect(report.totalHits == 0)
    #expect(report.files[0].status == .searched)

    options = AdvancedSearchOptions(maximumResultsPerDocument: 1)
    let multi = try SearchTestSupport.multiSourceDocument()
    report = try AdvancedSearch.search(
      query: "zebra", documents: [document("handbook.pdf", multi)], options: options)
    #expect(report.totalHits == 5)
    #expect(report.files[0].hits.count == 1)
  }

  @Test func unsearchableContentIsDistinctFromNoMatch() throws {
    let scanned = try PDFFixtures.scannedPages()
    let plain = try PDFFixtures.onePage()
    let report = try AdvancedSearch.search(
      query: "zebra",
      documents: [document("scan.pdf", scanned), document("plain.pdf", plain)])
    let scan = report.files[0]
    let text = report.files[1]
    #expect(scan.status == .noSearchableContent)
    #expect(scan.totalHits == 0)
    #expect(scan.searchedSources.isEmpty)
    #expect(text.status == .searched)
    #expect(text.totalHits == 0)
    #expect(text.summary == "No matches")
    #expect(report.noContentFiles == 1)
    #expect(report.filesWithoutMatches == 1)
    #expect(report.unsearchableFiles == 0)
    #expect(report.summary.contains("without searchable content"))
    #expect(report.summary.contains("searched with no match"))
  }

  @Test func lockedAndPermissionRestrictedDocumentsAreHandled() throws {
    let lockedData = try SearchTestSupport.encryptedDocument(
      text: "ZebraSecret meadow")
    var report = try AdvancedSearch.search(
      query: "ZebraSecret", documents: [document("locked.pdf", lockedData)])
    #expect(report.files[0].status == .passwordRequired)
    #expect(report.unsearchableFiles == 1)
    #expect(report.totalHits == 0)

    report = try AdvancedSearch.search(
      query: "ZebraSecret",
      documents: [document("user.pdf", lockedData, password: "user")])
    let restricted = report.files[0]
    #expect(restricted.status == .searched)
    #expect(restricted.permissionRestricted)
    #expect(restricted.totalHits == 1)
    #expect(restricted.hits[0].pageIndex == 0)
    #expect(restricted.hits[0].context == nil)
    #expect(restricted.hits[0].matchedText == nil)
    #expect(report.permissionRestrictedFiles == 1)
    #expect(report.summary.contains("permission-restricted"))

    report = try AdvancedSearch.search(
      query: "ZebraSecret",
      documents: [document("owner.pdf", lockedData, password: "owner")])
    let owner = report.files[0]
    #expect(!owner.permissionRestricted)
    #expect(owner.hits[0].context?.contains("ZebraSecret meadow") == true)
    #expect(owner.hits[0].matchedText == "ZebraSecret")
  }

  @Test func folderSearchRecursesAndHonorsLimits() throws {
    let root = try SearchTestSupport.tempDirectory("folder")
    try SearchTestSupport.write(try PDFFixtures.threePages(), to: root, name: "Alpha.pdf")
    try SearchTestSupport.write(
      try SearchTestSupport.multiSourceDocument(), to: root, name: "sub/Beta.pdf")
    try SearchTestSupport.write(
      try SearchTestSupport.encryptedDocument(text: "ZebraSecret"),
      to: root, name: "locked.pdf")
    try SearchTestSupport.write(try PDFFixtures.scannedPages(), to: root, name: "scan.pdf")
    try SearchTestSupport.write(try PDFFixtures.onePage(), to: root, name: ".hidden.pdf")
    try SearchTestSupport.write(Data("notes".utf8), to: root, name: "notes.txt")

    var report = try AdvancedSearch.search(query: "fixture", folder: root)
    let names = Set(report.files.map(\.displayName))
    #expect(names == ["Alpha.pdf", "Beta.pdf", "locked.pdf", "scan.pdf"])
    #expect(!names.contains(".hidden.pdf"))
    #expect(report.filesWithHits == 2)
    #expect(report.noContentFiles == 1)
    #expect(report.unsearchableFiles == 1)
    let alpha = try #require(report.files.first { $0.displayName == "Alpha.pdf" })
    #expect(alpha.totalHits == 3)
    let beta = try #require(report.files.first { $0.displayName == "Beta.pdf" })
    #expect(beta.totalHits == 2)

    var options = AdvancedSearchOptions(includeSubfolders: false)
    report = try AdvancedSearch.search(query: "fixture", folder: root, options: options)
    #expect(Set(report.files.map(\.displayName)) == ["Alpha.pdf", "locked.pdf", "scan.pdf"])

    options = AdvancedSearchOptions(maximumDocuments: 1)
    report = try AdvancedSearch.search(query: "fixture", folder: root, options: options)
    #expect(report.files.count == 1)
    #expect(report.skippedDocuments >= 1)
  }

  @Test func invalidRequestsThrow() throws {
    let data = try PDFFixtures.onePage()
    #expect(throws: PDFError.self) {
      _ = try AdvancedSearch.search(query: "   ", documents: [document("a.pdf", data)])
    }
    #expect(throws: PDFError.self) {
      var options = AdvancedSearchOptions()
      options.contextCharacters = 5
      _ = try AdvancedSearch.search(
        query: "x", documents: [document("a.pdf", data)], options: options)
    }
    #expect(throws: PDFError.self) {
      let options = AdvancedSearchOptions(
        searchDocumentText: false, includeRecognizedOCRText: false,
        includeComments: false, includeFormValues: false, includeBookmarks: false,
        includeMetadata: false)
      _ = try AdvancedSearch.search(
        query: "x", documents: [document("a.pdf", data)], options: options)
    }
    #expect(throws: PDFError.self) {
      _ = try AdvancedSearch.search(
        query: "x", folder: URL(fileURLWithPath: "/nonexistent-search-folder-xyz"))
    }
  }
}
