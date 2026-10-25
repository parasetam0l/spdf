import CoreText
import CryptoKit
import Foundation
import PDFEditing

/// A local record of Google Fonts files installed after their license was
/// displayed and accepted. Ordinary fonts in ~/Library/Fonts are never
/// treated as embeddable based on family name alone.
public enum ProvisionedFontStore {
  private static let manifestName = ".spdf-licensed-fonts.json"
  private static let maximumManifestBytes = 2 * 1_024 * 1_024
  private static let maximumFileBytes = 20 * 1_024 * 1_024
  private static let maximumLoadedFonts = 32
  private static let maximumLoadedBytes = 120 * 1_024 * 1_024

  private struct Manifest: Codable {
    var version: Int
    var packages: [PackageRecord]
  }

  private struct PackageRecord: Codable {
    var family: String
    var licenseDirectory: String
    var licenseText: String
    var licenseAccepted: Bool
    var files: [FileRecord]
  }

  private struct FileRecord: Codable {
    var name: String
    var sha256: String
  }

  /// Persist the exact files covered by the user's accepted license. The
  /// manifest stays beside the per-user font installs and is not a font file.
  static func recordAccepted(
    _ package: GoogleFontPackage, installed: [URL], in directory: URL
  ) throws {
    guard let licenseText = package.licenseText,
      !licenseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let licenseDirectory = package.licenseDirectory,
      GoogleFontsInstaller.licenseDirectories.contains(licenseDirectory),
      installed.count == package.files.count, installed.count <= GoogleFontsInstaller.Limits().maxFiles
    else { throw FontProvisioningError.licenseRequired }

    let root = directory.standardizedFileURL
    var files: [FileRecord] = []
    for url in installed {
      let file = url.standardizedFileURL
      guard file.deletingLastPathComponent() == root,
        file.lastPathComponent == url.lastPathComponent,
        let data = try? Data(contentsOf: file), data.count <= maximumFileBytes else {
        throw FontProvisioningError.malformed("An installed font could not be verified.")
      }
      files.append(.init(name: file.lastPathComponent, sha256: digest(data)))
    }

    let manifestURL = root.appendingPathComponent(manifestName)
    var manifest = readManifest(at: manifestURL) ?? Manifest(version: 1, packages: [])
    guard manifest.version == 1 else {
      throw FontProvisioningError.malformed("The local font license record is unsupported.")
    }
    manifest.packages.removeAll { $0.family.caseInsensitiveCompare(package.family) == .orderedSame }
    manifest.packages.append(.init(
      family: package.family, licenseDirectory: licenseDirectory,
      licenseText: licenseText, licenseAccepted: true, files: files))
    guard manifest.packages.count <= 200 else {
      throw FontProvisioningError.tooLarge("The local font license record reached its limit.")
    }
    let data = try JSONEncoder().encode(manifest)
    guard data.count <= maximumManifestBytes else {
      throw FontProvisioningError.tooLarge("The local font license record is too large.")
    }
    try data.write(to: manifestURL, options: .atomic)
  }

  /// Return only byte-identical, locally accepted, subsettable TrueType fonts.
  /// This intentionally ignores fonts installed outside the app's accepted
  /// provisioning flow and refuses changed files. FNT-01: faces imported from
  /// a user-provided licensed font file (recorded individually by digest) are
  /// merged in, so the inline editor sees one accepted set.
  public static func availableFonts(
    in directory: URL? = nil, importedDirectory: URL? = nil
  ) -> [CustomTextFont] {
    let root = (directory ?? GoogleFontsInstaller.defaultFontsDirectory()).standardizedFileURL
    var result: [CustomTextFont] = []
    var totalBytes = 0
    var identifiers = Set<String>()
    let url = root.appendingPathComponent(manifestName)
    if let manifest = readManifest(at: url), manifest.version == 1,
      manifest.packages.count <= 200
    {
      for package in manifest.packages.sorted(by: { $0.family.localizedStandardCompare($1.family) == .orderedAscending }) {
        guard package.licenseAccepted,
          !package.licenseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          GoogleFontsInstaller.licenseDirectories.contains(package.licenseDirectory) else { continue }
        for record in package.files {
          guard result.count < maximumLoadedFonts, !record.name.isEmpty,
            URL(fileURLWithPath: record.name).lastPathComponent == record.name,
            URL(fileURLWithPath: record.name).pathExtension.lowercased() == "ttf" else { continue }
          let file = root.appendingPathComponent(record.name).standardizedFileURL
          guard file.deletingLastPathComponent() == root,
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]),
            values.isSymbolicLink != true,
            let data = try? Data(contentsOf: file), data.count <= maximumFileBytes,
            totalBytes + data.count <= maximumLoadedBytes,
            digest(data) == record.sha256,
            let inspector = try? TrueTypeInspector.inspect(data),
            !inspector.isCFF, inspector.permitsEditableSubsetEmbedding,
            inspector.unicodeToGlyph.values.contains(where: { $0 > 0 && $0 < inspector.glyphCount })
          else { continue }

          guard let native = coreTextFont(program: data, size: 12) else { continue }
          let actualFamily = CTFontCopyFamilyName(native) as String
          let style = CTFontCopyPostScriptName(native) as String
          let traits = CTFontGetSymbolicTraits(native)
          let label = "\(actualFamily) · \(style)"
          let id = record.sha256
          guard identifiers.insert(id).inserted else { continue }
          totalBytes += data.count
          result.append(.init(
            program: data, familyName: package.family, faceName: label, identifier: id,
            isBold: traits.contains(.boldTrait), isItalic: traits.contains(.italicTrait)))
        }
        if result.count >= maximumLoadedFonts || totalBytes >= maximumLoadedBytes { break }
      }
    }
    // FNT-01: locally imported, explicitly licensed faces. Entries are capped
    // together with the provisioned Google Fonts files above.
    for font in ImportedFontStore.availableFonts(in: importedDirectory) {
      guard result.count < maximumLoadedFonts,
        totalBytes + font.program.count <= maximumLoadedBytes,
        identifiers.insert(font.identifier).inserted
      else { continue }
      totalBytes += font.program.count
      result.append(font)
    }
    return result
  }

  private static func readManifest(at url: URL) -> Manifest? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
      let size = values.fileSize, size >= 0, size <= maximumManifestBytes,
      let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Manifest.self, from: data)
  }

  static func coreTextFont(program: Data, size: Double) -> CTFont? {
    guard size.isFinite, size > 0,
      let descriptors = CTFontManagerCreateFontDescriptorsFromData(program as CFData)
        as? [CTFontDescriptor], let descriptor = descriptors.first else { return nil }
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    guard let inspector = try? TrueTypeInspector.inspect(program, requireUnicodeMap: false) else {
      return nil
    }
    guard inspector.tables["fvar"] != nil else { return font }

    // The PDF subsetter writes the source program's base glyf/hmtx tables and
    // drops variation tables. Measure the variable font at those same default
    // axis values, rather than inheriting a named instance such as Noto Sans
    // Thin from CoreText's first descriptor.
    guard let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]], !axes.isEmpty else {
      return nil
    }
    var defaults: [NSNumber: NSNumber] = [:]
    for axis in axes {
      guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
        let value = axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber
      else { return nil }
      defaults[identifier] = value
    }
    guard defaults.count == axes.count else { return nil }
    let attributes = [kCTFontVariationAttribute as String: defaults] as CFDictionary
    let defaultDescriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
    let defaultFont = CTFontCreateWithFontDescriptor(defaultDescriptor, size, nil)
    guard let current = CTFontCopyVariation(defaultFont) as? [NSNumber: NSNumber] else { return nil }
    guard defaults.allSatisfy({ identifier, value in
      guard let active = current[identifier] else { return true }
      return active.doubleValue == value.doubleValue
    }) else { return nil }
    return defaultFont
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
