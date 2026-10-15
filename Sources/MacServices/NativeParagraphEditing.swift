import AppKit
import CoreText
import PDFCore
import PDFEditing
import PDFKit

public struct PageTextParagraph: Sendable, Equatable {
  public let originalText: [Int: String]
  public let lineSpacing: Double
  public let firstBaseline: Double
  public let standardFontAdvances: [Int: Double]
}

/// Reconstruct a paragraph only when its source lines round-trip through
/// native wrapping. A nearby label, heading or column is not enough evidence.
@MainActor
public enum NativeParagraphEditing {
  public static func targets(
    from blocks: [PageTextTarget], pageID: PDFObjectID, graph: PDFGraph, page: PDFPage
  ) -> [PageTextTarget] {
    let ordered = blocks.sorted {
      $0.rect[3] == $1.rect[3] ? $0.rect[0] < $1.rect[0] : $0.rect[3] > $1.rect[3]
    }
    var consumed = Set<Int>()
    var result: [PageTextTarget] = []
    for (offset, first) in ordered.enumerated() where !consumed.contains(offset) {
      guard let style = first.style, first.runIndices.count == 1,
        RewritePageTextCommand.standardFonts.contains(style.fontFamily ?? ""),
        let font = font(for: first, page: page)
      else {
        result.append(first)
        continue
      }
      var members = [(offset, first)]
      for (index, block) in ordered.enumerated().dropFirst(offset + 1) {
        guard !consumed.contains(index), block.style == style, block.runIndices.count == 1,
          abs(block.rect[0] - first.rect[0]) <= 2,
          let previous = members.last?.1
        else { continue }
        let gap = previous.rect[1] - block.rect[1]
        guard gap >= style.fontSize * 0.95, gap <= style.fontSize * 1.75 else { continue }
        if members.count > 1 {
          let spacing = members[0].1.rect[1] - members[1].1.rect[1]
          guard abs(gap - spacing) < 0.75 else { continue }
        }
        // A short label must not recruit the next label into a paragraph.
        guard previous.text.split(whereSeparator: \.isWhitespace).count >= 4 else { break }
        members.append((index, block))
        if members.count == 100 { break }
      }
      guard members.count >= 2 else {
        result.append(first)
        continue
      }
      let width = (members.map { $0.1.rect[2] }.max() ?? first.rect[2]) - first.rect[0] + 0.75
      let text = members.map { $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: " ")
      let nativeLines = wrappedLines(text, font: font, width: width)
      guard width >= 120,
        nativeLines == members.map({ $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines) })
      else {
        result.append(first)
        continue
      }
      let original = Dictionary(uniqueKeysWithValues: members.map { ($0.1.runIndex, $0.1.text) })
      var advances: [Int: Double] = [:]
      for (_, member) in members {
        if let value = standardAdvance(member.text, family: style.fontFamily, size: style.fontSize)
        {
          advances[member.runIndex] = value
        }
      }
      let probe = RewritePageTextCommand(
        pageID: pageID, originalText: original, lines: [], fontSize: style.fontSize,
        color: style.fillColor, standardFontAdvances: advances)
      guard (try? probe.validate(in: graph)) != nil else {
        result.append(first)
        continue
      }
      let rect = [
        first.rect[0], members.map { $0.1.rect[1] }.min()!,
        first.rect[0] + width, first.rect[3],
      ]
      result.append(
        PageTextTarget(
          pageIndex: first.pageIndex, runIndex: first.runIndex, rect: rect, text: text,
          style: style, runIndices: members.map { $0.1.runIndex },
          paragraph: PageTextParagraph(
            originalText: original,
            lineSpacing: members[0].1.rect[1] - members[1].1.rect[1],
            firstBaseline: first.rect[1] - font.descender,
            standardFontAdvances: advances)))
      consumed.formUnion(members.dropFirst().map(\.0))
    }
    return result
  }

  public static func font(for target: PageTextTarget, page: PDFPage) -> NSFont? {
    let rect = target.rect
    guard rect.count == 4 else { return nil }
    let selection = page.selection(
      for: CGRect(
        x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1]))
    if let text = selection?.attributedString, text.length > 0,
      let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    {
      return font
    }
    guard let style = target.style, let family = style.fontFamily else { return nil }
    return NSFont(name: family, size: style.fontSize)
  }

  public static func wrappedLines(_ text: String, font: NSFont, width: Double) -> [String] {
    let storage = NSTextStorage(string: text, attributes: [.font: font, .kern: 0, .ligature: 0])
    let manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: width, height: 1_000_000))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    var lines: [String] = []
    manager.enumerateLineFragments(
      forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)
    ) {
      _, _, _, glyphs, _ in
      let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      lines.append(
        (text as NSString).substring(with: characters)
          .trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return lines
  }

  public static func standardAdvance(_ text: String, family: String?, size: Double) -> Double? {
    guard let family, RewritePageTextCommand.standardFonts.contains(family),
      let font = NSFont(name: family, size: 1_000)
    else { return nil }
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
      return nil
    }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    // PDF Standard-14 metrics are integer thousandths. CoreText exposes the
    // installed outline's fractional em values; normalize per glyph before
    // scaling so removing a long source string does not accumulate drift.
    return advances.reduce(0) { $0 + $1.width.rounded() * size / 1_000 }
  }
}
