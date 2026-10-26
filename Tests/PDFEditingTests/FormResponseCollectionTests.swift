import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-07 evidence: collecting completed forms across documents into a
/// reviewable table, with visible conflicts/missing values/duplicates and
/// CSV/XLSX exports. Sources are only read.
@Suite("Form response collection")
struct FormResponseCollectionTests {
  enum Spec {
    case text(String)
    case multilineText(String)
    case choice(String, [String])
    case checkbox(String)
    case signature(String)
  }

  private func form(
    _ specs: [Spec], values: [String: String] = [:]
  ) throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    var commands: [any PDFEditCommand] = []
    var row = 0
    for spec in specs {
      let rect: [Double] = [72, Double(700 - row * 40), 272, Double(724 - row * 40)]
      row += 1
      switch spec {
      case .text(let name):
        commands.append(
          AddTextFieldCommand(pageID: pageID, rect: rect, name: name, required: false))
      case .multilineText(let name):
        commands.append(
          AddTextFieldCommand(
            pageID: pageID, rect: rect, name: name, multiline: true, required: false))
      case .choice(let name, let options):
        commands.append(
          AddChoiceFieldCommand(
            pageID: pageID, rect: rect, name: name,
            options: options.map { AuthoredChoiceOption(exportValue: $0) }))
      case .checkbox(let name):
        commands.append(AddCheckboxCommand(pageID: pageID, rect: rect, name: name))
      case .signature(let name):
        commands.append(AddSignatureFieldCommand(pageID: pageID, rect: rect, name: name))
      }
    }
    graph = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    var fill: [any PDFEditCommand] = []
    for spec in specs {
      switch spec {
      case .text(let name):
        if let value = values[name] {
          fill.append(SetFormTextCommand(fieldName: name, text: value))
        }
      case .multilineText(let name):
        if let value = values[name] {
          fill.append(SetFormTextCommand(fieldName: name, text: value))
        }
      case .choice(let name, let options):
        if let value = values[name], options.contains(value) {
          fill.append(SetFormChoiceCommand(fieldName: name, exportValue: value))
        }
      case .checkbox(let name):
        if let value = values[name], value != "Off" {
          fill.append(SetFormButtonStateCommand(fieldName: name, state: PDFName("Yes")))
        }
      case .signature:
        break
      }
    }
    if !fill.isEmpty {
      graph = try PDFEditingEngine.commit(PDFTransaction(fill), to: graph)
    }
    return (graph, pageID)
  }

  private func pdfSource(
    _ specs: [Spec], name: String, values: [String: String] = [:]
  ) throws -> FormResponseSource {
    let (graph, pageID) = try form(specs, values: values)
    _ = pageID
    return try FormResponseCollection.readPDFSource(
      try PDFWriter.write(graph), displayName: name)
  }

  @Test func mergingDocumentsMakesConflictsAndMissingFieldsVisible() throws {
    let first = try pdfSource(
      [.text("Name"), .text("Email"), .checkbox("Agree")], name: "asha.pdf",
      values: ["Name": "Asha", "Email": "asha@example.com", "Agree": "Yes"])
    let second = try pdfSource(
      [.text("Name"), .text("Phone")], name: "boris.pdf",
      values: ["Name": "Boris", "Phone": "+90 555 000 00 00"])
    let table = FormResponseCollection.merge([first, second])
    #expect(table.sourceCount == 2)
    #expect(table.columns.map(\.name) == ["Name", "Email", "Agree", "Phone"])
    #expect(table.rows.count == 2)
    #expect(table.rows[0].cells[0].status == .present)
    #expect(table.rows[0].cells[1].value?.displayText == "asha@example.com")
    #expect(table.rows[1].cells[1].status == .missing)
    #expect(table.rows[1].cells[3].status == .present)
    #expect(table.missingValueCount == 3)
    #expect(table.issues.contains { $0.kind == .fieldNameConflict && $0.fieldName == "Email" })
    #expect(table.issues.contains { $0.kind == .fieldNameConflict && $0.fieldName == "Phone" })
    #expect(table.summary.contains("2 submissions"))
    #expect(table.summary.contains("nothing was modified"))
  }

  @Test func duplicateSubmissionsAreGroupedAndReported() throws {
    let specs: [Spec] = [.text("Name"), .text("City")]
    let values = ["Name": "Asha", "City": "Istanbul"]
    let first = try pdfSource(specs, name: "first.pdf", values: values)
    let second = try pdfSource(specs, name: "copy.pdf", values: values)
    let third = try pdfSource(specs, name: "other.pdf", values: ["Name": "Boris"])
    let table = FormResponseCollection.merge([first, second, third])
    #expect(table.duplicateSubmissionCount == 1)
    let duplicateRow = try #require(table.rows.first { $0.duplicateOf != nil })
    #expect(duplicateRow.displayName == "copy.pdf")
    #expect(duplicateRow.duplicateOf == first.id)
    #expect(table.rows[2].duplicateOf == nil)
    #expect(table.issues.contains {
      $0.kind == .duplicateSubmission && $0.sourceName == "copy.pdf"
    })
  }

  @Test func fieldNameKindMismatchIsAConflict() throws {
    let textSource = try pdfSource([.text("Answer")], name: "text-form.pdf",
      values: ["Answer": "Forty two"])
    let buttonSource = try pdfSource([.checkbox("Answer")], name: "check-form.pdf")
    let table = FormResponseCollection.merge([textSource, buttonSource])
    let column = try #require(table.columns.first { $0.name == "Answer" })
    #expect(column.kinds.sorted() == ["button", "text"])
    #expect(column.isTypeConflict)
    #expect(table.typeConflictColumns.count == 1)
    #expect(table.issues.contains { $0.kind == .typeMismatch && $0.fieldName == "Answer" })
  }

  @Test func emptyAndMissingValuesStayDistinguishable() throws {
    let first = try pdfSource([.text("Name"), .text("Email")], name: "empty.pdf",
      values: ["Name": "Asha", "Email": ""])
    let second = try pdfSource([.text("Name")], name: "partial.pdf",
      values: ["Name": "Boris"])
    let table = FormResponseCollection.merge([first, second])
    let emailIndex = try #require(table.columns.firstIndex { $0.name == "Email" })
    #expect(table.rows[0].cells[emailIndex].status == .empty)
    #expect(table.rows[1].cells[emailIndex].status == .missing)
    #expect(table.issues.contains {
      $0.kind == .missingValue && $0.sourceName == "empty.pdf"
    })
    #expect(table.issues.contains { $0.kind == .fieldNameConflict && $0.fieldName == "Email" })
  }

  @Test func dataFileSourcesMergeWithDocumentSources() throws {
    let (graph, pageID) = try form(
      [.text("Name"), .text("Email")], values: ["Name": "Asha", "Email": "asha@example.com"])
    let pdf = try FormResponseCollection.readGraphSource(
      graph, pageIDs: [pageID], displayName: "form.pdf")
    let values = try FormValues.values(in: graph, pageIDs: [pageID])
    let xfdf = FormDataExchange.export(values, format: .xfdf)
    let dataSource = try FormResponseCollection.readFormDataSource(
      xfdf, format: .xfdf, displayName: "last-saved.xfdf")
    let dataFileName = try #require(dataSource.values["Name"])
    #expect(dataFileName.kind == nil)
    let table = FormResponseCollection.merge([pdf, dataSource])
    #expect(table.sourceCount == 2)
    #expect(table.typeConflictColumns.isEmpty)
    #expect(table.rows[1].cells[0].value?.displayText == "Asha")
    #expect(table.rows[1].cells[1].value?.displayText == "asha@example.com")
  }

  @Test func csvExportQuotesUnicodeCommasQuotesAndNewlines() throws {
    // WinAnsi-safe Unicode (the simple-text profile refuses other scripts).
    let tricky = "Doe, Jane \"JJ\"\nKöln, Größe"
    let source = try pdfSource(
      [.multilineText("Note"), .text("Name")], name: "tricky.pdf",
      values: ["Note": tricky, "Name": "Ärger, \"quoted\""])
    let table = FormResponseCollection.merge([source])
    let data = table.exportCSV()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"Doe, Jane \"\"JJ\"\"\nKöln, Größe\""))
    #expect(text.contains("\"Ärger, \"\"quoted\"\"\""))
    let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    #expect(lines.first == "Submission,Note,Name")
    #expect(lines.count == 2)
    #expect(text.hasSuffix("\r\n"))
    let withIssues = table.exportCSV(
      options: FormResponseCSVOptions(includeIssueSummary: true))
    #expect(String(decoding: withIssues, as: UTF8.self).contains("Issues"))
  }

  @Test func xlsxExportIsAValidWorkbookWithTheReviewTable() throws {
    let first = try pdfSource([.text("Name")], name: "one.pdf", values: ["Name": "Asha"])
    let second = try pdfSource([.text("Name")], name: "two.pdf", values: ["Name": "Boris"])
    let table = FormResponseCollection.merge([first, second])
    let data = try table.exportXLSX()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-frm07-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("responses.xlsx")
    try data.write(to: url)
    let listing = try run("/usr/bin/unzip", ["-t", url.path])
    #expect(listing.status == 0, "unzip -t: \(listing.output)")
    let names = try run("/usr/bin/unzip", ["-Z1", url.path])
    #expect(names.status == 0)
    #expect(names.output.contains(XLSXExport.worksheetPart(index: 1)))
    #expect(names.output.contains(XLSXExport.sharedStringsPart))
    let strings = try run("/usr/bin/unzip", ["-p", url.path, XLSXExport.sharedStringsPart])
    #expect(strings.output.contains("Submission"))
    #expect(strings.output.contains("Name"))
    #expect(strings.output.contains("Asha"))
    #expect(strings.output.contains("Boris"))
  }

  @Test func collectionNeverModifiesTheSourceFilesOrGraphs() throws {
    let (graph, pageID) = try form(
      [.text("Name"), .checkbox("Agree")], values: ["Name": "Asha", "Agree": "Yes"])
    let data = try PDFWriter.write(graph)
    let graphBefore = graph
    let dataBefore = data
    let source = try FormResponseCollection.readPDFSource(data, displayName: "original.pdf")
    let table = FormResponseCollection.merge([source])
    _ = try table.exportXLSX()
    _ = table.exportCSV()
    #expect(data == dataBefore)
    #expect(graph == graphBefore)
    _ = pageID
  }

  @Test func combinedDocumentKeepsEveryFieldIdentityAndValue() throws {
    let (firstGraph, firstPage) = try form(
      [.text("Name"), .text("Email")], values: ["Name": "Asha", "Email": "asha@example.com"])
    let (secondGraph, secondPage) = try form(
      [.text("Name"), .text("Email")], values: ["Name": "Boris", "Email": "boris@example.com"])
    let merged = try DocumentAssembly.merge([
      (graph: firstGraph, pageIDs: [firstPage]),
      (graph: secondGraph, pageIDs: [secondPage]),
    ])
    #expect(!merged.report.renamedFields.isEmpty)
    let combined = try FormResponseCollection.readGraphSource(
      merged.graph, pageIDs: try PageTreeView(graph: merged.graph).pages,
      displayName: "combined.pdf")
    #expect(combined.values.count == 4)
    let displayed = Set(combined.values.values.map(\.displayText))
    #expect(displayed == Set(["Asha", "Boris", "asha@example.com", "boris@example.com"]))
    // Original graphs are untouched by assembly and collection.
    let originalFirst = try FormValues.values(in: firstGraph, pageIDs: [firstPage])
    let originalSecond = try FormValues.values(in: secondGraph, pageIDs: [secondPage])
    #expect(originalFirst.count == 2)
    #expect(originalSecond.count == 2)
  }

  private func run(_ tool: String, _ arguments: [String]) throws
    -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
