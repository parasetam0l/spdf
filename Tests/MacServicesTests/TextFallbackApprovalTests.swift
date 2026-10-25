import AppKit
import Foundation
import MacServices
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

@MainActor
private final class FormatTestTextView: NSTextView {
  let history = UndoManager()
  override var undoManager: UndoManager? { history }
}

/// FNT-02: deliberate missing-glyph fallback. Missing characters are previewed,
/// compatible same-face subsets are distinguished from face changes, and a
/// different face is only applied when explicitly approved. Approved fallback
/// runs are then saved with glyphs and extracted Unicode matching the intended
/// text.
@Suite("Missing-glyph fallback approval")
struct TextFallbackApprovalTests {
  private var fixtureProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64)
      else { throw PDFError(.malformed, "Test font program is corrupt") }
      return program
    }
  }

  private func profile(
    source: PageTextSourceFont, program: Data, characters: [String]
  ) throws -> PageTextFontProfile {
    let inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    var glyphs: [String: PageTextFontProfile.Glyph] = [:]
    for character in characters {
      let scalar = try #require(character.unicodeScalars.first)
      let glyph = try #require(inspector.unicodeToGlyph[Int(scalar.value)])
      let width = Double(inspector.advances[glyph] ?? 0) * 1_000
        / Double(max(1, inspector.unitsPerEm))
      glyphs[character] = .init(id: glyph, width: width, codes: [UInt8(scalar.value & 0xFF)])
    }
    return .init(source: source, program: program, glyphs: glyphs)
  }

  @Test @MainActor func previewProposesCompatibleSameFaceSubset() throws {
    let program = try fixtureProgram
    let first = PageTextSourceFont(resource: PDFName("TT1"), name: "DejaVuSans")
    let second = PageTextSourceFont(resource: PDFName("TT2"), name: "DejaVuSans")
    let firstProfile = try profile(source: first, program: program, characters: ["A", "B"])
    let secondProfile = try profile(source: second, program: program, characters: ["C"])
    let base = PageTextFormat(size: 16, sourceFont: first)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "AB", format: base)], initial: base,
      profiles: [first.resource: firstProfile, second.resource: secondProfile])
    formatting.render(scale: 1, minimumLineSpacing: 19)
    view.setSelectedRange(NSRange(location: 2, length: 0))

    let preview = try #require(
      formatting.fallbackPreview("C", replacing: view.selectedRange()))
    #expect(preview.isRequired)
    #expect(preview.requirements.map(\.character) == ["C"])
    #expect(preview.changes.count == 1)
    let change = try #require(preview.changes.first)
    #expect(change.characters == "C")
    #expect(change.source.isCompatibleSameFaceSubset)
    #expect(!change.requiresExplicitApproval)
    #expect(change.toFontName == "DejaVuSans")
    #expect(!preview.needsExplicitApproval)
    #expect(preview.canApply)
    #expect(preview.message.localizedCaseInsensitiveContains("compatible"))

    let plan = formatting.insertionPlan(
      "C", replacing: view.selectedRange(), fallbackApproval: .compatibleSourceSubsetsOnly)
    #expect(plan.issue == nil)
    #expect(plan.usesSourceFontFallback)
    #expect(plan.fragments.map(\.text) == ["C"])
    #expect(plan.fragments.map { $0.format.sourceFont?.resource } == [PDFName("TT2")])
    #expect(plan.fallbackPreview?.changes.count == 1)
    #expect(plan.attributedText?.length == 1)
  }

  @Test @MainActor func crossFaceFallbackRequiresExplicitApproval() throws {
    let full = try fixtureProgram
    let tiny = try TrueTypeSubsetter.subset(program: full, unicodes: [0x41])
    let baseFont = CustomTextFont(
      program: tiny, familyName: "BaseSans", faceName: "BaseSans · Regular",
      identifier: "base-face")
    let fallback = CustomTextFont(
      program: full, familyName: "FallbackSans", faceName: "FallbackSans · Regular",
      identifier: "fallback-face")
    let base = PageTextFormat(size: 16, customFont: baseFont)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "A", format: base)], initial: base,
      licensedFonts: [baseFont, fallback])
    formatting.render(scale: 1, minimumLineSpacing: 19)
    view.setSelectedRange(NSRange(location: 1, length: 0))

    let preview = try #require(
      formatting.fallbackPreview("B", replacing: view.selectedRange()))
    #expect(preview.requirements.map(\.character) == ["B"])
    let change = try #require(preview.changes.first)
    #expect(change.requiresExplicitApproval)
    #expect(change.toFontName == "FallbackSans · Regular")
    #expect(preview.needsExplicitApproval)
    #expect(preview.canApply)

    let refused = formatting.insertionPlan(
      "B", replacing: view.selectedRange(), fallbackApproval: .none)
    #expect(refused.issue != nil)
    #expect(refused.attributedText == nil)
    #expect(refused.fallbackPreview != nil)
    let message = try #require(refused.issue)
    #expect(message.contains("B"))
    #expect(message.localizedCaseInsensitiveContains("FallbackSans"))

    let unapproved = formatting.insertionPlan(
      "B", replacing: view.selectedRange(),
      fallbackApproval: .approving(["Some Other Face"]))
    #expect(unapproved.issue != nil)
    #expect(unapproved.attributedText == nil)

    let approved = formatting.insertionPlan(
      "B", replacing: view.selectedRange(),
      fallbackApproval: .approving(["FallbackSans · Regular"]))
    #expect(approved.issue == nil)
    #expect(approved.usesSourceFontFallback)
    #expect(approved.fragments.map(\.text) == ["B"])
    #expect(approved.fragments.first?.format.customFont?.identifier == "fallback-face")
    #expect(approved.attributedText?.length == 1)
    #expect(approved.fallbackPreview?.changes.first?.source == .licensedFont(fallback))
  }

  @Test @MainActor func characterWithoutAnyCoveringFontIsReported() throws {
    let view = FormatTestTextView(frame: .zero)
    let base = PageTextFormat(size: 16)
    let formatting = NativeTextFormatting(view: view, fragments: [], initial: base)
    formatting.render(scale: 1, minimumLineSpacing: 19)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    let range = NSRange(location: 0, length: 0)
    let preview = try #require(formatting.fallbackPreview("Ω", replacing: range))
    #expect(preview.requirements.map(\.character) == ["Ω"])
    #expect(preview.changes.isEmpty)
    #expect(!preview.canApply)
    #expect(preview.message.contains("Ω"))

    let plan = formatting.insertionPlan(
      "Ω", replacing: range, fallbackApproval: .compatibleSourceSubsetsOnly)
    #expect(plan.issue != nil)
    #expect(plan.attributedText == nil)
    #expect(plan.fragments.isEmpty)
  }

  @Test @MainActor func approvalHandlerDrivesTheDecision() throws {
    let full = try fixtureProgram
    let tiny = try TrueTypeSubsetter.subset(program: full, unicodes: [0x41])
    let baseFont = CustomTextFont(
      program: tiny, familyName: "BaseSans", faceName: "BaseSans · Regular",
      identifier: "base-face")
    let fallback = CustomTextFont(
      program: full, familyName: "FallbackSans", faceName: "FallbackSans · Regular",
      identifier: "fallback-face")
    let base = PageTextFormat(size: 16, customFont: baseFont)

    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "A", format: base)], initial: base,
      licensedFonts: [baseFont, fallback])
    formatting.render(scale: 1, minimumLineSpacing: 19)
    view.setSelectedRange(NSRange(location: 1, length: 0))
    let range = NSRange(location: 1, length: 0)

    var presented: NativeFallbackPreview?
    formatting.fallbackApprovalHandler = { preview in
      presented = preview
      return .approving(["FallbackSans · Regular"])
    }
    let approved = formatting.insertionPlan(
      "B", replacing: range, requestingFallbackApproval: true)
    #expect(approved.issue == nil)
    #expect(presented?.requirements.map(\.character) == ["B"])

    formatting.fallbackApprovalHandler = { _ in nil }
    let cancelled = formatting.insertionPlan(
      "B", replacing: range, requestingFallbackApproval: true)
    #expect(cancelled.issue != nil)
    #expect(cancelled.attributedText == nil)

    formatting.fallbackApprovalHandler = nil
    let noHandler = formatting.insertionPlan(
      "B", replacing: range, requestingFallbackApproval: true)
    #expect(noHandler.issue != nil)
    #expect(noHandler.attributedText == nil)
  }

  @Test @MainActor func approvedFallbackRunSavesIntendedGlyphsAndUnicode() throws {
    let full = try fixtureProgram
    let tiny = try TrueTypeSubsetter.subset(program: full, unicodes: [0x41])
    let baseFont = CustomTextFont(
      program: tiny, familyName: "BaseSans", faceName: "BaseSans · Regular",
      identifier: "base-face")
    let fallback = CustomTextFont(
      program: full, familyName: "FallbackSans", faceName: "FallbackSans · Regular",
      identifier: "fallback-face")
    let base = PageTextFormat(size: 16, customFont: baseFont)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "A", format: base)], initial: base,
      licensedFonts: [baseFont, fallback])
    formatting.render(scale: 1, minimumLineSpacing: 19)
    view.setSelectedRange(NSRange(location: 1, length: 0))
    let caret = NSRange(location: 1, length: 0)
    let plan = formatting.insertionPlan(
      "B", replacing: caret, fallbackApproval: .approving(["FallbackSans · Regular"]))
    let inserted = try #require(plan.attributedText)
    view.insertText(inserted, replacementRange: caret)
    #expect(view.string == "AB")

    let fragments = formatting.fragments()
    #expect(fragments.map(\.text) == ["A", "B"])
    #expect(fragments.map { $0.format.customFont?.identifier } == ["base-face", "fallback-face"])

    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    var x = 48.0
    let segments = fragments.map { fragment -> PageTextSegment in
      let segment = PageTextSegment(text: fragment.text, x: x, format: fragment.format)
      x += 10
      return segment
    }
    let line = PageTextLine(
      text: fragments.map(\.text).joined(), x: 48, baseline: 700, segments: segments)
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 300, lineSpacing: 20)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)]),
      to: parsed.graph)
    let bytes = try PDFWriter.write(graph)
    let reopened = try PDFParser.parse(bytes)
    let content = try PageContent.load(pageID: reopened.pageIDs[0], in: reopened.graph)
    let layout = try PageTextLayout.build(in: content, graph: reopened.graph)
    #expect(layout.lines.count == 1)
    // Extraction uses the written ToUnicode maps: the intended text survives.
    #expect(layout.text(in: layout.lines[0]) == "AB")

    // Exactly the intended glyphs were saved: one subset covers A, the other
    // covers B, so a silently substituted single face cannot explain the text.
    var coverage: [Set<Int>] = []
    for value in reopened.graph.objects.values {
      guard case .dictionary(let dictionary) = value,
        case .reference(let fileID)? = dictionary[PDFName("FontFile2")],
        case .stream(let stream)? = reopened.graph.objects[fileID]
      else { continue }
      let inspector = try TrueTypeInspector.inspect(stream.bytes)
      coverage.append(Set(inspector.unicodeToGlyph.keys))
    }
    #expect(coverage.count == 2)
    #expect(coverage.contains { $0.contains(0x41) && !$0.contains(0x42) })
    #expect(coverage.contains { $0.contains(0x42) && !$0.contains(0x41) })
  }
}
