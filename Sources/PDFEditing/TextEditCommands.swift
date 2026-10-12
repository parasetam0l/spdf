import Foundation
import PDFCore

/// P18-010: fixed-box policy for replacements wider than the run.
/// The run's box is fixed (following text is held in place), so longer text
/// extends past it. `.allow` keeps the historical behavior; `.refuse`
/// throws before mutating, reporting the measured overflow.
public enum BoxOverflowPolicy: String, Sendable, Equatable {
  case allow
  case refuse
}

/// P18-011: measured overflow of a replacement against its fixed box, shown
/// before committing. `overflow` is points past the run (0 when it fits);
/// `overlapsFollowingText` tells whether the overhang reaches later text.
public struct OverflowReport: Sendable, Equatable {
  public let oldAdvance: Double
  public let newAdvance: Double
  public let overflow: Double
  public let fits: Bool
  public let overlapsFollowingText: Bool

  public init(
    oldAdvance: Double, newAdvance: Double, overflow: Double, fits: Bool,
    overlapsFollowingText: Bool
  ) {
    self.oldAdvance = oldAdvance
    self.newAdvance = newAdvance
    self.overflow = overflow
    self.fits = fits
    self.overlapsFollowingText = overlapsFollowingText
  }
}

/// P18-001/P18-002/P18-005: replace the actual text-show operand of one
/// narrowly supported run. Only the target instruction is rewritten; text
/// state, positioning operators, neighboring instructions, and every other
/// object stay untouched. Inside a TJ array, following members keep their
/// positions when the font carries width data: the immediately following
/// adjustment is rewritten (or one is inserted), so the run's advance change
/// is compensated. Without width data, replacing a member that has further
/// members is refused rather than misplacing text (P18-009/P18-012/P18-013).
/// P18-003: a TJ array is split at member boundaries — non-target members
/// keep their values and both neighboring runs keep their positions.
/// P18-004: surrounding text-state operators (spacing, rise, leading, font
/// selection) are never rewritten, and compensation accounts for spacing.
/// P18-007: when the run's font lacks replacement glyphs and a fallback
/// program is supplied, the fallback is embedded (reused when identical)
/// and the target is wrapped with font selections — the replacement shows
/// in the fallback while preceding and following text keeps the original
/// font. Without a covering fallback the command refuses explicitly.
/// P18-017: with `formResource` set, the run indexes a reusable form drawn
/// by this page instead of the page content. The form stream is edited with
/// the same Tj/TJ/fallback profile (fallback fonts register in the form's
/// own resources; the overflow preview checks the form-local layout), and a
/// shared form is copied first with only this page's entry repointed.
public struct ReplaceTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let runIndex: Int
  public let replacement: String
  /// P18-007: fallback program applied when the run's font lacks glyphs.
  /// Nil keeps the refusal. The program must cover every replacement scalar
  /// and be subsettable (TrueType); CFF programs refuse explicitly.
  public let fallbackFont: CustomTextFont?
  /// P18-010: what happens when the replacement is wider than the run.
  /// `.allow` (default) keeps the historical behavior of extending past it.
  public let overflowPolicy: BoxOverflowPolicy
  /// P18-017: when set, the run indexes text inside this page's reusable
  /// form (Form XObject) instead of the page content. The form is copied
  /// before the edit when it is shared, so other pages keep the original.
  public let formResource: PDFName?

  public init(
    pageID: PDFObjectID, runIndex: Int, replacement: String,
    fallbackFont: CustomTextFont? = nil, overflowPolicy: BoxOverflowPolicy = .allow,
    formResource: PDFName? = nil
  ) {
    self.pageID = pageID
    self.runIndex = runIndex
    self.replacement = replacement
    self.fallbackFont = fallbackFont
    self.overflowPolicy = overflowPolicy
    self.formResource = formResource
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Replace Text" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolve(in: graph, limits: PDFLimits())
    // P18-010: the refusal policy is enforced before any mutation.
    if overflowPolicy == .refuse {
      let report = try previewOverflow(in: graph, limits: PDFLimits())
      guard report.fits else {
        var message =
          "The replacement extends \(AnnotationSupport.number(report.overflow)) pt past the run"
        if report.overlapsFollowingText {
          message += " into the following text"
        }
        throw PDFError(.unsupported, message)
      }
    }
  }

  /// P18-011: measure the replacement against its fixed box without
  /// mutating, so callers can show the overflow before committing. Throws
  /// for unencodable text exactly like resolve (including the fallback
  /// coverage check); when neither font carries width data there is nothing
  /// to measure against, and the report fits vacuously.
  public func previewOverflow(
    in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> OverflowReport {
    let resolved = try resolve(in: graph, limits: limits)
    let run = resolved.run
    let oldAdvance = resolved.font.advance(
      of: run.rawCodes, fontSize: run.fontSize, charSpacing: run.charSpacing,
      wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale)
    let newAdvance: Double?
    if let fallback = resolved.fallback {
      let inspector = try TrueTypeInspector.inspect(fallback.custom.program)
      newAdvance = Self.inspectorAdvance(
        inspector: inspector, text: replacement, run: run)
    } else {
      newAdvance = resolved.font.advance(
        of: resolved.codes, fontSize: run.fontSize, charSpacing: run.charSpacing,
        wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale)
    }
    guard let oldAdvance, let newAdvance else {
      return OverflowReport(
        oldAdvance: 0, newAdvance: 0, overflow: 0, fits: true,
        overlapsFollowingText: false)
    }
    // Thousandth-point rounding matches the adjustment serialization.
    let overflow = max(0, ((newAdvance - oldAdvance) * 1000).rounded() / 1000)
    // P18-017: form runs overlap-check against the form-local layout, whose
    // bounds share the form's coordinate space with the run.
    let layout: PageTextLayout
    if resolved.formID != nil {
      layout = try PageTextLayout.build(
        in: resolved.content, graph: graph, limits: limits,
        resources: resolved.resources)
    } else {
      layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    }
    let own = layout.clusters.filter { $0.runIndex == runIndex }.map(\.bounds)
    guard let runEnd = own.map({ $0[2] }).max(),
      let runTop = own.map({ $0[3] }).max(),
      let runBottom = own.map({ $0[1] }).min()
    else {
      return OverflowReport(
        oldAdvance: oldAdvance, newAdvance: newAdvance, overflow: overflow,
        fits: overflow == 0, overlapsFollowingText: false)
    }
    let regionEnd = runEnd + overflow
    let overlaps = layout.clusters.contains { cluster in
      guard cluster.runIndex != runIndex else { return false }
      return cluster.bounds[0] < regionEnd - 0.001 && cluster.bounds[2] > runEnd + 0.001
        && cluster.bounds[1] < runTop && cluster.bounds[3] > runBottom
    }
    return OverflowReport(
      oldAdvance: oldAdvance, newAdvance: newAdvance, overflow: overflow,
      fits: overflow == 0, overlapsFollowingText: overlaps)
  }

  /// Advance of `text` from inspected program widths (pure, no embedding),
  /// mirroring the fallback compensation math. Inspector advances are raw
  /// font units, so they scale by units-per-em (unlike WrittenFont widths,
  /// which are stored per mille).
  static func inspectorAdvance(
    inspector: TrueTypeInspector, text: String, run: TextRun
  ) -> Double? {
    guard inspector.unitsPerEm > 0 else { return nil }
    var total = 0.0
    for scalar in text.unicodeScalars {
      guard let glyph = inspector.unicodeToGlyph[Int(scalar.value)],
        let width = inspector.advances[glyph]
      else { return nil }
      total += Double(width) / Double(inspector.unitsPerEm) * run.fontSize + run.charSpacing
      if scalar.value == 0x20 { total += run.wordSpacing }
    }
    return total * run.horizontalScale / 100
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    // P17-005: content shared with another page is copied first, so this
    // edit never changes a different page. P18-017: form text privatizes
    // the shared form instead, repointing only this page's entry.
    var graph = graph
    if let formResource {
      graph = try PageContentCopy.makeFormPrivate(
        pageID: pageID, resource: formResource, in: graph, limits: limits
      ).graph
    } else {
      graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: limits)
    }
    let resolved = try resolve(in: graph, limits: limits)
    if let fallback = resolved.fallback {
      return try applyWithFallback(fallback, resolved: resolved, graph: graph, limits: limits)
    }
    if resolved.run.operandPath.count == 2 {
      return try applyInsideTJArray(resolved, graph: graph, limits: limits)
    }
    return try resolved.content.replacing(
      range: resolved.run.stringSpan, with: Self.literalStringBytes(resolved.codes),
      in: graph, limits: limits)
  }

  struct Resolved {
    let content: PageContent
    let run: TextRun
    let codes: [UInt8]
    let font: SimpleFont
    /// P18-007: set when the run's font lacks glyphs and the fallback
    /// program covers the replacement (checked without mutating).
    let fallback: FallbackUse?
    /// P18-017: the addressed form (nil for page content) plus the font
    /// resources the run was indexed against.
    let formID: PDFObjectID?
    let resources: [PDFName: PDFValue]?
  }

  /// P18-007: the checked fallback plan — the program covers every
  /// replacement scalar and subsets cleanly, so apply only embeds and writes.
  struct FallbackUse {
    let custom: CustomTextFont
    let subset: Data
  }

  func resolve(in graph: PDFGraph, limits: PDFLimits) throws -> Resolved {
    // P17-027: the target must still be reachable from the page tree. A page
    // object retained after a delete (retention policy) is stale, and editing
    // it would dirty the document without changing any visible page.
    let view = try PageTreeView(graph: graph)
    guard view.pages.contains(pageID) else {
      throw PDFError(.malformed, "Text edit target is not a page in the document")
    }
    // P18-017: form runs index the form stream against the form's own
    // resources; page runs keep the existing path byte-for-byte.
    let content: PageContent
    let runs: [TextRun]
    let formID: PDFObjectID?
    let resources: [PDFName: PDFValue]?
    if let formResource {
      let loaded = try FormTextContent.load(
        pageID: pageID, resource: formResource, in: graph, limits: limits)
      content = loaded.content
      runs = loaded.runs
      formID = loaded.formID
      resources = loaded.resources
    } else {
      content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
      runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
      formID = nil
      resources = nil
    }
    guard runIndex >= 0, runIndex < runs.count else {
      throw PDFError(.malformed, "Text run index is outside the page")
    }
    let run = runs[runIndex]
    guard let segmentIndex = content.segmentIndex(for: run.stringSpan),
      content.segments[segmentIndex].isEditable
    else {
      throw PDFError(
        .unsupported, "The text run spans streams or uses filters that cannot be edited")
    }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    // P18-017: form runs resolve their font against the effective form
    // resources, never the page's.
    let fontScope: [PDFName: PDFValue]
    if let resources {
      fontScope = [PDFName("Resources"): .dictionary(resources)]
    } else {
      fontScope = page
    }
    guard let font = SimpleFont.resolve(resource: run.fontResource, page: fontScope, in: graph),
      font.isSupported
    else {
      throw PDFError(.unsupported, "The text run's font cannot be edited by this profile")
    }
    // P14-023: Type 3 replacement reuses existing glyph programs; the font
    // must expose readable programs for them to be verified.
    guard font.isEditable else {
      throw PDFError(
        .unsupported,
        "This text uses a Type 3 font without readable glyph programs; the text is preserved, not rewritten")
    }
    guard let codes = font.encode(replacement) else {
      // P18-007: the run's font lacks glyphs. Without a fallback program
      // the command refuses; with one it is checked (not yet embedded).
      guard let fallbackFont else {
        throw PDFError(
          .unsupported,
          font.isType3
            ? "The Type 3 font has no glyph program for every replacement character"
            : "The replacement text needs glyphs this font does not provide; "
              + "provide a fallback font program to substitute them")
      }
      let fallback = try resolveFallback(custom: fallbackFont)
      return Resolved(
        content: content, run: run, codes: [], font: font, fallback: fallback,
        formID: formID, resources: resources)
    }
    return Resolved(
      content: content, run: run, codes: codes, font: font, fallback: nil,
      formID: formID, resources: resources)
  }

  /// P18-007: resolve the fallback without mutating — coverage (P14-021)
  /// first for an explicit missing-glyph error, then a pure subset pass so
  /// validate agrees with apply (which embeds). Uncovered text refuses with
  /// the missing scalars named; nothing is substituted.
  private func resolveFallback(custom: CustomTextFont) throws -> FallbackUse {
    let needed = Set(replacement.unicodeScalars.map { Int($0.value) })
    let availability = try TrueTypeSubsetter.availability(
      program: custom.program, unicodes: needed)
    guard availability.missing.isEmpty else {
      let names = availability.missing.sorted().prefix(4).map {
        "U+" + String($0, radix: 16, uppercase: true)
      }.joined(separator: ", ")
      throw PDFError(
        .unsupported,
        "The fallback font has no glyph for \(names); no partial substitution is written")
    }
    let subset = try TrueTypeSubsetter.subset(program: custom.program, unicodes: needed)
    return FallbackUse(custom: custom, subset: subset)
  }

  /// Rebuild the whole TJ array with the new string and a compensating
  /// adjustment so every following member keeps its position.
  private func applyInsideTJArray(
    _ resolved: Resolved, graph: PDFGraph, limits: PDFLimits
  ) throws -> PDFGraph {
    let content = resolved.content
    let run = resolved.run
    let instruction = content.instructions[run.instructionIndex]
    guard let arrayOperand = instruction.operands.first,
      case .array(let members) = arrayOperand.value
    else {
      throw PDFError(.malformed, "TJ instruction lost its array")
    }
    let memberIndex = run.operandPath[1]
    guard memberIndex < members.count else {
      throw PDFError(.malformed, "TJ member no longer matches the text run")
    }
    // The last member has nothing inside the array to disturb.
    if memberIndex == members.count - 1 {
      return try content.replacing(
        range: run.stringSpan, with: Self.literalStringBytes(resolved.codes), in: graph,
        limits: limits)
    }
    guard let oldAdvance = resolved.font.advance(
      of: run.rawCodes, fontSize: run.fontSize, charSpacing: run.charSpacing,
      wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale),
      let newAdvance = resolved.font.advance(
        of: resolved.codes, fontSize: run.fontSize, charSpacing: run.charSpacing,
        wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale)
    else {
      throw PDFError(
        .unsupported,
        "This font has no width data; text after the replaced run cannot keep its position")
    }
    let em = run.fontSize / 1000 * run.horizontalScale / 100
    let delta = newAdvance - oldAdvance
    let adjustment = em == 0 ? 0 : delta / em

    var rebuilt = members
    rebuilt[memberIndex] = .string(Data(resolved.codes))
    let tail = Self.compensatedTail(
      Array(members.suffix(from: memberIndex + 1)), adjustment: adjustment)
    rebuilt.replaceSubrange((memberIndex + 1)..<members.count, with: tail)
    let serialized = try PDFWriter.serializedValue(.array(rebuilt), limits: limits)
    return try content.replacing(
      range: arrayOperand.span, with: [UInt8](serialized), in: graph, limits: limits)
  }

  /// Absorb an advance delta into the tail following a replaced member: an
  /// existing adjustment number is rewritten, otherwise one is inserted
  /// unless the delta is zero.
  static func compensatedTail(_ tail: [PDFValue], adjustment: Double) -> [PDFValue] {
    var tail = tail
    guard !tail.isEmpty else { return tail }
    if let existing = Self.number(of: tail[0]) {
      tail[0] = Self.adjustmentValue(existing + adjustment)
    } else {
      let value = Self.adjustmentValue(adjustment)
      if value != .integer(0) {
        tail.insert(value, at: 0)
      }
    }
    return tail
  }

  /// P18-007: replace through an embedded fallback program. The fallback is
  /// embedded (or an identical registered subset is reused) and the
  /// replacement is encoded with it. The fallback selection wraps only the
  /// target: for a TJ array the array is split at the member boundary into
  /// two complete TJ instructions with the fallback selection between them,
  /// so preceding members keep the original font untouched; for a single
  /// string the selection is inserted before the string. A restoring
  /// selection of the original font follows whenever later text in the same
  /// scope still uses it. TJ compensation uses the fallback advance.
  private func applyWithFallback(
    _ fallback: FallbackUse, resolved: Resolved, graph: PDFGraph, limits: PDFLimits
  ) throws -> PDFGraph {
    var graph = graph
    let writable = try AddedContent.selectFont(
      style: AddedTextStyle(), custom: fallback.custom, covering: replacement,
      pageID: pageID, in: &graph, resourceOwner: resolved.formID)
    guard let codes = writable.encode(replacement) else {
      throw PDFError(
        .unsupported, "The fallback font cannot encode the replacement text")
    }
    guard let oldAdvance = resolved.font.advance(
      of: resolved.run.rawCodes, fontSize: resolved.run.fontSize,
      charSpacing: resolved.run.charSpacing, wordSpacing: resolved.run.wordSpacing,
      horizontalScale: resolved.run.horizontalScale),
      let newAdvance = Self.fallbackAdvance(
        writable: writable, codes: codes, run: resolved.run)
    else {
      throw PDFError(
        .unsupported,
        "This font has no width data; text after the replaced run cannot keep its position")
    }
    let run = resolved.run
    let content = resolved.content
    let instruction = content.instructions[run.instructionIndex]
    let fallbackName = try PDFWriter.serializedValue(
      .name(writable.resourceName), limits: limits)
    var selection = Array("\n".utf8)
    selection.append(contentsOf: fallbackName)
    selection.append(
      contentsOf: Array(" \(AnnotationSupport.number(run.fontSize)) Tf ".utf8))
    var restore: [UInt8] = []
    if Self.needsFontRestore(run: run, in: content) {
      let oldName = try PDFWriter.serializedValue(.name(run.fontResource), limits: limits)
      restore = Array("\n".utf8)
      restore.append(contentsOf: oldName)
      restore.append(
        contentsOf: Array(" \(AnnotationSupport.number(run.fontSize)) Tf".utf8))
    }
    if run.operandPath.count == 2,
      let arrayOperand = instruction.operands.first,
      case .array(let members) = arrayOperand.value
    {
      let memberIndex = run.operandPath[1]
      guard memberIndex < members.count else {
        throw PDFError(.malformed, "TJ member no longer matches the text run")
      }
      let em = run.fontSize / 1000 * run.horizontalScale / 100
      let delta = newAdvance - oldAdvance
      let adjustment = em == 0 ? 0 : delta / em
      let tail = Self.compensatedTail(
        Array(members.suffix(from: memberIndex + 1)), adjustment: adjustment)
      let targetBytes = try PDFWriter.serializedValue(
        .array([.string(Data(codes))]), limits: limits)
      // P18-007: the split instructions are separate text objects, and pen
      // position does not carry between them in this profile — each part is
      // placed absolutely in the run's own matrix (identity-CTM scope, like
      // the rest of the layout), so real renderers and the indexer agree.
      // The base is the target's original text-space offset.
      let base = run.hasKnownOffset ? run.textSpaceOffset : 0
      func penLine(_ position: Double) throws -> [UInt8] {
        guard run.matrix.count == 6 else {
          throw PDFError(.malformed, "Text run matrix is incomplete")
        }
        let matrix = run.matrix
        let x = matrix[4] + position * matrix[0]
        let y = matrix[5] + position * matrix[1]
        let operands = [matrix[0], matrix[1], matrix[2], matrix[3], x, y]
          .map { AnnotationSupport.number($0) }.joined(separator: " ")
        return Array((operands + " Tm").utf8)
      }
      // Preceding members keep the original font in their own instruction.
      var replacement: [UInt8] = []
      if memberIndex > 0 {
        let first = try PDFWriter.serializedValue(
          .array(Array(members.prefix(upTo: memberIndex))), limits: limits)
        replacement += first
        replacement += Array(" TJ".utf8)
      }
      replacement += selection
      replacement += try penLine(base)
      replacement += Array("\n".utf8)
      replacement += targetBytes
      replacement += Array(" TJ".utf8)
      if tail.isEmpty {
        // Nothing follows inside the array: the original operator closes the
        // target instruction, and the restore (when needed) follows it.
        var ranges = [(range: arrayOperand.span, replacement: replacement)]
        if !restore.isEmpty {
          ranges.append((
            range: instruction.span.upperBound..<instruction.span.upperBound,
            replacement: restore))
        }
        return try content.replacing(ranges: ranges, in: graph, limits: limits)
      }
      // Following members switch back to the original font inside the same
      // rewrite, placed where the target ends; they must never show in the
      // fallback (its encoding only covers the replacement).
      let tailBytes = try PDFWriter.serializedValue(.array(tail), limits: limits)
      var innerRestore = restore
      if innerRestore.isEmpty {
        let oldName = try PDFWriter.serializedValue(.name(run.fontResource), limits: limits)
        innerRestore = Array("\n".utf8)
        innerRestore.append(contentsOf: oldName)
        innerRestore.append(
          contentsOf: Array(" \(AnnotationSupport.number(run.fontSize)) Tf".utf8))
      }
      replacement += innerRestore
      replacement += Array(" ".utf8)
      replacement += try penLine(base + newAdvance)
      replacement += Array("\n".utf8)
      replacement += tailBytes
      return try content.replacing(
        range: arrayOperand.span, with: replacement, in: graph, limits: limits)
    }
    var ranges = [(
      range: run.stringSpan.lowerBound..<run.stringSpan.lowerBound, replacement: selection)]
    ranges.append((range: run.stringSpan, replacement: Self.literalStringBytes(codes)))
    if !restore.isEmpty {
      ranges.append((
        range: instruction.span.upperBound..<instruction.span.upperBound, replacement: restore))
    }
    return try content.replacing(ranges: ranges, in: graph, limits: limits)
  }

  /// Whether later text in the target's scope still uses the original font:
  /// later members of the same TJ array always do, as does the next text
  /// before any following font selection.
  static func needsFontRestore(run: TextRun, in content: PageContent) -> Bool {
    if run.operandPath.count == 2,
      let instruction = content.instructions[safe: run.instructionIndex],
      case .array(let members)? = instruction.operands.first?.value
    {
      if run.operandPath[1] < members.count - 1 { return true }
    }
    var index = run.instructionIndex + 1
    while index < content.instructions.count {
      let name = content.instructions[index].operatorName
      if name == "Tf" { return false }
      if name == "Tj" || name == "TJ" || name == "'" || name == "\"" { return true }
      index += 1
    }
    return false
  }

  /// Advance of fallback-encoded codes under the run's spacing state,
  /// mirroring SimpleFont.advance (spacing applies per code regardless of
  /// the font; word spacing applies to the space scalar).
  static func fallbackAdvance(
    writable: WritableTextFont, codes: [UInt8], run: TextRun
  ) -> Double? {
    switch writable {
    case .graph(let font, _):
      return font.advance(
        of: codes, fontSize: run.fontSize, charSpacing: run.charSpacing,
        wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale)
    case .embedded(let written, _):
      var total = 0.0
      for code in codes {
        guard let width = written.widths[code] else { return nil }
        total += Double(width) / 1000 * run.fontSize + run.charSpacing
        if written.encoding[code] == 0x20 { total += run.wordSpacing }
      }
      return total * run.horizontalScale / 100
    }
  }

  static func number(of value: PDFValue) -> Double? {
    switch value {
    case .integer(let raw): return Double(raw)
    case .real(let raw): return raw
    default: return nil
    }
  }

  /// Round to a thousandth of a text-space unit and prefer integers.
  static func adjustmentValue(_ value: Double) -> PDFValue {
    let rounded = (value * 1000).rounded() / 1000
    if rounded.rounded() == rounded, rounded.magnitude < 9e15 {
      return .integer(Int64(rounded))
    }
    return .real(rounded)
  }

  /// PDF literal string bytes with balanced escaping for delimiters and
  /// backslashes; non-printable codes use three-digit octal escapes.
  static func literalStringBytes(_ codes: [UInt8]) -> [UInt8] {
    var output: [UInt8] = [40]
    for byte in codes {
      switch byte {
      case 40, 41, 92:
        output.append(92)
        output.append(byte)
      case 32...126:
        output.append(byte)
      default:
        output.append(92)
        output.append(48 + (byte >> 6))
        output.append(48 + ((byte >> 3) & 7))
        output.append(48 + (byte & 7))
      }
    }
    output.append(41)
    return output
  }
}
