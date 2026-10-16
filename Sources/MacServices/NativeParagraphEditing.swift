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
  public let fragments: [PageTextFragment]
  public let wraps: Bool
  public var fontProfiles: [PDFName: PageTextFontProfile] = [:]
}

/// Reconstruct a paragraph only when its source lines round-trip through
/// native wrapping. A nearby label, heading or column is not enough evidence.
@MainActor
public enum NativeParagraphEditing {
  public static func fonts(profiles: [PDFName: PageTextFontProfile]) -> [PDFName: NSFont] {
    profiles.compactMapValues { profile in
      guard let program = profile.previewProgram,
        let provider = CGDataProvider(data: program as CFData),
        let graphics = CGFont(provider) else { return nil }
      return CTFontCreateWithGraphicsFont(graphics, 1_000, nil, nil) as NSFont
    }
  }

  public static func targets(
    from blocks: [PageTextTarget], pageID: PDFObjectID, graph: PDFGraph, page: PDFPage,
    pageIndex: Int? = nil
  ) -> [PageTextTarget] {
    var owned: [PageTextTarget] = []
    var ownedRuns = Set<Int>()
    let standardRuns = Set((try? StandardTextFont.editableRunIndices(pageID: pageID, in: graph)) ?? [])
    let profiles = (try? PageTextEditing.fontProfiles(pageID: pageID, in: graph)) ?? [:]
    let embedded = fonts(profiles: profiles)
    for authored in (try? AuthoredPageTextBoxes.read(pageID: pageID, in: graph)) ?? [] {
      let indices = authored.originalText.keys.sorted()
      guard let first = indices.first, let initial = authored.fragments.first else { continue }
      let segments = authored.lines.flatMap(\.segments)
      var advances: [Int: Double] = [:]
      for (index, segment) in zip(indices, segments) {
        advances[index] = standardAdvance(segment.text,
          family: segment.format.sourceFont == nil ? segment.format.font.rawValue : nil, size: segment.format.size)
      }
      guard authored.fragments.allSatisfy({ nativeFont($0.format, embedded: embedded) != nil }) else { continue }
      guard (try? RewritePageTextCommand(pageID: pageID, originalText: authored.originalText,
        lines: [], fontSize: initial.format.size, color: initial.format.color,
        standardFontAdvances: advances).validate(in: graph)) != nil else { continue }
      var bottom = authored.box.firstBaseline
      var top = authored.box.firstBaseline
      for line in authored.lines {
        for segment in line.segments {
          guard let font = nativeFont(segment.format, embedded: embedded) else { continue }
          bottom = min(bottom, line.baseline + font.descender)
          top = max(top, line.baseline + font.ascender)
        }
        bottom = min(bottom, line.baseline - initial.format.size * 0.2)
      }
      owned.append(PageTextTarget(pageIndex: pageIndex ?? blocks.first?.pageIndex ?? 0, runIndex: first,
        rect: [authored.box.x, bottom, authored.box.x + authored.box.width, top],
        text: authored.fragments.map(\.text).joined(),
        style: .init(fontFamily: initial.format.fontName, fontSize: initial.format.size,
          fillColor: initial.format.color), runIndices: indices,
        paragraph: PageTextParagraph(originalText: authored.originalText,
          lineSpacing: authored.box.lineSpacing, firstBaseline: authored.box.firstBaseline,
          standardFontAdvances: advances, fragments: authored.fragments, wraps: authored.box.wraps,
          fontProfiles: profiles)))
      ownedRuns.formUnion(indices)
    }
    let imported = importedTargets(from: blocks.filter { ownedRuns.isDisjoint(with: $0.runIndices) },
      pageID: pageID, graph: graph, profiles: profiles, embedded: embedded)
    owned += imported
    ownedRuns.formUnion(imported.flatMap(\.runIndices))
    let ordered = blocks.filter { ownedRuns.isDisjoint(with: $0.runIndices) }.sorted {
      $0.rect[3] == $1.rect[3] ? $0.rect[0] < $1.rect[0] : $0.rect[3] > $1.rect[3]
    }
    var consumed = Set<Int>()
    var result: [PageTextTarget] = owned
    for (offset, first) in ordered.enumerated() where !consumed.contains(offset) {
      guard let style = first.style, first.runIndices.count == 1,
        standardRuns.contains(first.runIndex),
        RewritePageTextCommand.standardFonts.contains(style.fontFamily ?? ""),
        let font = font(for: first, page: page)
      else {
        result.append(first)
        continue
      }
      var members = [(offset, first)]
      for (index, block) in ordered.enumerated().dropFirst(offset + 1) {
        guard !consumed.contains(index), block.style == style, block.runIndices.count == 1,
          standardRuns.contains(block.runIndex),
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
        result.append(editableSingle(first, pageID: pageID, graph: graph, font: font))
        continue
      }
      let width = (members.map { $0.1.rect[2] }.max() ?? first.rect[2]) - first.rect[0] + 0.75
      let text = members.map { $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: " ")
      let nativeLines = wrappedLines(text, font: font, width: width)
      guard width >= 120,
        nativeLines == members.map({ $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines) })
      else {
        result.append(editableSingle(first, pageID: pageID, graph: graph, font: font))
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
            standardFontAdvances: advances,
            fragments: [.init(text: text, format: .init(
              font: StandardTextFont(rawValue: style.fontFamily ?? "")!,
              size: style.fontSize, color: style.fillColor))], wraps: true)))
      consumed.formUnion(members.dropFirst().map(\.0))
    }
    return result
  }

  static func nativeFont(_ format: PageTextFormat, embedded: [PDFName: NSFont]) -> NSFont? {
    if let source = format.sourceFont {
      guard let font = embedded[source.resource] else { return nil }
      return CTFontCreateCopyWithAttributes(font, format.size, nil, nil) as NSFont
    }
    return NSFont(name: format.font.rawValue, size: format.size)
  }

  private static func importedTargets(from blocks: [PageTextTarget], pageID: PDFObjectID,
    graph: PDFGraph, profiles: [PDFName: PageTextFontProfile], embedded: [PDFName: NSFont]) -> [PageTextTarget] {
    struct Span {
      let source: PageTextEditing.SourceRun
      let block: PageTextTarget
      let x: Double
      let width: Double
      let fragments: [PageTextFragment]
    }
    struct Line {
      var spans: [Span]
      var x: Double { spans[0].x }
      var y: Double { spans[0].source.baseline }
      var width: Double { spans.last!.x + spans.last!.width - x }
      var text: String { spans.map { $0.source.text }.joined().trimmingCharacters(in: .whitespaces) }
    }
    let sources = (try? PageTextEditing.sourceRuns(pageID: pageID, in: graph)) ?? []
    var spans: [Span] = []
    for block in blocks {
      let members = sources.filter { block.runIndices.contains($0.index) }
      guard members.count == block.runIndices.count,
        members.map(\.text).joined() == block.text else { continue }
      var candidate: [Span] = []
      for source in members {
        var width = 0.0
        var valid = true
        for piece in source.fragments {
          guard let font = nativeFont(piece.format, embedded: embedded), piece.text.utf16.count == 1,
            let character = piece.text.utf16.first else { valid = false; break }
          var code = character
          var glyph: CGGlyph = 0
          guard CTFontGetGlyphsForCharacters(font, &code, &glyph, 1), glyph != 0 else { valid = false; break }
          var size = CGSize.zero
          _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &size, 1)
          if let reference = piece.format.sourceFont {
            guard let mapping = profiles[reference.resource]?.glyphs[piece.text],
              mapping.id == nil || mapping.id == Int(glyph),
              abs(size.width * 1_000 / piece.format.size - mapping.width) <= 1.1
            else { valid = false; break }
          }
          width += size.width + piece.format.characterSpacing
        }
        guard valid else { candidate = []; break }
        let x = source.format.sourceFont == nil && source.index == block.runIndices.first ? block.rect[0] : source.x
        candidate.append(Span(source: source, block: block, x: x, width: width, fragments: source.fragments))
      }
      spans += candidate
    }
    spans.sort { abs($0.source.baseline - $1.source.baseline) > 0.25
      ? $0.source.baseline > $1.source.baseline : $0.x < $1.x }
    var lines: [Line] = []
    for span in spans {
      if let last = lines.last, let previous = last.spans.last,
        abs(last.y - span.source.baseline) < 0.25,
        abs(span.x - previous.x - previous.width) <= max(0.75, span.source.format.size * 0.3) {
        lines[lines.count - 1].spans.append(span)
      } else { lines.append(Line(spans: [span])) }
    }
    var result: [PageTextTarget] = []
    var offset = 0
    while offset < lines.count {
      let first = lines[offset]
      var members = [first]
      var next = offset + 1
      while next < lines.count, members.last!.text.split(whereSeparator: \.isWhitespace).count >= 4 {
        let line = lines[next]
        let size = first.spans.map { $0.source.format.size }.max() ?? 12
        let gap = members.last!.y - line.y
        guard abs(line.x - first.x) <= 2, gap >= size * 0.95, gap <= size * 1.75,
          members.count == 1 || abs(gap - (first.y - members[1].y)) < 0.5 else { break }
        members.append(line); next += 1
      }
      func target(_ members: [Line]) -> PageTextTarget? {
        let all = members.flatMap(\.spans)
        let formats = all.flatMap(\.fragments).map(\.format)
        guard let initial = formats.first,
          formats.contains(where: { $0.sourceFont != nil || $0 != initial || $0.characterSpacing != 0 })
            || all.contains(where: { $0.block.runIndices.count > 1 || abs($0.source.textScale - 1) > 1e-6 }) else { return nil }
        var fragments: [PageTextFragment] = []
        for (index, line) in members.enumerated() {
          var parts: [PageTextFragment] = []
          for (index, span) in line.spans.enumerated() {
            var pieces = span.fragments
            if index + 1 < line.spans.count, let last = pieces.popLast() {
              var format = last.format
              format.characterSpacing += line.spans[index + 1].x - span.x - span.width
              pieces.append(.init(text: last.text, format: format))
            }
            parts += pieces
          }
          while parts.last?.text.allSatisfy(\.isWhitespace) == true { parts.removeLast() }
          while parts.first?.text.allSatisfy(\.isWhitespace) == true { parts.removeFirst() }
          fragments += parts
          if index + 1 < members.count, let last = parts.last {
            var format = last.format; format.characterSpacing = 0
            fragments.append(.init(text: " ", format: format))
          }
        }
        let width = max(24, members.map(\.width).max()! + 0.75)
        let spacing = members.count > 1 ? first.y - members[1].y : initial.size * 1.2
        guard let layout = nativeLayout(fragments, embedded: embedded, width: width, spacing: spacing),
          layout.text == members.map(\.text),
          zip(layout.baselines, members).allSatisfy({ abs($0.0 - (first.y - $0.1.y)) < 0.5 }) else { return nil }
        let original = Dictionary(uniqueKeysWithValues: all.map { ($0.source.index, $0.source.text) })
        var advances: [Int: Double] = [:]
        for span in all where span.source.format.sourceFont == nil {
          advances[span.source.index] = standardAdvance(span.source.text,
            family: span.source.format.font.rawValue, size: span.source.format.size / span.source.textScale)
        }
        guard (try? RewritePageTextCommand(pageID: pageID, originalText: original, lines: [],
          fontSize: initial.size, color: initial.color, standardFontAdvances: advances).validate(in: graph)) != nil
        else { return nil }
        return PageTextTarget(pageIndex: all[0].block.pageIndex, runIndex: all[0].source.index,
          rect: [first.x, all.map { $0.block.rect[1] }.min()!, first.x + width,
            all.map { $0.block.rect[3] }.max()!], text: fragments.map(\.text).joined(),
          style: .init(fontFamily: initial.fontName, fontSize: initial.size, fillColor: initial.color),
          runIndices: all.map { $0.source.index }, paragraph: .init(originalText: original,
            lineSpacing: spacing, firstBaseline: first.y, standardFontAdvances: advances,
            fragments: fragments, wraps: members.count > 1, fontProfiles: profiles))
      }
      if let grouped = target(members) { result.append(grouped); offset = next }
      else { if let single = target([first]) { result.append(single) }; offset += 1 }
    }
    return result
  }

  private static func nativeLayout(_ fragments: [PageTextFragment], embedded: [PDFName: NSFont],
    width: Double, spacing: Double) -> (text: [String], baselines: [Double])? {
    let attributed = NSMutableAttributedString(string: "")
    let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = spacing
    for fragment in fragments {
      guard let font = nativeFont(fragment.format, embedded: embedded) else { return nil }
      attributed.append(NSAttributedString(string: fragment.text, attributes: [
        .font: font, .kern: fragment.format.characterSpacing, .ligature: 0, .paragraphStyle: paragraph]))
    }
    let storage = NSTextStorage(attributedString: attributed)
    let manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: width, height: 1_000_000))
    container.lineFragmentPadding = 0; storage.addLayoutManager(manager); manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    var text: [String] = []; var baselines: [Double] = []
    manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
      rect, _, _, glyphs, _ in
      let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      text.append((storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
      baselines.append(rect.minY + manager.location(forGlyphAt: glyphs.location).y)
    }
    let first = baselines.first ?? 0
    return (text, baselines.map { $0 - first })
  }

  private static func editableSingle(_ target: PageTextTarget, pageID: PDFObjectID,
    graph: PDFGraph, font: NSFont) -> PageTextTarget {
    guard let style = target.style, let family = style.fontFamily,
      let face = StandardTextFont(rawValue: family), target.runIndices.count == 1,
      let advance = standardAdvance(target.text, family: family, size: style.fontSize)
    else { return target }
    let original = [target.runIndex: target.text]
    let advances = [target.runIndex: advance]
    guard (try? RewritePageTextCommand(pageID: pageID, originalText: original,
      lines: [], fontSize: style.fontSize, color: style.fillColor,
      standardFontAdvances: advances).validate(in: graph)) != nil else { return target }
    var rect = target.rect
    rect[2] = rect[0] + max(24, rect[2] - rect[0] + 0.75)
    return PageTextTarget(pageIndex: target.pageIndex, runIndex: target.runIndex,
      rect: rect, text: target.text, style: style, runIndices: target.runIndices,
      paragraph: .init(originalText: original, lineSpacing: style.fontSize * 1.2,
        firstBaseline: rect[1] - font.descender, standardFontAdvances: advances,
        fragments: [.init(text: target.text, format: .init(font: face, size: style.fontSize,
          color: style.fillColor))], wraps: false))
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
