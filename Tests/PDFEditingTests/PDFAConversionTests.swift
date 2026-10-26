import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PRE-01/PRE-02: conforming PDF/A conversion. The independent verdict comes
/// from veraPDF against the final serialized bytes; synthetic inputs are used
/// for the local test (no corpus is claimed).
@Suite("PDF/A conversion")
struct PDFAConversionTests {
  static let validatorPath = ArchivalDerivative.defaultValidatorPath
  static var validatorAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: validatorPath)
  }
  static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

  func options(
    _ profile: ArchivalConversionProfile,
    associatedFiles: [ArchivalAssociatedFile] = []
  ) -> ArchivalConversionOptions {
    ArchivalConversionOptions(
      profile: profile, title: "sPDF archival test",
      modificationDate: Self.fixedDate, associatedFiles: associatedFiles)
  }

  func convert(
    _ data: Data, _ profile: ArchivalConversionProfile,
    associatedFiles: [ArchivalAssociatedFile] = []
  ) throws -> ArchivalConversionOutcome {
    let parsed = try PDFParser.parse(data)
    return PDFAConverter.convert(
      parsed, options: options(profile, associatedFiles: associatedFiles),
      validatorPath: Self.validatorPath)
  }

  func reopened(_ outcome: ArchivalConversionOutcome) throws -> (graph: PDFGraph, data: Data) {
    let data = try #require(outcome.data)
    return (try PDFParser.parse(data).graph, data)
  }

  func catalog(_ graph: PDFGraph) throws -> [PDFName: PDFValue] {
    let root = try #require(graph.trailer[PDFName("Root")])
    guard case .reference(let id) = root,
      case .dictionary(let catalog)? = graph.objects[id]
    else {
      Issue.record("catalog is missing")
      return [:]
    }
    return catalog
  }

  func metadataText(_ graph: PDFGraph) throws -> String {
    let catalog = try catalog(graph)
    guard case .reference(let id)? = catalog[PDFName("Metadata")],
      case .stream(let stream)? = graph.objects[id]
    else {
      Issue.record("metadata stream is missing")
      return ""
    }
    return String(decoding: stream.bytes, as: UTF8.self)
  }

  @Test func pdfA2bConversionPassesIndependentValidation() throws {
    guard Self.validatorAvailable else { return }
    let input = try PDFFixtures.imagePages()
    let outcome = try convert(input, .pdfa2b)
    #expect(outcome.status == .conforming)
    #expect(outcome.isConforming)
    #expect(outcome.identifier == "PDF/A-2b (ISO 19005-2)")
    #expect(outcome.validation?.isCompliant == true)
    #expect(outcome.validation?.validator == "veraPDF")
    let reopened = try reopened(outcome)
    let catalog = try catalog(reopened.graph)
    #expect(catalog[PDFName("Metadata")] != nil)
    #expect(catalog[PDFName("OutputIntents")] != nil)
    #expect(reopened.graph.trailer[PDFName("ID")] != nil)
    let xmp = try metadataText(reopened.graph)
    #expect(xmp.contains("<pdfaid:part>2</pdfaid:part>"))
    #expect(xmp.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
    #expect(reopened.data == outcome.data)
  }

  @Test func pdfA1bAndA3bProfilesHaveTheirOwnRules() throws {
    guard Self.validatorAvailable else { return }
    let lowercase = try convert(try PDFFixtures.imagePages(), .pdfa1b)
    #expect(lowercase.status == .conforming)
    #expect(lowercase.profile == .pdfa1b)
    let lowercaseGraph = try reopened(lowercase)
    let lowercaseXMP = try metadataText(lowercaseGraph.graph)
    #expect(lowercaseXMP.contains("<pdfaid:part>1</pdfaid:part>"))
    #expect(lowercaseGraph.graph.version == "1.4")
    #expect(lowercaseGraph.graph.trailer[PDFName("Info")] == nil)

    let associated = ArchivalAssociatedFile(
      name: "evidence.txt", data: Data("sPDF associated evidence".utf8),
      mimeType: "text/plain", relationship: .source)
    let upper = try convert(
      try PDFFixtures.imagePages(), .pdfa3b, associatedFiles: [associated])
    #expect(upper.status == .conforming)
    let upperGraph = try reopened(upper)
    let catalog = try catalog(upperGraph.graph)
    #expect(catalog[PDFName("AF")] != nil)
    let attachments = PDFAttachmentInventory.attachments(in: upperGraph.graph)
    #expect(attachments.contains { $0.name == "evidence.txt" })
    let xmp = try metadataText(upperGraph.graph)
    #expect(xmp.contains("<pdfaid:part>3</pdfaid:part>"))
  }

  @Test func attachmentRulesAreNotGeneralizedAcrossProfiles() throws {
    let associated = ArchivalAssociatedFile(
      name: "source.txt", data: Data("source".utf8), relationship: .source)
    let a2 = try convert(try PDFFixtures.imagePages(), .pdfa2b, associatedFiles: [associated])
    #expect(a2.status == .refused)
    #expect(a2.data == nil)
    #expect(!a2.isConforming)
    #expect(a2.checks.contains { $0.rule == "Associated files" && $0.outcome == .refused })
    // The same associated file is legal only for A-3b.
    guard Self.validatorAvailable else { return }
    let a3 = try convert(try PDFFixtures.imagePages(), .pdfa3b, associatedFiles: [associated])
    #expect(a3.status == .conforming)
  }

  @Test func transparencyRulesAreProfileSpecific() throws {
    let input = try PDFFixtures.imagePages()
    var graph = try PDFParser.parse(input).graph
    // Add an ExtGState with constant alpha to a page's resources; the transparency
    // scan reports it, so the profile rules can be compared.
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard let firstPage = pageIDs.first,
      case .dictionary(var page)? = graph.objects[firstPage],
      case .dictionary(var resources)? = page[PDFName("Resources")]
    else {
      Issue.record("image fixture page resources missing")
      return
    }
    let stateID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[stateID] = .dictionary([PDFName("ca"): .real(0.5)])
    resources[PDFName("ExtGState")] = .dictionary([PDFName("GS1"): .reference(stateID)])
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[firstPage] = .dictionary(page)
    let a1 = PDFAConverter.convert(
      graph: graph, options: options(.pdfa1b), validatorPath: Self.validatorPath)
    #expect(a1.status == .refused)
    #expect(a1.checks.contains { $0.rule == "Transparency" && $0.outcome == .refused })
    let a2 = PDFAConverter.convert(
      graph: graph, options: options(.pdfa2b), validatorPath: Self.validatorPath)
    #expect(a2.status != .refused)
    #expect(a2.checks.contains { $0.rule == "Transparency" && $0.outcome == .passed })
  }

  @Test func unembeddedFontsRefuseConversionInsteadOfMislabelling() throws {
    let input = try PDFFixtures.onePage()
    let outcome = try convert(input, .pdfa2b)
    #expect(outcome.status == .refused)
    #expect(outcome.data == nil)
    #expect(outcome.candidateData == nil)
    #expect(outcome.validation == nil)
    #expect(!outcome.isConforming)
    #expect(outcome.identifier == nil)
    #expect(outcome.checks.contains { $0.rule == "Font embedding" && $0.outcome == .refused })
    #expect(!outcome.plainText.contains("Status: Conforming"))
  }

  @Test func failedIndependentValidationPublishesNoBytes() throws {
    guard Self.validatorAvailable else { return }
    // Annotations are not repaired by this converter; the candidate serializes
    // but veraPDF must reject it, and no conforming bytes may be published.
    let input = try PDFFixtures.annotationPages()
    let outcome = try convert(input, .pdfa2b)
    if outcome.status == .notConforming {
      #expect(outcome.data == nil)
      #expect(outcome.candidateData != nil)
      #expect(outcome.validation?.isCompliant == false)
      #expect(outcome.identifier == nil)
      #expect(outcome.warnings.contains { $0.contains("no conforming bytes") })
    } else {
      // If a future converter repairs annotations this path must not be a
      // silent conforming claim: accept conforming only with a real verdict.
      #expect(outcome.status == .conforming)
      #expect(outcome.validation?.isCompliant == true)
    }
  }

  @Test func unavailableValidatorNeverClaimsConformance() throws {
    let outcome = PDFAConverter.convert(
      try PDFParser.parse(try PDFFixtures.imagePages()),
      options: options(.pdfa2b),
      validatorPath: "/nonexistent/verapdf")
    #expect(outcome.status == .validatorUnavailable)
    #expect(outcome.data == nil)
    #expect(outcome.candidateData != nil)
    #expect(!outcome.isConforming)
    #expect(outcome.identifier == nil)
    #expect(outcome.warnings.contains { $0.contains("not labelled conforming") })
  }

  @Test func conversionIsDeterministic() throws {
    guard Self.validatorAvailable else { return }
    let input = try PDFFixtures.imagePages()
    let first = try convert(input, .pdfa2b)
    let second = try convert(input, .pdfa2b)
    #expect(first.status == .conforming)
    #expect(second.status == .conforming)
    #expect(first.data == second.data)
    #expect(first.profile.disclosure.contains("PDF/A-2b"))
    #expect(first.plainText.contains("Independent validation:"))
  }
}
