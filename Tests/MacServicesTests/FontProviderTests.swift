import AppKit
import Foundation
import Testing
@testable import MacServices
@testable import PDFEditing

/// P15-001–P15-008/P15-025/P15-003/P15-006: CoreText shaping, cluster mappings,
/// fallback detection, missing-glyph reporting, permission records, coverage,
/// direction/language preservation, and the licensed embedding-fallback set.
@Suite("Font provider")
struct FontProviderTests {
  @Test func shapingReportsGlyphsAdvancesAndClusters() throws {
    let provider = FontProvider()
    let run = provider.shape("Hello", fontName: "Helvetica", pointSize: 12)
    #expect(run.glyphs.count == 5)
    #expect(run.missingGlyphCount == 0)
    #expect(run.advance > 0)
    // Cluster mappings cover the string in order (P15-025).
    #expect(run.glyphs.first?.clusterStart == 0)
    #expect(run.glyphs.last?.clusterEnd == 5)
    #expect(run.glyphs.allSatisfy { $0.clusterEnd > $0.clusterStart })
  }

  @Test func ligaturesKeepReverseSelectionMappings() throws {
    let provider = FontProvider()
    // A font with ligature substitution maps several characters to one glyph;
    // the cluster still spans the whole source range.
    let run = provider.shape("office", fontName: "Helvetica", pointSize: 12)
    let clusters = run.glyphs.map { ($0.clusterStart, $0.clusterEnd) }
    #expect(clusters.first?.0 == 0)
    #expect(clusters.last?.1 == 6)
    // Every UTF-16 offset is covered by exactly one cluster in order.
    var expected = 0
    for cluster in clusters {
      #expect(cluster.0 == expected)
      expected = cluster.1
    }
  }

  @Test func fallbackAndMissingGlyphsAreExplicit() throws {
    let provider = FontProvider()
    // A script Helvetica does not cover: the cascade provides glyphs and the
    // fallback flag is set (P15-008).
    let run = provider.shape("日本語", fontName: "Helvetica", pointSize: 12)
    #expect(!run.glyphs.isEmpty)
    #expect(run.glyphs.contains { $0.isFallback } || run.missingGlyphCount > 0)
    let covering = provider.coveringFont(for: "Hello", preferred: "Helvetica")
    #expect(covering == "Helvetica")
    // A coverage request for an unsupported combination returns nil or a
    // covering system font, never a silent wrong answer.
    let exotic = provider.coveringFont(for: "\u{10FFFF}")
    if let exotic { #expect(!exotic.isEmpty) }
  }

  @Test func permissionRecordsDistinguishSystemAndProvisionedFonts() throws {
    let system = FontProvider.PermissionRecord.systemFont("Helvetica")
    #expect(!system.mayEmbedForEditing)
    #expect(!system.maySubset)
    #expect(system.note.contains("render-only"))
    let provisioned = FontProvider.PermissionRecord.provisionedFont("Open Sans")
    #expect(provisioned.mayEmbedForEditing)
    #expect(provisioned.maySubset)
    #expect(provisioned.note.contains("license"))
    // The installed-font inventory returns records (bounded).
    let records = FontProvider().availableFonts(limit: 25)
    #expect(records.count <= 25)
    #expect(records.allSatisfy { !$0.mayEmbedForEditing })
  }

  @Test func directionAndLanguageContextArePreserved() throws {
    let provider = FontProvider()
    // LTR default with no language context.
    let latin = provider.shape("Hello", fontName: "Helvetica", pointSize: 12)
    #expect(latin.direction == "ltr")
    #expect(latin.language == nil)
    // Hebrew shapes as RTL even without an explicit language tag.
    let hebrew = provider.shape("שלום", fontName: "Helvetica", pointSize: 12)
    #expect(hebrew.direction == "rtl")
    #expect(!hebrew.glyphs.isEmpty)
    // Every source offset is still covered exactly once (as a set), even
    // though visual glyph order is reordered for RTL.
    let utf16Count = "שלום".utf16.count
    let covered = hebrew.glyphs.flatMap { $0.clusterStart..<$0.clusterEnd }
    #expect(covered.sorted() == Array(0..<utf16Count))
    #expect(hebrew.glyphs.allSatisfy { $0.clusterEnd > $0.clusterStart })
    // Arabic with an explicit language tag preserves both.
    let arabic = provider.shape(
      "مرحبا", fontName: "Helvetica", pointSize: 12, language: "ar")
    #expect(arabic.direction == "rtl")
    #expect(arabic.language == "ar")
    #expect(!arabic.glyphs.isEmpty)
    // A well-formed regional tag is preserved verbatim.
    let regional = provider.shape(
      "Hello", fontName: "Helvetica", pointSize: 12, language: "en-US")
    #expect(regional.direction == "ltr")
    #expect(regional.language == "en-US")
    // Malformed tags are ignored rather than passed to shaping as-is.
    let malformed = provider.shape(
      "Hello", fontName: "Helvetica", pointSize: 12, language: "!!")
    #expect(malformed.language == nil)
    #expect(malformed.direction == "ltr")
    // Mixed text follows the majority script; empty text stays LTR.
    #expect(
      provider.shape("Hello שלום", fontName: "Helvetica", pointSize: 12).direction == "ltr")
    #expect(
      provider.shape("שלום مرحبا test", fontName: "Helvetica", pointSize: 12).direction
        == "rtl")
    let empty = provider.shape("", fontName: "Helvetica", pointSize: 12)
    #expect(empty.direction == "ltr")
    #expect(empty.glyphs.isEmpty)
  }

  @Test func licensedFallbackSetIsSmallExplicitAndEmbeddable() throws {
    // The set is small and every member is OFL with a stated source.
    #expect(LicensedFallbackSet.fonts.count == 3)
    let families = LicensedFallbackSet.fonts.map(\.family)
    #expect(Set(families).count == families.count)
    #expect(LicensedFallbackSet.fonts.allSatisfy { $0.license == "OFL-1.1" })
    #expect(
      LicensedFallbackSet.fonts.allSatisfy { $0.provisionSource.contains("Google Fonts") })
    // No render-only system font is a member.
    for system in ["Helvetica", "Times New Roman", "Arial", "Menlo"] {
      #expect(!families.contains(system))
    }
    // Style preference orders selection; unknown styles fall through.
    let provider = FontProvider()
    #expect(
      provider.licensedFallback(
        for: "Hello", preferring: .serif,
        installed: ["Noto Sans", "Noto Serif"], covers: { _ in true }) == "Noto Serif")
    #expect(
      provider.licensedFallback(
        for: "Hello", preferring: .mono,
        installed: ["Noto Sans", "Noto Serif"], covers: { _ in true }) == "Noto Sans")
    #expect(
      provider.licensedFallback(
        for: "Hello", installed: ["Noto Sans Mono"], covers: { _ in true })
        == "Noto Sans Mono")
    // Nothing installed, or only system fonts installed: nil, never a
    // render-only system font for embedding.
    #expect(provider.licensedFallback(for: "Hello", installed: []) == nil)
    #expect(
      provider.licensedFallback(
        for: "Hello", installed: ["Helvetica", "Times New Roman"],
        covers: { _ in true }) == nil)
    // A member without real coverage is skipped.
    #expect(
      provider.licensedFallback(
        for: "Hello", installed: ["Noto Sans"], covers: { _ in false }) == nil)
  }
}
