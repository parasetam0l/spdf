import AppKit
import Foundation
import MacServices
import PDFEditing
import Testing

@MainActor
private final class ToggleTestTextView: NSTextView {
  let history = UndoManager()
  override var undoManager: UndoManager? { history }
}

@Suite("Character formatting toggles and rich-paste scale")
struct TextFormattingToggleTests {
  /// Renders a single run and selects it, matching the live page editor.
  @MainActor
  private func makeFormatting(
    _ text: String, format: PageTextFormat
  ) -> (view: ToggleTestTextView, formatting: NativeTextFormatting) {
    let view = ToggleTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: text, format: format)], initial: format)
    formatting.render(scale: 1, minimumLineSpacing: 16)
    view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
    return (view, formatting)
  }

  @Test @MainActor func clearingDecorationsAndRiseRemovesAppKitAttributes() throws {
    let format = PageTextFormat(size: 12)
    let (view, formatting) = makeFormatting("Toggle", format: format)
    let storage = try #require(view.textStorage)

    #expect(formatting.apply(.underline(true), isTyping: true) == nil)
    #expect(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    #expect(formatting.apply(.underline(false), isTyping: true) == nil)
    #expect(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)

    #expect(formatting.apply(.strikeout(true), isTyping: true) == nil)
    #expect(storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
    #expect(formatting.apply(.strikeout(false), isTyping: true) == nil)
    #expect(storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)

    #expect(formatting.apply(.superscript(true), isTyping: true) == nil)
    let raised = try #require(formatting.fragments().first?.format)
    #expect(raised.rise > 0.01)
    #expect(abs(raised.size - 12 * 0.65) < 1e-12)
    #expect(storage.attribute(.baselineOffset, at: 0, effectiveRange: nil) != nil)

    // Applying superscript twice must not shrink the already-raised run again.
    #expect(formatting.apply(.superscript(true), isTyping: true) == nil)
    let repeated = try #require(formatting.fragments().first?.format)
    #expect(repeated == raised)

    #expect(formatting.apply(.superscript(false), isTyping: true) == nil)
    let restored = try #require(formatting.fragments().first?.format)
    #expect(abs(restored.size - 12) < 1e-12)
    #expect(abs(restored.rise) < 1e-12)
    #expect(storage.attribute(.baselineOffset, at: 0, effectiveRange: nil) == nil)
    let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(abs(font.pointSize - 12) < 0.001)
  }

  @Test @MainActor func superscriptConvertsToSubscriptWithoutDoubleShrinking() throws {
    let (_, formatting) = makeFormatting("Toggle", format: PageTextFormat(size: 12))
    #expect(formatting.apply(.superscript(true), isTyping: true) == nil)
    #expect(formatting.apply(.subscripted(true), isTyping: true) == nil)
    let converted = try #require(formatting.fragments().first?.format)
    #expect(converted.rise < -0.01)
    #expect(abs(converted.size - 12 * 0.65) < 1e-12)

    #expect(formatting.apply(.subscripted(false), isTyping: true) == nil)
    let restored = try #require(formatting.fragments().first?.format)
    #expect(abs(restored.size - 12) < 1e-12)
    #expect(abs(restored.rise) < 1e-12)
  }

  @Test @MainActor func mixedSuperscriptRunsDoNotShrinkRaisedRunAgain() throws {
    let normal = PageTextFormat(size: 12)
    let raised = PageTextFormat(size: 7.8, rise: 4.2)
    let text = "plain high"
    let view = ToggleTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view,
      fragments: [
        .init(text: "plain ", format: normal),
        .init(text: "high", format: raised),
      ], initial: normal)
    formatting.render(scale: 1, minimumLineSpacing: 16)
    view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))

    #expect(formatting.apply(.superscript(true), isTyping: true) == nil)
    let fragments = formatting.fragments()
    #expect(fragments.map(\.text) == ["plain ", "high"])
    #expect(fragments.allSatisfy { $0.format.rise > 0.01 })
    #expect(abs(fragments[0].format.size - 12 * 0.65) < 1e-12)
    #expect(fragments[1].format == raised)
  }

  @Test @MainActor func richPasteNormalizesScreenPointsToPageSpace() throws {
    let base = PageTextFormat(size: 12)
    let view = ToggleTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "Keep", format: base)], initial: base)
    formatting.render(scale: 2, minimumLineSpacing: 16)
    let pasted = NSMutableAttributedString(string: "AB")
    let font = try #require(NSFont(name: "Helvetica-Bold", size: 24))
    pasted.addAttribute(.font, value: font, range: NSRange(location: 0, length: 2))

    let plan = formatting.richInsertionPlan(pasted, replacing: NSRange(location: 0, length: 0))
    #expect(plan.issue == nil)
    let fragment = try #require(plan.fragments.first)
    #expect(fragment.format.font == .helveticaBold)
    #expect(fragment.format.size == 12)
  }

  @Test @MainActor func richPasteAtUnitScaleKeepsPointSize() throws {
    let base = PageTextFormat(size: 12)
    let view = ToggleTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "Keep", format: base)], initial: base)
    formatting.render(scale: 1, minimumLineSpacing: 16)
    let pasted = NSMutableAttributedString(string: "AB")
    let font = try #require(NSFont(name: "Helvetica", size: 16))
    pasted.addAttribute(.font, value: font, range: NSRange(location: 0, length: 2))

    let plan = formatting.richInsertionPlan(pasted, replacing: NSRange(location: 0, length: 0))
    #expect(plan.issue == nil)
    let fragment = try #require(plan.fragments.first)
    #expect(fragment.format.size == 16)
  }
}
