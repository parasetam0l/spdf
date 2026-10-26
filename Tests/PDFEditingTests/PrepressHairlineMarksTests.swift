import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("Prepress hairline and production marks")
struct PrepressHairlineMarksTests {
  private func graph(content: String, resources: [PDFName: PDFValue] = [:]) -> PDFGraph {
    let pageID = PDFObjectID(4)
    let contentID = PDFObjectID(5)
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(pageID)]),
        ]),
        contentID: .stream(PDFStream(bytes: Data(content.utf8))),
        pageID: .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
          PDFName("Resources"): .dictionary(resources),
          PDFName("Contents"): .reference(contentID),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func hairlineCheckerFindsWidthsScalesAndExtGState() throws {
    let extGState = PDFObjectID(10)
    let content = """
      0.1 w 10 10 m 100 10 l S
      2 w 10 20 m 100 20 l S
      q 0.01 0 0 0.01 0 0 cm 1 w 10 30 m 100 30 l S Q
      q 0 w 10 40 m 100 40 l S Q
      /GS1 gs 5 5 m 6 6 l S
      q 1 0 0 1 0 0 cm 0.5 w 10 50 m 100 50 l S Q
      """
    let graph = graph(
      content: content,
      resources: [
        PDFName("ExtGState"): .dictionary([PDFName("GS1"): .reference(extGState)])
      ])
    var graphWithState = graph
    graphWithState.objects[extGState] = .dictionary([
      PDFName("Type"): .name(PDFName("ExtGState")),
      PDFName("LW"): .real(0.05),
    ])
    let report = try HairlineChecker.check(graphWithState, pageIDs: [PDFObjectID(4)])
    #expect(report.threshold == 0.25)
    #expect(report.checkedPageCount == 1)
    // 0.1pt, 0.01-scaled 1pt (0.01 effective), zero width, /GS1 0.05pt.
    #expect(report.count == 4)
    #expect(report.deviceHairlineCount == 1)
    #expect(report.findings.contains { abs($0.effectiveWidth - 0.01) < 0.0001 })
    #expect(report.findings.contains { abs($0.effectiveWidth - 0.05) < 0.0001 })
    #expect(report.findings.contains { $0.isDeviceHairline })
    #expect(report.report().contains("Read-only check"))
  }

  @Test func nestedFormHairlinesAreScannedWithEnclosingMatrix() throws {
    let formID = PDFObjectID(10)
    let formContent = Data("q 0.2 0 0 10 cm 0.5 w 1 1 m 2 1 l S Q".utf8)
    let content = "q 1 0 0 1 0 0 cm /Fm1 Do Q"
    var graph = graph(
      content: content,
      resources: [PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(formID)])])
    graph.objects[formID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(100), .integer(100)]),
          PDFName("Resources"): .dictionary([:]),
        ], bytes: formContent))
    let report = try HairlineChecker.check(graph, pageIDs: [PDFObjectID(4)])
    // 0.5pt * 10 = 5pt effective, so this is not a hairline.
    #expect(report.count == 0)
    let scaledFormContent = Data("q 0.01 0 0 0.01 0 0 cm 1 w 1 1 m 2 1 l S Q".utf8)
    graph.objects[formID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(100), .integer(100)]),
          PDFName("Resources"): .dictionary([:]),
        ], bytes: scaledFormContent))
    let scaled = try HairlineChecker.check(graph, pageIDs: [PDFObjectID(4)])
    #expect(scaled.count == 1)
    #expect(abs((scaled.findings.first?.effectiveWidth ?? 0) - 0.01) < 0.0001)
  }

  @Test func productionMarksLayoutHasCropRegistrationBarAndSlug() throws {
    let inputs = [
      ProductionMarksPageInput(
        mediaBox: [0, 0, 612, 792], trimBox: [20, 20, 572, 752], bleedBox: [10, 10, 592, 772])
    ]
    let options = ProductionMarksOptions(
      margin: 24, cropMarkLength: 12, markGap: 3,
      jobLabel: "Brochure",
      inks: [
        ProductionInk(name: "Cyan", isProcess: true),
        ProductionInk(name: "Magenta", isProcess: true),
        ProductionInk(name: "PANTONE 185 C"),
      ])
    let layout = try ProductionMarksPlanner.plan(pageInputs: inputs, options: options)
    #expect(layout.pages.count == 1)
    let page = layout.pages[0]
    #expect(page.outputBox == [0, 0, 660, 840])
    #expect(page.sourcePlacementRect == [24, 24, 612, 792])
    #expect(page.trimBox == [20, 20, 572, 752])
    #expect(page.inkNames.count == 3)
    let lines = page.marks.filter {
      if case .line = $0 { return true }
      return false
    }
    #expect(lines.count == 8 + 8)  // 8 crop marks + 2 per registration mark
    let circles = page.marks.filter {
      if case .circle = $0 { return true }
      return false
    }
    #expect(circles.count == 4)
    let rectangles = page.marks.filter {
      if case .rectangle = $0 { return true }
      return false
    }
    #expect(rectangles.count == 3)
    #expect(page.slugLines.contains { $0.contains("PANTONE 185 C") })
    #expect(page.slugLines.contains { $0.contains("no PDF/X") })
    #expect(layout.report().contains("Crop marks follow TrimBox"))
  }

  @Test func productionMarksDiscloseMissingTrimAndRefuseBadMargins() throws {
    let layout = try ProductionMarksPlanner.plan(
      pageInputs: [ProductionMarksPageInput(mediaBox: [0, 0, 612, 792])],
      options: ProductionMarksOptions(margin: 24, inks: []))
    #expect(layout.warnings.contains { $0.contains("no TrimBox") })
    #expect(layout.warnings.contains { $0.contains("No production inks") })
    #expect(layout.pages[0].warnings.contains { $0.contains("color bar is omitted") })
    #expect(throws: PDFError.self) {
      _ = try ProductionMarksPlanner.plan(
        pageInputs: [ProductionMarksPageInput(mediaBox: [0, 0, 612, 792])],
        options: ProductionMarksOptions(margin: 4))
    }
  }
}
