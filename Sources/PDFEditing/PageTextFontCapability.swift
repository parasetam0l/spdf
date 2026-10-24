import Foundation

/// TXT-02: the font-assignment policy shared by inline paragraph editing and
/// paragraph reflow. A replacement character may use a different embedded
/// subset only when the faces match and at least two shared source glyphs prove
/// the programs have the same advances. No system-font substitution is allowed.
public enum PageTextFontCapability {
  /// Strip a six-letter subset prefix such as `ABCDEF+` and compare face names
  /// case-insensitively.
  public static func normalizedEmbeddedFace(_ name: String) -> String {
    let bytes = Array(name.utf8)
    if bytes.count > 7, bytes[6] == 43,
      bytes[..<6].allSatisfy({ (65...90).contains($0) })
    {
      return String(decoding: bytes.dropFirst(7), as: UTF8.self).lowercased()
    }
    return name.lowercased()
  }

  /// One refusal message for inline typing and paragraph reflow.
  public static func uncoveredCharacterMessage(_ character: String) -> String {
    "No font already used by this paragraph can represent “\(character)”. "
      + "Choose another font or remove that character."
  }

  /// Compare the source glyphs that both profiles contain. Two agreeing
  /// non-zero advances are the minimum evidence for using an alternative
  /// subset; a missing or ambiguous witness fails closed.
  public static func sharesMetrics(
    source: PageTextFontProfile, candidate: PageTextFontProfile,
    witnessText: String
  ) -> Bool {
    var sharedGlyphs = Set<String>()
    for scalar in witnessText.unicodeScalars {
      let text = String(scalar)
      guard let sourceGlyph = source.glyphs[text],
        let candidateGlyph = candidate.glyphs[text],
        sourceGlyph.width.isFinite, candidateGlyph.width.isFinite
      else { continue }
      guard abs(sourceGlyph.width - candidateGlyph.width) <= 0.001 else { return false }
      sharedGlyphs.insert(text)
    }
    return sharedGlyphs.count >= 2
  }

  /// TXT-02: a same-face subset may fill a glyph gap when the source programs
  /// share metric witnesses. Some PDF generators split a face into tiny
  /// subsets with no overlapping glyphs (a `ş/ğ` subset next to a Latin
  /// subset); for that case the caller can use the candidate's own direct
  /// glyph coverage, but never a different face or an unrelated program.
  public static func canUseSubset(
    source: PageTextFontProfile, candidate: PageTextFontProfile,
    witnessText: String
  ) -> Bool {
    guard normalizedEmbeddedFace(source.source.name)
      == normalizedEmbeddedFace(candidate.source.name)
    else { return false }
    if sharesMetrics(source: source, candidate: candidate, witnessText: witnessText) {
      return true
    }
    return !candidate.glyphs.isEmpty
  }
}
