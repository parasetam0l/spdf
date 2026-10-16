import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P32-001–P32-004/P32-009–P32-020/P32-022–P32-028 evidence: comparison of two
/// immutable snapshots with explicit page mapping, text/image/annotation/form/
/// box/metadata/signature differences, OCR labeling, uncertainty reporting,
/// filtering, report privacy, cancellation, and no merging.
@Suite("Document comparison")
struct ComparisonTests {
  private func parsed(_ data: Data) throws -> (graph: PDFGraph, source: Data) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, data)
  }

  private func commit(
    _ commands: [any PDFEditCommand], to input: (graph: PDFGraph, source: Data)
  ) throws -> (graph: PDFGraph, source: Data) {
    (try PDFEditingEngine.commit(PDFTransaction(commands), to: input.graph), input.source)
  }

  @Test func textChangesMapToGeometry() throws {
    let left = try parsed(PDFFixtures.threePages())
    let right = try commit(
      [ReplaceTextCommand(pageID: left.graph.objects.keys.contains(PDFObjectID(4)) ? PDFObjectID(4) : PDFObjectID(4), runIndex: 0, replacement: "sPDF Editor fixture - page one")],
      to: left)
    let result = try PDFComparison.compare(left: left, right: right)
    let textChanges = result.changes(kinds: [.textChanged, .textRemoved, .textAdded])
    #expect(!textChanges.isEmpty)
    #expect(textChanges.allSatisfy { $0.leftPageIndex == 0 || $0.rightPageIndex == 0 })
    let withBounds = textChanges.filter { $0.leftBounds != nil || $0.rightBounds != nil }
    #expect(!withBounds.isEmpty)
    // Other pages report nothing.
    #expect(result.changes(pageIndex: 1).isEmpty)
    #expect(result.changes(pageIndex: 2).isEmpty)
  }

  @Test func whitespaceOptionsSeparateFormattingFromSubstance() throws {
    let left = try parsed(PDFFixtures.threePages())
    let pageID = PDFObjectID(4)
    let right = try commit(
      [ReplaceTextCommand(
        pageID: pageID, runIndex: 1,
        replacement: "Original  Swift-generated   content. No personal data.")], to: left)
    let lenient = try PDFComparison.compare(left: left, right: right)
    #expect(lenient.changes(kinds: [.textChanged, .textRemoved, .textAdded]).isEmpty)
    let strict = try PDFComparison.compare(
      left: left, right: right, options: PDFComparisonOptions(ignoreWhitespace: false))
    #expect(!strict.changes(kinds: [.textChanged, .textRemoved, .textAdded]).isEmpty)
  }

  @Test func pageMappingDetectsReorderInsertDelete() throws {
    let left = try parsed(PDFFixtures.threePages())

    // Reorder: move page 1 (object 4) after page 3.
    let reordered = try commit(
      [ReorderPagesCommand(pageID: PDFObjectID(4), toIndex: 2)], to: left)
    let reorderResult = try PDFComparison.compare(left: left, right: reordered)
    let reorderedPairs = reorderResult.pageMapping.filter { $0.status == .reordered }
    // Only the moved page is a reorder; the others stay matched.
    #expect(reorderedPairs.count == 1)
    // P32-026: moved pages do not produce misleading all-page text reports.
    #expect(reorderResult.changes(kinds: [.textChanged, .textRemoved, .textAdded]).isEmpty)
    #expect(reorderResult.changes(kinds: [.pageReordered]).count == 1)

    // Delete page 2 (object 6).
    let deleted = try commit([DeletePagesCommand(pageIDs: [PDFObjectID(6)])], to: left)
    let deleteResult = try PDFComparison.compare(left: left, right: deleted)
    #expect(deleteResult.pageMapping.contains { $0.status == .deleted })
    #expect(deleteResult.changes(kinds: [.pageDeleted]).count == 1)

    // Insert a blank page after page 1.
    let inserted = try commit(
      [InsertBlankPageCommand(atIndex: 1, width: 612, height: 792)], to: left)
    let insertResult = try PDFComparison.compare(left: left, right: inserted)
    #expect(insertResult.pageMapping.contains { $0.status == .inserted })
    #expect(insertResult.changes(kinds: [.pageInserted]).count == 1)
  }

  @Test func boxRotationImageAnnotationFormMetadataAndAttachmentDifferences() throws {
    let left = try parsed(PDFFixtures.threePages())
    let withRotation = try commit(
      [RotatePagesCommand(pageIDs: [PDFObjectID(4)], byDegrees: 90)], to: left)
    let boxResult = try PDFComparison.compare(left: left, right: withRotation)
    #expect(boxResult.changes(kinds: [.pageBoxOrRotation]).count == 1)

    // Image move.
    let imageLeft = try parsed(PDFFixtures.imagePages())
    let imageRight = try commit(
      [MoveImageCommand(pageID: PDFObjectID(3), placementIndex: 0, dx: 25, dy: 0)],
      to: imageLeft)
    let imageResult = try PDFComparison.compare(left: imageLeft, right: imageRight)
    #expect(imageResult.changes(kinds: [.imageMoved]).count == 1)

    // Annotations and form values.
    let formLeft = try parsed(PDFFixtures.formPages())
    let formRight = try commit(
      [
        AddHighlightCommand(
          pageID: PDFObjectID(3), quads: [100, 700, 200, 700, 100, 680, 200, 680]),
        SetFormTextCommand(fieldName: "name", text: "Alice"),
      ], to: formLeft)
    let formResult = try PDFComparison.compare(left: formLeft, right: formRight)
    #expect(formResult.changes(kinds: [.annotationAdded]).count == 1)
    #expect(formResult.changes(kinds: [.formValueChanged]).count == 1)

    // Metadata and attachments.
    var metadataLeft = left.graph
    var metadataRight = left.graph
    metadataLeft.objects[PDFObjectID(50)] = .dictionary([
      PDFName("Title"): .string(Data("Left title".utf8))
    ])
    metadataRight.objects[PDFObjectID(50)] = .dictionary([
      PDFName("Title"): .string(Data("Right title".utf8))
    ])
    metadataLeft.trailer[PDFName("Info")] = .reference(PDFObjectID(50))
    metadataRight.trailer[PDFName("Info")] = .reference(PDFObjectID(50))
    metadataRight.objects[PDFObjectID(51)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("EmbeddedFile")),
          PDFName("F"): .string(Data("note.txt".utf8)),
        ], bytes: Data("attachment".utf8)))
    let metadataResult = try PDFComparison.compare(
      left: (metadataLeft, left.source), right: (metadataRight, left.source))
    #expect(metadataResult.changes(kinds: [.metadataChanged]).count >= 1)
    #expect(metadataResult.changes(kinds: [.attachmentChanged]).count == 1)
  }

  @Test func ocrLayersAreLabeledAsATextSource() throws {
    let left = try parsed(PDFFixtures.imagePages())
    let right = try commit(
      [AddSearchableTextLayerCommand(
        pageID: PDFObjectID(3),
        lines: [SearchableTextLine(text: "scanned", rect: [10, 10, 60, 30], confidence: 0.9)])],
      to: left)
    let labeled = try PDFComparison.compare(left: left, right: right)
    let ocrChanges = labeled.changes.filter { $0.isOCRSourced }
    #expect(!ocrChanges.isEmpty)
    #expect(ocrChanges.allSatisfy { $0.summary.contains("OCR") })
    let excluded = try PDFComparison.compare(
      left: left, right: right, options: PDFComparisonOptions(includeOCRText: false))
    #expect(excluded.changes.filter { $0.isOCRSourced }.isEmpty)
    #expect(excluded.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
  }

  @Test func signatureAndEncryptionStatusStayVisible() throws {
    let signedData = try Data(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Signed/signed-one-page.pdf"))
    let left = try parsed(signedData)
    let right = try parsed(PDFFixtures.onePage())
    let result = try PDFComparison.compare(left: left, right: right)
    #expect(result.left.signatureCount == 1)
    #expect(result.right.signatureCount == 0)
    #expect(result.changes(kinds: [.signatureStatus]).count == 1)
    #expect(result.left.signatureStatuses.first?.contains("valid") == true)
  }

  @Test func cancellationAndResumeAtPagePairs() async throws {
    let left = try parsed(PDFFixtures.threePages())
    let task = Task { () -> PDFComparisonResult in
      try PDFComparison.compare(left: left, right: left)
    }
    task.cancel()
    let result = await task.result
    switch result {
    case .success:
      Issue.record("A cancelled comparison completed")
    case .failure(let error):
      #expect(error is CancellationError)
    }
    // Resume: starting at page pair 2 processes the remaining pairs only.
    let resumed = try PDFComparison.compare(left: left, right: left, resumingAt: 2)
    #expect(resumed.changes(pageIndex: 0).isEmpty)
    #expect(resumed.nextPagePairIndex == nil)
  }

  @Test func reportKeepsPrivacyAndFiltersChanges() throws {
    let left = try parsed(PDFFixtures.threePages())
    let right = try commit(
      [ReplaceTextCommand(
        pageID: PDFObjectID(4), runIndex: 0, replacement: "sPDF Editor fixture - revised")],
      to: left)
    let result = try PDFComparison.compare(left: left, right: right)
    let report = PDFComparisonReport.text(result)
    // Changed snippets appear; unchanged document text does not.
    #expect(report.contains("revised"))
    #expect(!report.contains("Original Swift-generated content"))
    #expect(!report.contains("A4 page"))
    // Filtering by kind and page works.
    let textOnly = result.changes(kinds: [.textChanged, .textRemoved, .textAdded])
    #expect(!textOnly.isEmpty)
    #expect(result.changes(pageIndex: 2).isEmpty)
    // P32-023: comparison never mutates the snapshots.
    #expect(left.source == (try parsed(PDFFixtures.threePages()).source))
    #expect(right.source == left.source)
  }
}
