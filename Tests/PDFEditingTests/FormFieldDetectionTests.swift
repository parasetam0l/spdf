import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-01 evidence: field detection with confidence, eligibility and an
/// explicit review flow that never creates fields silently.
@Suite("Form field detection")
struct FormFieldDetectionTests {
  private let pageBounds: [Double] = [0, 0, 612, 792]

  // MARK: Pure heuristics

  @Test func colonLabelProposesBoundedTextField() {
    let lines = [
      FormDetectionTextLine(text: "Full Name:", rect: [72, 700, 140, 712], source: .documentText),
      FormDetectionTextLine(text: "Date:", rect: [320, 700, 360, 712], source: .documentText),
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: PDFObjectID(3), pageBounds: pageBounds, textLines: lines, shapes: [],
      existingFields: [])
    #expect(outcome.report.isDetectable)
    #expect(outcome.report.textLineCount == 2)
    let name = outcome.candidates.first { $0.kind == .text && $0.label == "Full Name" }
    #expect(name != nil)
    guard let name else { return }
    #expect(name.isEligible)
    #expect(name.source == .documentText)
    #expect(name.confidence > 0.7)
    #expect(name.primaryRect[0] >= 140 && name.primaryRect[2] <= 316)
    #expect(name.suggestedName == "FullName")
    #expect(name.evidence.contains { $0.contains("colon") })
  }

  @Test func underscoreLeaderBecomesTextField() {
    let line = FormDetectionTextLine(
      text: "Signature: ______________", rect: [72, 600, 320, 612], source: .documentText)
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: [line], shapes: [],
      existingFields: [])
    let candidate = outcome.candidates.first { $0.kind == .text }
    #expect(candidate != nil)
    guard let candidate else { return }
    #expect(candidate.isEligible)
    #expect(candidate.label == "Signature")
    #expect(candidate.confidence >= 0.85)
    #expect(candidate.warnings.isEmpty)
  }

  @Test func paintedSquareWithAdjacentLabelBecomesCheckbox() {
    let shapes = [FormDetectionShape(kind: .rectangle, rect: [72, 500, 84, 512])]
    let lines = [
      FormDetectionTextLine(text: "Agree to terms", rect: [94, 498, 210, 512], source: .documentText)
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: lines, shapes: shapes,
      existingFields: [])
    let checkbox = outcome.candidates.first { $0.kind == .checkbox }
    #expect(checkbox != nil)
    guard let checkbox else { return }
    #expect(checkbox.isEligible)
    #expect(checkbox.label == "Agree to terms")
    #expect(checkbox.suggestedName == "Agreetoterms")
    #expect(checkbox.primaryRect == [72, 500, 84, 512])
    #expect(checkbox.evidence.contains { $0.contains("painted rectangle") })
  }

  @Test func circleRowBecomesRadioGroupWithExportValues() {
    let shapes = [
      FormDetectionShape(kind: .ellipse, rect: [72, 400, 84, 412]),
      FormDetectionShape(kind: .ellipse, rect: [102, 400, 114, 412]),
      FormDetectionShape(kind: .ellipse, rect: [132, 400, 144, 412]),
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: [], shapes: shapes,
      existingFields: [])
    let radio = outcome.candidates.first { $0.kind == .radio }
    #expect(radio != nil)
    guard let radio else { return }
    #expect(radio.isEligible)
    #expect(radio.rects.count == 3)
    #expect(radio.exportValues == ["Option1", "Option2", "Option3"])
    #expect(radio.confidence > 0.8)
    #expect(radio.warnings.contains { $0.contains("default") })
  }

  @Test func overlappingExistingFieldIsRefused() {
    let existing = FormField(
      fieldID: PDFObjectID(50), name: "Agree", kind: .button, flags: 0, value: nil,
      defaultValue: nil,
      widgets: [
        FormWidget(
          objectID: PDFObjectID(51), pageIndex: 0, rect: [70, 498, 86, 514], appearanceStates: [],
          appearanceState: nil)
      ], options: [], selectedIndexes: [], maxLength: nil)
    let shapes = [FormDetectionShape(kind: .rectangle, rect: [72, 500, 84, 512])]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: [], shapes: shapes,
      existingFields: [existing])
    let checkbox = outcome.candidates.first { $0.kind == .checkbox }
    #expect(checkbox != nil)
    #expect(checkbox?.isEligible == false)
    #expect(checkbox?.refusalReason?.contains("overlaps the existing field Agree") == true)
  }

  @Test func lowConfidenceRecognizedTextIsRefused() {
    let line = FormDetectionTextLine(
      text: "Name: __________", rect: [72, 600, 260, 612],
      source: .recognizedText(confidence: 0.35))
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: [line], shapes: [],
      existingFields: [])
    let candidate = outcome.candidates.first
    #expect(candidate != nil)
    #expect(candidate?.isEligible == false)
    #expect(candidate?.refusalReason?.contains("confidence") == true)
  }

  @Test func geometryOutsidePageIsRefused() {
    let line = FormDetectionTextLine(
      text: "Notes:", rect: [560, 600, 610, 612], source: .documentText)
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: [line], shapes: [],
      existingFields: [])
    let candidate = outcome.candidates.first { $0.kind == .text }
    #expect(candidate != nil)
    #expect(candidate?.isEligible == false)
    #expect(candidate?.refusalReason?.contains("outside the page box") == true)
  }

  @Test func duplicateLabelsAndUnicodeLabelsGetReadableUniqueNames() {
    let lines = [
      FormDetectionTextLine(text: "Name:", rect: [72, 700, 110, 712], source: .documentText),
      FormDetectionTextLine(text: "Name:", rect: [72, 650, 110, 662], source: .documentText),
      FormDetectionTextLine(
        text: "E-Posta (İş):", rect: [72, 600, 180, 612], source: .documentText),
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: lines, shapes: [],
      existingFields: [])
    let names = outcome.candidates.map(\.suggestedName)
    #expect(Set(names).count == names.count)
    #expect(names.contains("Name"))
    #expect(names.contains("Name2"))
    #expect(names.contains("EPosta"))
    let adjusted = outcome.candidates.first { $0.suggestedName == "Name2" }
    #expect(adjusted?.warnings.contains { $0.contains("already used") } == true)
  }

  // MARK: Review flow

  @Test func reviewAcceptRejectAndCommitAsOnePlan() throws {
    let graph = try fixtureGraph()
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let lines = [
      FormDetectionTextLine(text: "First:", rect: [72, 700, 120, 712], source: .documentText),
      FormDetectionTextLine(text: "Second:", rect: [72, 650, 130, 662], source: .documentText),
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: pageID, pageBounds: pageBounds, textLines: lines, shapes: [],
      existingFields: [])
    #expect(outcome.candidates.count == 2)
    var review = FormFieldDetectionReview(report: FormDetectionReport(
      pages: [outcome.report], candidates: outcome.candidates))
    review.acceptAllEligible()
    #expect(review.acceptedCount == 2)
    let plan = try review.makePlan(in: graph)
    #expect(plan.transaction.commands.count == 2)
    #expect(plan.fieldNames.count == 2)
    let edited = try PDFEditingEngine.commit(plan.transaction, to: graph)
    let fields = try FormInventory.fields(in: edited, pageIDs: [pageID])
    #expect(fields.count == 2)
    #expect(Set(fields.map(\.name)) == Set(plan.fieldNames))
    let descriptors = try FormDesignInventory.widgets(in: edited, pageIDs: [pageID])
    #expect(descriptors.contains { $0.label == "First" })
    #expect(descriptors.contains { $0.label == "Second" })
  }

  @Test func rejectingEveryProposalCreatesNoField() throws {
    let graph = try fixtureGraph()
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let lines = [
      FormDetectionTextLine(text: "Name:", rect: [72, 700, 110, 712], source: .documentText)
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: pageID, pageBounds: pageBounds, textLines: lines, shapes: [],
      existingFields: [])
    var review = FormFieldDetectionReview(report: FormDetectionReport(
      pages: [outcome.report], candidates: outcome.candidates))
    review.rejectAll()
    #expect(review.acceptedCount == 0)
    #expect(try FormInventory.fields(in: graph, pageIDs: [pageID]).isEmpty)
    #expect(throws: PDFError.self) { _ = try review.makePlan(in: graph) }
  }

  @Test func editedDuplicateNameIsRefusedNotSilentlyRenamed() throws {
    let graph = try fixtureGraph()
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let lines = [
      FormDetectionTextLine(text: "Name:", rect: [72, 700, 110, 712], source: .documentText),
      FormDetectionTextLine(text: "Name:", rect: [72, 650, 110, 662], source: .documentText),
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: pageID, pageBounds: pageBounds, textLines: lines, shapes: [],
      existingFields: [])
    var review = FormFieldDetectionReview(report: FormDetectionReport(
      pages: [outcome.report], candidates: outcome.candidates))
    review.acceptAllEligible()
    guard let second = outcome.candidates.dropFirst().first else {
      Issue.record("Expected a second proposal")
      return
    }
    review.update(second.id) { $0.name = "Name" }
    #expect(throws: PDFError.self) { _ = try review.makePlan(in: graph) }
  }

  @Test func recognizedLayerTextNeedsReviewAndAmbiguousCheckboxWarns() {
    let shapes = [FormDetectionShape(kind: .rectangle, rect: [72, 500, 86, 514])]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: nil, pageBounds: pageBounds, textLines: [], shapes: shapes,
      existingFields: [])
    #expect(outcome.candidates.first?.isEligible == true)
    #expect(outcome.candidates.first?.warnings.contains { $0.contains("No adjacent label") } == true)
  }

  // MARK: Graph-backed extraction

  @Test func digitalTextGraphYieldsTextFieldCandidate() throws {
    let graph = try textGraph(
      content: """
        BT /F1 12 Tf 72 700 Td (Full Name: ) Tj ET
        BT /F1 12 Tf 320 700 Td (Date: ) Tj ET
        """)
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let outcome = try FormFieldDetection.detect(pageIndex: 0, pageID: pageID, in: graph)
    #expect(outcome.report.isDetectable)
    #expect(outcome.report.hasDocumentText)
    let candidate = outcome.candidates.first { $0.kind == .text && $0.label == "Full Name" }
    #expect(candidate != nil)
    #expect(candidate?.isEligible == true)
    #expect(candidate?.source == .documentText)
  }

  @Test func scanWithoutOCRDataIsRefusedExplicitly() throws {
    let graph = try textGraph(content: "q 0.2 0.4 0.8 rg 100 100 200 120 re f Q\n")
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let outcome = try FormFieldDetection.detect(pageIndex: 0, pageID: pageID, in: graph)
    #expect(outcome.candidates.isEmpty)
    #expect(outcome.report.hasOCRTextLayer == false)
    #expect(outcome.report.refusalReason?.contains("Recognize Text") == true)
  }

  @Test func scanWithOCRLayerYieldsReviewedCandidate() throws {
    var graph = try textGraph(content: "q 0.2 0.4 0.8 rg 100 100 200 120 re f Q\n")
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [
            SearchableTextLine(text: "Full Name: ______________", rect: [72, 700, 300, 712])
          ])
      ]), to: graph)
    let outcome = try FormFieldDetection.detect(pageIndex: 0, pageID: pageID, in: graph)
    #expect(outcome.report.hasOCRTextLayer)
    #expect(outcome.report.hasRecognizedText)
    #expect(outcome.report.hasDocumentText == false)
    let candidate = outcome.candidates.first { $0.kind == .text }
    #expect(candidate != nil)
    #expect(candidate?.source?.isRecognized == true)
    #expect(candidate?.label == "Full Name")
    #expect(candidate?.isEligible == true)
  }

  @Test func shapeExtractionFindsPaintedBoxesAndCircles() throws {
    let content = """
      q 0.5 w
      72 500 12 12 re S
      Q
      q 0.5 w
      126 500 m 126 503.3 123.3 506 120 506 c 116.7 506 114 503.3 114 500 c 114 496.7 116.7 494 120 494 c 123.3 494 126 496.7 126 500 c S
      Q
      """
    let graph = try textGraph(content: content)
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let shapes = try FormFieldDetection.extractShapes(pageID: pageID, in: graph)
    #expect(shapes.count == 2)
    let box = shapes.first { $0.kind == .rectangle }
    #expect(box != nil)
    #expect(box?.rect[0] == 72)
    #expect(box?.rect[2] == 84)
    let circle = shapes.first { $0.kind == .ellipse }
    #expect(circle != nil)
  }

  @Test func detectedFieldKeepsLabelAfterSaveAndReopen() throws {
    var graph = try textGraph(
      content: "BT /F1 12 Tf 72 700 Td (Full Name: ) Tj ET\n")
    let pageID = try #require(PageTreeView(graph: graph).pages.first)
    let outcome = try FormFieldDetection.detect(pageIndex: 0, pageID: pageID, in: graph)
    var review = FormFieldDetectionReview(report: FormDetectionReport(
      pages: [outcome.report], candidates: outcome.candidates))
    review.acceptAllEligible()
    let plan = try review.makePlan(in: graph)
    graph = try PDFEditingEngine.commit(plan.transaction, to: graph)
    let saved = try PDFParser.parse(try PDFWriter.write(graph))
    let fields = try FormInventory.fields(in: saved.graph, pageIDs: [pageID])
    #expect(fields.count == 1)
    #expect(fields.first?.name == "FullName")
    let descriptors = try FormDesignInventory.widgets(in: saved.graph, pageIDs: [pageID])
    #expect(descriptors.first?.label == "Full Name")
  }

  // MARK: Helpers

  private func fixtureGraph() throws -> PDFGraph {
    PDFFixtures.graph(pages: 1)
  }

  private func textGraph(content: String) throws -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [:]
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
    ])
    objects[PDFObjectID(3)] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
      PDFName("Resources"): .dictionary([
        PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
      ]),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ])
    objects[PDFObjectID(4)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    let bytes = Data(content.utf8)
    objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
    return PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }
}
