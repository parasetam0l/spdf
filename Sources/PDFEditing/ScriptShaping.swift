import CoreGraphics
import CoreText
import Foundation

/// FNT-04: Core Text shaping with a reliable glyph-cluster-to-PDF source map.
///
/// The inline editor's text engine (TextKit) shapes a *source string*: one
/// typed grapheme can shape to several glyphs (an accented letter), several
/// graphemes to one glyph (a ligature), or a base plus combining marks to a
/// positioned cluster. A PDF text run stores *character codes*, decoded to
/// Unicode through the font's encoding/ToUnicode map. Editing, caret movement
/// and selection must never cut through a grapheme cluster: deleting half of
/// "fi" (one ligature code) or half of base+combining-mark would corrupt the
/// stored text.
///
/// This file provides:
/// - `ScriptShaping`: Core Text shaping that reports every glyph's advance and
///   its complete UTF-16 source grapheme cluster, including fallback-cascade
///   runs. Only Core Text/Core Graphics are imported (the PDFEditing core may
///   not depend on a UI framework).
/// - `ScriptGraphemes`: Unicode grapheme-cluster boundaries and grapheme-safe
///   caret movement, deletion, selection expansion and replacement helpers
///   (Turkish `İ`/`ı` and decomposed `e` + U+0301 included).
/// - `GlyphClusterSourceMap`: the reverse bridge. Given a PDF run's decoded
///   glyphs (codes plus Unicode) and the shaped source text, it maps every
///   shaped cluster to the exact PDF code range and refuses to build when a
///   shaped cluster would split a stored code (for example a decomposed
///   ligature) instead of silently mis-editing it.
public enum ScriptShaping {
  /// One shaped glyph. `sourceRange` is measured in UTF-16 units of the
  /// shaped string (that is what NSTextView stores).
  public struct Glyph: Sendable, Equatable {
    public let glyphID: UInt16
    /// Advance in the shaped point size (Core Text units, normally points).
    public let advance: Double
    /// UTF-16 source range this glyph was shaped from; never empty.
    public let sourceRange: Range<Int>
    /// True when the glyph came from the system fallback cascade rather than
    /// the requested font.
    public let isFallback: Bool

    public init(glyphID: UInt16, advance: Double, sourceRange: Range<Int>, isFallback: Bool) {
      self.glyphID = glyphID
      self.advance = advance
      self.sourceRange = sourceRange
      self.isFallback = isFallback
    }
  }

  /// One visible shaping cluster: complete source graphemes and the glyphs
  /// they produced. A cluster may contain several graphemes when a font
  /// substitutes a ligature (for example U+FB03 "ffi"), and several glyphs
  /// when one grapheme decomposes (a base letter plus a combining mark).
  public struct Cluster: Sendable, Equatable {
    public let text: String
    /// UTF-16 source range. Never splits a Unicode grapheme cluster.
    public let sourceRange: Range<Int>
    /// Glyph indices in `ShapedText.glyphs`.
    public let glyphRange: Range<Int>
    /// Shaped advance for the whole cluster in points.
    public let advance: Double
    public let isFallback: Bool

    public init(
      text: String, sourceRange: Range<Int>, glyphRange: Range<Int>, advance: Double,
      isFallback: Bool
    ) {
      self.text = text
      self.sourceRange = sourceRange
      self.glyphRange = glyphRange
      self.advance = advance
      self.isFallback = isFallback
    }

    /// Number of Unicode grapheme clusters in this shaping cluster (1 unless a
    /// ligature connected several graphemes).
    public var graphemeCount: Int {
      text.reduce(into: 0) { count, _ in count += 1 }
    }
  }

  /// The shaped form of one source string.
  public struct ShapedText: Sendable, Equatable {
    public let text: String
    public let fontName: String
    public let pointSize: Double
    public let language: String?
    public let glyphs: [Glyph]
    public let clusters: [Cluster]
    public let missingGlyphCount: Int
    /// False when Core Text returns reordered (right-to-left) glyphs. The
    /// source map below declines to build from such a run rather than
    /// guessing logical order.
    public let isLogicallyOrdered: Bool

    public var advance: Double { clusters.reduce(0) { $0 + $1.advance } }

    /// Every UTF-16 offset belongs to exactly one cluster, in ascending
    /// source order.
    public var coversAllSourceOffsets: Bool {
      guard isLogicallyOrdered, clusters.first?.sourceRange.lowerBound == 0 else { return false }
      var next = 0
      for cluster in clusters {
        guard cluster.sourceRange.lowerBound == next, !cluster.sourceRange.isEmpty else { return false }
        next = cluster.sourceRange.upperBound
      }
      return next == text.utf16.count
    }
  }

  /// Shape `text` with a named font, falling back through the system cascade
  /// for characters the requested face does not cover.
  public static func shape(
    _ text: String, fontName: String, pointSize: Double, language: String? = nil
  ) -> ShapedText {
    let size = pointSize.isFinite && pointSize > 0 ? pointSize : 12
    if !fontName.isEmpty {
      return shape(text, font: CTFontCreateWithName(fontName as CFString, size, nil), language: language)
    }
    let system = CTFontCreateUIFontForLanguage(.system, size, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    return shape(text, font: system, language: language)
  }

  /// Shape `text` with an explicit Core Text font.
  public static func shape(
    _ text: String, font: CTFont, language: String? = nil
  ) -> ShapedText {
    let pointSize = Double(CTFontGetSize(font))
    let baseName = CTFontCopyPostScriptName(font) as String
    let normalizedLanguage = normalizedLanguage(language)
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font
    ]
    if let normalizedLanguage {
      attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = normalizedLanguage
    }
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    var glyphs: [Glyph] = []
    var rawClusters: [(range: Range<Int>, glyphRange: Range<Int>, advance: Double, fallback: Bool)] = []
    var missing = 0
    for run in runs {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var glyphIDs = [CGGlyph](repeating: 0, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphIDs)
      CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
      let runRange = CTRunGetStringRange(run)
      let runEnd = runRange.location + runRange.length
      var boundaries = Set(indices.map { Int($0) })
      boundaries.insert(runEnd)
      let sorted = boundaries.filter { $0 >= 0 && $0 <= text.utf16.count }.sorted()
      var runFontName = baseName
      let runAttributes = CTRunGetAttributes(run) as NSDictionary
      if let value = runAttributes[kCTFontAttributeName] {
        runFontName = CTFontCopyPostScriptName(value as! CTFont) as String
      }
      let fallback = runFontName != baseName
      let firstGlyph = glyphs.count
      for index in 0..<count {
        let start = Int(indices[index])
        let end = sorted.first { $0 > start } ?? min(runEnd, start + 1)
        let range = start..<max(end, start + 1)
        let glyph = Glyph(
          glyphID: UInt16(truncatingIfNeeded: glyphIDs[index]),
          advance: Double(advances[index].width),
          sourceRange: range, isFallback: fallback)
        glyphs.append(glyph)
        if glyph.glyphID == 0 { missing += 1 }
      }
      // Per-run cluster boundaries: each glyph maps from its string index to
      // the next boundary inside the run. Only glyphs that share the same
      // string index are one shaping cluster; adjacent distinct clusters must
      // stay separate so ligature/combining mappings remain exact.
      for index in 0..<count {
        let start = Int(indices[index])
        let end = sorted.first { $0 > start } ?? runEnd
        let range = start..<max(end, start + 1)
        if let last = rawClusters.last, last.range.lowerBound == start {
          rawClusters[rawClusters.count - 1] = (
            last.range.lowerBound..<max(last.range.upperBound, range.upperBound),
            last.glyphRange.lowerBound..<max(last.glyphRange.upperBound, firstGlyph + index + 1),
            last.advance + glyphs[firstGlyph + index].advance, last.fallback || fallback
          )
        } else {
          rawClusters.append((
            range, (firstGlyph + index)..<(firstGlyph + index + 1),
            glyphs[firstGlyph + index].advance, fallback
          ))
        }
      }
    }
    // Core Text returns visual order. Sort defensively so the logical source
    // order is what callers see, and remember when reordering occurred.
    var ordered = rawClusters.sorted { $0.range.lowerBound < $1.range.lowerBound }
    // Drop degenerate/duplicate ranges, keeping the first glyph data.
    var deduped: [(range: Range<Int>, glyphRange: Range<Int>, advance: Double, fallback: Bool)] = []
    for cluster in ordered {
      if let last = deduped.last, cluster.range.lowerBound < last.range.upperBound { continue }
      deduped.append(cluster)
    }
    ordered = deduped
    let logicallyOrdered =
      rawClusters.count == ordered.count
      && zip(rawClusters, ordered).allSatisfy { $0.range == $1.range }
    // FNT-04: shape clusters are made grapheme-safe without subdividing them.
    // A raw Core Text cluster is expanded outwards to complete Unicode
    // graphemes (so a base and its combining marks stay one editing unit),
    // then raw clusters whose expanded ranges overlap are merged (a base and
    // a mark can arrive in separate fallback runs). A ligature that spans
    // several graphemes stays one cluster: splitting it would make the stored
    // PDF code uneditable instead of atomic.
    let graphemeBoundaries = ScriptGraphemes.boundaries(in: text)
    let utf16Count = text.utf16.count
    func snapped(_ range: Range<Int>) -> Range<Int> {
      let start = graphemeBoundaries.last { $0 <= range.lowerBound } ?? 0
      let end = graphemeBoundaries.first { $0 >= range.upperBound } ?? utf16Count
      return start..<max(end, start)
    }
    var clusters: [Cluster] = []
    for raw in ordered {
      let range = snapped(raw.range)
      guard !range.isEmpty else { continue }
      if let last = clusters.last, range.lowerBound < last.sourceRange.upperBound {
        let mergedRange = last.sourceRange.lowerBound..<max(last.sourceRange.upperBound, range.upperBound)
        clusters[clusters.count - 1] = Cluster(
          text: selfText(text, range: mergedRange), sourceRange: mergedRange,
          glyphRange: last.glyphRange.lowerBound..<max(last.glyphRange.upperBound, raw.glyphRange.upperBound),
          advance: last.advance + raw.advance, isFallback: last.isFallback || raw.fallback)
      } else {
        clusters.append(
          Cluster(
            text: selfText(text, range: range), sourceRange: range,
            glyphRange: raw.glyphRange, advance: raw.advance, isFallback: raw.fallback))
      }
    }
    // A grapheme Core Text produced no glyph for (for example a dropped
    // formatting character) still needs a covering cluster so every source
    // offset belongs to exactly one editing unit.
    var completed: [Cluster] = []
    var next = 0
    for cluster in clusters {
      if cluster.sourceRange.lowerBound > next {
        let gap = next..<cluster.sourceRange.lowerBound
        completed.append(
          Cluster(
            text: selfText(text, range: gap), sourceRange: gap, glyphRange: 0..<0,
            advance: 0, isFallback: false))
      }
      completed.append(cluster)
      next = cluster.sourceRange.upperBound
    }
    if next < utf16Count {
      let gap = next..<utf16Count
      completed.append(
        Cluster(
          text: selfText(text, range: gap), sourceRange: gap, glyphRange: 0..<0,
          advance: 0, isFallback: false))
    }
    clusters = completed
    return ShapedText(
      text: text, fontName: baseName, pointSize: pointSize, language: normalizedLanguage,
      glyphs: glyphs, clusters: clusters, missingGlyphCount: missing,
      isLogicallyOrdered: logicallyOrdered)
  }

  private static func selfText(_ text: String, range: Range<Int>) -> String {
    let units = Array(text.utf16)
    guard range.lowerBound >= 0, range.upperBound <= units.count else { return "" }
    return String(decoding: units[range.lowerBound..<range.upperBound], as: UTF16.self)
  }

  /// BCP-47 shape context tags are preserved when well formed; anything else
  /// is ignored rather than guessed (the same rule FontProvider uses).
  public static func normalizedLanguage(_ tag: String?) -> String? {
    guard let tag else { return nil }
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 35 else { return nil }
    let pattern = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/
    guard trimmed.wholeMatch(of: pattern) != nil else { return nil }
    return trimmed
  }
}

/// FNT-04: Unicode grapheme-cluster segmentation and grapheme-safe text
/// operations. All offsets are UTF-16 offsets (the unit NSTextView, PDFKit
/// and PDF string operands all use).
public enum ScriptGraphemes {
  /// Ascending UTF-16 boundaries of the text's grapheme clusters, including 0
  /// and the UTF-16 length. Deleting or replacing only at these offsets can
  /// never cut a grapheme.
  public static func boundaries(in text: String) -> [Int] {
    var result: [Int] = [0]
    var offset = 0
    for character in text {
      offset += String(character).utf16.count
      result.append(offset)
    }
    return result
  }

  public static func isBoundary(_ offset: Int, in text: String) -> Bool {
    boundaries(in: text).contains(offset)
  }

  /// The complete grapheme cluster containing `offset` (clamped into range).
  public static func cluster(containing offset: Int, in text: String) -> Range<Int> {
    let count = text.utf16.count
    let clamped = min(max(0, offset), count)
    let list = boundaries(in: text)
    for index in 0..<(list.count - 1) {
      if clamped >= list[index], clamped < list[index + 1] {
        return list[index]..<list[index + 1]
      }
    }
    return count..<count
  }

  /// Expand `range` outwards until both edges sit on grapheme boundaries.
  public static func snap(_ range: Range<Int>, in text: String) -> Range<Int> {
    let count = text.utf16.count
    let lower = min(max(0, range.lowerBound), count)
    let upper = min(max(lower, range.upperBound), count)
    let list = boundaries(in: text)
    let start = list.last { $0 <= lower } ?? 0
    let end = list.first { $0 >= upper } ?? count
    return start..<end
  }

  public static func snap(_ range: NSRange, in text: String) -> NSRange {
    guard range.location != NSNotFound else { return range }
    let snapped = snap(range.location..<(range.location + range.length), in: text)
    return NSRange(location: snapped.lowerBound, length: snapped.count)
  }

  /// Caret movement by whole grapheme clusters. `offset` is first clamped to a
  /// boundary; a forward move goes to the next boundary, a backward move to
  /// the previous one.
  public static func caretOffset(_ offset: Int, movingForward: Bool, in text: String) -> Int {
    let count = text.utf16.count
    let clamped = min(max(0, offset), count)
    let list = boundaries(in: text)
    let current = list.last { $0 <= clamped } ?? 0
    guard let index = list.firstIndex(of: current) else { return current }
    if movingForward { return index + 1 < list.count ? list[index + 1] : count }
    return index > 0 ? list[index - 1] : 0
  }

  /// The range a backward delete removes at `caret` (nil at the start).
  public static func deleteBackward(at caret: Int, in text: String) -> Range<Int>? {
    let count = text.utf16.count
    let clamped = min(max(0, caret), count)
    let list = boundaries(in: text)
    guard let index = list.firstIndex(where: { $0 >= clamped }), index > 0 else { return nil }
    let end = list[index] == clamped ? clamped : list[index]
    let start = list[index - 1]
    return start..<max(start, end)
  }

  /// The range a forward delete removes at `caret` (nil at the end).
  public static func deleteForward(at caret: Int, in text: String) -> Range<Int>? {
    let count = text.utf16.count
    let clamped = min(max(0, caret), count)
    let list = boundaries(in: text)
    guard let index = list.lastIndex(where: { $0 <= clamped }), index + 1 < list.count else {
      return nil
    }
    let start = list[index]
    return start..<list[index + 1]
  }

  /// A grapheme-safe replacement: `range` is expanded to complete clusters
  /// before the replacement is applied.
  public static func replacing(
    _ range: Range<Int>, in text: String, with replacement: String
  ) -> String {
    let units = Array(text.utf16)
    let complete = snap(range, in: text)
    guard complete.lowerBound >= 0, complete.upperBound <= units.count else { return text }
    var result = String(decoding: units[0..<complete.lowerBound], as: UTF16.self)
    result += replacement
    result += String(decoding: units[complete.upperBound..<units.count], as: UTF16.self)
    return result
  }

  /// True when no grapheme cluster straddles either edge of `range`.
  public static func isAtomic(_ range: Range<Int>, in text: String) -> Bool {
    range.lowerBound >= 0 && range.upperBound <= text.utf16.count
      && isBoundary(range.lowerBound, in: text) && isBoundary(range.upperBound, in: text)
  }

  /// Turkish-safe case mapping helpers used by the editing tests to prove the
  /// input string keeps its own Unicode form. The system locale-aware case
  /// conversion is the authority; these only expose it on a named locale so
  /// callers can ask for Turkish explicitly instead of guessing from the host.
  public static func uppercased(_ text: String, localeIdentifier: String?) -> String {
    guard let localeIdentifier else { return text.uppercased() }
    return text.uppercased(with: Locale(identifier: localeIdentifier))
  }

  public static func lowercased(_ text: String, localeIdentifier: String?) -> String {
    guard let localeIdentifier else { return text.lowercased() }
    return text.lowercased(with: Locale(identifier: localeIdentifier))
  }
}

/// FNT-04: one decoded glyph of a PDF text run, as both the stored character
/// codes and the Unicode its ToUnicode/encoding produced.
public struct PDFSourceGlyph: Sendable, Equatable {
  public let text: String
  public let codes: [UInt8]

  public init(text: String, codes: [UInt8]) {
    self.text = text
    self.codes = codes
  }
}

/// FNT-04: the reliable glyph-cluster-to-PDF source map.
///
/// A PDF run stores codes (1–4 bytes each); decoding yields glyph texts that
/// may cover several Unicode scalars (a ligature) and may be several glyphs
/// per grapheme (base + combining mark). Core Text shaping of the *decoded
/// text* produces clusters in source order. The map joins the two: each shaped
/// cluster owns a contiguous range of PDF glyphs and their exact code bytes.
///
/// The initializer throws instead of producing a half-correct map. A shaped
/// cluster that would start or end inside one stored PDF code (for example a
/// PDF ligature "ffi" that this font does not shape as one cluster) cannot be
/// edited safely, so callers are required to refuse rather than corrupt it.
public struct GlyphClusterSourceMap: Sendable, Equatable {
  public struct MappedCluster: Sendable, Equatable {
    public let text: String
    /// UTF-16 range in the decoded run text.
    public let sourceRange: Range<Int>
    /// Glyph indices in the shaped text.
    public let glyphRange: Range<Int>
    /// Indices into `PDFSourceGlyph` list.
    public let pdfGlyphRange: Range<Int>
    /// Byte range in the concatenated code stream.
    public let codeRange: Range<Int>
    public let advance: Double

    public init(
      text: String, sourceRange: Range<Int>, glyphRange: Range<Int>,
      pdfGlyphRange: Range<Int>, codeRange: Range<Int>, advance: Double
    ) {
      self.text = text
      self.sourceRange = sourceRange
      self.glyphRange = glyphRange
      self.pdfGlyphRange = pdfGlyphRange
      self.codeRange = codeRange
      self.advance = advance
    }
  }

  public enum MappingError: Error, Equatable {
    /// The glyph list does not decode to the shaped text.
    case textMismatch
    /// Right-to-left/reordered shaping has no single logical source map.
    case notLogicallyOrdered
    /// A shaped cluster starts or ends inside one stored PDF glyph (a code
    /// that expands to several Unicode scalars but was split by shaping).
    case clusterSplitsStoredGlyph(offset: Int)
    /// The shaped clusters do not cover the whole decoded text exactly once.
    case incompleteCoverage(offset: Int)
    case emptyText
  }

  public let text: String
  public let sourceGlyphs: [PDFSourceGlyph]
  public let codes: [UInt8]
  public let clusters: [MappedCluster]
  public let shaped: ScriptShaping.ShapedText

  public init(
    text: String, glyphs: [PDFSourceGlyph], shaped: ScriptShaping.ShapedText
  ) throws {
    guard !text.isEmpty, !glyphs.isEmpty else { throw MappingError.emptyText }
    guard glyphs.map(\.text).joined() == text, shaped.text == text else {
      throw MappingError.textMismatch
    }
    guard shaped.isLogicallyOrdered, shaped.coversAllSourceOffsets else {
      throw MappingError.notLogicallyOrdered
    }
    var glyphSourceRanges: [Range<Int>] = []
    var glyphCodeRanges: [Range<Int>] = []
    var sourceOffset = 0
    var codeOffset = 0
    for glyph in glyphs {
      let sourceLength = glyph.text.utf16.count
      glyphSourceRanges.append(sourceOffset..<(sourceOffset + sourceLength))
      glyphCodeRanges.append(codeOffset..<(codeOffset + glyph.codes.count))
      sourceOffset += sourceLength
      codeOffset += glyph.codes.count
    }
    guard sourceOffset == text.utf16.count else { throw MappingError.incompleteCoverage(offset: sourceOffset) }
    var mapped: [MappedCluster] = []
    var glyphIndex = 0
    for cluster in shaped.clusters {
      let start = cluster.sourceRange.lowerBound
      let end = cluster.sourceRange.upperBound
      guard start < end else { throw MappingError.incompleteCoverage(offset: start) }
      // The cluster must begin exactly on a stored-glyph boundary and end on
      // one; a start inside a glyph means shaping split a stored code.
      while glyphIndex < glyphSourceRanges.count,
        glyphSourceRanges[glyphIndex].upperBound <= start
      { glyphIndex += 1 }
      guard glyphIndex < glyphSourceRanges.count,
        glyphSourceRanges[glyphIndex].lowerBound == start
      else { throw MappingError.clusterSplitsStoredGlyph(offset: start) }
      var last = glyphIndex
      while last < glyphSourceRanges.count, glyphSourceRanges[last].upperBound <= end
      { last += 1 }
      guard last > glyphIndex,
        glyphSourceRanges[last - 1].upperBound == end,
        glyphCodeRanges[glyphIndex].lowerBound != glyphCodeRanges[last - 1].upperBound
      else { throw MappingError.clusterSplitsStoredGlyph(offset: end - 1) }
      if glyphIndex > 0, glyphSourceRanges[glyphIndex - 1].upperBound != start {
        throw MappingError.incompleteCoverage(offset: start)
      }
      let codeRange = glyphCodeRanges[glyphIndex].lowerBound..<glyphCodeRanges[last - 1].upperBound
      mapped.append(
        MappedCluster(
          text: cluster.text, sourceRange: start..<end, glyphRange: cluster.glyphRange,
          pdfGlyphRange: glyphIndex..<last, codeRange: codeRange, advance: cluster.advance))
      glyphIndex = last
    }
    guard Self.coversCompletely(
      mapped, glyphCount: glyphs.count, textLength: text.utf16.count)
    else {
      throw MappingError.incompleteCoverage(offset: mapped.last?.sourceRange.upperBound ?? 0)
    }
    var flattened: [UInt8] = []
    for glyph in glyphs { flattened += glyph.codes }
    self.text = text
    self.sourceGlyphs = glyphs
    self.codes = flattened
    self.clusters = mapped
    self.shaped = shaped
  }

  private static func coversCompletely(
    _ mapped: [MappedCluster], glyphCount: Int, textLength: Int
  ) -> Bool {
    guard let first = mapped.first, let last = mapped.last else { return false }
    guard first.sourceRange.lowerBound == 0, last.sourceRange.upperBound == textLength,
      last.pdfGlyphRange.upperBound == glyphCount
    else { return false }
    var nextSource = 0
    var nextGlyph = 0
    for cluster in mapped {
      guard cluster.sourceRange.lowerBound == nextSource,
        cluster.pdfGlyphRange.lowerBound == nextGlyph,
        !cluster.codeRange.isEmpty
      else { return false }
      nextSource = cluster.sourceRange.upperBound
      nextGlyph = cluster.pdfGlyphRange.upperBound
    }
    return nextSource == textLength && nextGlyph == glyphCount
  }

  /// The full PDF code range for any editing range. The requested range is
  /// expanded to whole stored code clusters; an edit therefore never removes
  /// half of a ligature or a combining cluster.
  public func codeRange(for sourceRange: Range<Int>) throws -> Range<Int> {
    guard sourceRange.lowerBound >= 0, sourceRange.upperBound <= text.utf16.count,
      !sourceRange.isEmpty
    else { throw MappingError.incompleteCoverage(offset: sourceRange.lowerBound) }
    let overlapping = clusters.filter {
      $0.sourceRange.upperBound > sourceRange.lowerBound
        && $0.sourceRange.lowerBound < sourceRange.upperBound
    }
    guard let first = overlapping.first, let last = overlapping.last else {
      throw MappingError.incompleteCoverage(offset: sourceRange.lowerBound)
    }
    return first.codeRange.lowerBound..<last.codeRange.upperBound
  }

  /// The UTF-16 range touched by a byte range of the code stream. Offsets
  /// inside a stored code map to that code's whole cluster.
  public func sourceRange(forCodeRange codeRange: Range<Int>) -> Range<Int>? {
    guard codeRange.lowerBound >= 0, codeRange.upperBound <= codes.count,
      codeRange.lowerBound < codeRange.upperBound
    else { return nil }
    let overlapping = clusters.filter {
      $0.codeRange.upperBound > codeRange.lowerBound && $0.codeRange.lowerBound < codeRange.upperBound
    }
    guard let first = overlapping.first, let last = overlapping.last else { return nil }
    return first.sourceRange.lowerBound..<last.sourceRange.upperBound
  }

  /// What an edit did: the new decoded text, new code bytes, and the UTF-16
  /// range it replaced (expanded to complete graphemes/clusters).
  public struct EditResult: Sendable, Equatable {
    public let text: String
    public let codes: [UInt8]
    public let replacedRange: Range<Int>
    public let insertedText: String
    public let insertedCodeCount: Int
  }

  /// Grapheme-safe edit of the mapped run. `encoded` supplies the code bytes
  /// the font writes for the inserted text (computed by the caller from its
  /// encoding); the map only guarantees the edit boundaries never split a
  /// stored code or a grapheme cluster.
  public func applying(
    replacing sourceRange: Range<Int>, with replacementText: String, encoded: [UInt8]
  ) throws -> EditResult {
    // The grapheme-safe request is expanded to whole stored clusters: a
    // selection inside a ligature code cannot remove only part of the stored
    // code, so the text side removes exactly the same clusters the code side
    // does.
    let snapped = ScriptGraphemes.snap(sourceRange, in: text)
    let codeRange = try codeRange(for: snapped)
    let replaced = self.sourceRange(forCodeRange: codeRange) ?? snapped
    var newCodes = Array(codes[0..<codeRange.lowerBound])
    newCodes += encoded
    newCodes += codes[codeRange.upperBound...]
    let units = Array(text.utf16)
    var newText = String(decoding: units[0..<replaced.lowerBound], as: UTF16.self)
    newText += replacementText
    newText += String(decoding: units[replaced.upperBound...], as: UTF16.self)
    return EditResult(
      text: newText, codes: newCodes, replacedRange: replaced, insertedText: replacementText,
      insertedCodeCount: encoded.count)
  }

  /// Insert `text`/`encoded` at a caret offset, snapped to a grapheme and
  /// stored-code boundary.
  public func inserting(encoded: [UInt8], text replacementText: String, at offset: Int)
    throws -> EditResult
  {
    let count = text.utf16.count
    let clamped = min(max(0, offset), count)
    let list = ScriptGraphemes.boundaries(in: text)
    let graphemeBoundary = list.last { $0 <= clamped } ?? 0
    // A caret inside a stored code (for example inside a selected ligature
    // code that shapes to several graphemes) inserts before that code; PDF
    // strings cannot be split at an arbitrary byte.
    let boundary: Int
    if let containing = clusters.first(where: {
      $0.sourceRange.lowerBound < graphemeBoundary
        && graphemeBoundary < $0.sourceRange.upperBound
    }) {
      boundary = containing.sourceRange.lowerBound
    } else {
      boundary = graphemeBoundary
    }
    let codeRange = try codeRange(forInsertionAt: boundary)
    var newCodes = Array(codes[0..<codeRange.lowerBound])
    newCodes += encoded
    newCodes += codes[codeRange.upperBound...]
    let units = Array(text.utf16)
    var newText = String(decoding: units[0..<boundary], as: UTF16.self)
    newText += replacementText
    newText += String(decoding: units[boundary...], as: UTF16.self)
    return EditResult(
      text: newText, codes: newCodes, replacedRange: boundary..<boundary,
      insertedText: replacementText, insertedCodeCount: encoded.count)
  }

  private func codeRange(forInsertionAt offset: Int) throws -> Range<Int> {
    if let next = clusters.first(where: { $0.sourceRange.lowerBound >= offset }) {
      return next.codeRange.lowerBound..<next.codeRange.lowerBound
    }
    return codes.count..<codes.count
  }
}

/// FNT-04: split a laid-out line's styled segments so every segment boundary is
/// a grapheme boundary. TextKit can hand back attribute runs that begin inside
/// a grapheme (applying a format to the base of a decomposed accent, for
/// example). Writing those segments to PDF would store a split grapheme; the
/// normalizer merges the grapheme back into the run that owns its base and
/// keeps the total text identical.
public enum GraphemeSafeTextSegments {
  /// Normalized segments plus a non-nil explanation when the input segments
  /// did not actually cover `text` (callers should then keep their original
  /// result and report the issue rather than writing a corrupted line).
  public struct Result: Sendable, Equatable {
    public let segments: [PageTextSegment]
    public let issue: String?

    public init(segments: [PageTextSegment], issue: String?) {
      self.segments = segments
      self.issue = issue
    }
  }

  /// The normalized line plus any coverage issue.
  public struct LineResult: Sendable, Equatable {
    public let line: PageTextLine
    public let issue: String?

    public init(line: PageTextLine, issue: String?) {
      self.line = line
      self.issue = issue
    }
  }

  public static func normalize(segments: [PageTextSegment], text: String) -> Result {
    guard !segments.isEmpty else { return Result(segments: segments, issue: nil) }
    let lengths = segments.map { $0.text.utf16.count }
    guard lengths.reduce(0, +) == text.utf16.count,
      segments.map(\.text).joined() == text
    else {
      return Result(
        segments: segments,
        issue: "The text segments do not cover their line; the edit was kept unchanged")
    }
    var boundaries: [Int] = [0]
    for length in lengths { boundaries.append(boundaries.last! + length) }
    let graphemeBoundaries = Set(ScriptGraphemes.boundaries(in: text))
    // Merge across any segment boundary that falls inside a grapheme.
    var groups: [(start: Int, end: Int)] = []
    var groupStart = 0
    for index in 1..<boundaries.count {
      let boundary = boundaries[index]
      if index == boundaries.count - 1 || graphemeBoundaries.contains(boundary) {
        groups.append((groupStart, index))
        groupStart = index
      }
    }
    var normalized: [PageTextSegment] = []
    for group in groups {
      let first = segments[group.start]
      let groupText = segments[group.start..<group.end].map(\.text).joined()
      let x = first.x
      let widths = segments[group.start..<group.end].map(\.width)
      let width: Double? = widths.allSatisfy { $0 != nil }
        ? widths.compactMap { $0 }.reduce(0, +) : nil
      normalized.append(
        PageTextSegment(
          text: groupText, x: x, format: first.format,
          width: width.flatMap { $0.isFinite ? $0 : nil }))
    }
    return Result(segments: normalized, issue: nil)
  }

  public static func normalize(_ line: PageTextLine) -> LineResult {
    let result = normalize(segments: line.segments, text: line.text)
    if let issue = result.issue { return LineResult(line: line, issue: issue) }
    let rebuilt = PageTextLine(
      text: line.text, x: line.x, baseline: line.baseline, segments: result.segments,
      endsParagraph: line.endsParagraph, breakFormat: line.breakFormat)
    return LineResult(line: rebuilt, issue: nil)
  }
}
