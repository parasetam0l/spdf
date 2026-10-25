import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// FNT-01: locally licensed font files are inspected per face, embedding
/// eligibility is explicit, and a selected face is the exact program that gets
/// subset-embedded. No path may substitute another face or another collection
/// member.
@Suite("Font import eligibility")
struct FontImportEligibilityTests {
  private var fixtureProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64)
      else { throw PDFError(.malformed, "Test font program is corrupt") }
      return program
    }
  }

  private var cffProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.cffProgramBase64)
      else { throw PDFError(.malformed, "Test CFF program is corrupt") }
      return program
    }
  }

  @Test func singleFaceFileIsInspectedVerbatim() throws {
    let program = try fixtureProgram
    let faces = try FontFaceExtractor.extractFaces(from: program)
    #expect(faces.count == 1)
    let face = try #require(faces.first)
    #expect(face.faceIndex == 0)
    #expect(face.wasExtractedFromCollection == false)
    #expect(face.program == program)
    #expect(face.programDigest == FontImportDigest.sha256Hex(program))
    #expect(face.programDigest.count == 64)

    let inspections = try FontImportInspection.inspectFaces(program)
    let inspection = try #require(inspections.first)
    #expect(inspection.isEligible)
    #expect(inspection.embeddingFlags != nil)
    #expect(inspection.mappedScalarCount > 0)
    #expect(inspection.unitsPerEm == FontFixtureData.unitsPerEm)
    #expect(!inspection.isVariableFont)
    #expect(inspection.programDigest == face.programDigest)
  }

  @Test func collectionFacesAreExtractedAsStandalonePrograms() throws {
    let truetype = try fixtureProgram
    let cff = try cffProgram
    // The collection mixes a TrueType face and a CFF face so the extractor
    // cannot pass by returning the container bytes for every face.
    let collection = try makeCollection([truetype, cff])
    let faces = try FontFaceExtractor.extractFaces(from: collection)
    #expect(faces.count == 2)
    let first = try #require(faces.first)
    let second = try #require(faces.last)
    #expect(first.faceIndex == 0 && second.faceIndex == 1)
    #expect(first.wasExtractedFromCollection && second.wasExtractedFromCollection)
    #expect(first.program != collection && second.program != collection)
    // Both extracted programs are structurally valid standalone fonts.
    #expect(FontFaceExtractor.checksum32([UInt8](first.program)) == 0xB1B0_AFBA)
    #expect(FontFaceExtractor.checksum32([UInt8](second.program)) == 0xB1B0_AFBA)
    let firstInspector = try TrueTypeInspector.inspect(first.program)
    let secondInspector = try TrueTypeInspector.inspect(second.program)
    #expect(!firstInspector.isCFF)
    #expect(secondInspector.isCFF)
    #expect(first.sfntVersion == 0x0001_0000)
    #expect(second.sfntVersion == 0x4F54_544F)

    let inspections = try FontImportInspection.inspectFaces(collection)
    #expect(inspections.count == 2)
    #expect(inspections[0].isEligible)
    #expect(inspections[1].eligibility == .refused(.cffOutlines))
    #expect(inspections[0].programDigest != inspections[1].programDigest)
  }

  @Test func cffFaceIsRefusedForSubsetEmbedding() throws {
    let inspections = try FontImportInspection.inspectFaces(try cffProgram)
    let inspection = try #require(inspections.first)
    #expect(!inspection.isEligible)
    #expect(inspection.eligibility == .refused(.cffOutlines))
    #expect(inspection.eligibility.label.localizedCaseInsensitiveContains("CFF"))
  }

  @Test func restrictedEmbeddingRightsAreRefused() throws {
    let restricted = try patched(fixtureProgram, table: "OS/2", relativeOffset: 8, bytes: [0x00, 0x02])
    #expect(try TrueTypeInspector.inspect(restricted).embeddingFlags == 0x0002)
    let inspections = try FontImportInspection.inspectFaces(restricted)
    let inspection = try #require(inspections.first)
    #expect(!inspection.isEligible)
    #expect(inspection.eligibility == .refused(.restrictedEmbedding))
    #expect(inspection.eligibility.label.localizedCaseInsensitiveContains("embedding rights"))
  }

  @Test func faceWithoutUsableUnicodeMapIsRefused() throws {
    // cmap: version (2 bytes) then numTables (2 bytes). Declaring no subtables
    // leaves the face readable but with no Unicode coverage.
    let empty = try patched(fixtureProgram, table: "cmap", relativeOffset: 2, bytes: [0x00, 0x00])
    let inspections = try FontImportInspection.inspectFaces(empty)
    let inspection = try #require(inspections.first)
    #expect(!inspection.isEligible)
    #expect(inspection.eligibility == .refused(.missingUnicodeMap))
    #expect(inspection.mappedScalarCount == 0)
  }

  @Test func brokenOrForeignFilesAreRefusedExplicitly() throws {
    #expect(throws: FontImportError.self) {
      _ = try FontFaceExtractor.extractFaces(from: Data([0, 1, 2, 3]))
    }
    #expect(throws: FontImportError.self) {
      _ = try FontFaceExtractor.extractFaces(from: Data(repeating: 0x42, count: 64))
    }
    let truncated = Data(try fixtureProgram.prefix(300))
    #expect(throws: FontImportError.self) {
      _ = try FontFaceExtractor.extractFaces(from: truncated)
    }
    #expect(throws: FontImportError.self) {
      _ = try FontFaceExtractor.extractFaces(
        from: try fixtureProgram, limits: .init(maxFileBytes: 1_000))
    }
    // A collection whose face directory points outside the file is refused.
    let valid = try makeCollection([try fixtureProgram])
    var corrupted = [UInt8](valid)
    let faceOffset = 12
    corrupted[faceOffset] = 0x7F
    corrupted[faceOffset + 1] = 0xFF
    corrupted[faceOffset + 2] = 0xFF
    corrupted[faceOffset + 3] = 0xFF
    #expect(throws: FontImportError.self) {
      _ = try FontFaceExtractor.extractFaces(from: Data(corrupted))
    }
  }

  @Test func subsetEmbeddingUsesOnlyTheChosenFace() throws {
    let full = try fixtureProgram
    let tiny = try TrueTypeSubsetter.subset(program: full, unicodes: [0x41])
    let inspections = try FontImportInspection.inspectFaces(tiny)
    #expect(inspections.first?.isEligible == true)
    let custom = CustomTextFont(
      program: tiny, familyName: "TinyFace", faceName: "TinyFace · Regular",
      identifier: "tiny-face")
    // The subset does not contain B. The writer must refuse rather than
    // silently substituting the full program or a system font.
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 300, lineSpacing: 20)
    func command(_ text: String) -> AddPageTextLinesCommand {
      AddPageTextLinesCommand(
        pageID: pageID,
        lines: [
          .init(
            text: text, x: 48, baseline: 700,
            segments: [.init(text: text, x: 48,
              format: PageTextFormat(size: 16, customFont: custom))])
        ], box: box)
    }
    #expect(throws: PDFError.self) { try command("AB").validate(in: parsed.graph) }
    let graph = try PDFEditingEngine.commit(PDFTransaction([command("A")]), to: parsed.graph)
    let bytes = try PDFWriter.write(graph)
    let reopened = try PDFParser.parse(bytes)
    let content = try PageContent.load(pageID: reopened.pageIDs[0], in: reopened.graph)
    let layout = try PageTextLayout.build(in: content, graph: reopened.graph)
    #expect(layout.lines.count == 1)
    #expect(layout.text(in: layout.lines[0]) == "A")
    // The embedded program is the tiny face's subset: it covers A and not B.
    let embedded = try embeddedFontPrograms(in: reopened.graph)
    #expect(!embedded.isEmpty)
    for program in embedded {
      let inspector = try TrueTypeInspector.inspect(program)
      #expect(inspector.unicodeToGlyph[0x41] != nil)
      #expect(inspector.unicodeToGlyph[0x42] == nil)
      #expect(inspector.glyphCount < 12)
    }
    #expect(reopened.graph.objects.values.contains { value in
      guard case .dictionary(let dictionary) = value,
        case .name(let base)? = dictionary[PDFName("BaseFont")]
      else { return false }
      return String(decoding: base.bytes, as: UTF8.self).contains("TinyFace")
    })
  }

  @Test func collectionFaceSelectionEmbedsTheSelectedMember() throws {
    let full = try fixtureProgram
    let tiny = try TrueTypeSubsetter.subset(program: full, unicodes: [0x41])
    let collection = try makeCollection([full, tiny])
    let faces = try FontFaceExtractor.extractFaces(from: collection)
    #expect(faces.count == 2)
    // Select face 1 explicitly; its program must be the tiny member, not the
    // collection's first face.
    let selected = try #require(faces.dropFirst().first)
    let inspection = FontImportInspection.inspectFace(
      program: selected.program, faceIndex: selected.faceIndex,
      sfntVersion: selected.sfntVersion,
      wasExtractedFromCollection: selected.wasExtractedFromCollection)
    #expect(inspection.isEligible)
    let inspector = try TrueTypeInspector.inspect(selected.program)
    #expect(inspector.unicodeToGlyph[0x41] != nil)
    #expect(inspector.unicodeToGlyph[0x42] == nil)
    let custom = CustomTextFont(
      program: selected.program, familyName: "SelectedFace", identifier: "selected-face")
    let parsed = try PDFParser.parse(BlankPDF.data())
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 300, lineSpacing: 20)
    func command(_ text: String) -> AddPageTextLinesCommand {
      AddPageTextLinesCommand(
        pageID: parsed.pageIDs[0],
        lines: [
          .init(
            text: text, x: 48, baseline: 700,
            segments: [.init(text: text, x: 48,
              format: PageTextFormat(size: 16, customFont: custom))])
        ], box: box)
    }
    // Face 0 covers B; face 1 does not. A successful "B" save would prove the
    // wrong member was embedded.
    #expect(throws: PDFError.self) { try command("B").validate(in: parsed.graph) }
    let graph = try PDFEditingEngine.commit(PDFTransaction([command("A")]), to: parsed.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(graph))
    let content = try PageContent.load(pageID: reopened.pageIDs[0], in: reopened.graph)
    let layout = try PageTextLayout.build(in: content, graph: reopened.graph)
    #expect(layout.text(in: layout.lines[0]) == "A")
  }

  @Test func damagedSubsetterInputIsRefusedAsSubsettingFailure() throws {
    // A loca entry that points past the glyf table is structurally readable by
    // the inspector but cannot be subset, so eligibility must refuse instead
    // of promising a writable face.
    let program = try fixtureProgram
    let inspector = try TrueTypeInspector.inspect(program)
    let loca = try #require(inspector.tables["loca"])
    var bytes = [UInt8](program)
    // The last loca entry is the end offset of the final glyph. Point it far
    // past the glyf table but still inside the file.
    let entrySize = inspector.locaIsLong ? 4 : 2
    let last = loca.offset + inspector.glyphCount * entrySize
    if inspector.locaIsLong {
      bytes[last] = 0x00
      bytes[last + 1] = 0x0F
      bytes[last + 2] = 0xFF
      bytes[last + 3] = 0xFF
    } else {
      bytes[last] = 0xFF
      bytes[last + 1] = 0xFF
    }
    let broken = Data(bytes)
    // The inspector may or may not disagree; when it accepts the program the
    // eligibility check must still prove subsetting.
    let face = FontImportInspection.inspectFace(program: broken)
    #expect(!face.isEligible)
  }

  // MARK: - Helpers

  private func patched(
    _ program: Data, table tag: String, relativeOffset: Int, bytes: [UInt8]
  ) throws -> Data {
    let inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    guard let table = inspector.tables[tag] else {
      throw PDFError(.malformed, "Fixture is missing the \(tag) table")
    }
    var data = [UInt8](program)
    let start = table.offset + relativeOffset
    guard start >= 0, start + bytes.count <= data.count else {
      throw PDFError(.malformed, "Patch is outside the font program")
    }
    data.replaceSubrange(start..<(start + bytes.count), with: bytes)
    return Data(data)
  }

  private func embeddedFontPrograms(in graph: PDFGraph) throws -> [Data] {
    var programs: [Data] = []
    for value in graph.objects.values {
      guard case .dictionary(let dictionary) = value,
        case .reference(let fileID)? = dictionary[PDFName("FontFile2")],
        case .stream(let stream)? = graph.objects[fileID]
      else { continue }
      programs.append(stream.bytes)
    }
    return programs
  }

  /// Build a minimal valid TrueType collection from standalone sfnt programs.
  /// Each face keeps its own table directory and table bytes; table offsets and
  /// the collection face offsets are rewritten to absolute file offsets.
  private func makeCollection(_ programs: [Data]) throws -> Data {
    func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
      Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
    }
    func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
      var value = 0
      for index in 0..<4 { value = value * 256 + Int(bytes[offset + index]) }
      return value
    }
    func writeU16(_ value: Int, _ out: inout [UInt8], _ offset: Int) {
      out[offset] = UInt8((value >> 8) & 0xFF)
      out[offset + 1] = UInt8(value & 0xFF)
    }
    func writeU32(_ value: Int, _ out: inout [UInt8], _ offset: Int) {
      out[offset] = UInt8((value >> 24) & 0xFF)
      out[offset + 1] = UInt8((value >> 16) & 0xFF)
      out[offset + 2] = UInt8((value >> 8) & 0xFF)
      out[offset + 3] = UInt8(value & 0xFF)
    }
    func appendU16(_ value: Int, _ out: inout [UInt8]) {
      out += [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    func appendU32(_ value: Int, _ out: inout [UInt8]) {
      out += [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
      ]
    }

    var out: [UInt8] = Array("ttcf".utf8)
    appendU32(0x0001_0000, &out)
    appendU32(programs.count, &out)
    let offsetsStart = out.count
    out += [UInt8](repeating: 0, count: programs.count * 4)
    var faceOffsets: [Int] = []
    for program in programs {
      let bytes = [UInt8](program)
      let sfnt = u32(bytes, 0)
      let tableCount = u16(bytes, 4)
      while out.count % 4 != 0 { out.append(0) }
      let faceStart = out.count
      faceOffsets.append(faceStart)
      let headerSize = 12 + tableCount * 16
      out += [UInt8](repeating: 0, count: headerSize)
      for index in 0..<tableCount {
        let base = 12 + index * 16
        let tag = Array(bytes[base..<(base + 4)])
        let checksum = u32(bytes, base + 4)
        let sourceOffset = u32(bytes, base + 8)
        let length = u32(bytes, base + 12)
        while out.count % 4 != 0 { out.append(0) }
        let absolute = out.count
        out += bytes[sourceOffset..<(sourceOffset + length)]
        let record = faceStart + 12 + index * 16
        out.replaceSubrange(record..<(record + 4), with: tag)
        writeU32(checksum, &out, record + 4)
        writeU32(absolute, &out, record + 8)
        writeU32(length, &out, record + 12)
      }
      writeU32(sfnt, &out, faceStart)
      writeU16(tableCount, &out, faceStart + 4)
    }
    for (index, offset) in faceOffsets.enumerated() {
      writeU32(offset, &out, offsetsStart + index * 4)
    }
    return Data(out)
  }
}
