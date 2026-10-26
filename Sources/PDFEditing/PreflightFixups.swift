import Foundation
import PDFCore

// PRE-04: configurable preflight rule sets, object navigation, staged fixups with
// exact previews, affected-check reruns and an exportable report. Reuses the
// shipped read-only print inventory/checks and the PDF/X stage from PDFXOutput.

public enum PreflightSeverity: String, Sendable, Equatable, CaseIterable, Codable {
  case error, warning, info
  public var rank: Int { switch self { case .error: return 3; case .warning: return 2; case .info: return 1 } }
}

public struct PreflightRuleDefinition: Sendable, Equatable, Codable {
  public let id: String
  public let title: String
  public let defaultSeverity: PreflightSeverity
  public let fixupID: String?
  public init(id: String, title: String, defaultSeverity: PreflightSeverity, fixupID: String? = nil) {
    self.id = id; self.title = title; self.defaultSeverity = defaultSeverity; self.fixupID = fixupID
  }
  public static let all: [PreflightRuleDefinition] = [
    .init(id: "fontEmbedding", title: "Fonts embedded", defaultSeverity: .error),
    .init(id: "imageResolution", title: "Image resolution", defaultSeverity: .warning),
    .init(id: "outputIntent", title: "Output intent present", defaultSeverity: .error, fixupID: "addOutputIntent"),
    .init(id: "pdfxIdentification", title: "PDF/X identification", defaultSeverity: .error, fixupID: "addPDFXIdentification"),
    .init(id: "printBoxes", title: "TrimBox present", defaultSeverity: .error, fixupID: "addTrimBoxes"),
    .init(id: "transparency", title: "Transparency permitted by profile", defaultSeverity: .warning),
    .init(id: "rgbContent", title: "RGB content permitted by profile", defaultSeverity: .warning),
    .init(id: "annotations", title: "Annotations flattened for print", defaultSeverity: .warning, fixupID: "flattenAnnotations"),
    .init(id: "formFields", title: "Form fields flattened for print", defaultSeverity: .warning, fixupID: "flattenFormFields"),
    .init(id: "encryption", title: "Not encrypted", defaultSeverity: .error),
    .init(id: "filters", title: "Supported stream filters", defaultSeverity: .error),
  ]
  public static func definition(_ id: String) -> PreflightRuleDefinition? { all.first { $0.id == id } }
}

/// A reusable, configurable preflight rule set: which rules run, severity
/// overrides and thresholds. Codable so a user can save and reload it.
public struct PreflightRuleSet: Sendable, Equatable, Codable {
  public var name: String
  public var enabledRuleIDs: Set<String>
  public var severityOverrides: [String: PreflightSeverity]
  public var minimumImageDPI: Double

  public init(name: String, enabledRuleIDs: Set<String>, severityOverrides: [String: PreflightSeverity] = [:], minimumImageDPI: Double = 150) {
    self.name = name; self.enabledRuleIDs = enabledRuleIDs
    self.severityOverrides = severityOverrides; self.minimumImageDPI = minimumImageDPI
  }

  public func severity(for ruleID: String) -> PreflightSeverity {
    severityOverrides[ruleID] ?? PreflightRuleDefinition.definition(ruleID)?.defaultSeverity ?? .info
  }

  public static let printDelivery = PreflightRuleSet(
    name: "Print delivery",
    enabledRuleIDs: Set(PreflightRuleDefinition.all.map(\.id)))

  public static let pdfx4 = PreflightRuleSet(
    name: "PDF/X-4 declared subset",
    enabledRuleIDs: [
      "fontEmbedding", "outputIntent", "pdfxIdentification", "printBoxes",
      "annotations", "formFields", "encryption", "filters", "imageResolution",
    ])

  public static let pdfx1a = PreflightRuleSet(
    name: "PDF/X-1a:2003 declared subset",
    enabledRuleIDs: [
      "fontEmbedding", "outputIntent", "pdfxIdentification", "printBoxes",
      "transparency", "rgbContent", "annotations", "formFields", "encryption",
      "filters", "imageResolution",
    ],
    severityOverrides: ["transparency": .error, "rgbContent": .error])

  public func exportJSON() throws -> Data {
    try JSONEncoder().encode(self)
  }
  public static func importJSON(_ data: Data) throws -> PreflightRuleSet {
    try JSONDecoder().decode(PreflightRuleSet.self, from: data)
  }
}

public struct PreflightFinding: Sendable, Equatable, Codable {
  public let ruleID: String
  public let ruleTitle: String
  public let severity: PreflightSeverity
  public let message: String
  public let pageIndex: Int?
  public let objectID: Int?
  public let fixupID: String?
  public init(ruleID: String, severity: PreflightSeverity, message: String, pageIndex: Int? = nil, objectID: PDFObjectID? = nil, fixupID: String? = nil) {
    self.ruleID = ruleID
    self.ruleTitle = PreflightRuleDefinition.definition(ruleID)?.title ?? ruleID
    self.severity = severity; self.message = message; self.pageIndex = pageIndex
    self.objectID = objectID?.number; self.fixupID = fixupID
  }
  public var navigation: String {
    var parts: [String] = []
    if let pageIndex { parts.append("page \(pageIndex + 1)") }
    if let objectID { parts.append("object \(objectID)") }
    return parts.isEmpty ? "document" : parts.joined(separator: ", ")
  }
}

public struct PreflightReport: Sendable, Equatable {
  public let ruleSetName: String
  public let findings: [PreflightFinding]
  public init(ruleSetName: String, findings: [PreflightFinding]) {
    self.ruleSetName = ruleSetName; self.findings = findings
  }
  public var errors: [PreflightFinding] { findings.filter { $0.severity == .error } }
  public var warnings: [PreflightFinding] { findings.filter { $0.severity == .warning } }
  public var infos: [PreflightFinding] { findings.filter { $0.severity == .info } }
  public var affectedRuleIDs: Set<String> { Set(findings.map(\.ruleID)) }
  public var passed: Bool { errors.isEmpty }

  public func text() -> String {
    var lines = ["Preflight — \(ruleSetName): \(errors.count) error(s), \(warnings.count) warning(s), \(infos.count) info"]
    for (label, group) in [("ERROR", errors), ("WARN", warnings), ("INFO", infos)] {
      for finding in group {
        lines.append("  [\(label)] \(finding.ruleTitle) (\(finding.navigation)): \(finding.message)")
      }
    }
    if findings.isEmpty { lines.append("  no findings") }
    return lines.joined(separator: "\n")
  }
}

public struct PreflightFixupChange: Sendable, Equatable, Codable {
  public let pageIndex: Int?
  public let objectID: Int?
  public let before: String
  public let after: String
  public init(pageIndex: Int?, objectID: PDFObjectID?, before: String, after: String) {
    self.pageIndex = pageIndex; self.objectID = objectID?.number
    self.before = before; self.after = after
  }
}

public struct PreflightFixupPreview: Sendable, Equatable {
  public let fixupID: String
  public let title: String
  public let changes: [PreflightFixupChange]
  public let affectedRuleIDs: Set<String>
  public var summary: String {
    var lines = ["\(title): \(changes.count) change(s)"]
    for change in changes {
      let whereText = change.pageIndex.map { "page \($0 + 1)" } ?? "document"
      lines.append("  \(whereText): \(change.before) -> \(change.after)")
    }
    return lines.joined(separator: "\n")
  }
}

public enum PreflightFixup: String, Sendable, Equatable, CaseIterable, Codable {
  case addTrimBoxes, addOutputIntent, addPDFXIdentification, flattenAnnotations, flattenFormFields
  public var title: String {
    switch self {
    case .addTrimBoxes: return "Add missing TrimBox"
    case .addOutputIntent: return "Add declared CMYK output intent"
    case .addPDFXIdentification: return "Add PDF/X identification XMP"
    case .flattenAnnotations: return "Flatten annotations"
    case .flattenFormFields: return "Flatten form fields"
    }
  }
  public var affectedRuleIDs: Set<String> {
    switch self {
    case .addTrimBoxes: return ["printBoxes"]
    case .addOutputIntent: return ["outputIntent"]
    case .addPDFXIdentification: return ["pdfxIdentification"]
    case .flattenAnnotations: return ["annotations"]
    case .flattenFormFields: return ["formFields"]
    }
  }
}

public struct PreflightFixupApplyResult: Sendable, Equatable {
  public let preview: PreflightFixupPreview
  public let reportBefore: PreflightReport
  public let reportAfter: PreflightReport
  public let graph: PDFGraph
  public var resolvedRuleIDs: [String] { Array(preview.affectedRuleIDs.subtracting(reportAfter.affectedRuleIDs)).sorted() }
  public var remainingRuleIDs: [String] { Array(preview.affectedRuleIDs.intersection(reportAfter.affectedRuleIDs)).sorted() }
  public var summary: String {
    "\(preview.title) applied: \(resolvedRuleIDs.isEmpty ? "no affected rule resolved" : "resolved " + resolvedRuleIDs.joined(separator: ", "))\(remainingRuleIDs.isEmpty ? "" : "; remaining " + remainingRuleIDs.joined(separator: ", "))"
  }
}

public struct PreflightFixupSession: Sendable {
  public let sourceGraph: PDFGraph
  public private(set) var graph: PDFGraph
  public let pageIDs: [PDFObjectID]
  public var ruleSet: PreflightRuleSet
  public let profile: PDFXProfile
  public private(set) var appliedFixups: [PreflightFixupApplyResult]
  public private(set) var report: PreflightReport

  public init(graph: PDFGraph, pageIDs: [PDFObjectID], ruleSet: PreflightRuleSet = .printDelivery, profile: PDFXProfile = .x4) {
    self.sourceGraph = graph
    self.graph = graph
    self.pageIDs = pageIDs
    self.ruleSet = ruleSet
    self.profile = profile
    self.report = PreflightFixupSession.evaluate(graph: graph, pageIDs: pageIDs, ruleSet: ruleSet, profile: profile)
    self.appliedFixups = []
  }

  public mutating func rerun() {
    report = Self.evaluate(graph: graph, pageIDs: pageIDs, ruleSet: ruleSet, profile: profile)
  }

  public mutating func setRuleSet(_ ruleSet: PreflightRuleSet) {
    self.ruleSet = ruleSet
    rerun()
  }

  public func preview(_ fixup: PreflightFixup) -> PreflightFixupPreview {
    var changes: [PreflightFixupChange] = []
    switch fixup {
    case .addTrimBoxes:
      for (index, pageID) in pageIDs.enumerated() {
        guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
        if page[PDFName("TrimBox")] == nil {
          let fallback = Self.boxValues(page[PDFName("CropBox")] ?? page[PDFName("MediaBox")])
          changes.append(PreflightFixupChange(pageIndex: index, objectID: pageID, before: "no TrimBox", after: "TrimBox " + Self.format(fallback)))
        }
      }
    case .addOutputIntent:
      changes.append(PreflightFixupChange(pageIndex: nil, objectID: nil, before: graphOutputIntentState(), after: "declared CMYK output intent with embedded ICC"))
    case .addPDFXIdentification:
      changes.append(PreflightFixupChange(pageIndex: nil, objectID: nil, before: identificationState(), after: "PDF/X identification XMP for \(profile.identification)"))
    case .flattenAnnotations:
      for (index, pageID) in pageIDs.enumerated() {
        let count = (try? AnnotationInventory.annotations(in: graph, pageID: pageID))?.count ?? 0
        if count > 0 {
          changes.append(PreflightFixupChange(pageIndex: index, objectID: pageID, before: "\(count) annotation(s)", after: "annotations flattened into page content"))
        }
      }
    case .flattenFormFields:
      let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
      if !fields.isEmpty {
        changes.append(PreflightFixupChange(pageIndex: nil, objectID: nil, before: "\(fields.count) form field(s)", after: "values flattened into page content"))
      }
    }
    return PreflightFixupPreview(fixupID: fixup.rawValue, title: fixup.title, changes: changes, affectedRuleIDs: fixup.affectedRuleIDs)
  }

  public mutating func apply(_ fixup: PreflightFixup, limits: PDFLimits = PDFLimits()) throws -> PreflightFixupApplyResult {
    let before = report
    let preview = preview(fixup)
    var work = graph
    switch fixup {
    case .addTrimBoxes:
      for (index, pageID) in pageIDs.enumerated() {
        guard case .dictionary(var page)? = work.objects[pageID] else { continue }
        if page[PDFName("TrimBox")] == nil {
          let fallback = page[PDFName("CropBox")] ?? page[PDFName("MediaBox")]
          if let fallback { page[PDFName("TrimBox")] = fallback }
          _ = fallback
          _ = index
        }
        work.objects[pageID] = .dictionary(page)
      }
    case .addOutputIntent:
      let icc = PDFXICCProfile.declaredCMYK()
      let iccID = PDFXExporter.nextObjectID(in: work)
      work.objects[iccID] = .stream(PDFStream(dictionary: [PDFName("N"): .integer(4), PDFName("Length"): .integer(Int64(icc.count))], bytes: icc))
      let intent: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("OutputIntent")), PDFName("S"): .name(PDFName("GTS_PDFX")),
        PDFName("OutputCondition"): .string(Data(PDFXICCProfile.conditionInfo.utf8)),
        PDFName("OutputConditionIdentifier"): .string(Data(PDFXICCProfile.conditionIdentifier.utf8)),
        PDFName("RegistryName"): .string(Data(PDFXICCProfile.registryName.utf8)),
        PDFName("Info"): .string(Data(PDFXICCProfile.conditionInfo.utf8)),
        PDFName("DestOutputProfile"): .reference(iccID),
      ]
      if case .reference(let catalogID)? = work.trailer[PDFName("Root")], case .dictionary(var catalog)? = work.objects[catalogID] {
        catalog[PDFName("OutputIntents")] = .array([.dictionary(intent)])
        work.objects[catalogID] = .dictionary(catalog)
      }
    case .addPDFXIdentification:
      let xmpID = PDFXExporter.nextObjectID(in: work)
      work.objects[xmpID] = .stream(PDFStream(dictionary: [PDFName("Type"): .name(PDFName("Metadata")), PDFName("Subtype"): .name(PDFName("XML"))], bytes: Data(PDFXExporter.identificationXMP(profile: profile).utf8)))
      if case .reference(let catalogID)? = work.trailer[PDFName("Root")], case .dictionary(var catalog)? = work.objects[catalogID] {
        catalog[PDFName("Metadata")] = .reference(xmpID)
        work.objects[catalogID] = .dictionary(catalog)
      }
    case .flattenAnnotations:
      for pageID in pageIDs
      where !FlattenAnnotationsCommand.flattenablePageIDs(in: work, pageIDs: [pageID]).isEmpty {
        work = try PDFEditingEngine.commit(
          PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: work, limits: limits)
      }
    case .flattenFormFields:
      work = try PDFEditingEngine.commit(PDFTransaction([FlattenFormCommand()]), to: work, limits: limits)
    }
    let after = Self.evaluate(graph: work, pageIDs: pageIDs, ruleSet: ruleSet, profile: profile)
    graph = work
    report = after
    let result = PreflightFixupApplyResult(preview: preview, reportBefore: before, reportAfter: after, graph: work)
    appliedFixups.append(result)
    return result
  }

  public func exportReport() -> String {
    var lines = ["sPDF preflight and staged fixups", "Rule set: \(ruleSet.name)", "", report.text(), ""]
    if appliedFixups.isEmpty {
      lines.append("No staged fixups were applied.")
    } else {
      lines.append("Applied fixups:")
      for result in appliedFixups {
        lines.append("  " + result.summary)
        for change in result.preview.changes {
          lines.append("    " + (change.pageIndex.map { "page \($0 + 1)" } ?? "document") + ": " + change.before + " -> " + change.after)
        }
      }
    }
    lines.append("")
    lines.append("Source document was not modified; fixes were staged on copies.")
    return lines.joined(separator: "\n")
  }

  static func boxValues(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value else { return nil }
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let n): return Double(n)
      case .real(let n): return n
      default: return nil
      }
    }
    return numbers.count == 4 ? numbers : nil
  }

  static func format(_ box: [Double]?) -> String {
    guard let box else { return "missing" }
    return box.map { String(format: "%.0f", $0) }.joined(separator: "x")
  }

  private func graphOutputIntentState() -> String {
    let inventory = PDFXExporter.inventory(graph, pageIDs: pageIDs, profile: profile)
    if inventory.hasOutputIntent && inventory.outputIntentHasICC { return "existing output intent with ICC" }
    return inventory.hasOutputIntent ? "output intent without a valid ICC profile" : "no output intent"
  }

  private func identificationState() -> String {
    let inventory = PDFXExporter.inventory(graph, pageIDs: pageIDs, profile: profile)
    if let version = inventory.identifiedVersion { return "XMP identifies \(version)" }
    return "no PDF/X identification XMP"
  }

  static func evaluate(graph: PDFGraph, pageIDs: [PDFObjectID], ruleSet: PreflightRuleSet, profile: PDFXProfile) -> PreflightReport {
    let x4 = PDFXExporter.inventory(graph, pageIDs: pageIDs, profile: profile)
    var findings: [PreflightFinding] = []
    func emit(_ id: String, _ message: String, pageIndex: Int? = nil, objectID: PDFObjectID? = nil) {
      guard ruleSet.enabledRuleIDs.contains(id) else { return }
      findings.append(PreflightFinding(ruleID: id, severity: ruleSet.severity(for: id), message: message, pageIndex: pageIndex, objectID: objectID, fixupID: PreflightRuleDefinition.definition(id)?.fixupID))
    }
    if x4.fontsNotEmbedded > 0 {
      emit("fontEmbedding", "\(x4.fontsNotEmbedded) font(s) not embedded: " + x4.unembeddedFontNames.joined(separator: ", "))
    }
    let images = (try? PDFImageInventory.images(in: graph, pageIDs: pageIDs)) ?? []
    for image in images {
      let width = image.bounds.count == 4 ? image.bounds[2] - image.bounds[0] : 0
      if width > 0 {
        let dpi = Double(image.width) / (width / 72)
        if dpi < ruleSet.minimumImageDPI {
          emit("imageResolution", "\(image.name) is \(Int(dpi)) dpi at placement (minimum \(Int(ruleSet.minimumImageDPI)))", pageIndex: image.pageIndex, objectID: image.objectID)
        }
      }
    }
    if !x4.hasOutputIntent {
      emit("outputIntent", "No output intent")
    } else if !x4.outputIntentHasICC {
      emit("outputIntent", "Output intent has no valid CMYK ICC profile")
    }
    if x4.identifiedVersion != profile.identification {
      emit("pdfxIdentification", x4.identifiedVersion == nil ? "No PDF/X identification XMP" : "XMP identifies \(x4.identifiedVersion ?? "unknown") instead of \(profile.identification)")
    }
    for page in x4.pages where page.trimBox == nil {
      emit("printBoxes", "No TrimBox", pageIndex: page.pageIndex)
    }
    if x4.transparencyUses > 0 {
      let message = profile.allowsTransparency ? "\(x4.transparencyUses) transparency use(s) permitted by \(profile.identification)" : "\(x4.transparencyUses) transparency use(s); \(profile.identification) requires flattening (not provided)"
      if !protocolLimits.contains(ruleSet.name) || !profile.allowsTransparency {
        emit("transparency", message)
      }
    }
    if x4.rgbContentUses > 0 || !x4.rgbImageNames.isEmpty {
      let message = profile.allowsRGB ? "\(x4.rgbContentUses) RGB operator(s) and \(x4.rgbImageNames.count) RGB image(s) permitted by \(profile.identification)" : "\(x4.rgbContentUses) RGB operator(s), \(x4.rgbImageNames.count) RGB image(s); \(profile.identification) refuses RGB conversion"
      if !profile.allowsRGB || ruleSet.enabledRuleIDs.contains("rgbContent") {
        emit("rgbContent", message)
      }
    }
    if x4.annotationCount > 0 {
      emit("annotations", "\(x4.annotationCount) annotation(s) present; print export flattens them")
    }
    if x4.formFieldCount > 0 {
      emit("formFields", "\(x4.formFieldCount) form field(s) present; print export flattens them")
    }
    if x4.encrypted { emit("encryption", "Document is encrypted") }
    if !x4.unsupportedFilters.isEmpty { emit("filters", "Unsupported filters: " + x4.unsupportedFilters.joined(separator: ", ")) }
    findings.sort { lhs, rhs in
      if lhs.severity.rank != rhs.severity.rank { return lhs.severity.rank > rhs.severity.rank }
      return lhs.ruleID < rhs.ruleID
    }
    return PreflightReport(ruleSetName: ruleSet.name, findings: findings)
  }

  private static let protocolLimits: Set<String> = ["PDF/X-4 declared subset"]
}

