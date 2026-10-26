import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// SPC-07: the XFA reading/filling decision - static/dynamic detection, no
/// rendering or XFA fill, optional AcroForm fallback and explicit flattening.
struct XFACompatibilityTests {
  @Test func absentXFAReportsNone() throws {
    let data = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(data)
    let profile = XFACompatibility.profile(in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(profile.kind == .none)
    #expect(!profile.hasXFA)
    #expect(!profile.isDeclaredExclusion)
    #expect(!profile.flatteningAvailable)
    #expect(profile.summary.contains("No XFA"))
    #expect(profile.authoringDecision.contains("not supported"))
  }

  @Test func staticXFAIsDetectedAndNotRenderedOrFilled() throws {
    let graph = try CompatibilityFixtures.xfaDocument(.staticXFA, fallbackField: false)
    let pageIDs = try CompatibilityFixtures.pageIDs(of: graph)
    let profile = XFACompatibility.profile(in: graph, pageIDs: pageIDs)
    #expect(profile.kind == .staticXFA)
    #expect(profile.hasXFA)
    #expect(profile.isDeclaredExclusion)
    #expect(!profile.needsRendering)
    #expect(profile.packetCount == 1)
    #expect(profile.xfaByteCount > 0)
    #expect(!profile.fallbackAvailable)
    #expect(!profile.flatteningAvailable)
    #expect(profile.renderDecision.contains("not rendered"))
    #expect(profile.fillDecision.contains("cannot be filled"))
    #expect(profile.authoringDecision.contains("separate feature"))
    #expect(profile.flatteningDecision.contains("interactivity"))
    #expect(profile.flatteningDecision.contains("original file"))
    #expect(profile.disclosures.contains { $0.contains("never evaluated") })
    #expect(profile.summary.contains("Static XFA"))
  }

  @Test func dynamicXFAIsDetectedFromPacketsAndNeedsRendering() throws {
    let graph = try CompatibilityFixtures.xfaDocument(.dynamicXFA, fallbackField: false)
    let pageIDs = try CompatibilityFixtures.pageIDs(of: graph)
    let profile = XFACompatibility.profile(in: graph, pageIDs: pageIDs)
    #expect(profile.kind == .dynamicXFA)
    #expect(profile.needsRendering)
    #expect(profile.packetCount == 2)
    #expect(profile.xfaByteCount > 0)
    #expect(profile.renderDecision.contains("Dynamic XFA"))
    #expect(profile.disclosures.contains { $0.contains("Static or dynamic XFA")
      || $0.contains("Dynamic XFA") })
    #expect(profile.summary.contains("Dynamic XFA"))
  }

  @Test func acroFormFallbackRemainsFillableAndFlatteningIsExplicit() throws {
    let graph = try CompatibilityFixtures.xfaDocument(.staticXFA, fallbackField: true)
    let pageIDs = try CompatibilityFixtures.pageIDs(of: graph)
    let profile = XFACompatibility.profile(in: graph, pageIDs: pageIDs)
    #expect(profile.kind == .staticXFA)
    #expect(profile.fallbackAvailable)
    #expect(profile.flatteningAvailable)
    #expect(profile.acroFormFieldCount == 1)
    #expect(profile.fillDecision.contains("fillable"))
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    #expect(fields.first?.stringValue == "Ada")
    // Explicit flattening is a new static copy; the original keeps its XFA.
    let flattened = try FlattenFormCommand().apply(to: graph)
    let flattenedProfile = XFACompatibility.profile(
      in: flattened, pageIDs: try CompatibilityFixtures.pageIDs(of: flattened))
    #expect(flattenedProfile.kind == .none)
    #expect(flattenedProfile.acroFormFieldCount == 0)
    let originalStill = XFACompatibility.profile(
      in: graph, pageIDs: try CompatibilityFixtures.pageIDs(of: graph))
    #expect(originalStill.kind == .staticXFA)
    #expect(profile.flatteningDecision.contains("retained"))
  }

  @Test func unclassifiedXFAIsDisclosedAsUnknown() throws {
    let graph = try CompatibilityFixtures.xfaWithUnclassifiedValue()
    let pageIDs = try CompatibilityFixtures.pageIDs(of: graph)
    let profile = XFACompatibility.profile(in: graph, pageIDs: pageIDs)
    #expect(profile.kind == .unknown)
    #expect(profile.hasXFA)
    #expect(profile.isDeclaredExclusion)
    #expect(profile.summary.contains("Unclassified XFA"))
  }
}
