import Foundation
import PDFCore

/// Original synthetic test data. Never linked into the application target.
public enum PDFFixtures {
  public static func graph(pages: Int = 1, rotatedLastPage: Bool = false) -> PDFGraph {
    precondition((1...8).contains(pages))
    let pageIDs = (0..<pages).map { PDFObjectID(4 + $0 * 2) }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(pages)),
        PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
      ]),
    ]
    for (index, pageID) in pageIDs.enumerated() {
      let contentID = PDFObjectID(pageID.number + 1)
      let content = """
        q
        0.16 0.39 0.78 rg
        42 660 528 4 re f
        Q
        BT /F1 24 Tf 42 710 Td (sPDF Editor fixture - page \(index + 1)) Tj ET
        BT /F1 12 Tf 42 632 Td (Original Swift-generated content. No personal data.) Tj ET
        """ + "\n"
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array(
          (index == 1 ? [0, 0, 595, 842] : [0, 0, 612, 792]).map { .integer(Int64($0)) }),
        PDFName("Rotate"): .integer(rotatedLastPage && index == pages - 1 ? 90 : 0),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
    }
    return PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  public static func onePage() throws -> Data { try PDFWriter.write(graph()) }
  public static func threePages() throws -> Data {
    try PDFWriter.write(graph(pages: 3, rotatedLastPage: true))
  }

  /// P03-005: a two-page file whose catalog, page-tree, font, and page
  /// dictionaries live in a Flate object stream, with Flate content streams
  /// and a Flate cross-reference stream (W [1 4 2], explicit Index).
  public static func xrefStreamPages() throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    file.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    var offsets: [Int: Int] = [:]

    let catalog: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    let pages: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(2),
      PDFName("Kids"): .array([.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]),
    ])
    let font: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
    ])
    func page(box: [Int64], content: Int) -> PDFValue {
      .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array(box.map { .integer($0) }),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(content)),
      ])
    }
    func content(_ pageNumber: Int) throws -> PDFStream {
      let text = """
        q
        0.16 0.39 0.78 rg
        42 660 528 4 re f
        Q
        BT /F1 24 Tf 42 710 Td (sPDF Editor xref-stream fixture - page \(pageNumber)) Tj ET
        """ + "\n"
      return PDFStream(
        dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
        bytes: try PDFFilters.encodeFlate(Data(text.utf8)))
    }

    let compressedObjects: [(Int, PDFValue)] = [
      (1, catalog), (2, pages), (3, font),
      (4, page(box: [0, 0, 612, 792], content: 5)),
      (6, page(box: [0, 0, 595, 842], content: 7)),
    ]
    var objectStreamData = Data()
    var headerParts: [String] = []
    for (number, value) in compressedObjects {
      headerParts.append("\(number) \(objectStreamData.count)")
      objectStreamData.append(try PDFWriter.serializedValue(value))
      objectStreamData.append(0x0A)
    }
    let header = Data((headerParts.joined(separator: " ") + "\n").utf8)
    var objectStreamContent = header
    objectStreamContent.append(objectStreamData)
    let objectStream = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("ObjStm")),
        PDFName("N"): .integer(Int64(compressedObjects.count)),
        PDFName("First"): .integer(Int64(header.count)),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
      ], bytes: try PDFFilters.encodeFlate(objectStreamContent))

    func beginObject(_ number: Int, _ body: Data) {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n".utf8))
      file.append(body)
      file.append(Data("\nendobj\n".utf8))
    }
    beginObject(5, try PDFWriter.serializedValue(.stream(try content(1))))
    beginObject(7, try PDFWriter.serializedValue(.stream(try content(2))))
    beginObject(8, try PDFWriter.serializedValue(.stream(objectStream)))

    var entryFields: [Int: [Int]] = [
      0: [0, 0, 65_535],
      5: [1, offsets[5]!, 0],
      7: [1, offsets[7]!, 0],
      8: [1, offsets[8]!, 0],
    ]
    for (index, pair) in compressedObjects.enumerated() {
      entryFields[pair.0] = [2, 8, index]
    }
    let xrefOffset = file.count
    entryFields[9] = [1, xrefOffset, 0]

    func field(_ value: Int, width: Int) -> [UInt8] {
      (0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
    var xrefPayload = Data()
    for number in 0...9 {
      guard let fields = entryFields[number] else { continue }
      xrefPayload.append(contentsOf: field(fields[0], width: 1))
      xrefPayload.append(contentsOf: field(fields[1], width: 4))
      xrefPayload.append(contentsOf: field(fields[2], width: 2))
    }
    let xrefStream = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XRef")),
        PDFName("Size"): .integer(10),
        PDFName("W"): .array([.integer(1), .integer(4), .integer(2)]),
        PDFName("Index"): .array([.integer(0), .integer(10)]),
        PDFName("Root"): .reference(PDFObjectID(1)),
        PDFName("ID"): .array([
          .string(Data("sPDF-xref-stream-fixture".utf8)),
          .string(Data("sPDF-xref-stream-fixture".utf8)),
        ]),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
      ], bytes: try PDFFilters.encodeFlate(xrefPayload))
    beginObject(9, try PDFWriter.serializedValue(.stream(xrefStream)))
    guard offsets[9] == xrefOffset else {
      preconditionFailure("Cross-reference stream offset changed during assembly")
    }
    file.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return file
  }

  /// P03-006: a hybrid-reference file. The classic table marks the compressed
  /// objects free while the companion XRefStm stream binds them to an object
  /// stream, so resolution depends on the documented merge precedence.
  public static func hybridReferencePages() throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    file.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    var offsets: [Int: Int] = [:]
    func append(_ number: Int, _ body: Data) {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n".utf8))
      file.append(body)
      file.append(Data("\nendobj\n".utf8))
    }

    let catalog: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    let pages: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
    ])
    let font: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
    ])
    let page: PDFValue = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
      PDFName("Resources"): .dictionary([
        PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
      ]),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ])
    let compressedObjects: [(Int, PDFValue)] = [(1, catalog), (2, pages), (3, font), (4, page)]
    var objectStreamData = Data()
    var headerParts: [String] = []
    for (number, value) in compressedObjects {
      headerParts.append("\(number) \(objectStreamData.count)")
      objectStreamData.append(try PDFWriter.serializedValue(value))
      objectStreamData.append(0x0A)
    }
    let header = Data((headerParts.joined(separator: " ") + "\n").utf8)
    var objectStreamContent = header
    objectStreamContent.append(objectStreamData)
    let objectStream = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("ObjStm")),
        PDFName("N"): .integer(Int64(compressedObjects.count)),
        PDFName("First"): .integer(Int64(header.count)),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
      ], bytes: try PDFFilters.encodeFlate(objectStreamContent))

    let contentText = """
      q
      0.16 0.39 0.78 rg
      42 660 528 4 re f
      Q
      BT /F1 24 Tf 42 710 Td (sPDF Editor hybrid-reference fixture - page 1) Tj ET
      """ + "\n"
    let content = PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
      bytes: try PDFFilters.encodeFlate(Data(contentText.utf8)))

    append(5, try PDFWriter.serializedValue(.stream(content)))
    append(6, try PDFWriter.serializedValue(.stream(objectStream)))

    let xrefStreamOffset = file.count
    func field(_ value: Int, width: Int) -> [UInt8] {
      (0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
    var entryFields: [Int: [Int]] = [
      0: [0, 0, 65_535],
      5: [1, offsets[5]!, 0],
      6: [1, offsets[6]!, 0],
      7: [1, xrefStreamOffset, 0],
    ]
    for (index, pair) in compressedObjects.enumerated() {
      entryFields[pair.0] = [2, 6, index]
    }
    var xrefPayload = Data()
    for number in 0...7 {
      guard let fields = entryFields[number] else { continue }
      xrefPayload.append(contentsOf: field(fields[0], width: 1))
      xrefPayload.append(contentsOf: field(fields[1], width: 4))
      xrefPayload.append(contentsOf: field(fields[2], width: 2))
    }
    let xrefStream = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XRef")),
        PDFName("Size"): .integer(8),
        PDFName("W"): .array([.integer(1), .integer(4), .integer(2)]),
        PDFName("Index"): .array([.integer(0), .integer(8)]),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
      ], bytes: try PDFFilters.encodeFlate(xrefPayload))
    append(7, try PDFWriter.serializedValue(.stream(xrefStream)))
    guard offsets[7] == xrefStreamOffset else {
      preconditionFailure("Hybrid cross-reference stream offset changed during assembly")
    }

    let tableOffset = file.count
    file.append(Data("xref\n0 8\n".utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data(Self.classicXRefRow(offsets[5]!).utf8))
    file.append(Data(Self.classicXRefRow(offsets[6]!).utf8))
    file.append(Data(Self.classicXRefRow(offsets[7]!).utf8))
    file.append(
      Data(
        ("trailer\n<< /Size 8 /Root 1 0 R "
          + "/ID [(sPDF-hybrid-fixture) (sPDF-hybrid-fixture)] "
          + "/XRefStm \(xrefStreamOffset) >>\nstartxref\n\(tableOffset)\n%%EOF\n").utf8))
    return file
  }

  /// P03-007: two incremental revisions. The update overwrites the content
  /// stream, deletes object 6 (free entry) and adds object 7, with a new
  /// trailer carrying /Prev so the base revision stays in the file.
  public static func incrementalUpdate() throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    file.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    var offsets: [Int: Int] = [:]
    func append(_ number: Int, _ body: Data) {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n".utf8))
      file.append(body)
      file.append(Data("\nendobj\n".utf8))
    }
    func contentStream(_ text: String) throws -> PDFStream {
      PDFStream(
        dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
        bytes: try PDFFilters.encodeFlate(Data((text + "\n").utf8)))
    }

    // Revision 1.
    append(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
    append(2, Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8))
    append(
      3,
      Data(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
          .utf8))
    append(4, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))
    append(
      5,
      try PDFWriter.serializedValue(
        .stream(
          try contentStream(
            "BT /F1 24 Tf 42 710 Td (sPDF Editor incremental fixture - base revision) Tj ET"))))
    append(6, Data("<< /Title (base info) >>".utf8))
    let base = file.count
    file.append(Data("xref\n0 7\n".utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    for number in 1...6 {
      file.append(Data(Self.classicXRefRow(offsets[number]!).utf8))
    }
    file.append(
      Data("trailer\n<< /Size 7 /Root 1 0 R /Info 6 0 R >>\nstartxref\n\(base)\n%%EOF\n".utf8))

    // Revision 2.
    append(
      5,
      try PDFWriter.serializedValue(
        .stream(
          try contentStream(
            "BT /F1 24 Tf 42 710 Td (sPDF Editor incremental fixture - updated revision) Tj ET"))))
    append(7, Data("<< /Title (updated info) >>".utf8))
    let update = file.count
    file.append(Data("xref\n0 1\n".utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data("5 1\n".utf8))
    file.append(Data(Self.classicXRefRow(offsets[5]!).utf8))
    file.append(Data("6 1\n".utf8))
    file.append(Data(Self.classicFreeRow(generation: 1).utf8))  // object 6 deleted
    file.append(Data("7 1\n".utf8))
    file.append(Data(Self.classicXRefRow(offsets[7]!).utf8))
    file.append(
      Data(
        "trailer\n<< /Size 8 /Root 1 0 R /Info 7 0 R /Prev \(base) >>\nstartxref\n\(update)\n%%EOF\n"
          .utf8))
    return file
  }

  private static func classicXRefRow(_ offset: Int, generation: Int = 0) -> String {
    let offsetText = String(offset)
    let generationText = String(generation)
    return String(repeating: "0", count: max(0, 10 - offsetText.count)) + offsetText + " "
      + String(repeating: "0", count: max(0, 5 - generationText.count)) + generationText + " n \n"
  }

  private static func classicFreeRow(generation: Int, nextFree: Int = 0) -> String {
    let nextText = String(nextFree)
    let generationText = String(generation)
    return String(repeating: "0", count: max(0, 10 - nextText.count)) + nextText + " "
      + String(repeating: "0", count: max(0, 5 - generationText.count)) + generationText + " f \n"
  }

  /// P03 text fixture for the M2 edit slice: one page whose content uses a
  /// WinAnsi font, a Tj run, a TJ kerning array, and an escaped literal
  /// string, all with known expected text.
  public static func textEditPages() throws -> Data {
    let content = """
      BT /F1 24 Tf 42 710 Td (Replace this text) Tj ET
      BT /F1 12 Tf 42 632 Td [(Kern) -300 (ing stays)] TJ ET
      BT /F1 12 Tf 42 600 Td (Quotes \\(kept\\)) Tj ET
      """ + "\n"
    var graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    // The writer serializes stream Length; verification below re-reads it.
    _ = try PDFParser.parse(data)
    return data
  }

  /// P14-012/P14-015 fixture: a synthetic Helvetica-like font with explicit
  /// widths (all 500, space 250) plus a FontDescriptor MissingWidth, and a
  /// TJ line whose members let tests verify advance math and adjustment
  /// compensation without relying on system font metrics.
  public static func textWidthsPages() throws -> Data {
    let widthValues: [PDFValue] = (32...126).map { code in
      .integer(code == 32 ? 250 : 500)
    }
    let content = "BT /F1 20 Tf 42 710 Td [ (AB) -500 (CD) ] TJ ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("FirstChar"): .integer(32),
          PDFName("LastChar"): .integer(126),
          PDFName("Widths"): .array(widthValues),
          PDFName("FontDescriptor"): .reference(PDFObjectID(6)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("FontDescriptor")),
          PDFName("FontName"): .name(PDFName("Helvetica")),
          PDFName("MissingWidth"): .integer(250),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-022: a visible-but-unsanitized redaction across two revisions.
  /// Revision 1 sets "SECRET-TOKEN-123" as plain text; revision 2 paints a
  /// black rectangle over it and adds a Redact annotation, but the text
  /// remains in the live content stream (extractable: the hidden copy) and
  /// the superseded stream persists in the file (the historical copy).
  public static func redactionPages() throws -> Data {
    var file = Data("%PDF-1.7\n".utf8)
    file.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    var offsets: [Int: Int] = [:]
    func append(_ number: Int, _ body: Data) {
      offsets[number] = file.count
      file.append(Data("\(number) 0 obj\n".utf8))
      file.append(body)
      file.append(Data("\nendobj\n".utf8))
    }
    func contentStream(_ text: String) throws -> PDFStream {
      PDFStream(
        dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
        bytes: try PDFFilters.encodeFlate(Data((text + "\n").utf8)))
    }
    let line = "BT /F1 24 Tf 42 710 Td (Public text. SECRET-TOKEN-123. More public.) Tj ET"
    let paint = "0 0 0 rg 200 702 190 22 re f"

    // Revision 1: the secret as plain text.
    append(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
    append(2, Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8))
    append(
      3,
      Data(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
          .utf8))
    append(4, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))
    append(
      5,
      try PDFWriter.serializedValue(.stream(try contentStream(line))))
    let base = file.count
    file.append(Data("xref\n0 6\n".utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    for number in 1...5 {
      file.append(Data(Self.classicXRefRow(offsets[number]!).utf8))
    }
    file.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(base)\n%%EOF\n".utf8))

    // Revision 2: a visible black rectangle plus a Redact annotation. The
    // text itself is untouched, on purpose.
    append(
      3,
      Data(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /Annots [6 0 R] >>"
          .utf8))
    append(
      5,
      try PDFWriter.serializedValue(.stream(try contentStream(line + "\n" + paint))))
    append(
      6,
      Data(
        "<< /Type /Annot /Subtype /Redact /Rect [200 702 390 724] /QuadPoints [200 724 390 724 200 702 390 702] /IC [0 0 0] >>"
          .utf8))
    let update = file.count
    file.append(Data("xref\n0 1\n".utf8))
    file.append(Data(Self.classicFreeRow(generation: 65_535).utf8))
    file.append(Data("3 1\n".utf8))
    file.append(Data(Self.classicXRefRow(offsets[3]!).utf8))
    file.append(Data("5 2\n".utf8))
    file.append(Data(Self.classicXRefRow(offsets[5]!).utf8))
    file.append(Data(Self.classicXRefRow(offsets[6]!).utf8))
    file.append(
      Data(
        "trailer\n<< /Size 7 /Root 1 0 R /Prev \(base) >>\nstartxref\n\(update)\n%%EOF\n"
          .utf8))
    return file
  }

  /// P03-010: one page using an embedded DejaVu Sans subset (space, A,
  /// B, C, and the fi ligature through a Differences code) with a ToUnicode
  /// map, so extraction has known Unicode mappings from a real font program.
  public static func fontEmbeddedPages() throws -> Data {
    try fontSubsetPages(toUnicodeMissingC: false, extraUnmappedPage: false)
  }

  /// P03-011: subset-fixture companions — one page whose ToUnicode map lacks
  /// C (decoding must fail loudly for it) and one page using D, which has a
  /// known Unicode mapping but no glyph in the subset (zero width, .notdef
  /// rendering in consumers).
  public static func fontSubsetPages() throws -> Data {
    try fontSubsetPages(toUnicodeMissingC: true, extraUnmappedPage: true)
  }

  private static func fontSubsetPages(toUnicodeMissingC: Bool, extraUnmappedPage: Bool)
    throws -> Data
  {
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      throw PDFError(.malformed, "Embedded font fixture data is corrupt")
    }
    func width(_ code: Int) -> PDFValue {
      .integer(Int64(FontFixtureData.winAnsiWidths[code] ?? 0))
    }
    let widthValues: [PDFValue] = (32...68).map(width)
    var entries = ["<20> <0020>", "<41> <0041>", "<42> <0042>"]
    if !toUnicodeMissingC {
      entries.append("<43> <0043>")
    }
    entries += ["<44> <0044>", "<01> <FB01>"]
    let bfchar = entries.joined(separator: "\n") + "\n"
    let toUnicode =
      "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo\n<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n\(entries.count) beginbfchar\n\(bfchar)endbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    let descriptor = PDFObjectID(6)
    let programObject = PDFObjectID(7)
    let toUnicodeObject = PDFObjectID(8)
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(extraUnmappedPage ? 2 : 1),
        PDFName("Kids"): .array(
          extraUnmappedPage
            ? [.reference(PDFObjectID(3)), .reference(PDFObjectID(9))]
            : [.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(5)),
      ]),
      PDFObjectID(4): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("TrueType")),
        PDFName("BaseFont"): .name(PDFName("DejaVuSans")),
        PDFName("FirstChar"): .integer(32),
        PDFName("LastChar"): .integer(68),
        PDFName("Widths"): .array(widthValues),
        PDFName("Encoding"): .dictionary([
          PDFName("Type"): .name(PDFName("Encoding")),
          PDFName("BaseEncoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("Differences"): .array([.integer(1), .name(PDFName("fi"))]),
        ]),
        PDFName("FontDescriptor"): .reference(descriptor),
        PDFName("ToUnicode"): .reference(toUnicodeObject),
      ]),
      PDFObjectID(5): .stream(
        PDFStream(
          bytes: Data(
            "BT /F1 24 Tf 42 700 Td (ABC) Tj ET\nBT /F1 24 Tf 42 660 Td (\\001) Tj ET\n"
              .utf8))),
      descriptor: .dictionary([
        PDFName("Type"): .name(PDFName("FontDescriptor")),
        PDFName("FontName"): .name(PDFName("DejaVuSans")),
        PDFName("Flags"): .integer(32),
        PDFName("FontBBox"): .array(
          FontFixtureData.fontBBox.map { PDFValue.integer(Int64($0)) }),
        PDFName("ItalicAngle"): .integer(0),
        PDFName("Ascent"): .integer(Int64(FontFixtureData.ascent)),
        PDFName("Descent"): .integer(Int64(FontFixtureData.descent)),
        PDFName("FontFile2"): .reference(programObject),
      ]),
      programObject: .stream(PDFStream(bytes: program)),
      toUnicodeObject: .stream(PDFStream(bytes: Data(toUnicode.utf8))),
    ]
    if extraUnmappedPage {
      objects[PDFObjectID(9)] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(10)),
      ])
      objects[PDFObjectID(10)] = .stream(
        PDFStream(bytes: Data("BT /F1 24 Tf 42 700 Td (AD) Tj ET\n".utf8)))
    }
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P14-018: combining marks — a synthetic Helvetica-like font with
  /// `/Differences [1 /uni0301]` (zero-width combining acute) and two lines:
  /// base then mark (usual order) and mark then base (reordered stream
  /// order). Extraction, words, selection, and search must keep the mark
  /// with its base in both.
  public static func combiningMarkPages() throws -> Data {
    let widthValues: [PDFValue] = (32...126).map { code in
      .integer(code == 32 ? 250 : 500)
    }
    let content =
      "BT /F1 24 Tf 42 700 Td (e\\001) Tj ET\nBT /F1 24 Tf 42 660 Td (\\001e) Tj ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .dictionary([
            PDFName("Differences"): .array([.integer(1), .name(PDFName("uni0301"))])
          ]),
          PDFName("FirstChar"): .integer(32),
          PDFName("LastChar"): .integer(126),
          PDFName("Widths"): .array(widthValues),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P14-026: the licensed multilingual fixture — a DejaVu Sans subset
  /// covering Greek, Cyrillic, and Hebrew embedded as a simple TrueType
  /// font, with ToUnicode mappings and widths from the program's metrics.
  /// Three lines: Greek (ΑΒΓ), Cyrillic (БВ), and Hebrew stored in the
  /// visual order real RTL generators emit (readers apply bidi; see the
  /// extraction tests).
  public static func multilingualPages() throws -> Data {
    guard let program = Data(base64Encoded: FontFixtureData.multilingualProgramBase64) else {
      throw PDFError(.malformed, "Multilingual font fixture data is corrupt")
    }
    let content = """
      BT /F1 24 Tf 42 700 Td (ABC) Tj ET
      BT /F1 24 Tf 42 660 Td (DE) Tj ET
      BT /F1 24 Tf 42 620 Td (HGF) Tj ET
      """ + "\n"
    let toUnicode = """
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /CIDSystemInfo
      << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
      /CMapName /Adobe-Identity-UCS def
      /CMapType 2 def
      1 begincodespacerange
      <00> <FF>
      endcodespacerange
      9 beginbfchar
      <20> <0020>
      <41> <0391>
      <42> <0392>
      <43> <0393>
      <44> <0411>
      <45> <0412>
      <46> <05D0>
      <47> <05D1>
      <48> <05E9>
      endbfchar
      endcmap
      CMapName currentdict /CMap defineresource pop
      end
      end

      """
    let widthValues: [PDFValue] = (32...72).map { code in
      .integer(Int64(FontFixtureData.multilingualWidths[code] ?? 0))
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
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("TrueType")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+DejaVuSans")),
          PDFName("FirstChar"): .integer(32),
          PDFName("LastChar"): .integer(72),
          PDFName("Widths"): .array(widthValues),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("FontDescriptor"): .reference(PDFObjectID(6)),
          PDFName("ToUnicode"): .reference(PDFObjectID(8)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("FontDescriptor")),
          PDFName("FontName"): .name(PDFName("ABCDEF+DejaVuSans")),
          PDFName("Flags"): .integer(32),
          PDFName("FontBBox"): .array([
            .integer(-1021), .integer(-463), .integer(1793), .integer(1556),
          ]),
          PDFName("ItalicAngle"): .integer(0),
          PDFName("Ascent"): .integer(1493),
          PDFName("Descent"): .integer(-380),
          PDFName("FontFile2"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: program)),
        PDFObjectID(8): .stream(PDFStream(bytes: Data(toUnicode.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P14-027: vertical-writing fixture — a Type0 Identity-V font with
  /// `/W2`/`/DW2` vertical metrics and a ToUnicode map. The profile decodes
  /// the codes but does not lay out vertical writing; the fixture pins both
  /// the decode result and the explicit layout non-claim.
  public static func verticalTextPages() throws -> Data {
    let toUnicode = """
      begincodespacerange
      <0000> <FFFF>
      endcodespacerange
      3 beginbfchar
      <0001> <0391>
      <0002> <0392>
      <0003> <0393>
      endbfchar

      """
    let content = "BT /F1 12 Tf 100 700 Td <000100020003> Tj ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type0")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+VerticalCID")),
          PDFName("Encoding"): .name(PDFName("Identity-V")),
          PDFName("DescendantFonts"): .array([.reference(PDFObjectID(6))]),
          PDFName("ToUnicode"): .reference(PDFObjectID(8)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("CIDFontType2")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+VerticalCID")),
          PDFName("CIDSystemInfo"): .dictionary([
            PDFName("Registry"): .string(Data("Adobe".utf8)),
            PDFName("Ordering"): .string(Data("Identity".utf8)),
            PDFName("Supplement"): .integer(0),
          ]),
          PDFName("DW"): .integer(1000),
          PDFName("W"): .array([
            .integer(1), .array([.integer(600), .integer(600), .integer(600)]),
          ]),
          PDFName("DW2"): .array([.integer(880), .integer(-1000)]),
          PDFName("W2"): .array([
            .integer(1),
            .array([
              .integer(500), .integer(880), .integer(500),
              .integer(500), .integer(880), .integer(500),
              .integer(500), .integer(880), .integer(500),
            ]),
          ]),
          PDFName("FontDescriptor"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .dictionary([
          PDFName("Type"): .name(PDFName("FontDescriptor")),
          PDFName("FontName"): .name(PDFName("ABCDEF+VerticalCID")),
          PDFName("Flags"): .integer(4),
        ]),
        PDFObjectID(8): .stream(PDFStream(bytes: Data(toUnicode.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P16-007: a two-column page with three lines per column sharing
  /// baselines, so naive baseline grouping would interleave the columns.
  public static func twoColumnPages() throws -> Data {
    let content = """
      BT /F1 12 Tf 42 700 Td (Left one) Tj ET
      BT /F1 12 Tf 320 700 Td (Right one) Tj ET
      BT /F1 12 Tf 42 680 Td (Left two) Tj ET
      BT /F1 12 Tf 320 680 Td (Right two) Tj ET
      BT /F1 12 Tf 42 660 Td (Left three) Tj ET
      BT /F1 12 Tf 320 660 Td (Right three) Tj ET

      """
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-013: one Letter page with a nonzero-origin crop box plus a
  /// 90-degree rotated page, pinning crop/rotation coordinate handling.
  public static func croppedPages() throws -> Data {
    let content = "BT /F1 12 Tf 42 700 Td (Cropped fixture) Tj ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("CropBox"): .array([
            .integer(10), .integer(20), .integer(602), .integer(772),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Rotate"): .integer(90),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-012: transformed baselines — one line rotated 90 degrees and one
  /// line scaled 2x through the text matrix (kerning arrays live in
  /// text-edit.pdf; the fi ligature lives in font-embedded.pdf).
  public static func transformedTextPages() throws -> Data {
    let content =
      "BT /F1 12 Tf 0 1 -1 0 200 200 Tm (Rotated line) Tj ET\nBT /F1 12 Tf 2 0 0 2 42 500 Tm (Scaled line) Tj ET\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-014: masked and transparent images — a 1-bit image mask painting
  /// through the fill color plus an RGB image with a soft (SMask) alpha
  /// stream, sharing one graphics resource across both placements.
  public static func maskedImagePages() throws -> Data {
    let mask = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(4),
        PDFName("Height"): .integer(4),
        PDFName("ImageMask"): .boolean(true),
        PDFName("BitsPerComponent"): .integer(1),
      ], bytes: Data([0x00, 0x00, 0xFF, 0xFF]))
    let soft = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
        PDFName("BitsPerComponent"): .integer(8),
      ],
      bytes: Data([0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]))
    let photo = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
        PDFName("BitsPerComponent"): .integer(8),
        PDFName("SMask"): .reference(PDFObjectID(8)),
      ],
      bytes: Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]))
    let content =
      "1 0 0 rg q 100 0 0 100 200 200 cm /Mask1 Do Q\nq 100 0 0 100 200 400 cm /Photo1 Do Q\n"
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([
              PDFName("Mask1"): .reference(PDFObjectID(6)),
              PDFName("Photo1"): .reference(PDFObjectID(7)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(6): .stream(mask),
        PDFObjectID(7): .stream(photo),
        PDFObjectID(8): .stream(soft),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-015: a reusable form XObject (a filled square with a stroked edge)
  /// placed twice on page 1 and once on page 2.
  public static func formXObjectPages() throws -> Data {
    let form = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("BBox"): .array([
          .integer(0), .integer(0), .integer(50), .integer(50),
        ]),
        PDFName("Matrix"): .array([
          .integer(1), .integer(0), .integer(0), .integer(1), .integer(0),
          .integer(0),
        ]),
        PDFName("Resources"): .dictionary([:]),
      ],
      bytes: Data("0.2 0.4 0.8 rg 0 0 50 50 re f 0 0 0 RG 2 w 0 0 50 50 re S\n".utf8))
    let content1 = "q 2 0 0 2 100 600 cm /Fm1 Do Q\nq 1 0 0 1 300 600 cm /Fm1 Do Q\n"
    let content2 = "q 3 0 0 3 100 300 cm /Fm1 Do Q\n"
    let resources: PDFValue = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(6))])
    ])
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): resources,
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): resources,
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content1.utf8))),
        PDFObjectID(6): .stream(form),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(content2.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-016: annotations with a reply chain (/IRT), a generated appearance
  /// stream (/AP), and a note on the 90-degree rotated page.
  public static func annotationPages() throws -> Data {
    let appearance = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("BBox"): .array([
          .integer(0), .integer(0), .integer(120), .integer(40),
        ]),
      ],
      bytes: Data("1 1 0 rg 0 0 120 40 re f\n".utf8))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([:]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
          PDFName("Annots"): .array([
            .reference(PDFObjectID(6)), .reference(PDFObjectID(7)),
          ]),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Rotate"): .integer(90),
          PDFName("Resources"): .dictionary([:]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
          PDFName("Annots"): .array([.reference(PDFObjectID(8))]),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data("42 700 m\n".utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Text")),
          PDFName("Rect"): .array([
            .integer(100), .integer(100), .integer(120), .integer(120),
          ]),
          PDFName("Contents"): .string(Data("Parent note".utf8)),
          PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(9))]),
        ]),
        PDFObjectID(7): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Text")),
          PDFName("Rect"): .array([
            .integer(140), .integer(100), .integer(160), .integer(120),
          ]),
          PDFName("Contents"): .string(Data("Reply note".utf8)),
          PDFName("IRT"): .reference(PDFObjectID(6)),
        ]),
        PDFObjectID(8): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Text")),
          PDFName("Rect"): .array([
            .integer(100), .integer(100), .integer(120), .integer(120),
          ]),
          PDFName("Contents"): .string(Data("Rotated-page note".utf8)),
        ]),
        PDFObjectID(9): .stream(appearance),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P03-021: a scanned page — an 8x8 DeviceGray image with no text
  /// operators. The known transcription lives in the manifest; recognition
  /// itself is environment-dependent, so tests feed the documented lines as
  /// explicitly supplied recognized input (provenance, not recognition).
  public static func scannedPages() throws -> Data {
    let pixels = Data((0..<64).map { row in UInt8(200 + (row % 3) * 10) })
    let image = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(8),
        PDFName("Height"): .integer(8),
        PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
        PDFName("BitsPerComponent"): .integer(8),
      ], bytes: pixels)
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Scan1"): .reference(PDFObjectID(5))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(4)),
        ]),
        PDFObjectID(4): .stream(
          PDFStream(bytes: Data("q 468 0 0 648 72 72 cm /Scan1 Do Q\n".utf8))),
        PDFObjectID(5): .stream(image),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P20 image fixture: two pages sharing one 2x2 solid-green DeviceRGB
  /// image; page 1 draws it twice and page 2 once, each with the supported
  /// `q … cm /Name Do Q` pattern so placements can be moved and replaced.
  public static func imagePages() throws -> Data {
    let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
    let image = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
        PDFName("BitsPerComponent"): .integer(8),
      ], bytes: green)
    let content1 = """
      q
      120 0 0 120 80 600 cm
      /Im1 Do
      Q
      q
      120 0 0 120 80 400 cm
      /Im1 Do
      Q
      """ + "\n"
    let content2 = """
      q
      100 0 0 100 60 300 cm
      /Im1 Do
      Q
      """ + "\n"
    let pageResources: PDFValue = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))])
    ])
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): pageResources,
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): pageResources,
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content1.utf8))),
        PDFObjectID(6): .stream(image),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(content2.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P33 tagged fixture: StructTreeRoot with a role map and class map, a
  /// ParentTree with MCID and annotation keys, marked content (heading,
  /// paragraph, figure with /Alt, artifact), a link annotation, and a text
  /// widget linked through /StructParent.
  public static func taggedPages() throws -> Data {
    let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
    let xmp = """
      <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
       <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
         <dc:title><rdf:Alt><rdf:li xml:lang="x-default">sPDF tagged fixture</rdf:li></rdf:Alt></dc:title>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:pdfuaid="http://www.aiim.org/pdfua/ns/id/">
         <pdfuaid:part>1</pdfuaid:part>
        </rdf:Description>
       </rdf:RDF>
      </x:xmpmeta>
      <?xpacket end="w"?>
      """
    var taggedToUnicode = """
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /CMapName /F1-UCS2 def
      /CMapType 2 def
      1 begincodespacerange
      <20> <7E>
      endcodespacerange
      95 beginbfchar

      """
    for code in 32...126 {
      taggedToUnicode += String(format: "<%02X> <%04X>\n", code, code)
    }
    taggedToUnicode += """
      endbfchar
      endcmap
      CMapName currentdict /CMap defineresource pop
      end
      end

      """
    let content = """
      /MyHead <</MCID 0>> BDC
      BT /F1 20 Tf 42 710 Td (Tagged heading) Tj ET
      EMC
      /P <</MCID 1>> BDC
      BT /F1 12 Tf 42 660 Td (Tagged paragraph text) Tj ET
      EMC
      /Figure <</MCID 2>> BDC
      q 100 0 0 100 300 500 cm /Im1 Do Q
      EMC
      /Artifact <</Type /Pagination>> BDC
      0.16 0.39 0.78 rg 42 600 528 4 re f
      EMC

      """
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
          PDFName("StructTreeRoot"): .reference(PDFObjectID(20)),
          PDFName("MarkInfo"): .dictionary([PDFName("Marked"): .boolean(true)]),
          PDFName("Lang"): .string(Data("en-US".utf8)),
          PDFName("ViewerPreferences"): .dictionary([
            PDFName("DisplayDocTitle"): .boolean(true)
          ]),
          PDFName("Metadata"): .reference(PDFObjectID(9)),
          PDFName("AcroForm"): .reference(PDFObjectID(40)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(7))]),
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(8))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
          PDFName("StructParents"): .integer(0),
          PDFName("Tabs"): .name(PDFName("S")),
          PDFName("Annots"): .array([.reference(PDFObjectID(50))]),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(7): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type3")),
          PDFName("Name"): .name(PDFName("F1")),
          PDFName("FontBBox"): .array([
            .integer(0), .integer(0), .integer(1000), .integer(1000),
          ]),
          PDFName("FontMatrix"): .array([
            .real(0.001), .integer(0), .integer(0), .real(0.001), .integer(0), .integer(0),
          ]),
          PDFName("CharProcs"): .reference(PDFObjectID(10)),
          PDFName("Encoding"): .dictionary([
            PDFName("Type"): .name(PDFName("Encoding")),
            PDFName("Differences"): .array(
              [.integer(32), .name(PDFName("space"))]
                + (33...126).flatMap { [.integer(Int64($0)), .name(PDFName("square"))] }),
          ]),
          PDFName("FirstChar"): .integer(32),
          PDFName("LastChar"): .integer(126),
          PDFName("Widths"): .array((32...126).map { code in
            .integer(code == 32 ? 250 : 500)
          }),
          PDFName("Resources"): .dictionary([:]),
          PDFName("ToUnicode"): .reference(PDFObjectID(13)),
        ]),
        PDFObjectID(10): .dictionary([
          PDFName("space"): .reference(PDFObjectID(11)),
          PDFName("square"): .reference(PDFObjectID(12)),
        ]),
        PDFObjectID(11): .stream(
          PDFStream(bytes: Data("250 0 0 0 1000 1000 d1\n".utf8))),
        PDFObjectID(12): .stream(
          PDFStream(
            bytes: Data("500 0 0 0 1000 1000 d1 0 0 1000 1000 re f\n".utf8))),
        PDFObjectID(13): .stream(
          PDFStream(bytes: Data(taggedToUnicode.utf8))),
        PDFObjectID(8): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: green)),
        PDFObjectID(9): .stream(
          PDFStream(
            dictionary: [PDFName("Type"): .name(PDFName("Metadata")),
                         PDFName("Subtype"): .name(PDFName("XML"))],
            bytes: Data(xmp.utf8))),
        PDFObjectID(20): .dictionary([
          PDFName("Type"): .name(PDFName("StructTreeRoot")),
          PDFName("K"): .array([
            .reference(PDFObjectID(21)), .reference(PDFObjectID(22)),
            .reference(PDFObjectID(23)), .reference(PDFObjectID(24)),
            .reference(PDFObjectID(42)),
          ]),
          PDFName("RoleMap"): .dictionary([
            PDFName("MyHead"): .name(PDFName("H1"))
          ]),
          PDFName("ClassMap"): .dictionary([
            PDFName("Body"): .dictionary([
              PDFName("O"): .name(PDFName("Layout"))
            ])
          ]),
          PDFName("ParentTree"): .reference(PDFObjectID(25)),
          PDFName("ParentTreeNextKey"): .integer(3),
        ]),
        PDFObjectID(21): .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("MyHead")),
          PDFName("P"): .reference(PDFObjectID(20)),
          PDFName("Pg"): .reference(PDFObjectID(3)),
          PDFName("K"): .integer(0),
        ]),
        PDFObjectID(22): .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("P")),
          PDFName("P"): .reference(PDFObjectID(20)),
          PDFName("Pg"): .reference(PDFObjectID(3)),
          PDFName("C"): .name(PDFName("Body")),
          PDFName("K"): .integer(1),
        ]),
        PDFObjectID(23): .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("Figure")),
          PDFName("P"): .reference(PDFObjectID(20)),
          PDFName("Pg"): .reference(PDFObjectID(3)),
          PDFName("Alt"): .string(Data("A green square".utf8)),
          PDFName("K"): .integer(2),
        ]),
        PDFObjectID(24): .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("Link")),
          PDFName("P"): .reference(PDFObjectID(20)),
          PDFName("Pg"): .reference(PDFObjectID(3)),
          PDFName("K"): .array([
            .dictionary([
              PDFName("Type"): .name(PDFName("OBJR")),
              PDFName("Obj"): .reference(PDFObjectID(50)),
              PDFName("Pg"): .reference(PDFObjectID(3)),
            ])
          ]),
        ]),
        PDFObjectID(25): .dictionary([
          PDFName("Nums"): .array([
            .integer(0),
            .array([
              .reference(PDFObjectID(21)), .reference(PDFObjectID(22)),
              .reference(PDFObjectID(23)),
            ]),
            .integer(1),
            .reference(PDFObjectID(24)),
            .integer(2),
            .reference(PDFObjectID(42)),
          ])
        ]),
        PDFObjectID(40): .dictionary([
          PDFName("Fields"): .array([.reference(PDFObjectID(41))]),
          PDFName("DR"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("Helv"): .reference(PDFObjectID(7))])
          ]),
        ]),
        PDFObjectID(41): .dictionary([
          PDFName("FT"): .name(PDFName("Tx")),
          PDFName("T"): .string(Data("taggedField".utf8)),
          PDFName("V"): .string(Data()),
          PDFName("Subtype"): .name(PDFName("Widget")),
          PDFName("Rect"): .array([
            .integer(100), .integer(100), .integer(300), .integer(120),
          ]),
          PDFName("P"): .reference(PDFObjectID(3)),
          PDFName("StructParent"): .integer(2),
        ]),
        PDFObjectID(42): .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("Form")),
          PDFName("P"): .reference(PDFObjectID(20)),
          PDFName("Pg"): .reference(PDFObjectID(3)),
          PDFName("K"): .array([
            .dictionary([
              PDFName("Type"): .name(PDFName("OBJR")),
              PDFName("Obj"): .reference(PDFObjectID(41)),
              PDFName("Pg"): .reference(PDFObjectID(3)),
            ])
          ]),
        ]),
        PDFObjectID(50): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([
            .integer(42), .integer(700), .integer(240), .integer(730),
          ]),
          PDFName("Border"): .array([.integer(0), .integer(0), .integer(0)]),
          PDFName("StructParent"): .integer(1),
          PDFName("P"): .reference(PDFObjectID(3)),
          PDFName("Contents"): .string(Data("Open the tagged example link".utf8)),
          PDFName("A"): .dictionary([
            PDFName("S"): .name(PDFName("URI")),
            PDFName("URI"): .string(Data("https://example.invalid/tagged".utf8)),
          ]),
        ]),
      ],
      trailer: [
        PDFName("Root"): .reference(PDFObjectID(1)),
        PDFName("ID"): .array([
          .string(Data(repeating: 0x11, count: 16)),
          .string(Data(repeating: 0x11, count: 16)),
        ]),
      ])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  /// P34-017/P34-028 fixture: embedded files (one plain, one Flate-compressed
  /// with a traversal-shaped name) for attachment inventory and extraction.
  public static func attachmentPages() throws -> Data {
    let plain = Data("Attachment payload one.\n".utf8)
    let compressedPayload = Data("Compressed payload two.\n".utf8)
    let compressed = try PDFFilters.encodeFlate(compressedPayload)
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
          PDFName("Names"): .dictionary([
            PDFName("EmbeddedFiles"): .dictionary([
              PDFName("Names"): .array([
                .string(Data("notes.txt".utf8)), .reference(PDFObjectID(21)),
                .string(Data("../unsafe name.txt".utf8)), .reference(PDFObjectID(23)),
              ])
            ])
          ]),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(5): .stream(
          PDFStream(bytes: Data("BT /F1 12 Tf 42 700 Td (Attachments) Tj ET\n".utf8))),
        PDFObjectID(20): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("EmbeddedFile")),
              PDFName("Subtype"): .name(PDFName("text/plain")),
              PDFName("Params"): .dictionary([PDFName("Size"): .integer(Int64(plain.count))]),
            ], bytes: plain)),
        PDFObjectID(21): .dictionary([
          PDFName("Type"): .name(PDFName("Filespec")),
          PDFName("F"): .string(Data("notes.txt".utf8)),
          PDFName("UF"): .string(Data("notes.txt".utf8)),
          PDFName("Desc"): .string(Data("Release notes".utf8)),
          PDFName("Subtype"): .name(PDFName("text/plain")),
          PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(20))]),
        ]),
        PDFObjectID(22): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("EmbeddedFile")),
              PDFName("Subtype"): .name(PDFName("text/plain")),
              PDFName("Filter"): .name(PDFName("FlateDecode")),
              PDFName("Params"): .dictionary([
                PDFName("Size"): .integer(Int64(compressedPayload.count))
              ]),
            ], bytes: compressed)),
        PDFObjectID(23): .dictionary([
          PDFName("Type"): .name(PDFName("Filespec")),
          PDFName("F"): .string(Data("../unsafe name.txt".utf8)),
          PDFName("UF"): .string(Data("../unsafe name.txt".utf8)),
          PDFName("Desc"): .string(Data("Unsafe name".utf8)),
          PDFName("Subtype"): .name(PDFName("text/plain")),
          PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(22))]),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFWriter.write(graph)
  }

  public static func opaqueBytes() throws -> Data {
    var graph = graph()
    graph.objects[PDFObjectID(100)] = .dictionary([
      PDFName(bytes: [0x52, 0x61, 0x77, 0xFF]): .string(Data([0x00, 0x80, 0xFF, 0x28, 0x29])),
      PDFName("Payload"): .reference(PDFObjectID(101)),
    ])
    graph.objects[PDFObjectID(101)] = .stream(
      PDFStream(
        dictionary: [PDFName("PrivateExtension"): .boolean(true)],
        bytes: Data([0x00, 0xFF]) + Data("\nendstream\nendobj\nxref\n".utf8)))
    graph.trailer[PDFName("Info")] = .reference(PDFObjectID(100))
    return try PDFWriter.write(graph)
  }

  /// P24 form fixture: two Letter pages with a merged text field, a multiline
  /// field with a default value, a checkbox, a radio group spanning both
  /// pages, a push button carrying a JavaScript action, a signature field, a
  /// read-only text field, an orphaned widget, and a checkbox missing its
  /// on-state appearance.
  public static func formPages() throws -> Data {
    var objects: [PDFObjectID: PDFValue] = [:]
    func content(_ page: Int) -> PDFStream {
      let text = "BT /F1 12 Tf 42 710 Td (sPDF Editor form fixture - page \(page)) Tj ET\n"
      let bytes = Data(text.utf8)
      return PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes)
    }
    func page(contentID: Int) -> PDFValue {
      .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(7))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(contentID)),
      ])
    }
    func formStream(_ width: Int64, _ height: Int64, content: String = "q Q\n") -> PDFValue {
      let bytes = Data(content.utf8)
      return .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Form")),
            PDFName("FormType"): .integer(1),
            PDFName("BBox"): .array([
              .integer(0), .integer(0), .integer(width), .integer(height),
            ]),
            PDFName("Length"): .integer(Int64(bytes.count)),
          ], bytes: bytes))
    }
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
      PDFName("AcroForm"): .reference(PDFObjectID(101)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(2),
      PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
    ])
    objects[PDFObjectID(3)] = page(contentID: 5)
    objects[PDFObjectID(4)] = page(contentID: 6)
    objects[PDFObjectID(5)] = .stream(content(1))
    objects[PDFObjectID(6)] = .stream(content(2))
    objects[PDFObjectID(7)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    objects[PDFObjectID(100)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    objects[PDFObjectID(101)] = .dictionary([
      PDFName("Fields"): .array([
        .reference(PDFObjectID(110)), .reference(PDFObjectID(120)),
        .reference(PDFObjectID(130)), .reference(PDFObjectID(140)),
        .reference(PDFObjectID(150)), .reference(PDFObjectID(160)),
        .reference(PDFObjectID(170)), .reference(PDFObjectID(190)),
        .reference(PDFObjectID(200)), .reference(PDFObjectID(210)),
      ]),
      PDFName("DR"): .dictionary([
        PDFName("Font"): .dictionary([PDFName("Helv"): .reference(PDFObjectID(100))])
      ]),
      PDFName("DA"): .string(Data("/Helv 12 Tf 0 g".utf8)),
    ])
    // name: merged field+widget.
    objects[PDFObjectID(110)] = .dictionary([
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("T"): .string(Data("name".utf8)),
      PDFName("V"): .string(Data()),
      PDFName("DA"): .string(Data("/Helv 12 Tf 0 g".utf8)),
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Rect"): .array([.integer(100), .integer(600), .integer(300), .integer(620)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(111))]),
    ])
    objects[PDFObjectID(111)] = formStream(200, 20)
    // notes: multiline with a kid widget, a distinct default value, and the
    // required flag (P24-012).
    objects[PDFObjectID(120)] = .dictionary([
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("T"): .string(Data("notes".utf8)),
      PDFName("Ff"): .integer(4098),
      PDFName("V"): .string(Data()),
      PDFName("DV"): .string(Data("default notes".utf8)),
      PDFName("Kids"): .array([.reference(PDFObjectID(121))]),
    ])
    objects[PDFObjectID(121)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(120)),
      PDFName("Rect"): .array([.integer(100), .integer(540), .integer(300), .integer(580)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(122))]),
      PDFName("MK"): .dictionary([
        PDFName("BG"): .array([.integer(1), .integer(1), .integer(1)]),
        PDFName("BC"): .array([.integer(0), .integer(0), .integer(0)]),
      ]),
    ])
    objects[PDFObjectID(122)] = formStream(200, 40)
    // agree: checkbox with Off/Yes appearances and an /Off default.
    objects[PDFObjectID(130)] = .dictionary([
      PDFName("FT"): .name(PDFName("Btn")),
      PDFName("T"): .string(Data("agree".utf8)),
      PDFName("V"): .name(PDFName("Off")),
      PDFName("DV"): .name(PDFName("Off")),
      PDFName("Kids"): .array([.reference(PDFObjectID(131))]),
    ])
    objects[PDFObjectID(131)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(130)),
      PDFName("Rect"): .array([.integer(100), .integer(480), .integer(120), .integer(500)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AS"): .name(PDFName("Off")),
      PDFName("AP"): .dictionary([
        PDFName("N"): .dictionary([
          PDFName("Off"): .reference(PDFObjectID(132)),
          PDFName("Yes"): .reference(PDFObjectID(133)),
        ])
      ]),
    ])
    objects[PDFObjectID(132)] = formStream(20, 20)
    objects[PDFObjectID(133)] = formStream(20, 20, content: "q 0 0 m 5 5 l 20 20 l S Q\n")
    // color: radio group with widgets on two pages.
    objects[PDFObjectID(140)] = .dictionary([
      PDFName("FT"): .name(PDFName("Btn")),
      PDFName("Ff"): .integer(32768),
      PDFName("T"): .string(Data("color".utf8)),
      PDFName("V"): .name(PDFName("Off")),
      PDFName("Kids"): .array([
        .reference(PDFObjectID(141)), .reference(PDFObjectID(142)),
      ]),
    ])
    objects[PDFObjectID(141)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(140)),
      PDFName("Rect"): .array([.integer(100), .integer(420), .integer(120), .integer(440)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AS"): .name(PDFName("Off")),
      PDFName("AP"): .dictionary([
        PDFName("N"): .dictionary([
          PDFName("Off"): .reference(PDFObjectID(143)),
          PDFName("A"): .reference(PDFObjectID(144)),
        ])
      ]),
    ])
    objects[PDFObjectID(142)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(140)),
      PDFName("Rect"): .array([.integer(200), .integer(420), .integer(220), .integer(440)]),
      PDFName("P"): .reference(PDFObjectID(4)),
      PDFName("AS"): .name(PDFName("Off")),
      PDFName("AP"): .dictionary([
        PDFName("N"): .dictionary([
          PDFName("Off"): .reference(PDFObjectID(143)),
          PDFName("B"): .reference(PDFObjectID(145)),
        ])
      ]),
    ])
    objects[PDFObjectID(143)] = formStream(20, 20)
    objects[PDFObjectID(144)] = formStream(20, 20, content: "q 0 0 20 20 re f Q\n")
    objects[PDFObjectID(145)] = formStream(20, 20, content: "q 0 0 20 20 re f Q\n")
    // submit: push button carrying a JavaScript action that must never run.
    objects[PDFObjectID(150)] = .dictionary([
      PDFName("FT"): .name(PDFName("Btn")),
      PDFName("Ff"): .integer(65536),
      PDFName("T"): .string(Data("submit".utf8)),
      PDFName("Kids"): .array([.reference(PDFObjectID(151))]),
    ])
    objects[PDFObjectID(151)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(150)),
      PDFName("Rect"): .array([.integer(100), .integer(360), .integer(180), .integer(384)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(152))]),
      PDFName("A"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert('submit')".utf8)),
      ]),
    ])
    objects[PDFObjectID(152)] = formStream(80, 24)
    // sig: signature field, reserved and never filled.
    objects[PDFObjectID(160)] = .dictionary([
      PDFName("FT"): .name(PDFName("Sig")),
      PDFName("T"): .string(Data("sig".utf8)),
      PDFName("Kids"): .array([.reference(PDFObjectID(161))]),
    ])
    objects[PDFObjectID(161)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(160)),
      PDFName("Rect"): .array([.integer(100), .integer(300), .integer(240), .integer(330)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(162))]),
    ])
    objects[PDFObjectID(162)] = formStream(140, 30)
    // locked: read-only text field with a value.
    objects[PDFObjectID(170)] = .dictionary([
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("Ff"): .integer(1),
      PDFName("T"): .string(Data("locked".utf8)),
      PDFName("V"): .string(Data("locked".utf8)),
      PDFName("Kids"): .array([.reference(PDFObjectID(171))]),
    ])
    objects[PDFObjectID(171)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(170)),
      PDFName("Rect"): .array([.integer(100), .integer(240), .integer(240), .integer(264)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(172))]),
    ])
    objects[PDFObjectID(172)] = formStream(140, 24)
    // 180: orphaned widget with no parent field.
    objects[PDFObjectID(180)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Rect"): .array([.integer(300), .integer(600), .integer(320), .integer(620)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(181))]),
    ])
    objects[PDFObjectID(181)] = formStream(20, 20)
    // extra: checkbox whose on-state appearance must be generated.
    objects[PDFObjectID(190)] = .dictionary([
      PDFName("FT"): .name(PDFName("Btn")),
      PDFName("T"): .string(Data("extra".utf8)),
      PDFName("V"): .name(PDFName("Off")),
      PDFName("Kids"): .array([.reference(PDFObjectID(191))]),
    ])
    objects[PDFObjectID(191)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(190)),
      PDFName("Rect"): .array([.integer(140), .integer(480), .integer(160), .integer(500)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AS"): .name(PDFName("Off")),
      PDFName("AP"): .dictionary([
        PDFName("N"): .dictionary([PDFName("Off"): .reference(PDFObjectID(192))])
      ]),
    ])
    objects[PDFObjectID(192)] = formStream(20, 20)
    // department: combo choice field with a default selection.
    objects[PDFObjectID(200)] = .dictionary([
      PDFName("FT"): .name(PDFName("Ch")),
      PDFName("Ff"): .integer(131072),
      PDFName("T"): .string(Data("department".utf8)),
      PDFName("V"): .string(Data("Engineering".utf8)),
      PDFName("DV"): .string(Data("Sales".utf8)),
      PDFName("Opt"): .array([
        .string(Data("Engineering".utf8)),
        .string(Data("Sales".utf8)),
        .string(Data("Support".utf8)),
      ]),
      PDFName("Kids"): .array([.reference(PDFObjectID(201))]),
    ])
    objects[PDFObjectID(201)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(200)),
      PDFName("Rect"): .array([.integer(320), .integer(600), .integer(480), .integer(620)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(202))]),
    ])
    objects[PDFObjectID(202)] = formStream(160, 20)
    // team: list choice field (single selection) with export/display pairs.
    objects[PDFObjectID(210)] = .dictionary([
      PDFName("FT"): .name(PDFName("Ch")),
      PDFName("T"): .string(Data("team".utf8)),
      PDFName("V"): .string(Data("blue".utf8)),
      PDFName("I"): .array([.integer(1)]),
      PDFName("Opt"): .array([
        .array([.string(Data("red".utf8)), .string(Data("Red Team".utf8))]),
        .array([.string(Data("blue".utf8)), .string(Data("Blue Team".utf8))]),
      ]),
      PDFName("Kids"): .array([.reference(PDFObjectID(211))]),
    ])
    objects[PDFObjectID(211)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(210)),
      PDFName("Rect"): .array([.integer(320), .integer(540), .integer(480), .integer(580)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(212))]),
    ])
    objects[PDFObjectID(212)] = formStream(160, 40)
    // Page annotations, including the orphaned widget on page 1.
    objects[PDFObjectID(3)] = {
      guard case .dictionary(var page)? = objects[PDFObjectID(3)] else { return .null }
      page[PDFName("Annots")] = .array([
        .reference(PDFObjectID(110)), .reference(PDFObjectID(121)),
        .reference(PDFObjectID(131)), .reference(PDFObjectID(141)),
        .reference(PDFObjectID(151)), .reference(PDFObjectID(161)),
        .reference(PDFObjectID(171)), .reference(PDFObjectID(180)),
        .reference(PDFObjectID(191)), .reference(PDFObjectID(201)),
        .reference(PDFObjectID(211)),
      ])
      return .dictionary(page)
    }()
    objects[PDFObjectID(4)] = {
      guard case .dictionary(var page)? = objects[PDFObjectID(4)] else { return .null }
      page[PDFName("Annots")] = .array([.reference(PDFObjectID(142))])
      return .dictionary(page)
    }()
    let graph = PDFGraph(
      objects: objects,
      trailer: [
        PDFName("Root"): .reference(PDFObjectID(1)),
        PDFName("Size"): .integer(213),
      ])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }
}
