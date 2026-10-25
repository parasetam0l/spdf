import CoreText
import Foundation
import PDFCore
import PDFEditing

/// FNT-01: the user-facing local font import boundary. A user-provided font
/// file is inspected without mutating anything; face selection and embedding
/// eligibility are reported per face; only after the user states that they hold
/// a license covering PDF embedding is a selected face copied into the app's
/// private imported-font store and recorded with its content digest.
public enum LocalFontImportError: Error, LocalizedError, Equatable {
  case notAFileURL
  case unreadable(String)
  case fileNotRegular(String)
  case fileTooLarge(String)
  case licenseNotAccepted
  case faceNotFound(Int)
  case faceNotEligible(String)
  case changedSinceInspection
  case storage(String)

  public var errorDescription: String? {
    switch self {
    case .notAFileURL:
      return "Only a local font file can be imported."
    case .unreadable(let message), .fileNotRegular(let message), .fileTooLarge(let message),
      .faceNotEligible(let message), .storage(let message):
      return message
    case .licenseNotAccepted:
      return
        "Confirm that you hold a license covering embedding this font in PDF documents before importing it."
    case .faceNotFound(let index):
      return "The selected face (number \(index + 1)) is no longer present in the font file."
    case .changedSinceInspection:
      return "The font file changed after it was inspected. Choose the file again before importing."
    }
  }
}

/// FNT-01: one face of a user-selected font file, with Core Text identity and
/// the checked embedding eligibility. The exact program bytes are carried so
/// the writer can subset exactly this face.
public struct LocalFontFace: Sendable, Equatable, Identifiable {
  public let inspection: FontFaceInspection
  public let familyName: String
  public let styleName: String
  public let postScriptName: String
  /// User-facing face label, for example "DejaVu Sans · Book".
  public let faceName: String
  public let isBold: Bool
  public let isItalic: Bool
  /// Set for variable fonts: the app previews and embeds the default axis
  /// values only.
  public let variableFontNote: String?
  /// Effective eligibility: the program-level checks plus the Core Text
  /// preview/instance checks performed by this MacServices layer.
  public let eligibility: FontEmbeddingEligibility

  public init(
    inspection: FontFaceInspection, familyName: String, styleName: String,
    postScriptName: String, faceName: String, isBold: Bool, isItalic: Bool,
    variableFontNote: String?, eligibility: FontEmbeddingEligibility
  ) {
    self.inspection = inspection
    self.familyName = familyName
    self.styleName = styleName
    self.postScriptName = postScriptName
    self.faceName = faceName
    self.isBold = isBold
    self.isItalic = isItalic
    self.variableFontNote = variableFontNote
    self.eligibility = eligibility
  }

  public var id: String { identifier }
  public var faceIndex: Int { inspection.faceIndex }
  public var programDigest: String { inspection.programDigest }
  public var program: Data { inspection.program }
  public var isEligible: Bool { eligibility.isEligible }
  /// Stable identity for the license record and the editing pipeline. It
  /// includes the program digest, so a changed file or another face never
  /// reuses the accepted identity.
  public var identifier: String { "import-\(inspection.programDigest)-\(inspection.faceIndex)" }

  public var eligibilityLabel: String {
    if isEligible {
      return variableFontNote == nil
        ? "Eligible for subset embedding" : "Eligible at default axis values"
    }
    return inspection.eligibility.label
  }
}

/// FNT-01: bounded inspection result for one local font file.
public struct LocalFontFileInspection: Sendable, Equatable {
  public let url: URL
  public let fileName: String
  public let fileDigest: String
  public let byteCount: Int
  public let faces: [LocalFontFace]

  public var eligibleFaces: [LocalFontFace] { faces.filter(\.isEligible) }
  public var isCollection: Bool { faces.contains { $0.inspection.wasExtractedFromCollection } }

  /// The first eligible face, preferring the regular weight.
  public var preferredFace: LocalFontFace? {
    eligibleFaces.min { left, right in
      let leftRank = (left.isBold ? 1 : 0) + (left.isItalic ? 1 : 0)
      let rightRank = (right.isBold ? 1 : 0) + (right.isItalic ? 1 : 0)
      if leftRank != rightRank { return leftRank < rightRank }
      return left.faceIndex < right.faceIndex
    }
  }
}

public enum LocalFontImport {
  public struct Limits: Sendable, Equatable {
    public var maxFileBytes: Int
    public var inspection: FontImportInspection.Limits

    public init(
      maxFileBytes: Int = 20 * 1_024 * 1_024,
      inspection: FontImportInspection.Limits = .init()
    ) {
      self.maxFileBytes = maxFileBytes
      self.inspection = inspection
    }
  }

  /// The assertion recorded for an imported local font. The app never verifies
  /// a license and never downloads a font: it records exactly what the user
  /// confirmed for exactly these bytes.
  public static func licenseAssertion(fileName: String, faceName: String) -> String {
    "The user stated they hold a license for “\(fileName)” that permits embedding and subsetting the face “\(faceName)” in PDF documents."
  }

  /// Read and inspect a local font file without copying or registering it.
  public static func inspect(
    fileAt url: URL, limits: Limits = .init()
  ) throws -> LocalFontFileInspection {
    guard url.isFileURL else { throw LocalFontImportError.notAFileURL }
    let file = url.standardizedFileURL
    let values: URLResourceValues
    do {
      values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isReadableKey,
      ])
    } catch {
      throw LocalFontImportError.unreadable("The selected font file cannot be read.")
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw LocalFontImportError.fileNotRegular(
        "Choose a regular font file, not a folder or a symbolic link.")
    }
    guard values.isReadable != false, let size = values.fileSize else {
      throw LocalFontImportError.unreadable("The selected font file cannot be read.")
    }
    guard size > 0 else {
      throw LocalFontImportError.unreadable("The selected font file is empty.")
    }
    guard size <= limits.maxFileBytes else {
      throw LocalFontImportError.fileTooLarge(
        "The selected font file exceeds the 20 MB import bound.")
    }
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch {
      throw LocalFontImportError.unreadable("The selected font file cannot be read.")
    }
    guard data.count <= limits.maxFileBytes else {
      throw LocalFontImportError.fileTooLarge(
        "The selected font file exceeds the 20 MB import bound.")
    }
    let inspections: [FontFaceInspection]
    do {
      inspections = try FontImportInspection.inspectFaces(data, limits: limits.inspection)
    } catch let error as FontImportError {
      throw LocalFontImportError.unreadable(
        error.errorDescription ?? "The selected file is not a supported font.")
    }
    let faces = inspections.map { face in
      makeFace(face)
    }
    return LocalFontFileInspection(
      url: file, fileName: file.lastPathComponent,
      fileDigest: FontImportDigest.sha256Hex(data), byteCount: data.count, faces: faces)
  }

  /// Copy one eligible, user-licensed face into the app's imported-font store
  /// and record the accepted license assertion for exactly these bytes. The
  /// file is re-read and re-inspected first; a change since the preview refuses
  /// instead of importing unverified bytes.
  public static func install(
    face: LocalFontFace, accepting licenseAccepted: Bool, from url: URL,
    in directory: URL? = nil, limits: Limits = .init()
  ) throws -> CustomTextFont {
    guard licenseAccepted else { throw LocalFontImportError.licenseNotAccepted }
    let current: LocalFontFileInspection
    do {
      current = try inspect(fileAt: url, limits: limits)
    } catch let error as LocalFontImportError {
      throw error
    }
    guard let verified = current.faces.first(where: { $0.faceIndex == face.faceIndex }),
      verified.programDigest == face.programDigest
    else { throw LocalFontImportError.changedSinceInspection }
    guard verified.isEligible else {
      throw LocalFontImportError.faceNotEligible(verified.eligibility.label)
    }
    let root = ImportedFontStore.resolvedDirectory(directory)
    try ImportedFontStore.prepareDirectory(root)
    let fileName = "\(verified.programDigest)-face\(verified.faceIndex).ttf"
    let target = root.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: target.path) {
      guard let existing = try? Data(contentsOf: target),
        FontImportDigest.sha256Hex(existing) == verified.programDigest
      else {
        throw LocalFontImportError.storage(
          "An imported font file with this identity exists but does not match. Remove it first.")
      }
    } else {
      do {
        try verified.program.write(to: target, options: .atomic)
      } catch {
        throw LocalFontImportError.storage("The font file could not be copied into the app store.")
      }
      guard let written = try? Data(contentsOf: target),
        FontImportDigest.sha256Hex(written) == verified.programDigest
      else {
        try? FileManager.default.removeItem(at: target)
        throw LocalFontImportError.storage("The copied font file could not be verified.")
      }
    }
    let record = ImportedFontRecord(
      identifier: verified.identifier, fileName: fileName,
      fileDigest: current.fileDigest, programDigest: verified.programDigest,
      faceIndex: verified.faceIndex, familyName: verified.familyName,
      styleName: verified.styleName, faceName: verified.faceName,
      postScriptName: verified.postScriptName,
      licenseAssertion: licenseAssertion(
        fileName: current.fileName, faceName: verified.faceName),
      acceptedAt: ISO8601DateFormatter().string(from: Date()))
    do {
      try ImportedFontStore.record(record, in: root)
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw error
    }
    return CustomTextFont(
      program: verified.program, familyName: verified.familyName,
      faceName: verified.faceName, identifier: verified.identifier,
      isBold: verified.isBold, isItalic: verified.isItalic)
  }

  private static func makeFace(_ inspection: FontFaceInspection) -> LocalFontFace {
    let fallbackName = "Face \(inspection.faceIndex + 1)"
    var familyName = fallbackName
    var styleName = "Style unavailable"
    var postScriptName = fallbackName
    var isBold = false
    var isItalic = false
    var previewed = false
    if let native = ProvisionedFontStore.coreTextFont(program: inspection.program, size: 12) {
      previewed = true
      let family = CTFontCopyFamilyName(native) as String
      let postScript = CTFontCopyPostScriptName(native) as String
      if !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        familyName = family
      }
      if !postScript.isEmpty { postScriptName = postScript }
      if let style = CTFontCopyName(native, kCTFontStyleNameKey) as String?,
        !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        styleName = style
      } else {
        styleName = postScript.isEmpty ? familyName : postScript
      }
      let traits = CTFontGetSymbolicTraits(native)
      isBold = traits.contains(.boldTrait)
      isItalic = traits.contains(.italicTrait)
    }
    let faceName =
      styleName == familyName ? familyName : "\(familyName) · \(styleName)"
    let eligibility: FontEmbeddingEligibility
    if previewed {
      eligibility = inspection.eligibility
    } else if inspection.isVariableFont {
      eligibility = .refused(.variableFontUnverifiable)
    } else {
      eligibility = .refused(.previewUnavailable)
    }
    return LocalFontFace(
      inspection: inspection, familyName: familyName, styleName: styleName,
      postScriptName: postScriptName, faceName: faceName, isBold: isBold, isItalic: isItalic,
      variableFontNote: inspection.isVariableFont
        ? "Variable font: the app previews and embeds its default axis values."
        : nil,
      eligibility: eligibility)
  }
}

/// One accepted locally licensed face. Records are keyed by the exact program
/// digest and face index; a changed file or another face cannot reuse them.
public struct ImportedFontRecord: Sendable, Equatable, Codable {
  public let identifier: String
  public let fileName: String
  public let fileDigest: String
  public let programDigest: String
  public let faceIndex: Int
  public let familyName: String
  public let styleName: String
  public let faceName: String
  public let postScriptName: String
  public let licenseAssertion: String
  public let acceptedAt: String

  public init(
    identifier: String, fileName: String, fileDigest: String, programDigest: String,
    faceIndex: Int, familyName: String, styleName: String, faceName: String,
    postScriptName: String, licenseAssertion: String, acceptedAt: String
  ) {
    self.identifier = identifier
    self.fileName = fileName
    self.fileDigest = fileDigest
    self.programDigest = programDigest
    self.faceIndex = faceIndex
    self.familyName = familyName
    self.styleName = styleName
    self.faceName = faceName
    self.postScriptName = postScriptName
    self.licenseAssertion = licenseAssertion
    self.acceptedAt = acceptedAt
  }
}

/// FNT-01: the app-private store of faces the user imported from licensed font
/// files. A google-provisioned font store and this store are merged by
/// ProvisionedFontStore.availableFonts, so imported faces become available to
/// the inline editor without a separate wiring path.
public enum ImportedFontStore {
  public static let manifestName = ".spdf-imported-fonts.json"
  static let maximumManifestBytes = 2 * 1_024 * 1_024
  static let maximumStoredFileBytes = 20 * 1_024 * 1_024
  static let maximumEntries = 64
  static let maximumLoadedFonts = 32
  static let maximumLoadedBytes = 120 * 1_024 * 1_024

  /// Test/smoke hook: where imported faces are stored. Defaults to the
  /// app-private Application Support directory.
  nonisolated(unsafe) public static var storageDirectoryOverride: URL?

  public static func defaultDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("sPDF/ImportedFonts", isDirectory: true)
  }

  public static func resolvedDirectory(_ directory: URL? = nil) -> URL {
    (directory ?? storageDirectoryOverride ?? defaultDirectory()).standardizedFileURL
  }

  /// Records in stable face-label order. Only the manifest structure is
  /// validated here; availableFonts re-verifies every stored program.
  public static func records(in directory: URL? = nil) -> [ImportedFontRecord] {
    let root = resolvedDirectory(directory)
    guard let manifest = readManifest(at: root) else { return [] }
    return manifest.entries
      .filter { $0.isStructurallyValid }
      .sorted {
        if $0.faceName != $1.faceName {
          return $0.faceName.localizedStandardCompare($1.faceName) == .orderedAscending
        }
        return $0.identifier < $1.identifier
      }
  }

  /// Return only byte-identical, stored, subsettable TrueType faces. A changed
  /// file, a symlink, a malformed program or a face that no longer permits
  /// editable subset embedding is skipped instead of being offered for writing.
  public static func availableFonts(in directory: URL? = nil) -> [CustomTextFont] {
    let root = resolvedDirectory(directory)
    var result: [CustomTextFont] = []
    var identifiers = Set<String>()
    var totalBytes = 0
    for record in records(in: root) {
      guard result.count < maximumLoadedFonts,
        identifiers.insert(record.identifier).inserted
      else { continue }
      let file = root.appendingPathComponent(record.fileName).standardizedFileURL
      guard file.deletingLastPathComponent() == root,
        URL(fileURLWithPath: record.fileName).lastPathComponent == record.fileName,
        file.pathExtension.lowercased() == "ttf",
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let data = try? Data(contentsOf: file),
        data.count <= maximumStoredFileBytes,
        totalBytes + data.count <= maximumLoadedBytes,
        FontImportDigest.sha256Hex(data) == record.programDigest
      else { continue }
      let inspection = FontImportInspection.inspectFace(
        program: data, faceIndex: record.faceIndex, validateSubsetting: false)
      guard inspection.isEligible,
        ProvisionedFontStore.coreTextFont(program: data, size: 12) != nil
      else { continue }
      totalBytes += data.count
      result.append(
        CustomTextFont(
          program: data, familyName: record.familyName, faceName: record.faceName,
          identifier: record.identifier,
          isBold: inspection.glyphCount > 0 && record.styleName.localizedCaseInsensitiveContains("bold"),
          isItalic: record.styleName.localizedCaseInsensitiveContains("italic")))
    }
    return result.sorted {
      if $0.familyName != $1.familyName {
        return $0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending
      }
      if $0.faceName != $1.faceName {
        return $0.faceName.localizedStandardCompare($1.faceName) == .orderedAscending
      }
      return $0.identifier < $1.identifier
    }
  }

  /// Remove one accepted face and its copied file. Unknown identifiers are a
  /// no-op that reports false.
  @discardableResult
  public static func remove(identifier: String, in directory: URL? = nil) throws -> Bool {
    let root = resolvedDirectory(directory)
    guard var manifest = readManifest(at: root),
      let entry = manifest.entries.first(where: { $0.identifier == identifier })
    else { return false }
    manifest.entries.removeAll { $0.identifier == identifier }
    let file = root.appendingPathComponent(entry.fileName).standardizedFileURL
    if file.deletingLastPathComponent() == root,
      URL(fileURLWithPath: entry.fileName).lastPathComponent == entry.fileName,
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true
    {
      try? FileManager.default.removeItem(at: file)
    }
    try writeManifest(manifest, to: root)
    return true
  }

  static func prepareDirectory(_ root: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: root.path) {
      guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true, values.isSymbolicLink != true
      else {
        throw LocalFontImportError.storage(
          "The imported-font store location is not a plain directory.")
      }
      return
    }
    do {
      try manager.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      throw LocalFontImportError.storage("The imported-font store could not be created.")
    }
  }

  static func record(_ record: ImportedFontRecord, in root: URL) throws {
    guard record.isStructurallyValid else {
      throw LocalFontImportError.storage("The imported font record is invalid.")
    }
    var manifest = readManifest(at: root) ?? Manifest(version: 1, entries: [])
    guard manifest.version == 1 else {
      throw LocalFontImportError.storage("The imported-font record is unsupported.")
    }
    manifest.entries.removeAll {
      $0.identifier == record.identifier
        || ($0.programDigest == record.programDigest && $0.faceIndex == record.faceIndex)
    }
    manifest.entries.append(record)
    manifest.entries.sort {
      if $0.faceName != $1.faceName {
        return $0.faceName.localizedStandardCompare($1.faceName) == .orderedAscending
      }
      return $0.identifier < $1.identifier
    }
    guard manifest.entries.count <= maximumEntries else {
      throw LocalFontImportError.storage(
        "The imported-font store reached its entry limit. Remove a font and try again.")
    }
    try writeManifest(manifest, to: root)
  }

  private struct Manifest: Codable {
    var version: Int
    var entries: [ImportedFontRecord]
  }

  private static func readManifest(at root: URL) -> Manifest? {
    let url = root.appendingPathComponent(manifestName)
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize, size >= 0, size <= maximumManifestBytes,
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(Manifest.self, from: data)
  }

  private static func writeManifest(_ manifest: Manifest, to root: URL) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(manifest)
    } catch {
      throw LocalFontImportError.storage("The imported-font record could not be written.")
    }
    guard data.count <= maximumManifestBytes else {
      throw LocalFontImportError.storage("The imported-font record is too large.")
    }
    do {
      try data.write(to: root.appendingPathComponent(manifestName), options: .atomic)
    } catch {
      throw LocalFontImportError.storage("The imported-font record could not be written.")
    }
  }
}

extension ImportedFontRecord {
  /// Structural validation; byte identity is checked by availableFonts.
  var isStructurallyValid: Bool {
    !identifier.isEmpty && identifier.count <= 200
      && !fileName.isEmpty && fileName.count <= 200
      && URL(fileURLWithPath: fileName).lastPathComponent == fileName
      && URL(fileURLWithPath: fileName).pathExtension.lowercased() == "ttf"
      && !fileDigest.isEmpty && !programDigest.isEmpty
      && faceIndex >= 0 && faceIndex <= 1_000
      && !familyName.isEmpty && !faceName.isEmpty && !licenseAssertion.isEmpty
  }
}
