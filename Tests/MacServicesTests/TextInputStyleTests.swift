import AppKit
import Foundation
import Testing
@testable import MacServices
@testable import PDFEditing

/// P15-024: the run style maps to native control attributes with safe
/// fallbacks — installed families resolve, missing ones fall back to the
/// system font at the identical size, and malformed colors become the label
/// color instead of a wrong color.
@Suite("Text input styles")
struct TextInputStyleTests {
  @Test func installedFamiliesResolveAtOverlaySize() {
    let style = TextInputStyle(
      fontFamily: "Helvetica", fontSize: 20, fillColor: [0, 0, 0])
    let font = style.nativeFont(viewHeight: 20)
    #expect(font.familyName?.contains("Helvetica") == true)
    #expect(abs(font.pointSize - 12.4) < 0.001)
    // Black fill maps to a black opaque color.
    let color = style.nativeTextColor.usingColorSpace(.sRGB) ?? style.nativeTextColor
    #expect(abs(color.redComponent) < 0.001)
    #expect(abs(color.greenComponent) < 0.001)
    #expect(abs(color.blueComponent) < 0.001)
    #expect(abs(color.alphaComponent - 1) < 0.001)
  }

  @Test func missingFamiliesFallBackToSystemAtIdenticalSize() {
    let styled = TextInputStyle(
      fontFamily: "No Such Family Name", fontSize: 20, fillColor: [0, 0, 0])
    let fallback = styled.nativeFont(viewHeight: 20)
    #expect(fallback.familyName?.contains("Helvetica") == false)
    let unstyled = TextInputStyle(fontFamily: nil, fontSize: 20, fillColor: [0, 0, 0])
    #expect(unstyled.nativeFont(viewHeight: 20).pointSize == fallback.pointSize)
    // The overlay size rule is shared: height-derived and clamped.
    #expect(styled.nativeFont(viewHeight: 4).pointSize == 9)
    #expect(styled.nativeFont(viewHeight: 200).pointSize == 28)
  }

  @Test func malformedColorsBecomeTheLabelColor() {
    #expect(
      TextInputStyle(fontFamily: nil, fontSize: 12, fillColor: [1, 0]).nativeTextColor
        == .labelColor)
    #expect(
      TextInputStyle(
        fontFamily: nil, fontSize: 12, fillColor: [.nan, 0, 0]
      ).nativeTextColor == .labelColor)
    // Out-of-range components clamp instead of refusing (asserted in the
    // calibrated space; converting to sRGB would apply gamma).
    let clamped = TextInputStyle(
      fontFamily: nil, fontSize: 12, fillColor: [2, -1, 0.5]
    ).nativeTextColor
    #expect(abs(clamped.redComponent - 1) < 0.001)
    #expect(abs(clamped.greenComponent) < 0.001)
    #expect(abs(clamped.blueComponent - 0.5) < 0.001)
  }
}
