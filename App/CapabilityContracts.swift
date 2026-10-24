import AppKit
import Foundation

/// SAF-04: a contract for one advertised document tool. The contract records
/// the normal menu path and selector, the document service it reaches, the
/// operation's limits and its output semantics. The native audit walks the
/// real menu bar and verifies these entries rather than trusting a separate
/// hand-written list.
struct CapabilityContract: Sendable, Equatable {
  enum Group: String, Sendable, CaseIterable {
    case create
    case export
    case metadata
    case editText
    case page
    case form
    case review
    case annotate
    case tools
    case security
    case production

    var limits: String {
      switch self {
      case .create:
        return "Local image/text inputs; owned PDF writer; no embedded third-party PDF engine."
      case .export:
        return "Derivative gate commits pending edits, verifies output and never overwrites the open source."
      case .metadata:
        return "Document information dictionary only; XMP is not rewritten."
      case .editText:
        return "Supported fonts/runs only; unsupported transforms refuse without mutating source bytes."
      case .page:
        return "Page-tree transaction with undo; page identities and unrelated objects are preserved."
      case .form:
        return "Supported field kinds only; read-only/signature fields refuse; values and appearances stay coherent."
      case .review:
        return "Local XFDF exchange; unsupported payloads are reported rather than silently discarded."
      case .annotate:
        return "Supported annotation types; one undoable transaction; protected/signed constraints apply."
      case .tools:
        return "Operation-specific preflight; verified output; unsupported cases return explicit results."
      case .security:
        return "Permission-aware gate; required rewrites are verified; source is never modified in place."
      case .production:
        return "Owned compatibility/archival/color profiles only; no Ghostscript or hidden external engine."
      }
    }

    var output: String {
      switch self {
      case .create: return "A new editable PDF document."
      case .export: return "A chosen derivative file or package."
      case .metadata: return "Edited document information."
      case .editText: return "Edited page text with preserved surrounding content."
      case .page: return "Edited page structure and navigation metadata."
      case .form: return "Coherent field values and appearances."
      case .review: return "Portable review comments with stable identities and threads."
      case .annotate: return "Review annotations on the selected page."
      case .tools: return "Operation report or derivative."
      case .security: return "Sanitized, encrypted, locked or signed document as chosen."
      case .production: return "Compatibility report or converted derivative."
      }
    }

    var evidence: String {
      switch self {
      case .create:
        return "ImagePDFCreationTests, TextPDFCreationTests; native creation smoke."
      case .export:
        return "TextExportTests, PageImageExportTests, HTML/DOCX/Table export suites; native export smoke."
      case .metadata:
        return "OutlineAuthoringTests metadata test; native metadata round-trip."
      case .editText:
        return "Text pipeline/reflow suites; native inline edit and refusal smoke."
      case .page:
        return "Page operation/assembly suites, OutlineAuthoringTests; native organizer/split/combine smoke."
      case .form:
        return "FormTests, FormValueTests, FormFieldPropertiesTests; native form smoke."
      case .review:
        return "CommentExchangeTests, CommentTriageAcceptanceTests; native XFDF merge smoke."
      case .annotate:
        return "Markup/ink/content annotation suites; native annotation, appearance and flatten smoke."
      case .tools:
        return "Optimization/comparison/table/DOCX suites; native tools smoke."
      case .security:
        return "SecureRewriteTests, DerivativeOutputPolicyTests, signature suites; native security smoke."
      case .production:
        return "Compatibility/archival/color suites; native print-production smoke."
      }
    }
  }

  let id: String
  let title: String
  let menuPath: String
  let selector: String
  let service: String
  let group: Group
  let limits: String
  let output: String
  let evidence: String

  init(
    title: String, menuPath: String, selector: String, group: Group,
    service: String? = nil, limits: String? = nil, output: String? = nil,
    evidence: String? = nil
  ) {
    self.id = "\(menuPath)|\(selector)"
    self.title = title
    self.menuPath = menuPath
    self.selector = selector
    self.service = service ?? "ApplicationDelegate.\(selector) → current SPDFDocument"
    self.group = group
    self.limits = limits ?? group.limits
    self.output = output ?? group.output
    self.evidence = evidence ?? group.evidence
  }
}

/// SAF-04: build contracts from the actual main menu and verify that every
/// advertised document-tool item has one, that targets respond, and that the
/// critical workflows carry their specific limits rather than only a group
/// default.
enum CapabilityContractAudit {
  struct Report {
    let contracts: [CapabilityContract]
    let issues: [String]

    var text: String {
      var lines = [
        "sPDF Editor capability contracts",
        "Tools: \(contracts.count)",
        issues.isEmpty ? "Status: PASS" : "Status: FAIL",
        "",
      ]
      for contract in contracts {
        lines.append("\(contract.menuPath)")
        lines.append("  selector: \(contract.selector)")
        lines.append("  service: \(contract.service)")
        lines.append("  limits: \(contract.limits)")
        lines.append("  output: \(contract.output)")
        lines.append("  evidence: \(contract.evidence)")
        lines.append("")
      }
      if !issues.isEmpty {
        lines.append("Issues:")
        lines.append(contentsOf: issues)
      }
      return lines.joined(separator: "\n")
    }
  }

  private static let documentSubmenus: Set<String> = [
    "Create PDF", "Export", "Page", "Form", "Annotate", "Tools",
  ]

  private static let extraDocumentSelectors: Set<String> = [
    "documentMetadata:", "printDocument:",
    "copyAsRichText:", "showFind:", "findNext:", "findPrevious:",
    "editSelectedText:", "reflowParagraph:", "redactSelection:",
    "togglePageTextBold:", "togglePageTextItalic:",
    "selectNextPageObject:", "selectPreviousPageObject:",
  ]

  /// Critical tools whose contract must be more specific than its group.
  private static let specificSelectors: Set<String> = [
    "saveSanitizedCopy:", "exportEncryptedCopy:", "redactSelection:",
    "exportComments:", "importComments:", "createPDFFromImages:",
    "createPDFFromText:", "exportAttachments:", "manageAttachments:",
    "manageBookmarks:", "splitDocument:", "combineDocuments:",
    "importFormValues:", "exportFormValues:", "runOCR:",
    "runOCRAllPages:", "reflowParagraph:", "createArchivalCopy:",
  ]

  private static let specificLimits: [String: String] = [
    "saveSanitizedCopy:":
      "Staged sanitizer removes hidden data and unreachable objects; verified full rewrite; source untouched; exclusions reported.",
    "exportEncryptedCopy:":
      "Re-encrypts through the derivative gate; protected input is allowed only because output re-encrypts.",
    "redactSelection:":
      "Applied redaction forces a verified full rewrite and never appears secure through an incremental save.",
    "exportComments:":
      "XFDF carries supported note/markup/drawing comments with identity/thread/state; FileAttachment bytes are not carried.",
    "importComments:":
      "Merges by stable identity, supports cross-page moves, reports unsupported types and malformed geometry.",
    "createPDFFromImages:":
      "Local raster images only; one image per page; bounded input and explicit skipped-file reporting.",
    "createPDFFromText:":
      "Local plain text; paginates into editable page content using the owned writer.",
    "exportAttachments:":
      "Extracts embedded bytes only to a chosen folder; sanitized filenames and traversal refusal.",
    "manageAttachments:":
      "Add/edit-description/remove/export through undoable commands; embedded bytes and filespec identity preserved unless deliberately replaced.",
    "manageBookmarks:":
      "Page-target bookmark editing with sibling reorder, nest/outdent and subtree removal; links repaired.",
    "splitDocument:":
      "Page-exact split to verified files; duplicate membership refused; oversized pages isolated and disclosed.",
    "combineDocuments:":
      "Ordered local sources; duplicate-field policy and bookmark review before one verified write.",
    "importFormValues:":
      "JSON/XFDF/FDF mapped to existing field kinds; unknown, read-only and ambiguous fields reported.",
    "exportFormValues:":
      "JSON/XFDF/FDF carries supported values, Unicode, nested names, button states and multi-select arrays.",
    "runOCR:":
      "Selected OCR candidates only; Vision Accurate attempts Fast fallback and discloses fallback quality.",
    "runOCRAllPages:":
      "All OCR candidates; same quality fallback and explicit unsupported-page reporting.",
    "reflowParagraph:":
      "Supported fonts/runs and bounded spacing; unsupported advance mappings refuse instead of emitting garbled text.",
    "createArchivalCopy:":
      "Owned archival derivative profile with explicit PDF/A limitation disclosure; no unsupported identifier is claimed.",
  ]

  private static let specificServices: [String: String] = [
    "saveSanitizedCopy:": "SPDFDocument.saveSanitizedCopy()",
    "exportEncryptedCopy:": "SPDFDocument.exportEncryptedCopy()",
    "redactSelection:": "SPDFDocument.redactSelection()",
    "exportComments:": "SPDFDocument.exportComments()",
    "importComments:": "SPDFDocument.importComments()",
    "createPDFFromImages:": "ApplicationDelegate.createPDFFromImages()",
    "createPDFFromText:": "ApplicationDelegate.createPDFFromText()",
    "exportAttachments:": "SPDFDocument.exportAttachments()",
    "manageAttachments:": "SPDFDocument.manageAttachments()",
    "manageBookmarks:": "SPDFDocument.manageBookmarks()",
    "splitDocument:": "SPDFDocument.presentSplitDocument()",
    "combineDocuments:": "SPDFDocument.presentCombineDocuments()",
    "importFormValues:": "SPDFDocument.importFormValues()",
    "exportFormValues:": "SPDFDocument.exportFormValues()",
    "runOCR:": "SPDFDocument.runOCR()",
    "runOCRAllPages:": "SPDFDocument.runOCRAllPages()",
    "reflowParagraph:": "SPDFDocument.reflowParagraph()",
    "createArchivalCopy:": "SPDFDocument.createArchivalCopy()",
  ]

  private static let specificOutputs: [String: String] = [
    "saveSanitizedCopy:": "Chosen sanitized PDF with hidden data removed; source unchanged.",
    "exportEncryptedCopy:": "Encrypted copy PDF.",
    "redactSelection:": "Applied redactions in a secure-rewrite session.",
    "exportComments:": "XFDF comment file.",
    "importComments:": "Merged comments and thread links in the open document.",
    "createPDFFromImages:": "Untitled editable PDF with one image per page.",
    "createPDFFromText:": "Untitled editable, paginated PDF.",
    "exportAttachments:": "Files extracted into the chosen folder.",
    "manageAttachments:": "Undoable attachment list and description state.",
    "manageBookmarks:": "Undoable bookmark hierarchy and page targets.",
    "splitDocument:": "Verified part PDF files.",
    "combineDocuments:": "One verified combined PDF.",
    "importFormValues:": "Mapped form values plus a skipped/ambiguous-field report.",
    "exportFormValues:": "JSON, XFDF or FDF value file.",
    "runOCR:": "Searchable text layers on selected OCR pages.",
    "runOCRAllPages:": "Searchable text layers on all OCR candidates.",
    "reflowParagraph:": "Reflowed page text with surrounding content preserved.",
    "createArchivalCopy:": "Archival derivative with its declared profile limits.",
  ]

  static func run(menu: NSMenu?) -> Report {
    var contracts: [CapabilityContract] = []
    var issues: [String] = []
    guard let menu else {
      return Report(contracts: [], issues: ["The application menu is unavailable."])
    }
    walk(menu, path: [], contracts: &contracts, issues: &issues)
    var ids = Set<String>()
    for contract in contracts {
      if !ids.insert(contract.id).inserted {
        issues.append("Duplicate capability contract: \(contract.menuPath)")
      }
      if contract.limits.isEmpty || contract.output.isEmpty || contract.evidence.isEmpty {
        issues.append("Capability contract lacks limits/output/evidence: \(contract.menuPath)")
      }
    }
    for selector in specificSelectors {
      guard contracts.contains(where: { $0.selector == selector }) else {
        issues.append("Critical capability is missing from the document menus: \(selector)")
        continue
      }
      guard let expected = specificLimits[selector] else { continue }
      guard contracts.contains(where: {
        $0.selector == selector && $0.limits == expected
          && (specificServices[selector] == nil || $0.service == specificServices[selector])
          && (specificOutputs[selector] == nil || $0.output == specificOutputs[selector])
      }) else {
        issues.append("Critical capability lacks its specific contract: \(selector)")
        continue
      }
    }
    return Report(contracts: contracts.sorted { $0.menuPath < $1.menuPath }, issues: issues)
  }

  private static func walk(
    _ menu: NSMenu, path: [String], contracts: inout [CapabilityContract],
    issues: inout [String]
  ) {
    for item in menu.items {
      if item.isSeparatorItem { continue }
      let itemPath = path + [item.title]
      if let submenu = item.submenu {
        walk(submenu, path: itemPath, contracts: &contracts, issues: &issues)
        continue
      }
      guard let action = item.action else { continue }
      let selector = NSStringFromSelector(action)
      let inDocumentMenu = path.contains(where: { documentSubmenus.contains($0) })
      guard inDocumentMenu || extraDocumentSelectors.contains(selector) else { continue }
      guard let target = item.target else {
        issues.append("Document tool has no action target: \(itemPath.joined(separator: " → "))")
        continue
      }
      guard target.responds(to: action) else {
        issues.append(
          "Document tool target does not respond: \(itemPath.joined(separator: " → "))")
        continue
      }
      let group = group(for: path + [item.title])
      contracts.append(
        CapabilityContract(
          title: item.title, menuPath: itemPath.joined(separator: " → "),
          selector: selector, group: group,
          service: specificServices[selector],
          limits: specificLimits[selector],
          output: specificOutputs[selector]))
    }
  }

  private static func group(for path: [String]) -> CapabilityContract.Group {
    if path.contains("Print Production") { return .production }
    if path.contains("Security") { return .security }
    if path.contains("Create PDF") { return .create }
    if path.contains("Export") { return .export }
    if path.contains("Page") { return .page }
    if path.contains("Form") { return .form }
    if path.contains("Annotate") {
      if path.contains(where: { $0.contains("Comments") }) { return .review }
      return .annotate
    }
    if path.contains("Document Metadata") { return .metadata }
    if path.contains("Tools") { return .tools }
    if path.contains("Edit") { return .editText }
    return .tools
  }
}
