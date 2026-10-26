import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// FNT-07: variable-font instance capability and difficult-transform
/// classification. Every unsupported program/transform returns an explicit
/// result; supported previews use exactly the profile the writer saves.
@Suite("Variable font and transform capability")
struct FNT07CapabilityTests {
  private func fixtureProgram() throws -> Data {
    try VariableFontFixture.program()
  }

  @Test func parsesAxesAndNamedInstances() throws {
    let capability = VariableFontCapabilityInspector.inspect(program: try fixtureProgram())
    #expect(capability.isVariableFont)
    #expect(!capability.isCFF2)
    #expect(capability.axes.map(\.tag) == ["wght", "wdth"])
    let weight = try #require(capability.axes.first)
    #expect(weight.minimum == VariableFontFixture.weightMinimum)
    #expect(weight.defaultValue == VariableFontFixture.weightDefault)
    #expect(weight.maximum == VariableFontFixture.weightMaximum)
    #expect(weight.nameID == 256)
    #expect(capability.defaultInstanceCoordinates[VariableFontFixture.weightAxisTag]
      == VariableFontFixture.weightDefault)
    #expect(capability.defaultInstanceCoordinates[VariableFontFixture.widthAxisTag]
      == VariableFontFixture.widthDefault)
    #expect(capability.namedInstances.count == 2)
    #expect(capability.namedInstances[0].subfamilyNameID == 257)
    #expect(capability.namedInstances[0].coordinates[VariableFontFixture.weightAxisTag] == 300)
    #expect(capability.namedInstances[1].coordinates[VariableFontFixture.widthAxisTag] == 75)
    #expect(capability.defaultInstanceNameIDs.isEmpty)
    #expect(capability.nonDefaultInstances.count == 2)
    #expect(capability.profile == .staticDefaultInstance)
  }

  @Test func selectionCapabilityIsExplicitPerInstance() throws {
    let capability = VariableFontCapabilityInspector.inspect(program: try fixtureProgram())
    #expect(capability.capability(for: .defaultInstance).isSupported)
    // The default coordinate tuple is the only embeddable selection.
    #expect(
      capability.capability(
        for: .coordinates(capability.defaultInstanceCoordinates)
      ).isSupported)
    let named = capability.capability(for: .named(index: 0))
    #expect(!named.isSupported)
    #expect(named.reason?.localizedCaseInsensitiveContains("default axis") == true)
    let coordinateSelection = capability.capability(
      for: .coordinates([
        VariableFontFixture.weightAxisTag: 300,
        VariableFontFixture.widthAxisTag: 100,
      ]))
    #expect(!coordinateSelection.isSupported)
    #expect(coordinateSelection.reason != nil)
    #expect(
      !capability.capability(for: .named(index: 99)).isSupported)
    // The static default-instance selection is never approximated through a
    // named instance.
    #expect(
      capability.matchesDefaultInstance([
        VariableFontFixture.weightAxisTag: VariableFontFixture.weightDefault,
        VariableFontFixture.widthAxisTag: VariableFontFixture.widthDefault,
      ]))
    #expect(
      !capability.matchesDefaultInstance([
        VariableFontFixture.weightAxisTag: 300,
        VariableFontFixture.widthAxisTag: 100,
      ]))
  }

  @Test func staticFontAndMalformedProgramAreExplicit() throws {
    guard let staticProgram = Data(base64Encoded: FontFixtureData.subsetProgramBase64)
    else {
      Issue.record("Static fixture is corrupt")
      return
    }
    let staticCapability = VariableFontCapabilityInspector.inspect(program: staticProgram)
    #expect(!staticCapability.isVariableFont)
    #expect(staticCapability.axes.isEmpty)
    #expect(staticCapability.profile == .staticDefaultInstance)
    #expect(staticCapability.capability(for: .defaultInstance).isSupported)

    let truncated = try VariableFontFixture.truncatedProgram()
    let malformed = VariableFontCapabilityInspector.inspect(program: truncated)
    #expect(!malformed.isVariableFont)
    guard case .unsupported(let reason) = malformed.profile else {
      Issue.record("A truncated variable program must not claim a supported profile")
      return
    }
    #expect(reason.localizedCaseInsensitiveContains("malformed")
      || reason.localizedCaseInsensitiveContains("unsupported"))

    // Too many axes is refused by the bounded parser instead of truncated.
    let bounded = VariableFontCapabilityInspector.inspect(
      program: try fixtureProgram(), limits: .init(maximumAxes: 1))
    guard case .unsupported(let boundReason) = bounded.profile else {
      Issue.record("The axis limit must return an explicit unsupported profile")
      return
    }
    #expect(boundReason.localizedCaseInsensitiveContains("too many"))
  }

  @Test func subsetEmbedsTheStaticDefaultInstanceOnly() throws {
    let variable = try fixtureProgram()
    let full = try TrueTypeInspector.inspect(variable)
    let subset = try TrueTypeSubsetter.subset(program: variable, unicodes: [0x41])
    let sub = try TrueTypeInspector.inspect(subset)
    // The PDF path never carries variation tables: the saved program is the
    // static default instance, matching the declared capability.
    #expect(sub.tables["fvar"] == nil)
    #expect(sub.tables["gvar"] == nil)
    let fullGlyph = try #require(full.unicodeToGlyph[0x41])
    let subGlyph = try #require(sub.unicodeToGlyph[0x41])
    #expect(full.advances[fullGlyph] == sub.advances[subGlyph])
    #expect(sub.unitsPerEm == full.unitsPerEm)
    // The capability's only supported selection is the default instance.
    let capability = VariableFontCapabilityInspector.inspect(program: variable)
    #expect(capability.capability(for: .defaultInstance).isSupported)
    #expect(!capability.capability(for: .named(index: 0)).isSupported)
  }

  @Test func classifiesHorizontalTransformsAndShearBounds() {
    func profile(_ transform: [Double]) -> TextTransformProfile {
      TextTransformInspector.inspect(transform: transform).profile
    }
    #expect(profile([1, 0, 0, 1, 10, 20]) == .horizontal)
    #expect(profile([2, 0, 0, 2, 0, 0]) == .horizontal)
    #expect(profile([0.25, 0, 0, 0.25, 0, 0]) == .horizontal)
    #expect(profile([1, 0, 0.2, 1, 0, 0]) == .horizontalShear(0.2))
    #expect(profile([1, 0, 0.35, 1, 0, 0]) == .horizontalShear(0.35))
    #expect(profile([1, 0, -0.35, 1, 0, 0]) == .horizontalShear(-0.35))
    #expect(profile([1, 0, 0.36, 1, 0, 0]) == .unsupported(.excessiveShear))
    #expect(profile([2, 0, 0.4, 2, 0, 0]) == .horizontalShear(0.2))
    #expect(profile([2, 0, 1.0, 2, 0, 0]) == .unsupported(.excessiveShear))
    #expect(profile([1, 0.1, 0, 1, 0, 0]) == .unsupported(.verticalShear))
    #expect(profile([2, 0, 0, 1, 0, 0]) == .unsupported(.nonUniformScale))
    #expect(profile([-1, 0, 0, 1, 0, 0]) == .unsupported(.flipped))
    #expect(profile([0, 0, 0, 1, 0, 0]) == .unsupported(.singular))
    #expect(profile([.nan, 0, 0, 1, 0, 0]) == .unsupported(.invalid))
    #expect(profile([1, 0, 0, 1]) == .unsupported(.invalid))
    // Bounded shear classification also reports supported uses.
    let shear = TextTransformInspector.inspect(transform: [1, 0, 0.2, 1, 0, 0])
    #expect(shear.supports(.inlineParagraph))
    #expect(shear.supports(.runReplacement))
    #expect(shear.supports(.preview))
    let excessive = TextTransformInspector.inspect(transform: [1, 0, 0.5, 1, 0, 0])
    #expect(!excessive.supports(.preview))
    #expect(excessive.refusalMessage?.localizedCaseInsensitiveContains("shear") == true)
  }

  @Test func classifiesRotatedAndMixedTransforms() {
    let quarter = TextTransformInspector.inspect(transform: [0, 1, -1, 0, 200, 200])
    #expect(quarter.profile == .rotated(degrees: 90, scale: 1))
    #expect(quarter.supports(.runReplacement))
    #expect(!quarter.supports(.inlineParagraph))
    #expect(quarter.supports(.preview))
    let thirty = 30.0 * Double.pi / 180
    let rotated = TextTransformInspector.inspect(
      transform: [cos(thirty), sin(thirty), -sin(thirty), cos(thirty), 150, 350])
    guard case .rotated(let degrees, let scale) = rotated.profile else {
      Issue.record("A 30 degree rotation must classify as rotated")
      return
    }
    #expect(abs(degrees - 30) < 0.01)
    #expect(abs(scale - 1) < 0.001)
    // A 45 degree rotation with a uniform 1.414 scale is still the rotated
    // profile, not a shear.
    guard case .rotated(let diagonalDegrees, let diagonalScale) =
      TextTransformInspector.inspect(transform: [1, 1, -1, 1, 0, 0]).profile
    else {
      Issue.record("A 45 degree uniform rotation must classify as rotated")
      return
    }
    #expect(abs(diagonalDegrees - 45) < 0.01)
    #expect(abs(diagonalScale - 2.0.squareRoot()) < 0.001)
    // Rotation combined with shear is refused; tiny rotations are not forced
    // into either profile.
    let rotatedSheared: [Double] = [0.866_025_4, 0.5, 0.5, 0.866_025_4, 0, 0]
    #expect(
      TextTransformInspector.inspect(transform: rotatedSheared).profile
        == .unsupported(.rotationWithShear))
    let tiny = 0.01 * Double.pi / 180
    #expect(
      TextTransformInspector.inspect(
        transform: [cos(tiny), sin(tiny), -sin(tiny), cos(tiny), 0, 0]
      ).profile == .unsupported(.nearHorizontalRotation))
  }

  @Test func capabilityAgreesWithExistingWriterProfiles() {
    let horizontal: [[Double]] = [
      [1, 0, 0, 1, 0, 0], [2, 0, 0, 2, 5, 6], [1, 0, 0.15, 1, 0, 0],
    ]
    for matrix in horizontal {
      let capability = TextTransformInspector.inspect(transform: matrix)
      #expect(capability.supports(.inlineParagraph))
      let obliqueness = TextCanvasSupport.inlineObliqueness(for: matrix)
      #expect(obliqueness != nil)
      if case .horizontalShear(let shear) = capability.profile,
        let obliqueness
      {
        #expect(abs(shear - obliqueness) < 1e-9)
      }
    }
    let unsupported: [[Double]] = [
      [1, 0.1, 0, 1, 0, 0], [2, 0, 0, 1, 0, 0], [-1, 0, 0, 1, 0, 0],
      [1, 0, 0.4, 1, 0, 0],
    ]
    for matrix in unsupported {
      #expect(!TextTransformInspector.inspect(transform: matrix).supports(.inlineParagraph))
      #expect(TextCanvasSupport.inlineObliqueness(for: matrix) == nil)
    }
    let rotated: [[Double]] = [
      [0, 1, -1, 0, 10, 20], [0.8660254, 0.5, -0.5, 0.8660254, 30, 40],
    ]
    for matrix in rotated {
      let capability = TextTransformInspector.inspect(transform: matrix)
      guard case .rotated(let degrees, let scale) = capability.profile,
        let profile = TextCanvasSupport.rotationProfile(for: matrix)
      else {
        Issue.record("Rotation profile disagreement for \(matrix)")
        continue
      }
      #expect(abs(degrees - profile.degrees) < 0.01)
      #expect(abs(scale - profile.scale) < 0.001)
    }
  }

  @Test func composedRunMatricesFromFixtureClassifyExplicitly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.transformedTextPages())
    let pageID = parsed.pageIDs[0]
    let content = try PageContent.load(pageID: pageID, in: parsed.graph)
    let runs = try TextRunIndexer.runs(in: content, graph: parsed.graph)
    var profiles: [TextTransformProfile] = []
    for run in runs {
      let capability = TextTransformInspector.inspect(ctm: run.ctm, textMatrix: run.matrix)
      profiles.append(capability.profile)
    }
    // The fixture has a quarter-turned run and a uniformly scaled horizontal
    // run; both must be identified rather than silently approximated.
    #expect(profiles.contains { if case .rotated = $0 { return true } else { return false } })
    #expect(profiles.contains { $0 == .horizontal })
    for profile in profiles where !profile.isSupported {
      Issue.record("Fixture run unexpectedly unsupported: \(profile)")
    }
  }
}
