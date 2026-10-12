import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P43-002/P43-004/P43-011: font inventory facts, the commercial-license
/// heuristic, and deterministic substitution fallbacks.
@Suite("Font inventory")
struct FontInventoryTests {
  private func fixture() -> PDFGraph {
    PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([
              PDFName("F1"): .reference(PDFObjectID(10)),
              PDFName("F2"): .reference(PDFObjectID(11)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data("BT /F1 12 Tf 42 700 Td (x) Tj ET\n".utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(12))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: Data("BT /F1 12 Tf 42 700 Td (y) Tj ET\n".utf8))),
        PDFObjectID(10): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(11): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("TrueType")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+Custom Sans")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("FontDescriptor"): .reference(PDFObjectID(13)),
        ]),
        PDFObjectID(12): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("MinionPro-Regular")),
        ]),
        PDFObjectID(13): .dictionary([
          PDFName("Type"): .name(PDFName("FontDescriptor")),
          PDFName("FontName"): .name(PDFName("ABCDEF+Custom Sans")),
          PDFName("FontFile2"): .reference(PDFObjectID(14)),
        ]),
        PDFObjectID(14): .stream(PDFStream(bytes: Data(repeating: 0, count: 16))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func inventoryReportsEmbeddingSubsetsAndPages() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    #expect(fonts.count == 3)
    let helvetica = try #require(fonts.first { $0.familyName == "Helvetica" })
    #expect(helvetica.isStandard14)
    #expect(!helvetica.isEmbedded)
    #expect(helvetica.pageIndices == [0])
    let custom = try #require(fonts.first { $0.familyName == "Custom Sans" })
    #expect(custom.isSubset)
    #expect(custom.isEmbedded)
    #expect(custom.encoding == "WinAnsiEncoding")
    #expect(custom.subtype == "TrueType")
    let minion = try #require(fonts.first { $0.familyName == "MinionPro-Regular" })
    #expect(!minion.isEmbedded)
    #expect(minion.pageIndices == [1])
    #expect(minion.mayBeCommerciallyLicensed)
    #expect(!helvetica.mayBeCommerciallyLicensed)
  }

  @Test func fallbackMappingIsDeterministic() {
    #expect(FontFallback.family(for: "Custom Sans") == "Helvetica")
    #expect(FontFallback.family(for: "Times New Roman") == "Times New Roman")
    #expect(FontFallback.family(for: "Garamond") == "Times New Roman")
    #expect(FontFallback.family(for: "Courier New") == "Menlo")
    #expect(FontFallback.family(for: "Roboto Mono") == "Menlo")
    #expect(FontFallback.family(for: "Zapf Dingbats") == "Apple Symbols")
  }

  @Test func runFontLookupResolvesTheEditedRun() throws {
    let parsed = try PDFParser.parse(PDFWriter.write(PDFFixtures.graph(pages: 1)))
    let font = try PDFTextFontLookup.font(
      forRunAt: 0, pageID: parsed.pageIDs[0], in: parsed.graph)
    #expect(font?.baseName == "Helvetica")
    #expect(font?.isStandard14 == true)
  }
}

/// P15-006: the licensed fallback set is small, fully licensed, and selects
/// deterministically without touching machine state.
@Suite("Licensed fallback set")
struct LicensedFallbackSetTests {
  @Test func setMembersAreExplicitlyLicensed() {
    #expect(LicensedFallbackSet.fonts.count == 3)
    let families = LicensedFallbackSet.fonts.map(\.family)
    #expect(Set(families).count == families.count)
    #expect(LicensedFallbackSet.fonts.allSatisfy { $0.license == "OFL-1.1" })
    #expect(
      LicensedFallbackSet.fonts.allSatisfy { $0.provisionSource.contains("Google Fonts") })
    #expect(LicensedFallbackSet.fonts.allSatisfy { !$0.scripts.isEmpty })
    #expect(!families.contains("Helvetica"))
  }

  @Test func pickPrefersStyleThenListedOrder() {
    let both: Set<String> = ["Noto Sans", "Noto Serif"]
    #expect(LicensedFallbackSet.pick(preferring: .serif, installed: both)?.family == "Noto Serif")
    #expect(LicensedFallbackSet.pick(preferring: .sans, installed: both)?.family == "Noto Sans")
    #expect(LicensedFallbackSet.pick(installed: both)?.family == "Noto Sans")
    #expect(
      LicensedFallbackSet.pick(preferring: .mono, installed: both)?.family == "Noto Sans")
    #expect(
      LicensedFallbackSet.pick(installed: ["Noto Sans Mono"])?.family == "Noto Sans Mono")
  }

  @Test func pickFallsThroughStyleButNeverToSystemFonts() {
    #expect(LicensedFallbackSet.pick(installed: []) == nil)
    #expect(LicensedFallbackSet.pick(installed: ["Helvetica", "Arial"]) == nil)
    #expect(LicensedFallbackSet.pick(preferring: .mono, installed: ["Noto Serif"])?.family == "Noto Serif")
  }
}
