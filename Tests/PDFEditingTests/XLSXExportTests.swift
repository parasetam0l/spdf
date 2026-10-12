import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P36-017–P36-025: XLSX package parts and relationships, shared strings,
/// explicit cell types, literal formulas, merged cells and geometry, styles,
/// opt-in provenance, and independent package/cell-reference validation.
@Suite("XLSX export")
struct XLSXExportTests {
  private func table(
    rows: [[String?]], pageIndex: Int = 0, spans: [(Int, Int, Int, Int)] = [],
    cellBounds: [Double] = [0, 0, 80, 20]
  ) -> ExtractedTable {
    var cells: [ExtractedTable.Cell] = []
    for (row, values) in rows.enumerated() {
      for (column, value) in values.enumerated() {
        guard let value else { continue }
        let span = spans.first { $0.0 == row && $0.1 == column }
        var bounds = cellBounds
        bounds[0] += Double(column) * 80
        bounds[2] += Double(column) * 80
        cells.append(
          ExtractedTable.Cell(
            row: row, column: column, rowSpan: span?.2 ?? 1, columnSpan: span?.3 ?? 1,
            text: value, bounds: bounds, provenance: .text, confidence: 0.9))
      }
    }
    return ExtractedTable(
      pageIndex: pageIndex, detection: .geometry, bounds: [0, 0, 200, 100],
      rowCount: rows.count, columnCount: rows.first?.count ?? 0, cells: cells,
      confidence: 0.8, limitations: [])
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  private struct Package {
    let data: Data
    let url: URL
    let directory: URL
    let files: [String]

    func text(_ part: String) -> String {
      (try? String(decoding: Data(contentsOf: directory.appendingPathComponent(part)), as: UTF8.self))
        ?? ""
    }
  }

  private func package(
    tables: [ExtractedTable], options: XLSXExportOptions = .init()
  ) throws -> Package {
    let data = try XLSXExport.package(tables: tables, options: options)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-xlsx-\(UUID().uuidString).xlsx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-xlsx-extract-\(UUID().uuidString)")
    _ = try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", directory.path])
    var files: [String] = []
    let root = directory.resolvingSymlinksInPath().path + "/"
    if let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    {
      for case let fileURL as URL in enumerator {
        guard
          (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { continue }
        files.append(
          fileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: ""))
      }
    }
    return Package(data: data, url: url, directory: directory, files: files)
  }

  private func parseReference(_ reference: String) -> (row: Int, column: Int)? {
    var letters = ""
    var digits = ""
    for character in reference {
      if character.isLetter { letters.append(character) } else { digits.append(character) }
    }
    guard !letters.isEmpty, let row = Int(digits) else { return nil }
    var column = 0
    for scalar in letters.uppercased().unicodeScalars {
      column = column * 26 + Int(scalar.value) - 64
    }
    return (row, column - 1)
  }

  // MARK: - P36-017/P36-018

  @Test func packagePartsAndRelationshipsResolve() throws {
    let first = table(rows: [["A1", "B1"]])
    let second = table(rows: [["A2"]], pageIndex: 1)
    let package = try package(tables: [first, second])
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let listing = try run("/usr/bin/unzip", ["-t", package.url.path])
    #expect(listing.status == 0, "unzip -t: \(listing.output)")
    for part in [
      XLSXExport.contentTypesPart, XLSXExport.packageRelationshipsPart, XLSXExport.workbookPart,
      XLSXExport.workbookRelationshipsPart, XLSXExport.stylesPart,
      XLSXExport.sharedStringsPart, XLSXExport.worksheetPart(index: 1),
      XLSXExport.worksheetPart(index: 2),
    ] {
      #expect(package.files.contains(part), "missing \(part)")
    }
    // Every XML part parses; relationship targets exist; content types cover.
    var contentTypes: Set<String> = []
    var contentExtensions: Set<String> = []
    let typesXML = try XMLDocument(
      data: try Data(contentsOf: package.directory.appendingPathComponent(XLSXExport.contentTypesPart)))
    for node in try typesXML.nodes(forXPath: "//*[local-name()='Override']") {
      if let element = node as? XMLElement,
        let partName = element.attribute(forName: "PartName")?.stringValue
      {
        contentTypes.insert(String(partName.dropFirst()))
      }
    }
    for node in try typesXML.nodes(forXPath: "//*[local-name()='Default']") {
      if let element = node as? XMLElement,
        let value = element.attribute(forName: "Extension")?.stringValue
      {
        contentExtensions.insert(value.lowercased())
      }
    }
    for file in package.files where file.hasSuffix(".xml") || file.hasSuffix(".rels") {
      _ = try XMLDocument(data: try Data(contentsOf: package.directory.appendingPathComponent(file)))
    }
    for file in package.files where file != XLSXExport.contentTypesPart {
      let basename = (file as NSString).lastPathComponent
      let extensionName =
        basename.contains(".")
        ? String(basename.split(separator: ".").last ?? "").lowercased() : ""
      #expect(
        contentTypes.contains(file) || contentExtensions.contains(extensionName),
        "no content type for \(file)")
    }
    let workbook = package.text(XLSXExport.workbookPart)
    #expect(workbook.contains("name=\"Table 1\""))
    #expect(workbook.contains("name=\"Table 2\""))
    // Workbook relationships resolve to existing files under xl/.
    let relsXML = try XMLDocument(
      data: try Data(contentsOf: package.directory.appendingPathComponent(XLSXExport.workbookRelationshipsPart)))
    for node in try relsXML.nodes(forXPath: "//*[local-name()='Relationship']") {
      guard let element = node as? XMLElement,
        let target = element.attribute(forName: "Target")?.stringValue
      else { continue }
      #expect(package.files.contains("xl/\(target)"), "missing relationship target \(target)")
    }
  }

  // MARK: - P36-019

  @Test func sharedStringsAreDeduplicated() throws {
    let package = try package(tables: [table(rows: [["same", "same"], ["other", "same"]])])
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let shared = package.text(XLSXExport.sharedStringsPart)
    #expect(shared.contains("uniqueCount=\"2\""))
    #expect(shared.components(separatedBy: "<si>").count == 3)  // "same" + "other"
    let sheet = package.text(XLSXExport.worksheetPart(index: 1))
    // Three references to index 0 ("same") and one to index 1 ("other").
    #expect(sheet.components(separatedBy: "<v>0</v>").count == 4)
    #expect(sheet.contains("<v>1</v>"))
  }

  // MARK: - P36-020/P36-021

  @Test func cellTypesAreExplicitAndFormulasStayLiteral() throws {
    let grid = table(rows: [
      ["1234,56"],
      ["007"],
      ["hello"],
      ["31.12.2024"],
      ["=SUM(A1)"],
    ])
    let package = try package(
      tables: [grid], options: XLSXExportOptions(valuePolicy: TableValuePolicy(locale: .german)))
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let sheet = package.text(XLSXExport.worksheetPart(index: 1))
    // Numbers are numeric cells without a t attribute (German comma decimal).
    #expect(sheet.contains("<c r=\"A1\" s=\"0\"><v>1234.56</v></c>"))
    // Leading zeros stay strings (P36-011/P36-020).
    #expect(sheet.contains("<c r=\"A2\" s=\"0\" t=\"s\"><v>"))
    // Dates are serial numbers with the date style; 2024-12-31 = 45657.
    #expect(sheet.contains("<c r=\"A4\" s=\"1\"><v>45657</v></c>"))
    // Formula-looking text is a literal shared string, never a formula.
    let shared = package.text(XLSXExport.sharedStringsPart)
    #expect(shared.contains("=SUM(A1)"))
    for file in package.files where file.hasSuffix(".xml") {
      #expect(!package.text(file).contains("<f>"), "formula element in \(file)")
      #expect(!package.text(file).contains("<f "), "formula element in \(file)")
    }
    #expect(XLSXExport.dateSerial("2024-12-31") == 45657)
  }

  // MARK: - P36-022/P36-023

  @Test func mergedCellsGeometryAndStylesAreEmitted() throws {
    let grid = table(
      rows: [["Merged", nil], ["Left", "Right"]], spans: [(0, 0, 1, 2)],
      cellBounds: [0, 0, 120, 24])
    let package = try package(tables: [grid])
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let sheet = package.text(XLSXExport.worksheetPart(index: 1))
    #expect(sheet.contains("<mergeCells count=\"1\"><mergeCell ref=\"A1:B1\"/></mergeCells>"))
    #expect(sheet.contains("customHeight=\"1\""))
    #expect(sheet.contains("customWidth=\"1\""))
    #expect(sheet.contains("<dimension ref=\"A1:B2\"/>"))
    let styles = package.text(XLSXExport.stylesPart)
    #expect(styles.contains("numFmtId=\"164\""))
    #expect(styles.contains("formatCode=\"yyyy\\-mm\\-dd\""))
    #expect(styles.contains("<border>"))
    #expect(styles.contains("style=\"thin\""))
    #expect(styles.contains("wrapText=\"1\""))
  }

  // MARK: - P36-024

  @Test func sourcePageProvenanceIsOptIn() throws {
    let grid = table(rows: [["A", "B"], ["C", "D"]], pageIndex: 2)
    let plain = try package(tables: [grid])
    defer {
      try? FileManager.default.removeItem(at: plain.url)
      try? FileManager.default.removeItem(at: plain.directory)
    }
    #expect(plain.text(XLSXExport.worksheetPart(index: 1)).contains("<dimension ref=\"A1:B2\"/>"))
    #expect(!plain.text(XLSXExport.sharedStringsPart).contains("Page 3"))

    let withSource = try package(
      tables: [grid], options: XLSXExportOptions(includeSourcePage: true))
    defer {
      try? FileManager.default.removeItem(at: withSource.url)
      try? FileManager.default.removeItem(at: withSource.directory)
    }
    let sheet = withSource.text(XLSXExport.worksheetPart(index: 1))
    #expect(sheet.contains("<dimension ref=\"A1:C2\"/>"))
    #expect(withSource.text(XLSXExport.sharedStringsPart).contains("Page 3"))
    #expect(sheet.contains("<c r=\"C1\" s=\"0\" t=\"s\"><v>"))
  }

  // MARK: - P36-029

  @Test func analysisAndExportCostAreBounded() throws {
    // A born-digital ruled table: 40 rows × 8 columns (320 cells).
    let rows = 40
    let columns = 8
    var content = "0.5 w 0 0 0 RG\n"
    for row in 0..<rows {
      let y = 700 - Double(row) * 16
      content += "72 \(y) 400 16 re S\n"
    }
    for column in 0...columns {
      let x = 72 + Double(column) * 50
      content += "\(x) \(700 - Double(rows - 1) * 16) 0.5 \(Double(rows) * 16) re S\n"
    }
    for row in 0..<rows {
      let y = 700 - Double(row) * 16 + 5
      for column in 0..<columns {
        let x = 76 + Double(column) * 50
        content += "BT /F1 10 Tf \(x) \(y) Td (R\(row)C\(column)) Tj ET\n"
      }
    }
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)

    func millis(_ duration: Duration) -> Int {
      Int(
        duration.components.seconds * 1000
          + duration.components.attoseconds / 1_000_000_000_000_000)
    }
    let start = ContinuousClock.now
    let tables = try TableExtraction.tables(
      pageIDs: pageIDs, in: graph, profile: TableDetectionProfile(mode: .ruled))
    let extraction = ContinuousClock.now - start
    let table = try #require(tables.first)
    #expect(table.rowCount == rows)
    #expect(table.columnCount == columns)
    #expect(table.cells.count == rows * columns)
    #expect(table.confidence >= 0.6)

    let exportStart = ContinuousClock.now
    let data = try XLSXExport.package(tables: tables)
    let export = ContinuousClock.now - exportStart
    print(
      "[P36-029] \(table.cells.count) cells: extraction \(millis(extraction)) ms, "
        + "xlsx \(millis(export)) ms, \(data.count / 1024) KiB")
    #expect(millis(extraction) < 5_000)
    #expect(millis(export) < 5_000)
    #expect(data.count < 4 * 1_048_576)

    // The scanned variant: the same grid without text, recognized lines only.
    var scannedContent = "0.5 w 0 0 0 RG\n"
    for row in 0..<rows {
      let y = 700 - Double(row) * 16
      scannedContent += "72 \(y) 400 16 re S\n"
    }
    for column in 0...columns {
      let x = 72 + Double(column) * 50
      scannedContent +=
        "\(x) \(700 - Double(rows - 1) * 16) 0.5 \(Double(rows) * 16) re S\n"
    }
    var scannedObjects = graph.objects
    scannedObjects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(scannedContent.utf8)))
    let scanned = PDFGraph(objects: scannedObjects, trailer: graph.trailer)
    var lines: [SearchableTextLine] = []
    for row in 0..<rows {
      for column in 0..<columns {
        let x = 76 + Double(column) * 50
        let y = 700 - Double(row) * 16 + 2
        lines.append(
          SearchableTextLine(
            text: "R\(row)C\(column)", rect: [x, y, x + 40, y + 12], confidence: 0.9))
      }
    }
    let scannedStart = ContinuousClock.now
    let scannedTables = try TableExtraction.tables(
      pageIDs: pageIDs, in: scanned, profile: TableDetectionProfile(mode: .ruled),
      recognizedLines: [0: lines])
    let scannedDuration = ContinuousClock.now - scannedStart
    let scannedTable = try #require(scannedTables.first)
    print("[P36-029] scanned: \(scannedTable.cells.count) cells in \(millis(scannedDuration)) ms")
    #expect(scannedTable.cells.count == rows * columns)
    #expect(scannedTable.cells.allSatisfy { $0.provenance == .ocr })
    #expect(millis(scannedDuration) < 5_000)
  }

  // MARK: - P36-027/P36-028

  /// A ruled page with a merged header, a multi-line cell, and a leading-zero
  /// value, extracted end to end and exported to both CSV and XLSX.
  @Test func mergedMultilineAndLeadingZeroValuesSurviveExport() throws {
    var content = "1 w 0 0 0 RG\n"
    content += "72 600 100 40 re S\n"
    content += "172 600 100 40 re S\n"
    content += "72 640 200 40 re S\n"
    content += "BT /F1 12 Tf 90 655 Td (Quarterly Summary) Tj ET\n"
    content += "BT /F1 12 Tf 90 620 Td (Ada) Tj ET\n"
    content += "BT /F1 12 Tf 90 604 Td (Lovelace) Tj ET\n"
    content += "BT /F1 12 Tf 200 620 Td (007) Tj ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let tables = try TableExtraction.tables(
      pageIDs: pageIDs, in: graph, profile: TableDetectionProfile(mode: .ruled))
    let table = try #require(tables.first)
    // Merged header, multi-line cell text, and the literal leading zero.
    #expect(table.cell(row: 0, column: 0)?.columnSpan == 2)
    #expect(table.cell(row: 1, column: 0)?.text == "Ada\nLovelace")
    #expect(table.cell(row: 1, column: 1)?.text == "007")

    // CSV keeps the literal value and the merged slot as empty.
    let csv = TableCSVExport.text(for: table)
    #expect(csv.contains("007"))
    #expect(csv.contains("Quarterly Summary,"))

    // XLSX carries the merge, the string types, and the multiline value.
    let package = try package(tables: [table])
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let sheet = package.text(XLSXExport.worksheetPart(index: 1))
    #expect(sheet.contains("<mergeCell ref=\"A1:B1\"/>"))
    #expect(sheet.contains("t=\"s\""))
    let shared = package.text(XLSXExport.sharedStringsPart)
    #expect(shared.contains("007"))
    #expect(shared.contains("Ada\nLovelace"))
  }

  @Test func ambiguousDetectionsStayReviewable() throws {
    // The same geometry fixture the detection tests use: a 2×2 grid of cells.
    var content = ""
    content += "BT /F1 14 Tf 72 720 Td (Table of quarterly results) Tj ET\n"
    content += "BT /F1 12 Tf 72 660 Td (Name) Tj ET\n"
    content += "BT /F1 12 Tf 72 644 Td (Ada) Tj ET\n"
    content += "BT /F1 12 Tf 220 660 Td (Role) Tj ET\n"
    content += "BT /F1 12 Tf 220 644 Td (Engineer) Tj ET\n"
    content += "BT /F1 12 Tf 72 600 Td (City) Tj ET\n"
    content += "BT /F1 12 Tf 72 584 Td (London) Tj ET\n"
    content += "BT /F1 12 Tf 220 600 Td (Team) Tj ET\n"
    content += "BT /F1 12 Tf 220 584 Td (Platform) Tj ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // A strict gate marks the geometry detection for review but keeps it.
    let strict = TableDetectionProfile(mode: .unruled, confidenceGate: 0.85)
    let tables = try TableExtraction.tables(pageIDs: pageIDs, in: graph, profile: strict)
    let table = try #require(tables.first)
    #expect(table.confidence < 0.85)
    #expect(table.limitations.contains { $0.contains("Low-confidence detection") })
    #expect(table.cells.count == 4)
    // The default gate accepts the same detection without the review note.
    let relaxed = try TableExtraction.tables(pageIDs: pageIDs, in: graph)
    #expect(relaxed.first?.limitations.contains { $0.contains("Low-confidence") } == false)
  }

  // MARK: - P36-026

  @Test func quickLookOpensTheWorkbook() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/qlmanage") else { return }
    let grid = table(rows: [["Name", "Role"], ["Ada", "Engineer"]])
    let package = try package(tables: [grid])
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-quicklook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let result = try run(
      "/usr/bin/qlmanage", ["-t", "-s", "256", "-o", outputDirectory.path, package.url.path])
    let produced = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
    #expect(result.status == 0, "qlmanage: \(result.output)")
    #expect(produced.contains { $0.hasSuffix(".png") }, "no thumbnail produced: \(produced)")
  }

  // MARK: - P36-025

  @Test func cellReferencesAndSharedIndexesValidate() throws {
    #expect(XLSXExport.cellReference(row: 1, column: 0) == "A1")
    #expect(XLSXExport.cellReference(row: 1, column: 25) == "Z1")
    #expect(XLSXExport.cellReference(row: 1, column: 26) == "AA1")
    #expect(XLSXExport.cellReference(row: 10, column: 27) == "AB10")
    #expect(XLSXExport.cellReference(row: 10, column: 51) == "AZ10")
    #expect(XLSXExport.cellReference(row: 10, column: 52) == "BA10")

    let grid = table(rows: [["A", "B", nil], ["C", nil, "D"]], pageIndex: 1)
    let package = try package(tables: [grid], options: XLSXExportOptions(includeSourcePage: true))
    defer {
      try? FileManager.default.removeItem(at: package.url)
      try? FileManager.default.removeItem(at: package.directory)
    }
    let sheetXML = try XMLDocument(
      data: try Data(contentsOf: package.directory.appendingPathComponent(XLSXExport.worksheetPart(index: 1))))
    let shared = package.text(XLSXExport.sharedStringsPart)
    let uniqueCount =
      Int(
        shared.components(separatedBy: "uniqueCount=\"").dropFirst().first?
          .components(separatedBy: "\"").first ?? "0") ?? 0
    var cellCount = 0
    for rowNode in try sheetXML.nodes(forXPath: "//*[local-name()='row']") {
      guard let rowElement = rowNode as? XMLElement,
        let rowNumber = Int(rowElement.attribute(forName: "r")?.stringValue ?? "")
      else { continue }
      for cellNode in rowElement.elements(forName: "c") {
        guard let reference = cellNode.attribute(forName: "r")?.stringValue,
          let parsed = parseReference(reference)
        else { continue }
        cellCount += 1
        // The reference round-trips and its row matches the row element.
        #expect(XLSXExport.cellReference(row: parsed.row, column: parsed.column) == reference)
        #expect(parsed.row == rowNumber)
        // Shared string indexes stay in range.
        if cellNode.attribute(forName: "t")?.stringValue == "s",
          let value = cellNode.elements(forName: "v").first?.stringValue,
          let index = Int(value)
        {
          #expect(index >= 0 && index < uniqueCount, "shared index \(index) out of range")
        }
      }
    }
    // 4 grid cells plus 2 provenance cells.
    #expect(cellCount == 6)
    // Merges (none here) and the dimension reference are consistent.
    let dimension = try sheetXML.nodes(forXPath: "//*[local-name()='dimension']").first
    #expect((dimension as? XMLElement)?.attribute(forName: "ref")?.stringValue == "A1:D2")
  }
}
