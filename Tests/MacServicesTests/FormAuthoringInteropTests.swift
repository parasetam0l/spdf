import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing
@testable import MacServices

/// P25-025/P25-026: authored forms fill and save correctly in an independent
/// reader (PDFKit), and rename/delete keep widget relationships intact.
@Suite("Form authoring interop")
struct FormAuthoringInteropTests {
  private func authoredGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 640, 272, 664], name: "City", defaultValue: "Berlin"),
        AddCheckboxCommand(pageID: pageID, rect: [72, 600, 90, 618], name: "Subscribe"),
        AddRadioGroupCommand(
          pageID: pageID, rects: [[72, 560, 90, 578], [100, 560, 118, 578]], name: "Plan",
          exportValues: ["Basic", "Pro"], selectedIndex: 1),
        AddChoiceFieldCommand(
          pageID: pageID, rect: [72, 520, 220, 544], name: "Department",
          options: [
            AuthoredChoiceOption(exportValue: "eng", displayValue: "Engineering"),
            AuthoredChoiceOption(exportValue: "sales", displayValue: "Sales"),
          ], combo: true, defaultExportValue: "eng"),
      ]), to: graph)
    return (graph, pageID)
  }

  private func widgets(in document: PDFDocument) -> [PDFAnnotation] {
    (0..<document.pageCount).flatMap { index in
      document.page(at: index)?.annotations.filter { !$0.widgetFieldType.rawValue.isEmpty } ?? []
    }
  }

  @Test func authoredFormOpensInPDFKitWithNamesAndTypes() throws {
    let (graph, _) = try authoredGraph()
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data) else {
      Issue.record("PDFKit could not open the authored form")
      return
    }
    let names = Set(widgets(in: document).compactMap(\.fieldName))
    #expect(names == ["City", "Subscribe", "Plan", "Department"])
    let byName = Dictionary(
      grouping: widgets(in: document), by: { $0.fieldName ?? "" })
    #expect(byName["City"]?.first?.widgetFieldType == .text)
    #expect(byName["Subscribe"]?.first?.widgetFieldType == .button)
    #expect(byName["Plan"]?.count == 2)
    #expect(byName["Department"]?.first?.widgetFieldType == .choice)
    #expect(byName["City"]?.first?.widgetStringValue == "Berlin")
  }

  @Test func filledAuthoredFormSavesAndReopensWithValues() throws {
    let (graph, pageID) = try authoredGraph()
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "City", text: "Hamburg"),
        SetFormButtonStateCommand(fieldName: "Subscribe", state: PDFName("Yes")),
        SetFormButtonStateCommand(fieldName: "Plan", state: PDFName("Basic")),
        SetFormChoiceCommand(fieldName: "Department", exportValue: "sales"),
      ]), to: graph)
    let data = try PDFWriter.write(filled)
    guard let document = PDFDocument(data: data) else {
      Issue.record("PDFKit could not open the filled form")
      return
    }
    let byName = Dictionary(grouping: widgets(in: document), by: { $0.fieldName ?? "" })
    #expect(byName["City"]?.first?.widgetStringValue == "Hamburg")
    #expect(byName["Subscribe"]?.first?.buttonWidgetState.rawValue == 1)
    let planOnCount = byName["Plan"]?.filter { $0.buttonWidgetState.rawValue == 1 }.count ?? 0
    #expect(planOnCount == 1)
    #expect(byName["Department"]?.first?.widgetStringValue == "Sales")

    // The core inventory agrees with the independent reader.
    let reparsed = try PDFParser.parse(data)
    let fields = try FormInventory.fields(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(fields.first { $0.name == "City" }?.stringValue == "Hamburg")
    #expect(fields.first { $0.name == "Plan" }?.buttonState == PDFName("Basic"))
    #expect(fields.first { $0.name == "Department" }?.selectedOption?.export == "sales")
  }

  @Test func renameAndDeleteKeepRelationshipsIntact() throws {
    let (graph, pageID) = try authoredGraph()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([RenameFormFieldCommand(fieldName: "City", newName: "Address.City")]),
      to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([RemoveFormFieldCommand(fieldName: "Plan")]), to: edited)
    let data = try PDFWriter.write(edited)
    guard let document = PDFDocument(data: data) else {
      Issue.record("PDFKit could not open the edited form")
      return
    }
    let names = Set(widgets(in: document).compactMap(\.fieldName))
    #expect(names == ["Address.City", "Subscribe", "Department"])
    #expect(!names.contains("Plan"))
    // The renamed field still fills through the canonical command and is seen
    // by PDFKit under its new name.
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Address.City", text: "Bremen")]),
      to: edited)
    guard let refilled = PDFDocument(data: try PDFWriter.write(filled)) else {
      Issue.record("PDFKit could not reopen the renamed field")
      return
    }
    let byName = Dictionary(grouping: widgets(in: refilled), by: { $0.fieldName ?? "" })
    #expect(byName["Address.City"]?.first?.widgetStringValue == "Bremen")
    #expect(byName["Department"]?.first?.widgetStringValue == "Engineering")
    #expect(try FormInventory.fields(in: filled, pageIDs: [pageID]).count == 3)
  }

  @Test func styledFormattedCalculatedFormRendersInPDFKit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 640, 172, 668], name: "Price"),
        AddTextFieldCommand(pageID: pageID, rect: [180, 640, 260, 668], name: "Qty"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 628], name: "Total"),
        SetFormFieldStyleCommand(fieldName: "Total", fontSize: 14, alignment: 1),
        SetFormFieldFormatCommand(
          fieldName: "Total", format: .number(decimals: 2, prefix: "$", suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Total", calculation: .sum(fields: ["Price", "Qty"])),
        SetFormTextCommand(fieldName: "Price", text: "10.5"),
        SetFormTextCommand(fieldName: "Qty", text: "2"),
        RecalculateFormCommand(),
      ]), to: graph)
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data) else {
      Issue.record("PDFKit could not open the calculated form")
      return
    }
    let byName = Dictionary(grouping: widgets(in: document), by: { $0.fieldName ?? "" })
    #expect(byName["Total"]?.first?.widgetStringValue == "$12.50")
    #expect(byName["Price"]?.first?.widgetStringValue == "10.5")
    // The styled appearance renders visible content in the independent reader.
    guard let page = document.page(at: 0) else {
      Issue.record("Page missing")
      return
    }
    let thumbnail = page.thumbnail(of: NSSize(width: 300, height: 400), for: .cropBox)
    guard let tiff = thumbnail.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
    else {
      Issue.record("Thumbnail failed")
      return
    }
    var nonWhite = 0
    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
        if let color = bitmap.colorAt(x: x, y: y),
          color.redComponent < 0.98 || color.greenComponent < 0.98
            || color.blueComponent < 0.98
        {
          nonWhite += 1
        }
      }
    }
    #expect(nonWhite > 20)
  }

  @Test func tabOrderAndRequiredFlagsVisibleInPDFKit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 660, 172, 684], name: "Alpha"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 620, 172, 644], name: "Beta", required: true),
        AddTextFieldCommand(pageID: pageID, rect: [72, 580, 172, 604], name: "Gamma"),
        ReorderFormFieldsCommand(order: ["Gamma", "Alpha", "Beta"]),
      ]), to: graph)
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data) else {
      Issue.record("PDFKit could not open the reordered form")
      return
    }
    // Widget annotation order follows the requested tab order.
    let order = widgets(in: document).compactMap(\.fieldName)
    #expect(order == ["Gamma", "Alpha", "Beta"])
    // Required fields are flagged in the canonical inventory (the affordance
    // the forms panel shows).
    let fields = try FormInventory.fields(in: graph, pageIDs: parsed.pageIDs)
    #expect(fields.first { $0.name == "Beta" }?.isRequired == true)
    #expect(fields.first { $0.name == "Alpha" }?.isRequired == false)
  }

  @Test func authoredFormPassesIndependentStructuralCheck() throws {
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/qpdf") else { return }
    let (graph, _) = try authoredGraph()
    let data = try PDFWriter.write(graph)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-authored-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qpdf")
    process.arguments = ["--check", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "qpdf: \(output)")
  }
}
