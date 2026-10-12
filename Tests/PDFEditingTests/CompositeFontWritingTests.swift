import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P15-012/P15-014/P15-020: composite font writing — CIDFontType2 for
/// TrueType, CIDFontType0 for CFF, identity CID mapping, W widths, and
/// ToUnicode, with explicit CFF subsetting refusal.
@Suite("Composite font writing")
struct CompositeFontWritingTests {
  private var cffProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.cffProgramBase64) else {
        throw PDFError(.malformed, "Test CFF program is corrupt")
      }
      return program
    }
  }

  private var ttProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
        throw PDFError(.malformed, "Test font program is corrupt")
      }
      return program
    }
  }

  private func packagedComposite(
    _ written: WrittenCompositeFont, fileID: PDFObjectID, text: Data
  ) throws -> Data {
    let fontID = PDFObjectID(4)
    let descriptorID = PDFObjectID(6)
    let programID = PDFObjectID(7)
    let cmapID = PDFObjectID(8)
    let descendantID = PDFObjectID(9)
    guard case .dictionary(let descendant) = written.descendant,
      case .dictionary(let descriptor) = written.descriptor
    else {
      throw PDFError(.malformed, "Composite structures malformed")
    }
    var descriptorWithFile = descriptor
    // The file stream carries FontFile2 (TrueType) or FontFile3 (CFF).
    let fileKey = PDFName(
      written.fontFile.dictionary[PDFName("Subtype")] == nil ? "FontFile2" : "FontFile3")
    descriptorWithFile[fileKey] = .reference(programID)
    var descendantWithRefs = descendant
    descendantWithRefs[PDFName("FontDescriptor")] = .reference(descriptorID)
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
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        fontID: written.type0Dictionary(
          descendant: descendantID, toUnicode: cmapID, baseName: written.baseName),
        PDFObjectID(5): .stream(PDFStream(bytes: text)),
        descriptorID: .dictionary(descriptorWithFile),
        programID: .stream(written.fontFile),
        cmapID: .stream(written.toUnicode),
        descendantID: .dictionary(descendantWithRefs),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  @Test func inspectorDetectsCFFPrograms() throws {
    let inspector = try TrueTypeInspector.inspect(cffProgram)
    #expect(inspector.isCFF)
    #expect(inspector.unitsPerEm == 2048)
    #expect(inspector.glyphCount == 9)
    #expect(inspector.unicodeToGlyph[0x41] != nil)
    #expect(inspector.glyphOffsets.isEmpty)
    let tt = try TrueTypeInspector.inspect(ttProgram)
    #expect(!tt.isCFF)
    #expect(!tt.glyphOffsets.isEmpty)
  }

  @Test func subsetterRefusesCFFExplicitly() throws {
    do {
      _ = try TrueTypeSubsetter.subset(program: cffProgram, unicodes: [0x41])
      Issue.record("expected a refusal")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("CFF"))
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func compositeTrueTypeCoversText() throws {
    let written = try CompositeFontWriter.write(
      program: ttProgram, baseName: "DejaVuSans", covering: "ABCâ")
    #expect(written.baseName.hasSuffix("+DejaVuSans"))
    let tag = written.baseName.prefix(while: { $0 != "+" })
    #expect(tag.count == 6 && tag.allSatisfy(\.isUppercase))
    #expect(written.encoding == [0x41: 0, 0x42: 1, 0x43: 2, 0xE2: 3])
    #expect(written.widths[0] == 684)
    #expect(written.encode("AB") == [0, 0, 0, 1])
    #expect(written.encode("é") == nil)
    guard case .dictionary(let descendant) = written.descendant else {
      Issue.record("descendant malformed")
      return
    }
    #expect(descendant[PDFName("Subtype")] == .name(PDFName("CIDFontType2")))
    #expect(descendant[PDFName("DW")] == .integer(1000))
    guard case .array(let w)? = descendant[PDFName("W")],
      w.count == 2
    else {
      Issue.record("W array malformed")
      return
    }
    guard let codes = written.encode("ABCâ") else {
      Issue.record("encoding failed")
      return
    }
    var content = Data("BT /F1 24 Tf 42 700 Td <".utf8)
    content.append(contentsOf: codes.map { String(format: "%02X", $0) }.joined().utf8)
    content.append(Data("> Tj ET\n".utf8))
    let data = try packagedComposite(written, fileID: PDFObjectID(7), text: content)
    // ToUnicode maps every CID back; our layout engine does not decode
    // Type0, so PDFKit (independent) proves extraction below in the
    // MacServices suite.
    let parsed = try PDFParser.parse(data)
    let cmapID = try #require(try cmapIDOfType0(in: parsed.graph))
    guard case .stream(let cmap)? = parsed.graph.objects[cmapID],
      let map = ToUnicodeCMap(stream: cmap)
    else {
      Issue.record("ToUnicode missing")
      return
    }
    #expect(map.decode(0x0000) == "A")
    #expect(map.decode(0x0003) == "â")
  }

  @Test func compositeCFFCoversText() throws {
    let written = try CompositeFontWriter.write(
      program: cffProgram, baseName: "DejaVuSans", covering: "ABC")
    guard case .dictionary(let descendant) = written.descendant else {
      Issue.record("descendant malformed")
      return
    }
    #expect(descendant[PDFName("Subtype")] == .name(PDFName("CIDFontType0")))
    #expect(written.fontFile.dictionary[PDFName("Subtype")] == .name(PDFName("OpenType")))
    guard let codes = written.encode("ABC") else {
      Issue.record("encoding failed")
      return
    }
    var content = Data("BT /F1 24 Tf 42 700 Td <".utf8)
    content.append(contentsOf: codes.map { String(format: "%02X", $0) }.joined().utf8)
    content.append(Data("> Tj ET\n".utf8))
    let data = try packagedComposite(written, fileID: PDFObjectID(7), text: content)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageIDs.count == 1)
  }

  private func cmapIDOfType0(in graph: PDFGraph) throws -> PDFObjectID? {
    for value in graph.objects.values {
      guard case .dictionary(let dictionary) = value,
        dictionary[PDFName("Subtype")] == .name(PDFName("Type0")),
        case .reference(let id)? = dictionary[PDFName("ToUnicode")]
      else { continue }
      return id
    }
    return nil
  }
}
