import AppKit
import CoreText
import PDFCore
import PDFEditing

public enum PageTextFormatChange: Sendable {
  case family(AddedTextStyle.Family)
  case bold(Bool)
  case italic(Bool)
  case size(Double)
  case color([Double])
}

/// A local insertion plan. Mixed embedded subsets become attributed runs;
/// unsupported characters never fall back to a substituted system font.
public struct NativeTextInsertionPlan {
  public let usesSourceFontFallback: Bool
  public let fragments: [PageTextFragment]
  public let attributedText: NSAttributedString?
  public let issue: String?
}

/// Canonical point-size attributes survive view zoom and native typing Undo.
/// AppKit supplies caret/selection/layout; PDF output uses these same spans.
@MainActor
public final class NativeTextFormatting {
  private static let key = NSAttributedString.Key("spdf.pageText.format")
  private weak var view: NSTextView?
  private let original: [PageTextFragment]
  private var fallback: PageTextFormat
  private var scale = 1.0
  private let sourceFonts: [PDFName: NSFont]
  private let profiles: [PDFName: PageTextFontProfile]
  public var onChange: (() -> Void)?

  public init(view: NSTextView, fragments: [PageTextFragment], initial: PageTextFormat,
    profiles: [PDFName: PageTextFontProfile] = [:]) {
    sourceFonts = NativeParagraphEditing.fonts(profiles: profiles)
    self.profiles = profiles
    self.view = view
    original = Self.coalesced(fragments)
    fallback = initial
    let attributed = NSMutableAttributedString(string: "")
    for fragment in fragments {
      attributed.append(
        NSAttributedString(
          string: fragment.text,
          attributes: [Self.key: Self.dictionary(fragment.format)]))
    }
    view.isRichText = true
    view.importsGraphics = false
    view.usesFontPanel = false
    view.textStorage?.setAttributedString(attributed)
    view.typingAttributes = [Self.key: Self.dictionary(initial)]
  }

  public func fragments(in requested: NSRange? = nil) -> [PageTextFragment] {
    guard let storage = view?.textStorage else { return [] }
    let range = requested ?? NSRange(location: 0, length: storage.length)
    var result: [PageTextFragment] = []
    storage.enumerateAttributes(in: range) { attrs, range, _ in
      let text = (storage.string as NSString).substring(with: range)
      let format = Self.format(attrs, fallback: self.fallback)
      if let last = result.last, last.format == format {
        result[result.count - 1] = .init(text: last.text + text, format: format)
      } else {
        result.append(.init(text: text, format: format))
      }
    }
    return result
  }

  public var hasChanges: Bool { fragments() != original }

  public func insertionIssue(_ text: String) -> String? {
    insertionPlan(text, replacing: view?.selectedRange()
      ?? NSRange(location: 0, length: 0)).issue
  }

  /// Resolve each inserted scalar against verified fonts already present in
  /// this paragraph. A subset that lacks a character is never allowed to
  /// borrow an unrelated installed font silently.
  public func insertionPlan(_ text: String, replacing range: NSRange) -> NativeTextInsertionPlan {
    guard let view else {
      return .init(usesSourceFontFallback: false, fragments: [], attributedText: nil,
        issue: "The page text editor is unavailable.")
    }
    let base = Self.format(view.typingAttributes, fallback: fallback)
    let visible = text.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }
    let visibleText = String(String.UnicodeScalarView(visible))
    guard PageTextSourceFont.canWriteInline(visibleText) else {
      return .init(usesSourceFontFallback: false, fragments: [], attributedText: nil,
        issue: "This text needs shaping that inline editing does not yet support. The text was kept.")
    }

    var current: [(range: NSRange, format: PageTextFormat)] = []
    if let storage = view.textStorage {
      storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
        attrs, runRange, _ in
        current.append((runRange, Self.format(attrs, fallback: fallback)))
      }
    }
    let insertion = range.location == NSNotFound ? view.selectedRange().location : range.location
    var fragments: [PageTextFragment] = []

    func appendFragment(_ value: String, format: PageTextFormat) {
      if let last = fragments.last, last.format == format {
        fragments[fragments.count - 1] = .init(text: last.text + value, format: format)
      } else {
        fragments.append(.init(text: value, format: format))
      }
    }

    var needsFallback = false
    for scalar in text.unicodeScalars {
      if scalar == "\n" || scalar == "\r" {
        appendFragment(String(scalar), format: base)
      } else if let source = base.sourceFont,
        profiles[source.resource]?.glyphs[String(scalar)] != nil {
        appendFragment(String(scalar), format: base)
      } else if base.sourceFont == nil, StandardTextFont.canEncode(String(scalar)) {
        appendFragment(String(scalar), format: base)
      } else if let alternative = sourceFormat(for: scalar, base: base, current: current,
        insertion: insertion) {
        needsFallback = true
        appendFragment(String(scalar), format: alternative)
      } else {
        return .init(usesSourceFontFallback: false, fragments: fragments, attributedText: nil,
          issue: "No font already used by this paragraph can represent “\(String(scalar))”. Choose another font or remove that character.")
      }
    }
    guard needsFallback else {
      return .init(usesSourceFontFallback: false, fragments: fragments,
        attributedText: nil, issue: nil)
    }
    let attributed = NSMutableAttributedString(string: "")
    let paragraphStyle = view.typingAttributes[.paragraphStyle]
    for fragment in fragments {
      var attrs = attributes(fragment.format, scale: scale)
      if let paragraphStyle { attrs[.paragraphStyle] = paragraphStyle }
      attributed.append(NSAttributedString(string: fragment.text, attributes: attrs))
    }
    return .init(usesSourceFontFallback: true, fragments: fragments,
      attributedText: attributed, issue: nil)
  }

  private func sourceFormat(for scalar: UnicodeScalar, base: PageTextFormat,
    current: [(range: NSRange, format: PageTextFormat)], insertion: Int) -> PageTextFormat? {
    let value = String(scalar)
    let candidates = profiles.compactMap { resource, profile
      -> (resource: PDFName, source: PageTextSourceFont, distance: Int, order: String)? in
      guard profile.glyphs[value] != nil, sourceFonts[resource] != nil,
        PageTextSourceFont.canWriteInline(value) else { return nil }
      if let baseName = base.sourceFont?.name, profile.source.name != baseName {
        return nil
      }
      let nearest = current.compactMap { entry -> Int? in
        guard entry.format.sourceFont?.resource == resource else { return nil }
        let text = (view?.string as NSString?)?.substring(with: entry.range) ?? ""
        guard text.range(of: value) != nil else { return Int.max }
        return abs(entry.range.location + (text as NSString).range(of: value).location - insertion)
      }.min() ?? Int.max
      return (resource, profile.source, nearest, String(decoding: resource.bytes, as: UTF8.self))
    }
    guard !candidates.isEmpty else { return nil }
    let sorted = candidates.sorted {
      if $0.distance != $1.distance { return $0.distance < $1.distance }
      return $0.order < $1.order
    }
    // Two different embedded programs with the same style name would make
    // automatic assignment a guess. Prefer the source used at the caret;
    // otherwise require an unambiguous candidate.
    if base.sourceFont == nil {
      let nearest = sorted[0].distance
      let tied = sorted.filter { $0.distance == nearest }
      guard tied.count == 1 else { return nil }
    }
    var result = base
    result.sourceFont = sorted[0].source
    return result
  }

  private static func coalesced(_ fragments: [PageTextFragment]) -> [PageTextFragment] {
    var result: [PageTextFragment] = []
    for fragment in fragments where !fragment.text.isEmpty {
      if let previous = result.last, previous.format == fragment.format {
        result[result.count - 1] = .init(
          text: previous.text + fragment.text, format: fragment.format)
      } else {
        result.append(fragment)
      }
    }
    return result
  }

  public func selection(isTyping: Bool) -> (
    format: PageTextFormat, mixed: Set<String>, scope: String, usesSourceFont: Bool
  ) {
    guard let view else { return (fallback, [], "Text", fallback.sourceFont != nil) }
    let range =
      isTyping
      ? view.selectedRange() : NSRange(location: 0, length: (view.string as NSString).length)
    if range.length == 0 {
      return (
        Self.format(view.typingAttributes, fallback: fallback), [],
        isTyping ? "Typing style" : "Whole text box",
        Self.format(view.typingAttributes, fallback: fallback).sourceFont != nil
      )
    }
    let formats = fragments(in: range).map(\.format)
    let first = formats.first ?? fallback
    var mixed = Set<String>()
    for format in formats {
      if format.sourceFont != first.sourceFont || format.font.family != first.font.family { mixed.insert("family") }
      if format.font.isBold != first.font.isBold { mixed.insert("bold") }
      if format.font.isItalic != first.font.isItalic { mixed.insert("italic") }
      if format.size != first.size { mixed.insert("size") }
      if format.color != first.color { mixed.insert("color") }
    }
    return (first, mixed, isTyping ? "Selected characters" : "Whole text box",
      formats.contains { $0.sourceFont != nil })
  }

  @discardableResult
  public func apply(_ change: PageTextFormatChange, isTyping: Bool) -> String? {
    guard let view, let storage = view.textStorage else { return nil }
    if view.hasMarkedText() { return "Finish composing text before changing its format." }
    let selection = view.selectedRange()
    let range = isTyping ? selection : NSRange(location: 0, length: storage.length)
    let selectedText = (view.string as NSString).substring(with: range)
    let changesFont: Bool
    switch change { case .family, .bold, .italic: changesFont = true; default: changesFont = false }
    let sources = range.length == 0 ? [Self.format(view.typingAttributes, fallback: fallback)]
      : fragments(in: range).map(\.format)
    if sources.contains(where: { $0.sourceFont != nil }) {
      switch change {
      case .bold, .italic: return "Choose a font family before changing this embedded font's weight or slant."
      default: break
      }
    }
    guard !changesFont || StandardTextFont.canEncode(selectedText) else {
      return "These PDF fonts cannot represent every selected character. The format was kept."
    }
    func changed(_ source: PageTextFormat) -> PageTextFormat {
      var result = source
      switch change {
      case .family(let family):
        result.sourceFont = nil
        result.characterSpacing = 0
        result.font = .face(family: family, bold: source.font.isBold, italic: source.font.isItalic)
      case .bold(let enabled):
        result.font = .face(family: source.font.family, bold: enabled, italic: source.font.isItalic)
      case .italic(let enabled):
        result.font = .face(family: source.font.family, bold: source.font.isBold, italic: enabled)
      case .size(let size): result.size = size
      case .color(let color): result.color = color
      }
      return result
    }
    let initial = changed(Self.format(view.typingAttributes, fallback: fallback))
    guard initial.isValid else { return "Choose a valid font size and color." }
    if range.length == 0 {
      fallback = initial
      view.typingAttributes = attributes(initial, scale: scale)
      onChange?()
      return nil
    }
    view.breakUndoCoalescing()
    let snapshot = NSAttributedString(attributedString: storage)
    let typing = view.typingAttributes
    view.undoManager?.beginUndoGrouping()
    registerUndo(snapshot, selection: selection, typing: typing)
    let pieces = fragments(in: range)
    var offset = range.location
    storage.beginEditing()
    for piece in pieces {
      let format = changed(piece.format)
      let length = (piece.text as NSString).length
      storage.addAttributes(
        attributes(format, scale: scale), range: NSRange(location: offset, length: length))
      offset += length
    }
    storage.endEditing()
    view.undoManager?.setActionName("Format Text")
    view.undoManager?.endUndoGrouping()
    view.setSelectedRange(selection)
    view.didChangeText()
    onChange?()
    return nil
  }

  private func registerUndo(
    _ snapshot: NSAttributedString, selection: NSRange,
    typing: [NSAttributedString.Key: Any]
  ) {
    view?.undoManager?.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        guard let view = target.view, let storage = view.textStorage else { return }
        target.registerUndo(
          NSAttributedString(attributedString: storage),
          selection: view.selectedRange(), typing: view.typingAttributes)
        storage.setAttributedString(snapshot)
        view.setSelectedRange(selection)
        view.typingAttributes = typing
        view.didChangeText()
        target.onChange?()
      }
    }
  }

  public func render(scale: Double, minimumLineSpacing: Double) {
    guard let view, let storage = view.textStorage else { return }
    view.layoutManager?.usesFontLeading = false
    self.scale = scale
    let typing = Self.format(view.typingAttributes, fallback: fallback)
    var pieces: [(NSRange, PageTextFormat)] = []
    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
      attrs, range, _ in
      pieces.append((range, Self.format(attrs, fallback: self.fallback)))
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = minimumLineSpacing * scale
    // Imported PDFs often use leading below the font's platform default.
    // Preserve that baseline grid, allowing explicit larger type to grow it.
    paragraph.maximumLineHeight = max(minimumLineSpacing, pieces.map { $0.1.size }.max() ?? typing.size) * scale
    paragraph.lineBreakMode = .byWordWrapping
    storage.beginEditing()
    for (range, format) in pieces {
      storage.addAttributes(attributes(format, scale: scale), range: range)
      if let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
        NativeParagraphEditing.applySourceAdvances(to: storage, range: range, format: format,
          font: font, profiles: profiles, scale: scale)
      }
    }
    storage.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
    storage.endEditing()
    var attributes = attributes(typing, scale: scale)
    attributes[.paragraphStyle] = paragraph
    view.typingAttributes = attributes
    view.insertionPointColor = NSColor(
      srgbRed: typing.color[0], green: typing.color[1], blue: typing.color[2], alpha: 1)
  }

  private func attributes(_ format: PageTextFormat, scale: Double) -> [NSAttributedString
    .Key: Any]
  {
    let font: NSFont?
    if let source = format.sourceFont, let embedded = sourceFonts[source.resource] {
      font = CTFontCreateCopyWithAttributes(embedded, format.size * scale, nil, nil) as NSFont
    } else if format.sourceFont != nil { font = nil }
    else { font = NSFont(name: format.font.rawValue, size: format.size * scale) }
    guard let font else { return [:] }
    return [
      Self.key: Self.dictionary(format), .font: font, .kern: format.characterSpacing * scale, .ligature: 0,
      .foregroundColor: NSColor(
        srgbRed: format.color[0], green: format.color[1], blue: format.color[2], alpha: 1),
    ]
  }
  private static func dictionary(_ format: PageTextFormat) -> NSDictionary {
    var result: [String: Any] = ["font": format.font.rawValue, "size": format.size,
      "color": format.color, "spacing": format.characterSpacing]
    if let source = format.sourceFont {
      result["resource"] = String(decoding: source.resource.bytes, as: UTF8.self)
      result["sourceName"] = source.name
    }
    return result as NSDictionary
  }
  private static func format(_ attrs: [NSAttributedString.Key: Any], fallback: PageTextFormat)
    -> PageTextFormat
  {
    guard let dictionary = attrs[key] as? NSDictionary,
      let name = dictionary["font"] as? String, let font = StandardTextFont(rawValue: name),
      let size = dictionary["size"] as? Double, let color = dictionary["color"] as? [Double]
    else { return fallback }
    let source: PageTextSourceFont?
    if let resource = dictionary["resource"] as? String, let name = dictionary["sourceName"] as? String {
      source = .init(resource: PDFName(resource), name: name)
    } else { source = nil }
    return .init(font: font, size: size, color: color, sourceFont: source,
      characterSpacing: dictionary["spacing"] as? Double ?? 0)
  }
}
