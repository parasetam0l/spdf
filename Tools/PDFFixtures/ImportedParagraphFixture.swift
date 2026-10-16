import Foundation
import PDFCore

extension PDFFixtures {
  /// Independently assembled Identity-H subset, with explicit glyph IDs,
  /// mixed colors, adjusted TJ spacing and an unrelated following label.
  public static func importedParagraphPages() throws -> Data {
    guard let program = Data(base64Encoded: ParagraphFontFixture.programBase64) else {
      throw PDFError(.malformed, "Corrupt paragraph fixture program")
    }
    let glyphs = ParagraphFontFixture.glyphs
    func operand(_ text: String) throws -> String {
      var value = "<"
      for scalar in text.unicodeScalars {
        guard let glyph = glyphs[Int(scalar.value)] else { throw PDFError(.malformed, "Fixture coverage") }
        value += String(format: "%04X", glyph.id)
      }
      return value + ">"
    }
    func width(_ text: String) -> Double {
      text.unicodeScalars.reduce(0) { $0 + Double(glyphs[Int($1.value)]!.width) * 16 / 1000 }
    }
    let text = "This imported paragraph keeps its original embedded font while you edit on the page. Select a few words, change their color, then make the paragraph longer. The saved PDF should keep the same wrapping and leave the heading and neighboring text in place."
    var lines: [String] = []
    for word in text.split(separator: " ").map(String.init) {
      if let last = lines.last, width(last + " " + word) <= 340 { lines[lines.count - 1] += " " + word }
      else { lines.append(word) }
    }
    var content = "BT /Heading 24 Tf 1 0 0 1 42 740 Tm (Editing imported documents) Tj ET\n"
    for (index, line) in lines.enumerated() {
      let halves = line.components(separatedBy: "saved")
      content += "BT /Body 16 Tf 1 0 0 1 42 \(700 - index * 22) Tm 0.1 0.1 0.1 rg "
      if halves.count == 2 {
        content += "\(try operand(halves[0])) Tj 0.1 0.3 0.7 rg \(try operand("saved")) Tj 0.1 0.1 0.1 rg \(try operand(halves[1])) Tj ET\n"
      } else { content += "\(try operand(line)) Tj ET\n" }
    }
    content += "BT /Body 16 Tf 1 0 0 1 42 450 Tm [\(try operand("Adjusted ")) -12 \(try operand("spacing"))] TJ \(try operand(" / unchanged neighbor")) Tj ET\n"
    let entries = glyphs.sorted(by: { $0.key < $1.key }).map {
      String(format: "<%04X> <%04X>", $0.value.id, $0.key)
    }.joined(separator: "\n")
    let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def /CMapName /Adobe-Identity-UCS def /CMapType 2 def\n1 begincodespacerange <0000> <FFFF> endcodespacerange\n\(glyphs.count) beginbfchar\n\(entries)\nendbfchar\nendcmap CMapName currentdict /CMap defineresource pop end end"
    let widths = glyphs.sorted(by: { $0.value.id < $1.value.id }).flatMap {
      [PDFValue.integer(Int64($0.value.id)), .array([.integer(Int64($0.value.width))])]
    }
    let graph = PDFGraph(objects: [
      PDFObjectID(1): .dictionary([PDFName("Type"): .name(PDFName("Catalog")), PDFName("Pages"): .reference(PDFObjectID(2))]),
      PDFObjectID(2): .dictionary([PDFName("Type"): .name(PDFName("Pages")), PDFName("Count"): .integer(1), PDFName("Kids"): .array([.reference(PDFObjectID(3))])]),
      PDFObjectID(3): .dictionary([PDFName("Type"): .name(PDFName("Page")), PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        PDFName("Resources"): .dictionary([PDFName("Font"): .dictionary([PDFName("Body"): .reference(PDFObjectID(4)), PDFName("Heading"): .reference(PDFObjectID(10))])]),
        PDFName("Contents"): .reference(PDFObjectID(5))]),
      PDFObjectID(4): .dictionary([PDFName("Type"): .name(PDFName("Font")), PDFName("Subtype"): .name(PDFName("Type0")),
        PDFName("BaseFont"): .name(PDFName("ABCDEF+DejaVuSans")), PDFName("Encoding"): .name(PDFName("Identity-H")),
        PDFName("DescendantFonts"): .array([.reference(PDFObjectID(9))]), PDFName("ToUnicode"): .reference(PDFObjectID(8))]),
      PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      PDFObjectID(6): .dictionary([PDFName("Type"): .name(PDFName("FontDescriptor")), PDFName("FontName"): .name(PDFName("ABCDEF+DejaVuSans")),
        PDFName("FontFile2"): .reference(PDFObjectID(7)), PDFName("Flags"): .integer(32),
        PDFName("FontBBox"): .array([.integer(-2090), .integer(-948), .integer(3673), .integer(2524)]),
        PDFName("Ascent"): .integer(928), PDFName("Descent"): .integer(-236), PDFName("CapHeight"): .integer(729), PDFName("ItalicAngle"): .integer(0), PDFName("StemV"): .integer(80)]),
      PDFObjectID(7): .stream(PDFStream(dictionary: [PDFName("Length1"): .integer(Int64(program.count))], bytes: program)),
      PDFObjectID(8): .stream(PDFStream(bytes: Data(cmap.utf8))),
      PDFObjectID(9): .dictionary([PDFName("Type"): .name(PDFName("Font")), PDFName("Subtype"): .name(PDFName("CIDFontType2")),
        PDFName("BaseFont"): .name(PDFName("ABCDEF+DejaVuSans")), PDFName("FontDescriptor"): .reference(PDFObjectID(6)),
        PDFName("CIDSystemInfo"): .dictionary([PDFName("Registry"): .string(Data("Adobe".utf8)), PDFName("Ordering"): .string(Data("Identity".utf8)), PDFName("Supplement"): .integer(0)]),
        PDFName("CIDToGIDMap"): .name(PDFName("Identity")), PDFName("DW"): .integer(1000), PDFName("W"): .array(widths)]),
      PDFObjectID(10): .dictionary([PDFName("Type"): .name(PDFName("Font")), PDFName("Subtype"): .name(PDFName("Type1")), PDFName("BaseFont"): .name(PDFName("Helvetica-Bold")), PDFName("Encoding"): .name(PDFName("WinAnsiEncoding"))]),
    ], trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFWriter.write(graph)
  }
}
