import CryptoKit
import Foundation
import PDFCore

/// PRE-01/PRE-02: the PDF/A profiles this converter can actually produce and
/// validate. Rules are profile-specific on purpose: transparency, attachments
/// and optional content are allowed by some profiles and forbidden by others.
public enum ArchivalConversionProfile: String, Sendable, Equatable, CaseIterable {
  case pdfa1b = "PDF/A-1b"
  case pdfa2b = "PDF/A-2b"
  case pdfa3b = "PDF/A-3b"

  public static let selected: ArchivalConversionProfile = .pdfa2b

  public var standard: String {
    switch self {
    case .pdfa1b: return "ISO 19005-1"
    case .pdfa2b: return "ISO 19005-2"
    case .pdfa3b: return "ISO 19005-3"
    }
  }

  public var part: Int {
    switch self {
    case .pdfa1b: return 1
    case .pdfa2b: return 2
    case .pdfa3b: return 3
    }
  }

  public var conformance: String { "B" }

  /// veraPDF flavour token.
  public var validatorFlavour: String {
    switch self {
    case .pdfa1b: return "1b"
    case .pdfa2b: return "2b"
    case .pdfa3b: return "3b"
    }
  }

  /// ISO 32000 base version written to the final file.
  public var pdfVersion: String { self == .pdfa1b ? "1.4" : "1.7" }

  /// PDF/A-1 forbids transparency; PDF/A-2/3 allow it.
  public var allowsTransparency: Bool { self != .pdfa1b }
  /// PDF/A-1 forbids optional content; PDF/A-2/3 allow OCGs.
  public var allowsOptionalContent: Bool { self != .pdfa1b }
  /// Only PDF/A-3 permits arbitrary embedded files; PDF/A-1/A-2 do not.
  public var allowsEmbeddedFiles: Bool { self == .pdfa3b }
  /// PDF/A-1 permits only PDF 1.4 content (no object/xref streams, no JPX).
  public var requiresPDF14Features: Bool { self == .pdfa1b }

  public var disclosure: String {
    switch self {
    case .pdfa1b:
      return "Declared profile PDF/A-1b (ISO 19005-1, conformance B): no transparency, "
        + "no optional content, no embedded files, no JPX; fonts embedded; XMP pdfaid "
        + "part 1; deterministic trailer ID; sRGB output intent."
    case .pdfa2b:
      return "Declared profile PDF/A-2b (ISO 19005-2, conformance B): transparency and "
        + "optional content allowed, embedded files not allowed, no JPX restriction; "
        + "fonts embedded; XMP pdfaid part 2; deterministic trailer ID; sRGB output intent."
    case .pdfa3b:
      return "Declared profile PDF/A-3b (ISO 19005-3, conformance B): transparency and "
        + "optional content allowed, embedded files allowed only as associated files "
        + "with /AFRelationship; fonts embedded; XMP pdfaid part 3; deterministic trailer "
        + "ID; sRGB output intent."
    }
  }
}

/// PRE-02: one associated file for the PDF/A-3 workflow. The relationship is
/// required by PDF/A-3 and is never invented silently for existing attachments.
public struct ArchivalAssociatedFile: Sendable, Equatable {
  public enum Relationship: String, Sendable, Equatable {
    case source = "Source"
    case data = "Data"
    case alternative = "Alternative"
    case supplement = "Supplement"
    case unspecified = "Unspecified"
  }

  public let name: String
  public let data: Data
  public let mimeType: String?
  public let relationship: Relationship

  public init(
    name: String, data: Data, mimeType: String? = nil,
    relationship: Relationship = .unspecified
  ) {
    self.name = name
    self.data = data
    self.mimeType = mimeType
    self.relationship = relationship
  }
}

public enum ArchivalConversionStatus: String, Sendable, Equatable {
  case conforming = "Conforming"
  case notConforming = "Not conforming"
  case refused = "Refused before writing"
  case validatorUnavailable = "Independent validator unavailable"
}

/// PRE-01: one check/fix performed by the converter.
public struct ArchivalConversionCheck: Sendable, Equatable {
  public enum Outcome: String, Sendable, Equatable {
    case passed
    case fixed
    case refused
    case warning
  }

  public let rule: String
  public let outcome: Outcome
  public let detail: String

  public init(rule: String, outcome: Outcome, detail: String) {
    self.rule = rule
    self.outcome = outcome
    self.detail = detail
  }
}

/// PRE-01/PRE-02: options. The conversion is deterministic when a fixed date
/// is supplied; failures never produce a conforming label or output bytes.
public struct ArchivalConversionOptions: Sendable, Equatable {
  public var profile: ArchivalConversionProfile
  public var title: String?
  public var creatorTool: String
  public var modificationDate: Date
  public var associatedFiles: [ArchivalAssociatedFile]
  /// Remove executable actions instead of refusing the conversion.
  public var removeExecutableActions: Bool
  /// Drop pre-existing embedded files for profiles that forbid them. When
  /// false, a document with embedded files is refused instead of silently
  /// losing content.
  public var dropExistingEmbeddedFiles: Bool

  public init(
    profile: ArchivalConversionProfile = .selected, title: String? = nil,
    creatorTool: String = "sPDF Archival Converter", modificationDate: Date = Date(),
    associatedFiles: [ArchivalAssociatedFile] = [],
    removeExecutableActions: Bool = true, dropExistingEmbeddedFiles: Bool = false
  ) {
    self.profile = profile
    self.title = title
    self.creatorTool = creatorTool
    self.modificationDate = modificationDate
    self.associatedFiles = associatedFiles
    self.removeExecutableActions = removeExecutableActions
    self.dropExistingEmbeddedFiles = dropExistingEmbeddedFiles
  }
}

/// PRE-01/PRE-02: the conversion result. `data` is present only when the
/// declared profile passed independent validation of the final saved bytes.
public struct ArchivalConversionOutcome: Sendable, Equatable {
  public let profile: ArchivalConversionProfile
  public let status: ArchivalConversionStatus
  public let data: Data?
  public let candidateData: Data?
  public let validation: ArchivalValidationResult?
  public let checks: [ArchivalConversionCheck]
  public let losses: [String]
  public let warnings: [String]
  public let disclosure: String

  public init(
    profile: ArchivalConversionProfile, status: ArchivalConversionStatus, data: Data?,
    candidateData: Data?, validation: ArchivalValidationResult?,
    checks: [ArchivalConversionCheck], losses: [String], warnings: [String],
    disclosure: String
  ) {
    self.profile = profile
    self.status = status
    self.data = data
    self.candidateData = candidateData
    self.validation = validation
    self.checks = checks
    self.losses = losses
    self.warnings = warnings
    self.disclosure = disclosure
  }

  public var isConforming: Bool { status == .conforming && data != nil }
  public var identifier: String? {
    isConforming ? "\(profile.rawValue) (\(profile.standard))" : nil
  }

  public var summaryLines: [String] {
    var lines = [
      "Profile: \(profile.rawValue) (\(profile.standard))",
      "Status: \(status.rawValue)",
    ]
    if let validation {
      lines.append(
        "Independent validation: \(validation.validator) "
          + "\(validation.validatorVersion ?? "?") — "
          + (validation.isCompliant ? "compliant" : "not compliant")
          + " (\(validation.failedRules) failed rules)")
    } else {
      lines.append("Independent validation: not run")
    }
    lines.append(contentsOf: checks.map { "[\($0.outcome.rawValue)] \($0.rule): \($0.detail)" })
    if !losses.isEmpty { lines.append("Losses: " + losses.joined(separator: "; ")) }
    if !warnings.isEmpty { lines.append(contentsOf: warnings.map { "Warning: \($0)" }) }
    return lines
  }

  public var plainText: String {
    (summaryLines + ["", disclosure]).joined(separator: "\n")
  }
}

/// PRE-01: a genuinely conforming converter for the declared profiles. It
/// fixes what it can, refuses what it cannot, writes the declared identifiers
/// only into the candidate, and publishes bytes only when the independent
/// validator accepts the final file.
public enum PDFAConverter {
  static let iccCandidates = [
    "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
    "/Library/ColorSync/Profiles/sRGB Profile.icc",
    "/usr/share/color/icc/sRGB.icc",
  ]

  public static func convert(
    _ source: ParsedPDF, options: ArchivalConversionOptions = ArchivalConversionOptions(),
    validatorPath: String = ArchivalDerivative.defaultValidatorPath,
    limits: PDFLimits = PDFLimits()
  ) -> ArchivalConversionOutcome {
    convert(
      graph: source.graph, options: options, validatorPath: validatorPath, limits: limits)
  }

  public static func convert(
    graph: PDFGraph, options: ArchivalConversionOptions = ArchivalConversionOptions(),
    validatorPath: String = ArchivalDerivative.defaultValidatorPath,
    limits: PDFLimits = PDFLimits()
  ) -> ArchivalConversionOutcome {
    let profile = options.profile
    var checks: [ArchivalConversionCheck] = []
    var losses: [String] = []
    var warnings: [String] = []

    // 1. Hard refusals: profile-independent and profile-specific rules.
    if graph.trailer[PDFName("Encrypt")] != nil {
      checks.append(.init(
        rule: "Encryption", outcome: .refused,
        detail: "The input is encrypted; PDF/A does not allow encryption."))
      return outcome(
        profile: profile, status: .refused, data: nil, candidateData: nil, validation: nil,
        checks: checks, losses: losses, warnings: warnings)
    }
    let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
    let existingSignatures = (try? PDFSignatureInventory.signatures(in: graph, limits: limits))?
      .count ?? 0
    if existingSignatures > 0 {
      checks.append(.init(
        rule: "Digital signatures", outcome: .refused,
        detail: "The input has \(existingSignatures) signature(s). PDF/A conversion is a "
          + "full rewrite and would invalidate them; this converter refuses instead of "
          + "silently invalidating signed evidence."))
      return outcome(
        profile: profile, status: .refused, data: nil, candidateData: nil, validation: nil,
        checks: checks, losses: losses, warnings: warnings)
    }
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let notEmbedded = fonts.filter { !$0.isEmbedded }
    if !notEmbedded.isEmpty {
      checks.append(.init(
        rule: "Font embedding", outcome: .refused,
        detail: "Not embedded: " + notEmbedded.map(\.baseName).joined(separator: ", ")))
    } else {
      checks.append(.init(
        rule: "Font embedding", outcome: .passed,
        detail: fonts.isEmpty ? "No rendered fonts." : "\(fonts.count) font(s) embedded."))
    }

    let transparency = PDFCompatibilityScan.scan(in: graph).transparency
    if transparency > 0 && !profile.allowsTransparency {
      checks.append(.init(
        rule: "Transparency", outcome: .refused,
        detail: "\(profile.rawValue) forbids transparency; \(transparency) use(s) found. "
          + "Transparency is allowed by PDF/A-2/A-3 but not by PDF/A-1."))
    } else if transparency > 0 {
      checks.append(.init(
        rule: "Transparency", outcome: .passed,
        detail: "Transparency is allowed by \(profile.rawValue); \(transparency) use(s) kept."))
    }

    let optionalContent = hasOptionalContent(in: graph)
    if optionalContent && !profile.allowsOptionalContent {
      checks.append(.init(
        rule: "Optional content", outcome: .refused,
        detail: "\(profile.rawValue) forbids optional-content groups."))
    }

    let embeddedFiles = existingEmbeddedFileSpecs(in: graph)
    if !embeddedFiles.isEmpty && !profile.allowsEmbeddedFiles {
      if options.dropExistingEmbeddedFiles {
        losses.append("Existing embedded files were removed for \(profile.rawValue).")
        checks.append(.init(
          rule: "Embedded files", outcome: .fixed,
          detail: "\(embeddedFiles.count) embedded file(s) removed by request."))
      } else {
        checks.append(.init(
          rule: "Embedded files", outcome: .refused,
          detail: "\(profile.rawValue) does not allow embedded files. Choose PDF/A-3b for "
            + "associated files, or allow dropping them explicitly."))
      }
    }
    if !options.associatedFiles.isEmpty && !profile.allowsEmbeddedFiles {
      checks.append(.init(
        rule: "Associated files", outcome: .refused,
        detail: "\(profile.rawValue) does not allow embedded files; associated-file "
          + "workflows are a PDF/A-3b rule."))
    }
    if profile.requiresPDF14Features {
      let jpx = countJPXImages(in: graph)
      if jpx > 0 {
        checks.append(.init(
          rule: "JPX images", outcome: .refused,
          detail: "PDF/A-1 does not allow JPEG 2000 images (\(jpx) found)."))
      }
    }
    if hasActions(in: graph) && !options.removeExecutableActions {
      checks.append(.init(
        rule: "Executable actions", outcome: .refused,
        detail: "The document has executable actions; enable removal to convert."))
    }

    // 2. Refuse rather than produce an unvalidated or mislabelled file.
    let refusals = checks.filter { $0.outcome == .refused }
    if !refusals.isEmpty {
      return outcome(
        profile: profile, status: .refused, data: nil, candidateData: nil, validation: nil,
        checks: checks, losses: losses, warnings: warnings)
    }

    // 3. Build the candidate graph deterministically.
    var staged = graph
    if hasActions(in: staged) {
      staged = ArchivalDerivative.removingExecutableActions(from: staged)
      losses.append("Executable actions and the catalog OpenAction were removed.")
      checks.append(.init(
        rule: "Executable actions", outcome: .fixed,
        detail: "JavaScript/executable actions and the catalog OpenAction were removed."))
    } else {
      checks.append(.init(rule: "Executable actions", outcome: .passed, detail: "None found."))
    }
    if hasNeedAppearances(in: staged) {
      staged = ArchivalDerivative.removingNeedAppearances(from: staged)
      losses.append("AcroForm /NeedAppearances was removed (appearances are explicit).")
      checks.append(.init(
        rule: "NeedAppearances", outcome: .fixed,
        detail: "AcroForm /NeedAppearances removed."))
    }
    if !embeddedFiles.isEmpty && !profile.allowsEmbeddedFiles {
      staged = ArchivalDerivative.removingEmbeddedFiles(from: staged)
    } else if profile.allowsEmbeddedFiles {
      do {
        staged = try embeddingAssociatedFiles(
          in: staged, associatedFiles: options.associatedFiles)
        checks.append(.init(
          rule: "Associated files", outcome: .fixed,
          detail: "\(options.associatedFiles.count) associated file(s) embedded with "
            + "/AFRelationship."))
      } catch {
        warnings.append("Associated files could not be embedded: \(error.localizedDescription)")
      }
    }
    do {
      staged = try addingMetadataAndOutputIntent(to: staged, options: options)
      checks.append(.init(
        rule: "XMP metadata", outcome: .fixed,
        detail: "Deterministic XMP with pdfaid:part \(profile.part), conformance B."))
      checks.append(.init(
        rule: "Output intent", outcome: .fixed,
        detail: "sRGB ICC output intent added (/S /GTS_PDFA1)."))
      checks.append(.init(
        rule: "File identifier", outcome: .fixed,
        detail: "Deterministic trailer /ID added."))
    } catch {
      checks.append(.init(
        rule: "Metadata", outcome: .refused,
        detail: "Could not add XMP/output intent: \(error.localizedDescription)"))
      return outcome(
        profile: profile, status: .refused, data: nil, candidateData: nil, validation: nil,
        checks: checks, losses: losses, warnings: warnings)
    }

    // 4. Serialize and validate the actual final bytes.
    let candidate: Data
    do {
      candidate = try PDFWriter.write(staged, limits: limits)
      _ = try PDFParser.parse(candidate, limits: limits)
    } catch {
      checks.append(.init(
        rule: "Serialization", outcome: .refused,
        detail: "The converted PDF could not be written: \(error.localizedDescription)"))
      return outcome(
        profile: profile, status: .refused, data: nil, candidateData: nil, validation: nil,
        checks: checks, losses: losses, warnings: warnings)
    }
    guard FileManager.default.isExecutableFile(atPath: validatorPath) else {
      warnings.append(
        "The independent validator is unavailable; the file is not labelled conforming.")
      return outcome(
        profile: profile, status: .validatorUnavailable, data: nil,
        candidateData: candidate, validation: nil, checks: checks, losses: losses,
        warnings: warnings)
    }
    guard let validation = ArchivalDerivative.runValidator(
      data: candidate, flavour: profile.validatorFlavour, validatorPath: validatorPath)
    else {
      warnings.append(
        "The independent validator could not be executed; the file is not labelled conforming.")
      return outcome(
        profile: profile, status: .validatorUnavailable, data: nil,
        candidateData: candidate, validation: nil, checks: checks, losses: losses,
        warnings: warnings)
    }
    if validation.isCompliant {
      checks.append(.init(
        rule: "Independent validation", outcome: .passed,
        detail: "\(validation.validator) \(validation.validatorVersion ?? "?") accepted the "
          + "final saved bytes for \(profile.rawValue)."))
      return outcome(
        profile: profile, status: .conforming, data: candidate, candidateData: nil,
        validation: validation, checks: checks, losses: losses, warnings: warnings)
    }
    checks.append(.init(
      rule: "Independent validation", outcome: .refused,
      detail: "\(validation.validator) rejected the final bytes: "
        + "\(validation.failedRules) rule(s), \(validation.failedChecks) check(s)."))
    warnings.append(
      "Conversion failed independent validation; no conforming bytes were published.")
    return outcome(
      profile: profile, status: .notConforming, data: nil, candidateData: candidate,
      validation: validation, checks: checks, losses: losses, warnings: warnings)
  }

  static func outcome(
    profile: ArchivalConversionProfile, status: ArchivalConversionStatus, data: Data?,
    candidateData: Data?, validation: ArchivalValidationResult?,
    checks: [ArchivalConversionCheck], losses: [String], warnings: [String]
  ) -> ArchivalConversionOutcome {
    ArchivalConversionOutcome(
      profile: profile, status: status, data: data, candidateData: candidateData,
      validation: validation, checks: checks, losses: losses, warnings: warnings,
      disclosure: profile.disclosure)
  }

  // MARK: - Graph fixes

  static func catalog(in graph: PDFGraph) -> (id: PDFObjectID, dictionary: [PDFName: PDFValue])? {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { return nil }
    return (rootID, catalog)
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    switch value {
    case .reference(let id)?: return graph.objects[id]
    default: return value
    }
  }

  static func hasActions(in graph: PDFGraph) -> Bool {
    var found = false
    for (_, value) in graph.objects {
      guard case .dictionary(let dictionary) = value else { continue }
      for key in ["AA", "OpenAction", "JavaScript", "JS", "Launch", "Sound", "Movie", "Rendition"]
      where dictionary[PDFName(key)] != nil {
        found = true
      }
    }
    return found
  }

  static func hasNeedAppearances(in graph: PDFGraph) -> Bool {
    for (_, value) in graph.objects {
      guard case .dictionary(let dictionary) = value,
        case .dictionary(let form)? = resolved(dictionary[PDFName("AcroForm")], in: graph),
        case .boolean(let flag)? = form[PDFName("NeedAppearances")], flag
      else { continue }
      return true
    }
    return false
  }

  static func hasOptionalContent(in graph: PDFGraph) -> Bool {
    guard let catalog = catalog(in: graph) else { return false }
    return catalog.dictionary[PDFName("OCProperties")] != nil
  }

  static func existingEmbeddedFileSpecs(in graph: PDFGraph) -> [PDFValue] {
    guard let catalog = catalog(in: graph),
      case .dictionary(let names)? = resolved(
        catalog.dictionary[PDFName("Names")], in: graph),
      case .dictionary(let embedded)? = resolved(names[PDFName("EmbeddedFiles")], in: graph),
      case .array(let pairs)? = resolved(embedded[PDFName("Names")], in: graph)
    else { return [] }
    var specs: [PDFValue] = []
    var index = 1
    while index < pairs.count {
      specs.append(pairs[index])
      index += 2
    }
    return specs
  }

  static func countJPXImages(in graph: PDFGraph) -> Int {
    var count = 0
    for (_, value) in graph.objects {
      guard case .stream(let stream) = value else { continue }
      if stream.dictionary[PDFName("Filter")] == .name(PDFName("JPXDecode")) { count += 1 }
    }
    return count
  }

  static func addingMetadataAndOutputIntent(
    to graph: PDFGraph, options: ArchivalConversionOptions
  ) throws -> PDFGraph {
    guard let catalogInfo = catalog(in: graph) else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    var objects = graph.objects
    var catalog = catalogInfo.dictionary
    var next = (objects.keys.map(\.number).max() ?? 0) + 1

    let xmp = try xmpPacket(profile: options.profile, options: options)
    let metadataID = PDFObjectID(next)
    next += 1
    objects[metadataID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("Metadata")),
          PDFName("Subtype"): .name(PDFName("XML")),
        ], bytes: xmp))
    catalog[PDFName("Metadata")] = .reference(metadataID)

    guard let icc = loadICCProfile() else {
      throw PDFError(.unsupported, "No ICC profile is available for the output intent")
    }
    let profileID = PDFObjectID(next)
    next += 1
    objects[profileID] = .stream(
      PDFStream(dictionary: [PDFName("N"): .integer(3)], bytes: icc))
    let outputIntentID = PDFObjectID(next)
    next += 1
    objects[outputIntentID] = .dictionary([
      PDFName("Type"): .name(PDFName("OutputIntent")),
      PDFName("S"): .name(PDFName("GTS_PDFA1")),
      PDFName("OutputConditionIdentifier"): .string(Data("sRGB IEC61966-2.1".utf8)),
      PDFName("Info"): .string(Data("sRGB IEC61966-2.1".utf8)),
      PDFName("RegistryName"): .string(Data("http://www.color.org".utf8)),
      PDFName("DestOutputProfile"): .reference(profileID),
    ])
    catalog[PDFName("OutputIntents")] = .array([.reference(outputIntentID)])
    catalog[PDFName("Version")] = .name(PDFName(options.profile.pdfVersion))
    objects[catalogInfo.id] = .dictionary(catalog)

    // The XMP packet is the single deterministic metadata source; the Info
    // dictionary duplicates it and is therefore removed.
    var trailer = graph.trailer
    trailer[PDFName("Info")] = nil
    var result = PDFGraph(
      version: options.profile.pdfVersion, objects: objects, trailer: trailer)
    result = try ArchivalDerivative.addingFileIdentifier(to: result)
    return result
  }

  static func embeddingAssociatedFiles(
    in graph: PDFGraph, associatedFiles: [ArchivalAssociatedFile]
  ) throws -> PDFGraph {
    guard let catalogInfo = catalog(in: graph) else {
      throw PDFError(.malformed, "The catalog is missing for associated files")
    }
    var objects = graph.objects
    var catalog = catalogInfo.dictionary
    var next = (objects.keys.map(\.number).max() ?? 0) + 1
    var pairs: [PDFValue] = []
    var specifications: [PDFValue] = []
    if case .dictionary(let names)? = resolved(catalog[PDFName("Names")], in: graph),
      case .dictionary(let embedded)? = resolved(names[PDFName("EmbeddedFiles")], in: graph),
      case .array(let existing)? = resolved(embedded[PDFName("Names")], in: graph)
    {
      pairs = existing
      var index = 1
      while index < pairs.count {
        specifications.append(pairs[index])
        index += 2
      }
    }
    for file in associatedFiles {
      guard !file.data.isEmpty else {
        throw PDFError(.malformed, "An associated file is empty")
      }
      let streamID = PDFObjectID(next)
      next += 1
      objects[streamID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("EmbeddedFile")),
            PDFName("Subtype"): .name(
              PDFName(file.mimeType ?? "application/octet-stream")),
          ], bytes: file.data))
      let specificationID = PDFObjectID(next)
      next += 1
      let mimeType = file.mimeType ?? "application/octet-stream"
      var specification: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data(file.name.utf8)),
        PDFName("UF"): .string(Data(unicodeBOM(file.name))),
        PDFName("EF"): .dictionary([PDFName("F"): .reference(streamID)]),
        PDFName("AFRelationship"): .name(PDFName(file.relationship.rawValue)),
        // ISO 19005-3 6.8: the MIME type is specified on the file
        // specification dictionary (Subtype), not only on the stream.
        PDFName("Subtype"): .name(PDFName(mimeType)),
      ]
      if file.mimeType != nil {
        specification[PDFName("Desc")] = .string(Data(mimeType.utf8))
      }
      objects[specificationID] = .dictionary(specification)
      pairs.append(.string(Data(file.name.utf8)))
      pairs.append(.reference(specificationID))
      specifications.append(.reference(specificationID))
    }
    // Existing file specs get an explicit relationship; the converter never
    // invents a semantic relationship and uses Unspecified instead.
    for (index, value) in specifications.enumerated() {
      guard case .reference(let id) = value,
        case .dictionary(var specification)? = objects[id]
      else { continue }
      if specification[PDFName("AFRelationship")] == nil {
        specification[PDFName("AFRelationship")] = .name(PDFName("Unspecified"))
        objects[id] = .dictionary(specification)
      }
      specifications[index] = .reference(id)
    }
    var names: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = resolved(catalog[PDFName("Names")], in: graph) {
      names = existing
    }
    names[PDFName("EmbeddedFiles")] = .dictionary([PDFName("Names"): .array(pairs)])
    catalog[PDFName("Names")] = .dictionary(names)
    catalog[PDFName("AF")] = .array(specifications)
    objects[catalogInfo.id] = .dictionary(catalog)
    return PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer)
  }

  static func unicodeBOM(_ text: String) -> Data {
    var data = Data([0xFE, 0xFF])
    for unit in text.utf16 {
      data.append(UInt8(unit >> 8))
      data.append(UInt8(unit & 0xFF))
    }
    return data
  }

  static func loadICCProfile() -> Data? {
    for path in iccCandidates {
      if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 128,
        data.count <= PDFLimits().streamBytes
      {
        return data
      }
    }
    return nil
  }

  static func xmpPacket(
    profile: ArchivalConversionProfile, options: ArchivalConversionOptions
  ) throws -> Data {
    let date = iso8601(options.modificationDate)
    let title = xmlEscape(options.title ?? "")
    var parts: [String] = [
      "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>",
      "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">",
      "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">",
      "<rdf:Description rdf:about=\"\"",
      " xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"",
      " xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
      " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"",
      " xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">",
      "<pdfaid:part>\(profile.part)</pdfaid:part>",
      "<pdfaid:conformance>\(profile.conformance)</pdfaid:conformance>",
    ]
    if !title.isEmpty {
      parts.append(
        "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)</rdf:li></rdf:Alt></dc:title>")
    }
    parts.append(contentsOf: [
      "<xmp:CreatorTool>\(xmlEscape(options.creatorTool))</xmp:CreatorTool>",
      "<xmp:CreateDate>\(date)</xmp:CreateDate>",
      "<xmp:ModifyDate>\(date)</xmp:ModifyDate>",
      "<xmp:MetadataDate>\(date)</xmp:MetadataDate>",
      "<pdf:Producer>\(xmlEscape(options.creatorTool))</pdf:Producer>",
      "</rdf:Description>",
      "</rdf:RDF>",
      "</x:xmpmeta>",
      "<?xpacket end=\"w\"?>",
    ])
    guard let data = parts.joined(separator: "\n").data(using: .utf8) else {
      throw PDFError(.malformed, "The XMP metadata could not be encoded")
    }
    return data
  }

  static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  static func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
