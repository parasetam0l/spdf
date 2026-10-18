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
  /// Fixed page-space bounds from the actual PDF clipping operators.
  public var clippingRect: [Double]? = nil
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

  /// Refuse to crop any ink while editing a clipped cell. Use actual glyph
  /// outlines and PDF advances rather than a font's much larger line box.
  public static func clippingIssue(lines: [PageTextLine], clippingRect: [Double]?,
    profiles: [PDFName: PageTextFontProfile], nativeFonts: [PDFName: NSFont]? = nil) -> String? {
    guard let clip = clippingRect else { return nil }
    let issue = "Text no longer fits inside its original area. Shorten it, reduce its size, or move it inside the highlighted boundary."
    guard clip.count == 4, clip.allSatisfy(\.isFinite), clip[2] > clip[0], clip[3] > clip[1] else { return issue }
    let embedded = nativeFonts ?? fonts(profiles: profiles)
    for line in lines {
      guard line.text.isEmpty || !line.segments.isEmpty else { return issue }
      for segment in line.segments {
        guard let font = nativeFont(segment.format, embedded: embedded) else { return issue }
        var x = segment.x
        for scalar in segment.text.unicodeScalars {
          guard scalar.value <= 0xFFFF else { return issue }
          var code = UInt16(scalar.value), glyph: CGGlyph = 0
          guard CTFontGetGlyphsForCharacters(font, &code, &glyph, 1), glyph != 0 else { return issue }
          var bounds = CGRect.zero, advance = CGSize.zero
          _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
          _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
          // Empty outlines (spaces) need no clipping margin. A tiny tolerance
          // covers decimal serialization, not intentionally clipped glyphs.
          if !bounds.isEmpty, (x + bounds.minX < clip[0] - 0.002
            || x + bounds.maxX > clip[2] + 0.002
            || line.baseline + bounds.minY < clip[1] - 0.002
            || line.baseline + bounds.maxY > clip[3] + 0.002) { return issue }
          if let source = segment.format.sourceFont {
            guard let mapping = profiles[source.resource]?.glyphs[String(scalar)] else { return issue }
            advance.width = mapping.width * segment.format.size / 1_000
          }
          x += advance.width + segment.format.characterSpacing
        }
      }
    }
    return nil
  }

  /// Embedded source runs already verify their codes, glyph IDs and advances.
  /// Keep their measured geometry even when reader extraction expands a
  /// ligature or splits a word differently. Standard fonts without verified
  /// source metrics still need the reader's visible selection bounds.
  public static func targets(from blocks: [PageTextBlock], pageID: PDFObjectID,
    graph: PDFGraph, page: PDFPage, pageIndex: Int) -> [PageTextTarget] {
    let verified = Set(((try? PageTextEditing.sourceRuns(pageID: pageID, in: graph)) ?? [])
      .filter { $0.format.sourceFont != nil }.map(\.index))
    let string = (page.string ?? "") as NSString
    var used = Set<Int>()
    let aligned: [PageTextTarget] = blocks.compactMap { block in
      guard let first = block.runIndices.first else { return nil }
      let needle = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if needle.isEmpty || block.runIndices.allSatisfy(verified.contains) {
        return PageTextTarget(pageIndex: pageIndex, runIndex: first, rect: block.rect,
          text: block.text, style: block.style, runIndices: block.runIndices)
      }
      var remaining = NSRange(location: 0, length: string.length)
      var matches: [(NSRange, CGRect)] = []
      while remaining.length > 0 {
        let found = string.range(of: needle, range: remaining)
        guard found.location != NSNotFound else { break }
        if !used.contains(found.location), let selection = page.selection(for: found) {
          matches.append((found, selection.bounds(for: page)))
        }
        let next = NSMaxRange(found)
        remaining = NSRange(location: next, length: string.length - next)
      }
      let x = (block.rect[0] + block.rect[2]) / 2, y = (block.rect[1] + block.rect[3]) / 2
      guard let match = matches.min(by: {
        hypot($0.1.midX - x, $0.1.midY - y) < hypot($1.1.midX - x, $1.1.midY - y)
      }) else { return nil }
      used.insert(match.0.location)
      let rect = match.1
      return PageTextTarget(pageIndex: pageIndex, runIndex: first,
        rect: [rect.minX, rect.minY, rect.maxX, rect.maxY], text: block.text,
        style: block.style, runIndices: block.runIndices)
    }
    return targets(from: aligned, pageID: pageID, graph: graph, page: page, pageIndex: pageIndex)
  }

  public static func targets(
    from blocks: [PageTextTarget], pageID: PDFObjectID, graph: PDFGraph, page: PDFPage,
    pageIndex: Int? = nil
  ) -> [PageTextTarget] {
    var owned: [PageTextTarget] = []
    var ownedRuns = Set<Int>()
    let visible = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard let validator = try? PageTextRewriteValidator(pageID: pageID, in: graph) else { return visible }
    guard let separators = try? PageTextEditing.paragraphSeparators(pageID: pageID, in: graph) else { return visible }
    guard let markers = try? PageTextEditing.listMarkers(pageID: pageID, in: graph) else { return visible }
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
      guard (try? validator.validate(originalText: authored.originalText,
        fontSize: initial.format.size, color: initial.format.color,
        standardFontAdvances: advances)) != nil else { continue }
      let clippingRect: [Double]?
      do { clippingRect = try validator.clippingRect(for: indices) } catch { continue }
      guard clippingIssue(lines: authored.lines, clippingRect: clippingRect, profiles: profiles, nativeFonts: embedded) == nil else { continue }
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
          fontProfiles: profiles, clippingRect: clippingRect)))
      ownedRuns.formUnion(indices)
    }
    let imported = importedTargets(from: blocks.filter { ownedRuns.isDisjoint(with: $0.runIndices) },
      pageID: pageID, graph: graph, profiles: profiles, embedded: embedded, validator: validator,
      separators: separators, markers: markers)
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
        if startsListItem(runIndices: block.runIndices, x: block.rect[0],
          baseline: block.rect[1] - font.descender, size: style.fontSize, markers: markers) { break }
        let gap = previous.rect[1] - block.rect[1]
        guard !separators.contains(where: { rule in
          let y = (rule[1] + rule[3]) / 2
          return y > block.rect[1] && y < previous.rect[1]
            && min(rule[0], rule[2]) <= first.rect[0] + 2
            && max(rule[0], rule[2]) >= min(previous.rect[2], block.rect[2]) - 2
        }) else { break }
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
        result.append(editableSingle(first, validator: validator, font: font))
        continue
      }
      let width = (members.map { $0.1.rect[2] }.max() ?? first.rect[2]) - first.rect[0] + 0.75
      let text = members.map { $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: " ")
      let nativeLines = wrappedLines(text, font: font, width: width)
      guard width >= 120,
        nativeLines == members.map({ $0.1.text.trimmingCharacters(in: .whitespacesAndNewlines) })
      else {
        result.append(editableSingle(first, validator: validator, font: font))
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
      guard (try? validator.validate(originalText: original, fontSize: style.fontSize,
        color: style.fillColor, standardFontAdvances: advances)) != nil else {
        result.append(first)
        continue
      }
      // Clipped source targets use the glyph-verified imported path above.
      guard (try? validator.clippingRect(for: original.keys.sorted())) == nil else {
        result.append(first); continue
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
    return result.filter {
      guard !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      // A partially clipped known-font string must not fall back to the
      // legacy unclipped single-line editor after paragraph targeting refuses.
      return $0.paragraph != nil || (try? validator.clippingRect(for: $0.runIndices)) == nil
    }
  }

  static func nativeFont(_ format: PageTextFormat, embedded: [PDFName: NSFont]) -> NSFont? {
    if let source = format.sourceFont {
      guard let font = embedded[source.resource] else { return nil }
      return CTFontCreateCopyWithAttributes(font, format.size, nil, nil) as NSFont
    }
    return NSFont(name: format.font.rawValue, size: format.size)
  }

  /// TextKit measures hmtx advances; PDF paints with its declared /Widths or
  /// /W advances. Apply their verified, bounded difference only to the native
  /// preview. Canonical character spacing stays unchanged for PDF output.
  static func applySourceAdvances(to text: NSMutableAttributedString, range: NSRange,
    format: PageTextFormat, font: NSFont, profiles: [PDFName: PageTextFontProfile], scale: Double = 1) {
    guard let source = format.sourceFont, let profile = profiles[source.resource] else { return }
    let string = text.string as NSString
    for index in range.location..<NSMaxRange(range) {
      let value = string.substring(with: NSRange(location: index, length: 1))
      guard let mapping = profile.glyphs[value], let code = value.utf16.first else { continue }
      var character = code, glyph: CGGlyph = 0, advance = CGSize.zero
      guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { continue }
      _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
      let correction = mapping.width * format.size * scale / 1_000 - advance.width
      text.addAttribute(.kern, value: format.characterSpacing * scale + correction,
        range: NSRange(location: index, length: 1))
    }
  }

  private static func startsListItem(runIndices: [Int], x: Double, baseline: Double, size: Double,
    markers: [PageTextEditing.ListMarker]) -> Bool {
    markers.contains { marker in
      // An inline prefix must belong to this line. A standalone marker can
      // sit just to its left, on the same baseline and within a bounded indent.
      if runIndices.contains(marker.runIndex), abs(marker.x - x) <= 0.75 { return true }
      let gap = x - marker.x
      return marker.isStandalone && gap > 0.75 && gap <= max(size, marker.fontSize) * 3
        && abs(marker.baseline - baseline) <= max(0.5, min(size, marker.fontSize) * 0.08)
    }
  }

  private static func importedTargets(from blocks: [PageTextTarget], pageID: PDFObjectID,
    graph: PDFGraph, profiles: [PDFName: PageTextFontProfile], embedded: [PDFName: NSFont],
    validator: PageTextRewriteValidator, separators: [[Double]],
    markers: [PageTextEditing.ListMarker]) -> [PageTextTarget] {
    struct Span {
      let source: PageTextEditing.SourceRun
      let block: PageTextTarget
      let x: Double
      let width: Double
      let fragments: [PageTextFragment]
    }
    struct Line {
      var spans: [Span]
      var fragments: [PageTextFragment] = []
      var leadingAdvance: Double = 0
      var x: Double { spans[0].x + leadingAdvance }
      var y: Double { spans[0].source.baseline }
      var width: Double { spans.last!.x + spans.last!.width - x }
      var text: String { fragments.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
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
          var advance = size.width
          if let reference = piece.format.sourceFont {
            guard let mapping = profiles[reference.resource]?.glyphs[piece.text],
              mapping.id == nil || mapping.id == Int(glyph),
              abs(size.width * 1_000 / piece.format.size - mapping.width) <= 1.1
            else { valid = false; break }
            advance = mapping.width * piece.format.size / 1_000
          }
          width += advance + piece.format.characterSpacing
        }
        guard valid else { candidate = []; break }
        let x = source.format.sourceFont == nil && source.index == block.runIndices.first ? block.rect[0] : source.x
        candidate.append(Span(source: source, block: block, x: x, width: width, fragments: source.fragments))
      }
      spans += candidate
    }
    spans.sort { abs($0.source.baseline - $1.source.baseline) > 0.02
      ? $0.source.baseline > $1.source.baseline : $0.x < $1.x }
    var lines: [Line] = []
    for span in spans {
      if let last = lines.last, let previous = last.spans.last,
        abs(last.y - span.source.baseline) < 0.02,
        abs(span.x - previous.x - previous.width) <= max(0.75, span.source.format.size * 0.3) {
        lines[lines.count - 1].spans.append(span)
      } else { lines.append(Line(spans: [span])) }
    }
    for index in lines.indices {
      let spans = lines[index].spans
      func spaceWidth(_ format: PageTextFormat, text: String = " ") -> Double? {
        if let source = format.sourceFont {
          return profiles[source.resource]?.glyphs[text].map { $0.width * format.size / 1_000 }
        }
        return standardAdvance(text, family: format.font.rawValue, size: format.size)
      }
      let gaps = zip(spans, spans.dropFirst()).map { $1.x - $0.x - $0.width }
      let wordGaps = gaps.indices.map { index -> Bool in
        guard let last = spans[index].fragments.last, let next = spans[index + 1].fragments.first,
          last.text.last?.isWhitespace == false, next.text.first?.isWhitespace == false,
          let space = spaceWidth(last.format), space > 0 else { return false }
        return gaps[index] >= space * 0.6 && gaps[index] <= space * 1.4
      }
      // Uniform, widely tracked individual letters are ambiguous. Preserve
      // their measured tracking instead of guessing word breaks between them.
      let tracking = spans.allSatisfy { $0.source.text.count == 1 }
        && wordGaps.filter { $0 }.count >= 2 && wordGaps.filter { $0 }.count * 2 >= gaps.count
      var fragments: [PageTextFragment] = []
      for (index, span) in spans.enumerated() {
        var pieces = span.fragments
        if index < gaps.count, let last = pieces.popLast() {
          if wordGaps[index], !tracking, let width = spaceWidth(last.format) {
            pieces.append(last)
            var format = last.format
            format.characterSpacing = gaps[index] - width
            if abs(format.characterSpacing) < 1e-6 { format.characterSpacing = 0 }
            pieces.append(.init(text: " ", format: format))
          } else {
            var format = last.format
            if abs(gaps[index]) > 1e-6 { format.characterSpacing += gaps[index] }
            if abs(format.characterSpacing) < 1e-6 { format.characterSpacing = 0 }
            pieces.append(.init(text: last.text, format: format))
          }
        }
        fragments += pieces
      }
      // Whitespace can position a visible heading far from its text-show
      // origin. Trimming it must advance the editable box by the same PDF
      // distance, otherwise merely selecting the text makes it jump left.
      var leading = 0.0
      while let first = fragments.first, first.text.allSatisfy(\.isWhitespace),
        let advance = spaceWidth(first.format, text: first.text) {
        leading += advance + first.format.characterSpacing
        fragments.removeFirst()
      }
      lines[index].leadingAdvance = leading
      lines[index].fragments = fragments
    }
    var result: [PageTextTarget] = []
    var consumed = Set<Int>()
    for offset in lines.indices where !consumed.contains(offset) {
      let first = lines[offset]
      var members = [first]
      var indices = [offset]
      let size = first.spans.map { $0.source.format.size }.max() ?? 12
      for next in lines.indices.dropFirst(offset + 1) where !consumed.contains(next) {
        let line = lines[next]
        // Other columns can interleave at every baseline. They are neither
        // members nor a reason to stop following this column's prose.
        // The current paragraph model has one left edge. Do not silently
        // straighten indented lines while reconstructing an imported box.
        if abs(line.x - first.x) > 0.02 {
          if line.x + line.width < first.x - 2 || line.x > first.x + first.width + 2 { continue }
          if line.y < members.last!.y - 0.25 { break }
          continue
        }
        let gap = members.last!.y - line.y
        if gap < 0.25 { continue }
        let lineSize = line.spans.map { $0.source.format.size }.max() ?? size
        if startsListItem(runIndices: line.spans.map { $0.source.index }, x: line.x,
          baseline: line.y, size: lineSize, markers: markers) { break }
        let previous = members.last!.text
        let words = previous.split(whereSeparator: \.isWhitespace).count
        let previousLine = members.last!
        if separators.contains(where: { rule in
          let y = (rule[1] + rule[3]) / 2
          return y > line.y && y < previousLine.y
            && min(rule[0], rule[2]) <= first.x + 2
            && max(rule[0], rule[2]) >= min(previousLine.x + previousLine.width, line.x + line.width) - 2
        }) { break }
        guard words >= 4 || (words >= 3 && previous.count >= 24),
          abs(lineSize - size) <= 0.5, gap >= size * 0.95, gap <= size * 1.75,
          members.count == 1 || abs(gap - (first.y - members[1].y)) < 0.5 else { break }
        members.append(line); indices.append(next)
        if members.count == 100 { break }
      }
      func target(_ members: [Line]) -> PageTextTarget? {
        let first = members[0]
        let all = members.flatMap(\.spans)
        let formats = all.flatMap(\.fragments).map(\.format)
        guard let initial = formats.first,
          formats.contains(where: { $0.sourceFont != nil || $0 != initial || $0.characterSpacing != 0 })
            || all.contains(where: { $0.block.runIndices.count > 1 || abs($0.source.textScale - 1) > 1e-6 }) else { return nil }
        var fragments: [PageTextFragment] = []
        for (index, line) in members.enumerated() {
          var parts = line.fragments
          while parts.last?.text.allSatisfy(\.isWhitespace) == true { parts.removeLast() }
          while parts.first?.text.allSatisfy(\.isWhitespace) == true { parts.removeFirst() }
          fragments += parts
          if index + 1 < members.count, let last = parts.last, !line.text.hasSuffix("-") {
            var format = last.format; format.characterSpacing = 0
            fragments.append(.init(text: " ", format: format))
          }
        }
        let width = max(24, members.map(\.width).max()! + 0.75)
        let spacing = members.count > 1 ? first.y - members[1].y : initial.size * 1.2
        guard let layout = nativeLayout(fragments, embedded: embedded, profiles: profiles, width: width, spacing: spacing),
          layout.text == members.map(\.text),
          zip(layout.baselines, members).allSatisfy({ abs($0.0 - (first.y - $0.1.y)) < 0.02 }) else { return nil }
        let original = Dictionary(uniqueKeysWithValues: all.map { ($0.source.index, $0.source.text) })
        var advances: [Int: Double] = [:]
        for span in all where span.source.format.sourceFont == nil {
          advances[span.source.index] = standardAdvance(span.source.text,
            family: span.source.format.font.rawValue, size: span.source.format.size / span.source.textScale)
        }
        guard (try? validator.validate(originalText: original,
          fontSize: initial.size, color: initial.color, standardFontAdvances: advances)) != nil
        else { return nil }
        let clippingRect: [Double]?
        do { clippingRect = try validator.clippingRect(for: original.keys.sorted()) } catch { return nil }
        // Fully visible source ink is a prerequisite; never expose a source
        // string that the original document deliberately clipped away.
        let sourceLines = all.map { span in
          var x = span.x
          let segments = span.fragments.map { fragment -> PageTextSegment in
            defer {
              let advance: Double
              if let source = fragment.format.sourceFont,
                let mapping = profiles[source.resource]?.glyphs[fragment.text] {
                advance = mapping.width * fragment.format.size / 1_000
              } else {
                advance = standardAdvance(fragment.text, family: fragment.format.font.rawValue, size: fragment.format.size) ?? 0
              }
              x += advance + fragment.format.characterSpacing
            }
            return .init(text: fragment.text, x: x, format: fragment.format)
          }
          return PageTextLine(text: span.source.text, x: span.x, baseline: span.source.baseline, segments: segments)
        }
        guard clippingIssue(lines: sourceLines, clippingRect: clippingRect, profiles: profiles, nativeFonts: embedded) == nil else { return nil }
        return PageTextTarget(pageIndex: all[0].block.pageIndex, runIndex: all[0].source.index,
          rect: [first.x, all.map { $0.block.rect[1] }.min()!, first.x + width,
            all.map { $0.block.rect[3] }.max()!], text: fragments.map(\.text).joined(),
          style: .init(fontFamily: initial.fontName, fontSize: initial.size, fillColor: initial.color),
          runIndices: all.map { $0.source.index }, paragraph: .init(originalText: original,
            lineSpacing: spacing, firstBaseline: first.y, standardFontAdvances: advances,
            fragments: fragments, wraps: members.count > 1, fontProfiles: profiles, clippingRect: clippingRect))
      }
      // A short final line may be followed immediately by a new paragraph.
      // Find the longest prefix that actually reproduces the source wrapping;
      // never turn the whole column into one box just because its leading fits.
      var accepted: PageTextTarget?
      var count = members.count
      while count >= 2 {
        if let grouped = target(Array(members.prefix(count))) { accepted = grouped; break }
        count -= 1
      }
      if let accepted {
        result.append(accepted)
        consumed.formUnion(indices.prefix(count))
      } else if let single = target([first]) {
        result.append(single)
        consumed.insert(offset)
      }
    }
    return result
  }

  private static func nativeLayout(_ fragments: [PageTextFragment], embedded: [PDFName: NSFont],
    profiles: [PDFName: PageTextFontProfile], width: Double, spacing: Double) -> (text: [String], baselines: [Double])? {
    let attributed = NSMutableAttributedString(string: "")
    let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = spacing
    paragraph.maximumLineHeight = max(spacing, fragments.map { $0.format.size }.max() ?? spacing)
    for fragment in fragments {
      guard let font = nativeFont(fragment.format, embedded: embedded) else { return nil }
      let start = attributed.length
      attributed.append(NSAttributedString(string: fragment.text, attributes: [
        .font: font, .kern: fragment.format.characterSpacing, .ligature: 0, .paragraphStyle: paragraph]))
      applySourceAdvances(to: attributed, range: NSRange(location: start, length: (fragment.text as NSString).length),
        format: fragment.format, font: font, profiles: profiles)
    }
    let storage = NSTextStorage(attributedString: attributed)
    let manager = NSLayoutManager()
    manager.usesFontLeading = false
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

  private static func editableSingle(_ target: PageTextTarget, validator: PageTextRewriteValidator,
    font: NSFont) -> PageTextTarget {
    guard let style = target.style, let family = style.fontFamily,
      let face = StandardTextFont(rawValue: family), target.runIndices.count == 1,
      let advance = standardAdvance(target.text, family: family, size: style.fontSize)
    else { return target }
    let original = [target.runIndex: target.text]
    let advances = [target.runIndex: advance]
    guard (try? validator.validate(originalText: original,
      fontSize: style.fontSize, color: style.fillColor,
      standardFontAdvances: advances)) != nil else { return target }
    guard (try? validator.clippingRect(for: [target.runIndex])) == nil else { return target }
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
