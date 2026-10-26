import Foundation
import PDFCore

/// RED-06 harness fixture: one page whose protected seeds sit in every retained
/// representation RED-05/RED-06 review (visible text, info/XMP/page metadata,
/// comment, attachment, action, optional-content layer, structure alt text, XFA,
/// form value, thumbnail, private application data, /ID, an orphan stream and an
/// earlier revision present only in the file bytes).
public struct RedactionAdversarialFixture: Sendable {
  public let data: Data
  public let seeds: [String]
  public let revisionOnlySeeds: [String]

  public init(data: Data, seeds: [String], revisionOnlySeeds: [String]) {
    self.data = data
    self.seeds = seeds
    self.revisionOnlySeeds = revisionOnlySeeds
  }

  public static func make() throws -> RedactionAdversarialFixture {
    func name(_ value: String) -> PDFValue { .name(PDFName(value)) }
    func text(_ value: String) -> PDFValue { .string(Data(value.utf8)) }
    func integer(_ value: Int64) -> PDFValue { .integer(value) }
    func ref(_ number: Int) -> PDFValue { .reference(PDFObjectID(number)) }
    let objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): name("Catalog"),
        PDFName("Pages"): ref(2),
        PDFName("Metadata"): ref(7),
        PDFName("OCProperties"): .dictionary([
          PDFName("OCGs"): .array([ref(11)]),
          PDFName("D"): .dictionary([PDFName("OFF"): .array([ref(11)])]),
        ]),
        PDFName("AcroForm"): .dictionary([
          PDFName("Fields"): .array([ref(14)]),
          PDFName("XFA"): text("<xfa>XFA-SEED-xml</xfa>"),
        ]),
        PDFName("StructTreeRoot"): ref(12),
        PDFName("OpenAction"): ref(10),
        PDFName("Names"): .dictionary([
          PDFName("EmbeddedFiles"): .dictionary([
            PDFName("Names"): .array([text("secret.txt"), ref(17)])
          ])
        ]),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): name("Pages"), PDFName("Count"): integer(1),
        PDFName("Kids"): .array([ref(3)]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): name("Page"), PDFName("Parent"): ref(2),
        PDFName("MediaBox"): .array([integer(0), integer(0), integer(612), integer(792)]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): ref(4)]),
          PDFName("Properties"): .dictionary([PDFName("Hidden"): ref(21)]),
        ]),
        PDFName("Contents"): ref(5),
        PDFName("Annots"): .array([ref(8), ref(15)]),
        PDFName("Thumb"): ref(16),
        PDFName("Metadata"): ref(18),
        PDFName("PieceInfo"): .dictionary([
          PDFName("SPDF"): .dictionary([
            PDFName("LastModified"): text("D:20260101000000Z"),
            PDFName("Private"): text("PRIVATE-SEED"),
          ])
        ]),
      ]),
      PDFObjectID(4): .dictionary([
        PDFName("Type"): name("Font"), PDFName("Subtype"): name("Type1"),
        PDFName("BaseFont"): name("Helvetica"),
      ]),
      PDFObjectID(5): .stream(
        PDFStream(
          bytes: Data(
            ("""
            BT /F1 18 Tf 40 740 Td (VISIBLE-SEED) Tj ET
            q /OC /Hidden BDC BT /F1 12 Tf 40 700 Td (OC-SEED) Tj ET EMC Q

            """).utf8))),
      PDFObjectID(6): .dictionary([
        PDFName("Title"): text("INFO-SEED document title"),
        PDFName("Author"): text("INFO-SEED author"),
      ]),
      PDFObjectID(7): .stream(
        PDFStream(
          dictionary: [PDFName("Type"): name("Metadata")],
          bytes: Data("<x:xmpmeta>XMP-SEED</x:xmpmeta>".utf8))),
      PDFObjectID(8): .dictionary([
        PDFName("Type"): name("Annot"), PDFName("Subtype"): name("Text"),
        PDFName("Rect"): .array([integer(10), integer(10), integer(30), integer(30)]),
        PDFName("Contents"): text("COMMENT-SEED note"),
      ]),
      PDFObjectID(9): .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): name("EmbeddedFile"), PDFName("F"): text("secret.txt"),
          ], bytes: Data("ATTACH-SEED payload".utf8))),
      PDFObjectID(10): .dictionary([
        PDFName("S"): name("JavaScript"),
        PDFName("JS"): text("ACTION-SEED app.alert(1)"),
      ]),
      PDFObjectID(11): .dictionary([
        PDFName("Type"): name("OCG"), PDFName("Name"): text("OC-SEED hidden layer"),
      ]),
      PDFObjectID(12): .dictionary([
        PDFName("Type"): name("StructTreeRoot"), PDFName("K"): .array([ref(13)]),
      ]),
      PDFObjectID(13): .dictionary([
        PDFName("Type"): name("StructElem"), PDFName("S"): name("Figure"),
        PDFName("Alt"): text("ALT-SEED figure text"),
        PDFName("ActualText"): text("ALT-SEED actual"),
      ]),
      PDFObjectID(14): .dictionary([
        PDFName("Type"): name("Annot"), PDFName("Subtype"): name("Widget"),
        PDFName("FT"): name("Tx"), PDFName("T"): text("secretField"),
        PDFName("V"): text("FORM-SEED"),
        PDFName("Rect"): .array([integer(40), integer(40), integer(200), integer(60)]),
        PDFName("Kids"): .array([ref(15)]),
      ]),
      PDFObjectID(15): .dictionary([
        PDFName("Type"): name("Annot"), PDFName("Subtype"): name("Widget"),
        PDFName("FT"): name("Tx"), PDFName("T"): text("secretField"),
        PDFName("V"): text("FORM-SEED"),
        PDFName("Rect"): .array([integer(40), integer(40), integer(200), integer(60)]),
        PDFName("P"): ref(3),
      ]),
      PDFObjectID(16): .stream(
        PDFStream(
          dictionary: [PDFName("Subtype"): name("Image")],
          bytes: Data("THUMB-SEED".utf8))),
      PDFObjectID(17): .dictionary([
        PDFName("Type"): name("Filespec"), PDFName("F"): text("secret.txt"),
        PDFName("EF"): .dictionary([PDFName("F"): ref(9)]),
      ]),
      PDFObjectID(18): .stream(
        PDFStream(
          dictionary: [PDFName("Type"): name("Metadata")],
          bytes: Data("PAGEMETA-SEED".utf8))),
      PDFObjectID(19): .stream(PDFStream(bytes: Data("ORPHAN-SEED unused object".utf8))),
      PDFObjectID(20): .stream(
        PDFStream(bytes: Data("REVISION-ONLY-SEED first revision".utf8))),
      // Optional-content property list (not the OCG definition itself).
      PDFObjectID(21): .dictionary([
        PDFName("OCGs"): .array([ref(11)])
      ]),
    ]
    let graph = PDFGraph(
      objects: objects,
      trailer: [
        PDFName("Root"): ref(1),
        PDFName("Info"): ref(6),
        PDFName("ID"): .array([text("ID-SEED-a"), text("ID-SEED-b")]),
      ])
    var data = try PDFWriter.write(graph)
    data = try appendRevision(freeing: 20, to: data, size: 22)
    return RedactionAdversarialFixture(
      data: data,
      seeds: [
        "INFO-SEED", "XMP-SEED", "PAGEMETA-SEED", "COMMENT-SEED", "ATTACH-SEED",
        "ACTION-SEED", "OC-SEED", "ALT-SEED", "FORM-SEED", "XFA-SEED",
        "ORPHAN-SEED", "THUMB-SEED", "PRIVATE-SEED", "ID-SEED", "VISIBLE-SEED",
        "REVISION-ONLY-SEED",
      ],
      revisionOnlySeeds: ["REVISION-ONLY-SEED"])
  }

  static func appendRevision(freeing objectNumber: Int, to data: Data, size: Int) throws -> Data {
    guard let marker = data.range(of: Data("startxref".utf8), options: .backwards)
    else { throw PDFError(.malformed, "fixture has no startxref") }
    let tail = String(decoding: data[marker.upperBound...], as: UTF8.self)
    let digits = tail.drop { !$0.isNumber }.prefix { $0.isNumber }
    guard let previous = Int(digits) else {
      throw PDFError(.malformed, "fixture startxref is not numeric")
    }
    var file = data
    let update = file.count
    file.append(Data("xref\n\(objectNumber) 1\n".utf8))
    file.append(Data((String(repeating: "0", count: 10) + " 00001 f \n").utf8))
    file.append(
      Data(
        ("trailer\n<< /Size \(size) /Root 1 0 R /Info 6 0 R /ID [(ID-SEED-a) (ID-SEED-b)] /Prev \(previous) >>\n"
          + "startxref\n\(update)\n%%EOF\n").utf8))
    return file
  }
}

