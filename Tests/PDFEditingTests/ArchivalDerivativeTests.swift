import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P37-012/P37-013/P37-014: staged archival transformations, identifier
/// discipline, and independent validation.
@Suite("Archival derivative")
struct ArchivalDerivativeTests {
  private func fixture(
    javascript: Bool = false, needAppearances: Bool = false, identifier: Bool = false,
    embeddedFiles: Bool = false, embeddedFont: Bool = false, outputIntent: Bool = false
  ) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [:]
    var catalog: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ]
    if javascript {
      catalog[PDFName("OpenAction")] = .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert(1)".utf8)),
      ])
    }
    if needAppearances {
      catalog[PDFName("AcroForm")] = .dictionary([
        PDFName("NeedAppearances"): .boolean(true)
      ])
    }
    if embeddedFiles {
      catalog[PDFName("Names")] = .dictionary([
        PDFName("EmbeddedFiles"): .dictionary([
          PDFName("Names"): .array([.string(Data("file".utf8)), .reference(PDFObjectID(50))])
        ])
      ])
    }
    if outputIntent {
      catalog[PDFName("OutputIntents")] = .array([.reference(PDFObjectID(41))])
    }
    objects[PDFObjectID(1)] = .dictionary(catalog)
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
    ])
    var font: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ]
    if embeddedFont {
      font[PDFName("FontDescriptor")] = .reference(PDFObjectID(30))
      objects[PDFObjectID(30)] = .dictionary([
        PDFName("Type"): .name(PDFName("FontDescriptor")),
        PDFName("FontName"): .name(PDFName("Helvetica")),
        PDFName("Flags"): .integer(32),
        PDFName("FontFile2"): .reference(PDFObjectID(31)),
      ])
      objects[PDFObjectID(31)] = .stream(PDFStream(bytes: Data([0, 1, 2, 3])))
    }
    objects[PDFObjectID(3)] = .dictionary(font)
    var page: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("Resources"): .dictionary([
        PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
      ]),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ]
    if javascript {
      objects[PDFObjectID(10)] = .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Text")),
        PDFName("Rect"): .array([
          .integer(0), .integer(0), .integer(10), .integer(10),
        ]),
        PDFName("A"): .dictionary([
          PDFName("S"): .name(PDFName("JavaScript")),
          PDFName("JS"): .string(Data("app.alert(1)".utf8)),
        ]),
      ])
      page[PDFName("Annots")] = .array([.reference(PDFObjectID(10))])
    }
    objects[PDFObjectID(4)] = .dictionary(page)
    objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("BT /F1 12 Tf 72 700 Td (Hello) Tj ET\n".utf8)))
    if embeddedFiles {
      objects[PDFObjectID(50)] = .dictionary([
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data("file.txt".utf8)),
      ])
    }
    if outputIntent {
      objects[PDFObjectID(41)] = .dictionary([
        PDFName("Type"): .name(PDFName("OutputIntent")),
        PDFName("S"): .name(PDFName("GTS_PDFA1")),
        PDFName("DestOutputProfile"): .reference(PDFObjectID(42)),
      ])
      objects[PDFObjectID(42)] = .stream(PDFStream(bytes: Data([0, 0, 0, 0])))
    }
    var trailer: [PDFName: PDFValue] = [PDFName("Root"): .reference(PDFObjectID(1))]
    if identifier {
      trailer[PDFName("ID")] = .array([
        .string(Data("0123456789abcdef".utf8)), .string(Data("0123456789abcdef".utf8)),
      ])
    }
    return PDFGraph(version: "1.7", objects: objects, trailer: trailer)
  }

  // MARK: - P37-012

  @Test func planListsTransformationsWithExplicitImpact() throws {
    let graph = fixture(
      javascript: true, needAppearances: true, embeddedFiles: true, outputIntent: false)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let plan = ArchivalDerivative.plan(graph, pageIDs: pageIDs)
    let kinds = plan.transformations.map(\.kind)
    #expect(kinds.contains(.removeExecutableActions))
    #expect(kinds.contains(.removeNeedAppearances))
    #expect(kinds.contains(.addFileIdentifier))
    #expect(kinds.contains(.removeEmbeddedFiles))
    // Safe transformations need no decision; content/rendering changes do.
    #expect(plan.safeKinds == [.removeExecutableActions, .addFileIdentifier])
    let embedded = try #require(plan.transformations.first { $0.kind == .removeEmbeddedFiles })
    #expect(embedded.kind.requiresUserDecision)
    #expect(embedded.kind.contentImpact.contains("Content removed"))
    // Unresolved requirements are explicit and honest.
    #expect(plan.unresolvedRequirements.contains { $0.contains("Font embedding") })
    #expect(plan.unresolvedRequirements.contains { $0.contains("Output intent") })
    #expect(plan.unresolvedRequirements.contains { $0.contains("P37-013") })
    #expect(plan.report().contains("No PDF/A identifier is written"))
  }

  @Test func stagingAppliesOnlySelectedTransformations() throws {
    let graph = fixture(javascript: true, needAppearances: true, embeddedFiles: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let plan = ArchivalDerivative.plan(graph, pageIDs: pageIDs)
    let staged = try ArchivalDerivative.stage(
      graph, plan: plan, applying: [.removeExecutableActions, .addFileIdentifier])
    #expect(staged.applied == [.removeExecutableActions, .addFileIdentifier])
    #expect(staged.skipped.contains(.removeNeedAppearances))
    #expect(staged.skipped.contains(.removeEmbeddedFiles))
    // Actions are gone from the catalog and annotations.
    let catalogID = try #require({
      if case .reference(let id)? = graph.trailer[PDFName("Root")] { return id }
      return nil
    }())
    guard case .dictionary(let catalog)? = staged.graph.objects[catalogID] else {
      Issue.record("catalog missing")
      return
    }
    #expect(catalog[PDFName("OpenAction")] == nil)
    #expect(catalog[PDFName("Names")] != nil)  // embedded files untouched
    if case .dictionary(let annotation)? = staged.graph.objects[PDFObjectID(10)] {
      #expect(annotation[PDFName("A")] == nil)
    } else {
      Issue.record("annotation missing")
    }
    // A deterministic /ID was added.
    guard case .array(let id)? = staged.graph.trailer[PDFName("ID")], id.count == 2 else {
      Issue.record("ID missing")
      return
    }
    let first = try #require({
      if case .string(let data) = id[0] { return data }
      return nil
    }())
    #expect(first.count == 64)
    // The AcroForm still carries NeedAppearances (not selected).
    if case .dictionary(let form)? = catalog[PDFName("AcroForm")] {
      #expect(form[PDFName("NeedAppearances")] != nil)
    }
  }

  // MARK: - P37-013

  @Test func stagingNeverWritesConformanceMetadata() throws {
    let graph = fixture(
      javascript: true, identifier: true, embeddedFont: true, outputIntent: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let plan = ArchivalDerivative.plan(graph, pageIDs: pageIDs)
    let staged = try ArchivalDerivative.stage(graph, plan: plan, applying: plan.safeKinds)
    let data = try PDFWriter.write(staged.graph)
    let bytes = String(decoding: data, as: UTF8.self)
    // No PDF/A identifier or claim is added anywhere (the fixture's own
    // output intent stays as-is; staging adds none).
    #expect(!bytes.contains("pdfaid"))
    #expect(bytes.components(separatedBy: "GTS_PDFA1").count == 2)  // the pre-existing one only
    // The catalog has no XMP metadata added by staging.
    guard case .reference(let catalogID)? = staged.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = staged.graph.objects[catalogID]
    else {
      Issue.record("catalog missing")
      return
    }
    #expect(catalog[PDFName("Metadata")] == nil)
    // The inventory still reports the unresolved errors.
    #expect(!plan.inventory.passesInventory)
  }

  // MARK: - P37-014

  @Test func independentValidationRunsAndReportsHonestly() throws {
    guard FileManager.default.isExecutableFile(atPath: ArchivalDerivative.defaultValidatorPath)
    else { return }
    // Stage the safe transformations of a document that cannot be conformant
    // (fonts are not embedded).
    let graph = fixture(javascript: true, outputIntent: false)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let plan = ArchivalDerivative.plan(graph, pageIDs: pageIDs)
    let staged = try ArchivalDerivative.stage(graph, plan: plan, applying: plan.safeKinds)
    let data = try PDFWriter.write(staged.graph)
    let result = try #require(ArchivalDerivative.validate(data))
    #expect(result.validator == "veraPDF")
    #expect(result.validatorVersion != nil)
    #expect(result.profileName.contains("PDF/A-2b"))
    // The document is honestly reported as non-compliant: fonts are not
    // embedded and no output intent exists.
    #expect(!result.isCompliant)
    #expect(result.failedRules > 0)
    #expect(result.failingRules.contains { $0.description.contains("embedded") || $0.description.contains("OutputIntent") || $0.description.contains("Output intent") })
    let report = result.report()
    #expect(report.contains("Verdict: not compliant"))
    #expect(report.contains("No PDF/A identifier is written by this app"))
    // The validator is an independent tool; the report names it and its version.
    #expect(report.contains("veraPDF"))
  }
}
