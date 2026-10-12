import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P15-016–P15-019: TrueType subsetting — glyph closure with composite
/// dependencies, rebuilt tables/offsets/checksums, and preserved
/// hinting/metrics.
@Suite("Font subsetting")
struct FontSubsetTests {
  private var fontProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
        throw PDFError(.malformed, "Test font program is corrupt")
      }
      return program
    }
  }

  @Test func subsetKeepsRequestedGlyphsAndDependencies() throws {
    // â is composite (a + circumflex): all three must survive.
    let subset = try TrueTypeSubsetter.subset(
      program: fontProgram, unicodes: [0x41, 0xE2])
    let inspector = try TrueTypeInspector.inspect(subset)
    #expect(inspector.glyphCount == 5)
    // Every composite component targets a kept glyph (no dangling IDs).
    let bytes = [UInt8](subset)
    guard let glyf = inspector.tables["glyf"] else {
      Issue.record("subset lacks glyf")
      return
    }
    for glyph in 0..<inspector.glyphCount {
      let start = inspector.glyphOffsets[glyph]
      let end = inspector.glyphOffsets[glyph + 1]
      guard end > start else { continue }
      let base = glyf.offset + start
      let contours = Int(Int16(bitPattern: UInt16(bytes[base]) * 256 + UInt16(bytes[base + 1])))
      guard contours == -1 else { continue }
      var cursor = base + 10
      while true {
        let flags = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
        let component = Int(bytes[cursor + 2]) * 256 + Int(bytes[cursor + 3])
        #expect(component < inspector.glyphCount)
        cursor += 4 + ((flags & 1) != 0 ? 4 : 2)
        if (flags & 0x08) != 0 { cursor += 2 }
        else if (flags & 0x40) != 0 { cursor += 4 }
        else if (flags & 0x80) != 0 { cursor += 8 }
        if (flags & 0x20) == 0 { break }
      }
    }
    #expect(inspector.unicodeToGlyph[0x41] != nil)
    #expect(inspector.unicodeToGlyph[0xE2] != nil)
    #expect(inspector.unicodeToGlyph[0x42] == nil)
    // Advances survive per glyph.
    let full = try TrueTypeInspector.inspect(fontProgram)
    for scalar in [0x41, 0xE2] {
      let old = full.unicodeToGlyph[scalar]!
      let new = inspector.unicodeToGlyph[scalar]!
      #expect(inspector.advances[new] == full.advances[old])
    }
  }

  @Test func subsetChecksumAndStructureVerify() throws {
    let subset = try TrueTypeSubsetter.subset(
      program: fontProgram, unicodes: [0x41, 0x42, 0x43])
    let bytes = [UInt8](subset)
    // Whole-file checksum matches the TrueType constant.
    var sum = 0
    var index = 0
    while index < bytes.count {
      var word = 0
      for slot in 0..<4 {
        word = word * 256 + (index + slot < bytes.count ? Int(bytes[index + slot]) : 0)
      }
      sum = (sum + word) & 0xFFFF_FFFF
      index += 4
    }
    #expect(sum == 0xB1B0AFBA)
    // loca/glyf agree: every glyph slice lands inside the table.
    let inspector = try TrueTypeInspector.inspect(subset)
    guard let glyf = inspector.tables["glyf"] else {
      Issue.record("subset lacks glyf")
      return
    }
    for glyph in 0..<inspector.glyphCount {
      let start = inspector.glyphOffsets[glyph]
      let end = inspector.glyphOffsets[glyph + 1]
      #expect(start <= end)
      #expect(glyf.offset + end <= bytes.count)
    }
    // Units, ascent, and outline bounds carry over.
    let full = try TrueTypeInspector.inspect(fontProgram)
    #expect(inspector.unitsPerEm == full.unitsPerEm)
    #expect(inspector.ascent == full.ascent)
    #expect(inspector.fontBBox == full.fontBBox)
  }

  @Test func subsetAvailabilitySplitsCoveredFromMissing() throws {
    // P14-021: the committed subset covers Latin, â, and the fi ligature;
    // Cyrillic and CJK are missing. Malformed programs throw instead of
    // reporting empty availability.
    let availability = try TrueTypeSubsetter.availability(
      program: fontProgram, unicodes: [0x41, 0xE2, 0xFB01, 0x20, 0x41F, 0x4E2D])
    #expect(availability.covered == [0x41, 0xE2, 0xFB01, 0x20])
    #expect(availability.missing == [0x41F, 0x4E2D])
    let empty = try TrueTypeSubsetter.availability(program: fontProgram, unicodes: [])
    #expect(empty.covered.isEmpty && empty.missing.isEmpty)
    guard let cff = Data(base64Encoded: FontFixtureData.cffProgramBase64) else {
      Issue.record("test CFF program is corrupt")
      return
    }
    let cffAvailability = try TrueTypeSubsetter.availability(
      program: cff, unicodes: [0x41, 0x41F])
    #expect(cffAvailability.covered == [0x41])
    #expect(cffAvailability.missing == [0x41F])
    #expect(throws: PDFError.self) {
      try TrueTypeSubsetter.availability(program: Data([0, 1, 2, 3]), unicodes: [0x41])
    }
  }

  @Test func subsetRefusesMissingGlyphs() throws {
    #expect(throws: PDFError.self) {
      try TrueTypeSubsetter.subset(program: fontProgram, unicodes: [0x44])
    }
    do {
      _ = try TrueTypeSubsetter.subset(program: fontProgram, unicodes: [0x44])
      Issue.record("expected a refusal")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func subsetEmbedsAndExtracts() throws {
    let subset = try TrueTypeSubsetter.subset(
      program: fontProgram, unicodes: [0x41, 0xE2])
    let written = try FontWriter.writeTrueType(
      program: subset, baseName: "SPDFTS+DejaVuSans", covering: "Aâ")
    guard let bytes = written.encode("Aâ") else {
      Issue.record("encoding failed")
      return
    }
    #expect(bytes.count == 2)
    var content = Data("BT /F1 24 Tf 42 700 Td (".utf8)
    content.append(contentsOf: bytes)
    content.append(Data(") Tj ET\n".utf8))
    var font = try dictionary(written.fontDictionary)
    font[PDFName("FontDescriptor")] = .reference(PDFObjectID(6))
    font[PDFName("ToUnicode")] = .reference(PDFObjectID(8))
    var descriptor = try dictionary(written.descriptor)
    descriptor[PDFName("FontFile2")] = .reference(PDFObjectID(7))
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
        PDFObjectID(4): .dictionary(font),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
        PDFObjectID(6): .dictionary(descriptor),
        PDFObjectID(7): .stream(written.fontFile),
        PDFObjectID(8): .stream(written.toUnicode),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    let parsed = try PDFParser.parse(data)
    let pageContent = try PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph)
    let layout = try PageTextLayout.build(in: pageContent, graph: parsed.graph)
    #expect(layout.text(in: layout.lines[0]) == "Aâ")
  }

  private func dictionary(_ value: PDFValue) throws -> [PDFName: PDFValue] {
    guard case .dictionary(let dictionary) = value else {
      throw PDFError(.malformed, "Expected a dictionary value")
    }
    return dictionary
  }

}
