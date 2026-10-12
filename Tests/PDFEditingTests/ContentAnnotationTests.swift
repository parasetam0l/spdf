import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-005/P22-009/P22-010/P22-025 evidence: free-text and stamp annotations
/// with generated font appearances, link annotations with URI and internal
/// destinations, and value verification after writing.
@Suite("Content annotations")
struct ContentAnnotationTests {
  @Test func freeTextWritesFontAppearanceAndLogicalText() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddFreeTextCommand(
          pageID: pageID, rect: [100, 600, 300, 650], text: "Hello\nWorld", fontSize: 14,
          textColor: [0, 0, 0.5], fillColor: [1, 1, 0.9], borderColor: [0.5, 0.5, 0.5],
          borderWidth: 1, contents: "note", author: "Ada", modified: "D:20261010120000Z",
          subject: "Review")
      ]), to: parsed.graph)
    let annotation = try #require(
      try AnnotationInventory.annotations(in: graph, pageID: pageID).first)
    #expect(annotation.subtype == PDFName("FreeText"))
    #expect(annotation.rect == [100, 600, 300, 650])
    #expect(annotation.contents == "note")
    #expect(annotation.author == "Ada")
    #expect(annotation.subject == "Review")

    guard case .dictionary(let dr)? = annotation.dictionary[PDFName("DR")],
      case .dictionary(let fonts)? = dr[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("Helvetica")],
      case .dictionary(let font)? = graph.objects[fontID]
    else {
      Issue.record("Free text has no font resource")
      return
    }
    #expect(font[PDFName("BaseFont")] == .name(PDFName("Helvetica")))
    #expect(font[PDFName("Encoding")] == .name(PDFName("WinAnsiEncoding")))
    guard case .string(let da)? = annotation.dictionary[PDFName("DA")] else {
      Issue.record("Free text has no default appearance")
      return
    }
    #expect(String(decoding: da, as: UTF8.self).contains("14 Tf"))

    let content = try appearanceContent(of: annotation, in: graph)
    #expect(content.contains("BT"))
    #expect(content.contains("/F1 14 Tf"))
    #expect(content.contains("(Hello) Tj"))
    #expect(content.contains("(World) Tj"))
    #expect(content.contains("0 0 200 50 re f"))
    #expect(content.contains("0.5 0.5 0.5 RG"))
    #expect(content.contains("0.5 0.5 199 49 re S"))

    // The written output reparses to the identical graph (P22-025).
    let reparsed = try PDFParser.parse(PDFWriter.write(graph))
    #expect(reparsed.graph == graph)

    // A second free text reuses the standard font instead of adding one.
    let second = try PDFEditingEngine.commit(
      PDFTransaction([
        AddFreeTextCommand(pageID: pageID, rect: [100, 500, 300, 550], text: "More")
      ]), to: graph)
    #expect(second.objects.count == graph.objects.count + 2)
  }

  @Test func freeTextRefusesUnsupportedInput() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }
    refuse(AddFreeTextCommand(pageID: pageID, rect: [100, 600, 300, 650], text: "   "))
    refuse(
      AddFreeTextCommand(
        pageID: pageID, rect: [100, 600, 300, 650], text: "hello 🙂"))
    refuse(
      AddFreeTextCommand(pageID: pageID, rect: [100, 600, 300, 650], text: "x", fontSize: 200))
    refuse(AddFreeTextCommand(pageID: pageID, rect: [100, 600, 300, 600], text: "x"))
    refuse(
      AddFreeTextCommand(
        pageID: pageID, rect: [100, 600, 300, 650], text: "x", borderWidth: 60))
  }

  @Test func stampWritesStandardNameAndCenteredLabel() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddStampCommand(
          pageID: pageID, rect: [200, 500, 360, 560], stampName: .approved,
          modified: "D:20261010120000Z")
      ]), to: parsed.graph)
    let annotation = try #require(
      try AnnotationInventory.annotations(in: graph, pageID: pageID).first)
    #expect(annotation.subtype == PDFName("Stamp"))
    #expect(annotation.iconName == PDFName("Approved"))
    #expect(annotation.contents == "Approved")
    #expect(annotation.rect == [200, 500, 360, 560])
    let content = try appearanceContent(of: annotation, in: graph)
    #expect(content.contains("0.8 0 0 RG"))
    #expect(content.contains("2 w"))
    #expect(content.contains("1 1 158 58 re S"))
    #expect(content.contains("(Approved) Tj"))
    #expect(content.contains("BT"))

    let reparsed = try PDFParser.parse(PDFWriter.write(graph))
    #expect(reparsed.graph == graph)

    // Every standard name maps to a distinct PDF name and label.
    #expect(StampName.allCases.count == 10)
    #expect(Set(StampName.allCases.map(\.pdfName)).count == 10)
    #expect(StampName.notApproved.label == "Not Approved")

    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }
    refuse(AddStampCommand(pageID: pageID, rect: [200, 500, 360, 560], stampName: .draft, borderWidth: 0))
    refuse(
      AddStampCommand(
        pageID: pageID, rect: [200, 500, 360, 560], stampName: .draft, borderWidth: 40))
  }

  @Test func linkWritesURIAndInternalDestinations() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLinkCommand(
          pageID: pageID, rect: [100, 100, 260, 120],
          target: .uri("https://example.com/spdf"), contents: "External"),
        AddLinkCommand(
          pageID: pageID, rect: [300, 100, 420, 120], target: .page(0), contents: "Internal"),
      ]), to: parsed.graph)
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    #expect(annotations.count == 2)
    #expect(annotations[0].subtype == PDFName("Link"))
    #expect(annotations[0].contents == "External")
    #expect(annotations[0].dictionary[PDFName("AP")] == nil)
    #expect(
      annotations[0].dictionary[PDFName("A")]
        == .dictionary([
          PDFName("S"): .name(PDFName("URI")),
          PDFName("URI"): .string(Data("https://example.com/spdf".utf8)),
        ]))
    #expect(
      annotations[1].dictionary[PDFName("Dest")]
        == .array([.reference(parsed.pageIDs[0]), .name(PDFName("Fit"))]))

    // The one-object allocation keeps the trailer consistent (P22-025).
    let reparsed = try PDFParser.parse(PDFWriter.write(graph))
    #expect(reparsed.graph == graph)

    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }
    refuse(
      AddLinkCommand(
        pageID: pageID, rect: [100, 100, 200, 120],
        target: .uri("javascript:alert(1)")))
    refuse(
      AddLinkCommand(pageID: pageID, rect: [100, 100, 200, 120], target: .uri("file:///etc/passwd")))
    refuse(
      AddLinkCommand(
        pageID: pageID, rect: [100, 100, 200, 120], target: .uri("https://exämple.com")))
    refuse(AddLinkCommand(pageID: pageID, rect: [100, 100, 200, 120], target: .page(99)))
  }

  private func appearanceContent(of annotation: Annotation, in graph: PDFGraph) throws -> String {
    guard case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream(let stream)? = graph.objects[appearanceID]
    else {
      throw PDFError(.malformed, "Annotation has no appearance stream")
    }
    return String(decoding: stream.bytes, as: UTF8.self)
  }
}
