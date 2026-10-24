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
  /// Scalar counts assigned to each source run after accounting for visual
  /// word spaces inferred between adjacent PDF text runs.
  public var sourceRunOutputCounts: [Int: Int] = [:]
  public var fontProfiles: [PDFName: PageTextFontProfile] = [:]
  /// Fixed page-space bounds from the actual PDF clipping operators.
  public var clippingRect: [Double]? = nil
}

/// Reconstruct a paragraph only when its source lines round-trip through
/// native wrapping. A nearby label, heading or column is not enough evidence.
@MainActor
public enum NativeParagraphEditing {
  private struct SourceGlyphPiece {
    let text: String
    let mapping: PageTextFontProfile.Glyph
    let range: NSRange
    let profile: PageTextFontProfile
  }

  /// Match decoded text using the longest verified PDF glyph sequence first.
  /// A ToUnicode ligature such as `fl` is one source glyph even though the
  /// native string contains two Unicode scalars. Missing glyphs may come from
  /// another subset already used by this page, under the same face and
  /// matching shared metrics that the rewrite planner requires.
  private static func sourceGlyphPieces(in text: String,
    preferredProfile: PageTextFontProfile,
    profiles: [PDFName: PageTextFontProfile],
    metricWitnessText: String) -> [SourceGlyphPiece]? {
    let alternatives = profiles.keys.sorted().compactMap { profiles[$0] }.filter { candidate in
      candidate.source.resource != preferredProfile.source.resource
        && PageTextFontCapability.canUseSubset(
          source: preferredProfile, candidate: candidate, witnessText: metricWitnessText)
    }
    let orderedProfiles = [preferredProfile] + alternatives
    let candidates = orderedProfiles.enumerated().flatMap { profileIndex, profile in
      profile.glyphs.map { value, mapping in
        (text: value, mapping: mapping, profile: profile,
          profileIndex: profileIndex, scalars: value.unicodeScalars.map(\.value))
      }
    }.filter { !$0.scalars.isEmpty }.sorted {
      if $0.scalars.count != $1.scalars.count { return $0.scalars.count > $1.scalars.count }
      if $0.profileIndex != $1.profileIndex { return $0.profileIndex < $1.profileIndex }
      return $0.text < $1.text
    }
    let scalars = Array(text.unicodeScalars.map(\.value))
    var scalarOffset = 0
    var utf16Offset = 0
    var pieces: [SourceGlyphPiece] = []
    while scalarOffset < scalars.count {
      guard let candidate = candidates.first(where: { value in
        scalarOffset + value.scalars.count <= scalars.count
          && scalars[scalarOffset..<scalarOffset + value.scalars.count].elementsEqual(value.scalars)
      }) else { return nil }
      let length = candidate.text.utf16.count
      pieces.append(.init(text: candidate.text, mapping: candidate.mapping,
        range: NSRange(location: utf16Offset, length: length), profile: candidate.profile))
      scalarOffset += candidate.scalars.count
      utf16Offset += length
    }
    return pieces
  }

  /// Returns the text-bearing range of a visual line. TextKit includes the
  /// separator space that caused a soft wrap in the preceding line's range;
  /// that separator should not be serialized as trailing PDF text. Explicit
  /// paragraph breaks keep any whitespace entered before the break.
  public static func lineContentRange(_ range: NSRange, in text: NSString,
    hasHardBreak: Bool) -> NSRange {
    var end = NSMaxRange(range)
    guard range.location >= 0, range.length >= 0, end <= text.length else { return range }
    while end > range.location {
      let unit = text.character(at: end - 1)
      guard unit == 0x0A || unit == 0x0D else { break }
      end -= 1
    }
    if !hasHardBreak {
      while end > range.location {
        let unit = text.character(at: end - 1)
        guard let scalar = UnicodeScalar(unit),
          CharacterSet.whitespaces.contains(scalar)
        else { break }
        end -= 1
      }
    }
    return NSRange(location: range.location, length: end - range.location)
  }

  /// Chooses the paragraph target nearest the pointer when line-sized
  /// candidates overlap. A paragraph still wins over legacy run targets.
  public static func preferredHitTarget(from candidates: [PageTextTarget],
    at pagePoint: [Double]) -> PageTextTarget? {
    let paragraphs = candidates.filter { $0.paragraph != nil }
    guard pagePoint.count == 2, pagePoint.allSatisfy(\.isFinite) else {
      return paragraphs.first ?? candidates.first
    }
    return paragraphs.min(by: { lhs, rhs in
      func distance(_ target: PageTextTarget) -> Double {
        guard target.rect.count == 4, target.rect.allSatisfy(\.isFinite) else {
          return .infinity
        }
        return hypot(pagePoint[0] - (target.rect[0] + target.rect[2]) / 2,
          pagePoint[1] - (target.rect[1] + target.rect[3]) / 2)
      }
      let lhsDistance = distance(lhs), rhsDistance = distance(rhs)
      if abs(lhsDistance - rhsDistance) > 0.01 { return lhsDistance < rhsDistance }
      if lhs.runIndices.count != rhs.runIndices.count {
        return lhs.runIndices.count > rhs.runIndices.count
      }
      if lhs.text.utf16.count != rhs.text.utf16.count {
        return lhs.text.utf16.count > rhs.text.utf16.count
      }
      return lhs.paragraph?.wraps == true && rhs.paragraph?.wraps == false
    }) ?? candidates.first
  }

  public static func fonts(profiles: [PDFName: PageTextFontProfile]) -> [PDFName: NSFont] {
    profiles.compactMapValues { profile in
      guard let program = profile.previewProgram ?? CFFPreviewFont.program(profile),
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
        var x = segment.x
        if let source = segment.format.sourceFont {
          guard let profile = profiles[source.resource],
            let pieces = sourceGlyphPieces(in: segment.text,
              preferredProfile: profile, profiles: profiles,
              metricWitnessText: line.text) else { return issue }
          for piece in pieces {
            guard let id = piece.mapping.id, id > 0, id <= Int(UInt16.max) else { return issue }
            guard let baseFont = embedded[piece.profile.source.resource] else { return issue }
            let font = CTFontCreateCopyWithAttributes(
              baseFont, segment.format.size, nil, nil) as NSFont
            var glyph = CGGlyph(id), bounds = CGRect.zero
            _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
            let syntheticExpansion = segment.format.syntheticBoldStrokeWidth / 2
            let lowerShear = segment.format.obliqueness * Double(bounds.minY)
            let upperShear = segment.format.obliqueness * Double(bounds.maxY)
            let minShear = min(lowerShear, upperShear)
            let maxShear = max(lowerShear, upperShear)
            // Empty outlines (spaces) need no clipping margin. A tiny tolerance
            // covers decimal serialization, not intentionally clipped glyphs.
            if !bounds.isEmpty, (x + bounds.minX + minShear - syntheticExpansion < clip[0] - 0.002
              || x + bounds.maxX + maxShear + syntheticExpansion > clip[2] + 0.002
              || line.baseline + bounds.minY - syntheticExpansion < clip[1] - 0.002
              || line.baseline + bounds.maxY + syntheticExpansion > clip[3] + 0.002) { return issue }
            x += piece.mapping.width * segment.format.size / 1_000 + segment.format.characterSpacing
          }
        } else {
          guard let font = nativeFont(segment.format, embedded: embedded) else { return issue }
          for scalar in segment.text.unicodeScalars {
            guard scalar.value <= 0xFFFF else { return issue }
            var code = UInt16(scalar.value), glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &code, &glyph, 1), glyph != 0 else { return issue }
            var bounds = CGRect.zero, advance = CGSize.zero
            _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let syntheticExpansion = segment.format.syntheticBoldStrokeWidth / 2
            let lowerShear = segment.format.obliqueness * Double(bounds.minY)
            let upperShear = segment.format.obliqueness * Double(bounds.maxY)
            let minShear = min(lowerShear, upperShear)
            let maxShear = max(lowerShear, upperShear)
            if !bounds.isEmpty, (x + bounds.minX + minShear - syntheticExpansion < clip[0] - 0.002
              || x + bounds.maxX + maxShear + syntheticExpansion > clip[2] + 0.002
              || line.baseline + bounds.minY - syntheticExpansion < clip[1] - 0.002
              || line.baseline + bounds.maxY + syntheticExpansion > clip[3] + 0.002) { return issue }
            x += advance.width + segment.format.characterSpacing
          }
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
    graph: PDFGraph, page: PDFPage, pageIndex: Int,
    diagnostic: ((String) -> Void)? = nil
  ) -> [PageTextTarget] {
    let sourceRuns: [PageTextEditing.SourceRun]
    do {
      sourceRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: graph)
    } catch {
      diagnostic?("source-runs-unavailable: \(error)")
      sourceRuns = []
    }
    let verified = Set(sourceRuns.filter { $0.format.sourceFont != nil }.map(\.index))
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
    return targets(from: aligned, pageID: pageID, graph: graph, page: page,
      pageIndex: pageIndex, diagnostic: diagnostic)
  }

  public static func targets(
    from blocks: [PageTextTarget], pageID: PDFObjectID, graph: PDFGraph, page: PDFPage,
    pageIndex: Int? = nil, diagnostic: ((String) -> Void)? = nil
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
      guard clippingIssue(lines: authored.lines, clippingRect: clippingRect,
        profiles: profiles, nativeFonts: embedded) == nil else { continue }
      let rect = paragraphBounds(lines: authored.lines, firstBaseline: authored.box.firstBaseline,
        initialFontSize: initial.format.size, x: authored.box.x, width: authored.box.width,
        embedded: embedded)
      owned.append(PageTextTarget(pageIndex: pageIndex ?? blocks.first?.pageIndex ?? 0, runIndex: first,
        rect: rect,
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
      separators: separators, markers: markers, diagnostic: diagnostic)
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
    if let custom = format.customFont {
      guard let font = ProvisionedFontStore.coreTextFont(
        program: custom.program, size: format.size) else {
        return nil
      }
      return font as NSFont
    }
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
    guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= string.length,
      let pieces = sourceGlyphPieces(in: string.substring(with: range),
        preferredProfile: profile, profiles: [source.resource: profile],
        metricWitnessText: string.substring(with: range)) else { return }
    for piece in pieces {
      guard let id = piece.mapping.id, id > 0, id <= Int(UInt16.max) else { continue }
      let glyph = CGGlyph(id)
      if piece.text.unicodeScalars.count > 1 {
        guard let glyphInfo = NSGlyphInfo(cgGlyph: glyph, for: font, baseString: piece.text) else { continue }
        text.addAttribute(.glyphInfo, value: glyphInfo,
          range: NSRange(location: range.location + piece.range.location, length: piece.range.length))
      }
      var measuredGlyph = glyph, advance = CGSize.zero
      _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &measuredGlyph, &advance, 1)
      guard advance.width.isFinite else { continue }
      let adjustedRange = NSRange(location: range.location + piece.range.location, length: piece.range.length)
      let correction = piece.mapping.width * format.size * scale / 1_000 - advance.width
      text.addAttribute(.kern, value: format.characterSpacing * scale + correction, range: adjustedRange)
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
    markers: [PageTextEditing.ListMarker], diagnostic: ((String) -> Void)?) -> [PageTextTarget] {
    struct Span {
      let source: PageTextEditing.SourceRun
      let block: PageTextTarget
      let x: Double
      let width: Double
      let fragments: [PageTextFragment]
      let wordBoundaryBefore: Bool
      let wordBoundaryAfter: Bool
    }
    struct Line {
      var spans: [Span]
      var fragments: [PageTextFragment] = []
      var syntheticSeparatorsAfter: [Int] = []
      var leadingAdvance: Double = 0
      var x: Double { spans[0].x + leadingAdvance }
      var y: Double { spans[0].source.baseline }
      var width: Double { spans.last!.x + spans.last!.width - x }
      var text: String { fragments.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    }
    let sources = (try? PageTextEditing.sourceRuns(pageID: pageID, in: graph)) ?? []
    let sourceTextRuns = (try? PageTextEditing.textRunContents(pageID: pageID, in: graph)) ?? [:]
    var spans: [Span] = []
    for block in blocks {
      let members = sources.filter { block.runIndices.contains($0.index) }
      let sourceText = members.map(\.text).joined()
      func visibleCharacters(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
      }
      // PDFKit can infer word spaces from glyph positions even when a subset
      // font omits those space codes from its verified source-run map. The
      // span layout below may reconstruct those separators from measured
      // advances, but it must never invent, drop or reorder visible characters.
      let exactSourceText = members.count == block.runIndices.count && sourceText == block.text
      let sameVisibleCharacters = !members.isEmpty
        && visibleCharacters(sourceText) == visibleCharacters(block.text)
      guard exactSourceText || sameVisibleCharacters else {
        diagnostic?("source-block-unmatched (\(members.count)/\(block.runIndices.count)): block=\(String(reflecting: block.text)), source=\(String(reflecting: sourceText))")
        continue
      }
      if !exactSourceText {
        diagnostic?("source-block-whitespace-inferred: \(String(block.text.prefix(120)))")
      }
      var wordBoundaries = Set<Int>()
      var visibleCount = 0
      var sawWhitespace = false
      for character in block.text {
        if character.isWhitespace {
          if visibleCount > 0 { sawWhitespace = true }
        } else {
          if sawWhitespace { wordBoundaries.insert(visibleCount) }
          visibleCount += 1
          sawWhitespace = false
        }
      }
      var candidate: [Span] = []
      var visibleOffset = 0
      for (memberOffset, source) in members.enumerated() {
        var width = 0.0
        var valid = true
        var failure: String?
        for piece in source.fragments {
          guard let font = nativeFont(piece.format, embedded: embedded), !piece.text.isEmpty else {
            valid = false; failure = "native font or single-code-unit glyph unavailable"; break
          }
          let mapping = piece.format.sourceFont.flatMap {
            profiles[$0.resource]?.glyphs[piece.text]
          }
          var glyph: CGGlyph
          if piece.text.utf16.count == 1, let character = piece.text.utf16.first {
            var code = character
            glyph = 0
            guard CTFontGetGlyphsForCharacters(font, &code, &glyph, 1), glyph != 0 else {
              valid = false; failure = "native glyph mapping unavailable"; break
            }
          } else if let id = mapping?.id, id > 0, id <= Int(UInt16.max) {
            // ToUnicode can map one painted subset glyph to several Unicode
            // scalars (for example, an `ffi` ligature). The verified profile
            // retains that source glyph ID, so measure the actual embedded
            // glyph instead of rejecting the whole paragraph as uneditable.
            glyph = CGGlyph(id)
          } else {
            valid = false; failure = "verified multi-scalar source glyph unavailable"; break
          }
          var size = CGSize.zero
          _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &size, 1)
          var advance = size.width
          if piece.format.sourceFont != nil {
            guard let mapping,
              mapping.id == nil || mapping.id == Int(glyph),
              abs(size.width * 1_000 / piece.format.size - mapping.width) <= 1.1
            else {
              valid = false; failure = "source glyph ID or advance mismatch"; break
            }
            advance = mapping.width * piece.format.size / 1_000
          }
          width += advance + piece.format.characterSpacing
        }
        guard valid else {
          diagnostic?("source-span-unavailable: run \(source.index) \(String(source.text.prefix(100))): \(failure ?? "unknown mapping issue")")
          candidate = []; break
        }
        let x = source.format.sourceFont == nil && source.index == block.runIndices.first ? block.rect[0] : source.x
        let visibleLength = source.text.filter { !$0.isWhitespace }.count
        let previousHasWhitespace = memberOffset > 0
          && members[memberOffset - 1].text.last?.isWhitespace == true
        let nextHasWhitespace = members.indices.contains(memberOffset + 1)
          && members[memberOffset + 1].text.first?.isWhitespace == true
        let boundaryBefore = wordBoundaries.contains(visibleOffset)
          && source.text.first?.isWhitespace != true && !previousHasWhitespace
        let nextVisibleOffset = visibleOffset + visibleLength
        let boundaryAfter = wordBoundaries.contains(nextVisibleOffset)
          || (nextVisibleOffset == visibleCount && block.text.last?.isWhitespace == true)
        visibleOffset = nextVisibleOffset
        candidate.append(Span(source: source, block: block, x: x, width: width,
          fragments: source.fragments,
          wordBoundaryBefore: boundaryBefore && source.text.first?.isWhitespace != true,
          wordBoundaryAfter: boundaryAfter && source.text.last?.isWhitespace != true && !nextHasWhitespace))
      }
      spans += candidate
    }
    spans.sort { abs($0.source.baseline - $1.source.baseline) > 0.02
      ? $0.source.baseline > $1.source.baseline : $0.x < $1.x }
    var lines: [Line] = []
    for span in spans {
      if let last = lines.last, let previous = last.spans.last,
        abs(last.y - span.source.baseline) < 0.02 {
        let gap = span.x - previous.x - previous.width
        let tolerance = max(0.75, span.source.format.size * 0.3)
        let inferredWordGap = previous.wordBoundaryAfter || span.wordBoundaryBefore
        if abs(gap) <= tolerance
          || (inferredWordGap && gap >= -tolerance && gap <= span.source.format.size * 1.5) {
          lines[lines.count - 1].spans.append(span)
        } else {
          diagnostic?("same-baseline-split gap=\(gap) tolerance=\(tolerance): \(String(previous.block.text.prefix(80))) -> \(String(span.block.text.prefix(80)))")
          lines.append(Line(spans: [span]))
        }
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
      func inferredSpaceFormat(_ format: PageTextFormat, gap: Double) -> PageTextFormat? {
        guard gap > 0, gap <= format.size * 1.5 else { return nil }
        let face = format.sourceFont.map {
          StandardTextFont.face(family: .helvetica, bold: $0.isBold, italic: $0.isItalic)
        } ?? format.font
        guard let width = standardAdvance(" ", family: face.rawValue, size: format.size) else { return nil }
        var result = format
        result.font = face
        result.sourceFont = nil
        result.customFont = nil
        result.characterSpacing = gap - width
        return result.isValid ? result : nil
      }
      let gaps = zip(spans, spans.dropFirst()).map { $1.x - $0.x - $0.width }
      let wordGaps = gaps.indices.map { index -> Bool in
        let boundaryEvidence = spans[index].wordBoundaryAfter || spans[index + 1].wordBoundaryBefore
        guard let last = spans[index].fragments.last, let next = spans[index + 1].fragments.first,
          last.text.last?.isWhitespace == false, next.text.first?.isWhitespace == false else { return false }
        if boundaryEvidence { return inferredSpaceFormat(last.format, gap: gaps[index]) != nil }
        guard let space = spaceWidth(last.format), space > 0 else { return false }
        return gaps[index] >= space * 0.6 && gaps[index] <= space * 1.4
      }
      // Uniform, widely tracked individual letters are ambiguous. Preserve
      // their measured tracking instead of guessing word breaks between them.
      let tracking = spans.allSatisfy { $0.source.text.count == 1 }
        && wordGaps.filter { $0 }.count >= 2 && wordGaps.filter { $0 }.count * 2 >= gaps.count
      var fragments: [PageTextFragment] = []
      var syntheticSeparatorsAfter: [Int] = []
      for (index, span) in spans.enumerated() {
        var pieces = span.fragments
        if index < gaps.count, let last = pieces.popLast() {
          if wordGaps[index], !tracking {
            pieces.append(last)
            if let width = spaceWidth(last.format) {
              var format = last.format
              format.characterSpacing = gaps[index] - width
              if abs(format.characterSpacing) < 1e-6 { format.characterSpacing = 0 }
              pieces.append(.init(text: " ", format: format))
              syntheticSeparatorsAfter.append(span.source.index)
            } else if let format = inferredSpaceFormat(last.format, gap: gaps[index]) {
              pieces.append(.init(text: " ", format: format))
              syntheticSeparatorsAfter.append(span.source.index)
            } else {
              var format = last.format
              if abs(gaps[index]) > 1e-6 { format.characterSpacing += gaps[index] }
              pieces[pieces.count - 1] = .init(text: last.text, format: format)
            }
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
      lines[index].syntheticSeparatorsAfter = syntheticSeparatorsAfter
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
        let label = members.map(\.text).joined(separator: " | ")
        guard let initial = formats.first else {
          diagnostic?("missing-format: \(String(label.prefix(120)))")
          return nil
        }
        let candidateRuns = Array(Set(all.flatMap { span in
          [span.source.index] + span.block.runIndices
        })).sorted()
        // Nearby same-style show fragments can make one ordinary line. On
        // tagged pages, only expose the combined target when the rewrite can
        // preserve the source MCID assignments and structure-tree order.
        let canJoinFragments = all.count > 1
          && validator.canPreserveMarkedContentOrder(runIndices: candidateRuns)
        guard formats.contains(where: {
          $0.sourceFont != nil || $0 != initial || $0.characterSpacing != 0
        }) || all.contains(where: {
          $0.block.runIndices.count > 1 || abs($0.source.textScale - 1) > 1e-6
        }) || canJoinFragments else {
          diagnostic?("uniform-unverified-format: \(String(label.prefix(120)))")
          return nil
        }
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
        guard let layout = nativeLayout(fragments, embedded: embedded, profiles: profiles,
          width: width, spacing: spacing) else {
          diagnostic?("native-layout-unavailable: \(String(label.prefix(120)))")
          return nil
        }
        let expectedText = members.map(\.text)
        guard layout.text == expectedText else {
          diagnostic?(
            "native-layout-text: \(String(label.prefix(100))) => \(layout.text.joined(separator: " | "))")
          return nil
        }
        guard zip(layout.baselines, members).allSatisfy({
          abs($0.0 - (first.y - $0.1.y)) < 0.02
        }) else {
          diagnostic?("native-layout-baseline: \(String(label.prefix(120)))")
          return nil
        }
        var original = Dictionary(uniqueKeysWithValues: all.map { ($0.source.index, $0.source.text) })
        for span in all {
          for index in span.block.runIndices where original[index] == nil {
            guard let text = sourceTextRuns[index], text.allSatisfy(\.isWhitespace) else {
              diagnostic?("unmapped-source-run: \(index)=\(String(reflecting: sourceTextRuns[index])) in \(String(label.prefix(100)))")
              return nil
            }
            original[index] = text
          }
        }
        var sourceRunOutputCounts = original.mapValues { $0.unicodeScalars.count }
        for line in members {
          for runIndex in line.syntheticSeparatorsAfter {
            guard sourceRunOutputCounts[runIndex] != nil else {
              diagnostic?("unmapped-inferred-separator: source run \(runIndex) in \(String(label.prefix(100)))")
              return nil
            }
            sourceRunOutputCounts[runIndex, default: 0] += 1
          }
        }
        var advances: [Int: Double] = [:]
        for span in all where span.source.format.sourceFont == nil {
          advances[span.source.index] = standardAdvance(span.source.text,
            family: span.source.format.font.rawValue, size: span.source.format.size / span.source.textScale)
        }
        for span in all where span.source.format.sourceFont == nil {
          for index in span.block.runIndices where advances[index] == nil {
            guard let text = sourceTextRuns[index],
              let value = standardAdvance(text, family: span.source.format.font.rawValue,
                size: span.source.format.size / span.source.textScale) else { continue }
            advances[index] = value
          }
        }
        do {
          try validator.validate(originalText: original,
            fontSize: initial.size, color: initial.color, standardFontAdvances: advances)
        } catch {
          let issue = validator.issue(for: original.keys.sorted()) ?? "\(error)"
          diagnostic?("rewrite-validator: \(String(label.prefix(100))): \(issue)")
          return nil
        }
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
        guard clippingIssue(lines: sourceLines, clippingRect: clippingRect,
          profiles: profiles, nativeFonts: embedded) == nil else {
          diagnostic?("clipped-ink: \(String(label.prefix(120)))")
          return nil
        }
        diagnostic?("accepted: \(String(label.prefix(120)))")
        let rect = paragraphBounds(lines: sourceLines, firstBaseline: first.y,
          initialFontSize: initial.size, x: first.x, width: width, embedded: embedded)
        let runIndices = original.keys.sorted()
        return PageTextTarget(pageIndex: all[0].block.pageIndex, runIndex: runIndices[0],
          rect: rect, text: fragments.map(\.text).joined(),
          style: .init(fontFamily: initial.fontName, fontSize: initial.size, fillColor: initial.color),
          runIndices: runIndices, paragraph: .init(originalText: original,
            lineSpacing: spacing, firstBaseline: first.y, standardFontAdvances: advances,
            fragments: fragments, wraps: members.count > 1,
            sourceRunOutputCounts: sourceRunOutputCounts,
            fontProfiles: profiles, clippingRect: clippingRect))
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

  /// Use the saved paragraph's font-metric box for selection and inspector
  /// coordinates both before and after the paragraph receives authoring data.
  private static func paragraphBounds(lines: [PageTextLine], firstBaseline: Double,
    initialFontSize: Double, x: Double, width: Double, embedded: [PDFName: NSFont]) -> [Double] {
    var bottom = firstBaseline
    var top = firstBaseline
    for line in lines {
      for segment in line.segments {
        guard let font = nativeFont(segment.format, embedded: embedded) else { continue }
        bottom = min(bottom, line.baseline + font.descender)
        top = max(top, line.baseline + font.ascender)
      }
      bottom = min(bottom, line.baseline - initialFontSize * 0.2)
    }
    return [x, bottom, x + width, top]
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
