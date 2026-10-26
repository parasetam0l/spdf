import AppKit
import Foundation

/// SAF-04: a contract for one advertised document tool. The contract records
/// the normal menu path and selector, the document service it reaches, the
/// operation's limits and its output semantics. The native audit walks the
/// real menu bar and verifies these entries rather than trusting a separate
/// hand-written list.
struct CapabilityContract: Sendable, Equatable {
  enum ExecutionEvidence: String, Sendable {
    case nativeService = "native-service"
    case coreSuite = "core-suite"
    case menuWindow = "menu-or-window"
  }

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
  let execution: ExecutionEvidence
  let executionEvidence: String

  init(
    title: String, menuPath: String, selector: String, group: Group,
    service: String? = nil, limits: String? = nil, output: String? = nil,
    evidence: String? = nil, execution: ExecutionEvidence = .menuWindow,
    executionEvidence: String = "Menu/window route exercised; operation awaits user input."
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
    self.execution = execution
    self.executionEvidence = executionEvidence
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
      let native = contracts.filter { $0.execution == .nativeService }.count
      let core = contracts.filter { $0.execution == .coreSuite }.count
      let menuOnly = contracts.filter { $0.execution == .menuWindow }.count
      var lines = [
        "sPDF Editor capability contracts",
        "Tools: \(contracts.count)",
        "Execution evidence: native-service \(native), core-suite \(core), menu/window \(menuOnly)",
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
        lines.append("  execution: \(contract.execution.rawValue) — \(contract.executionEvidence)")
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
    "Create PDF", "Export", "Page", "Form", "Annotate", "Objects", "Tools",
  ]

  private static let extraDocumentSelectors: Set<String> = [
    "documentMetadata:", "printDocument:",
    "copyAsRichText:", "copyTextBox:", "pasteTextBox:", "duplicateTextBox:",
    "showRedactionMarks:", "signExistingSignatureField:", "showSignatureDetails:",
    "showRedactionSanitization:", "certifyDocument:", "showSignatureCertificationStatus:",
    "showSigningWorkflowGuide:", "showSignaturePresentation:", "signHiddenCertificate:",
    "showFormResponses:", "showFormAccessibleValidation:",
    "showFind:", "findNext:", "findPrevious:",
    "editSelectedText:", "reflowParagraph:", "redactSelection:",
    "togglePageTextBold:", "togglePageTextItalic:",
    "selectNextPageObject:", "selectPreviousPageObject:",
  ]

  /// Critical tools whose contract must be more specific than its group.
  private static let specificSelectors: Set<String> = [
    "saveSanitizedCopy:", "exportEncryptedCopy:", "redactSelection:", "showRedactionMarks:",
    "signExistingSignatureField:", "showSignatureDetails:",
    "exportComments:", "importComments:", "createPDFFromImages:",
    "editImageExternally:", "editVectorObject:",
    "showFormRulesPanel:", "showFormRichTextEditor:",
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
    "signExistingSignatureField:":
      "Fills an existing empty signature field as an incremental update; earlier signed bytes stay byte-identical; DocMDP/FieldMDP permissions and field locks are enforced; source is never modified in place.",
    "showSignatureDetails:":
      "Read-only signed-revision inspection (coverage, signer identity, crypto/trust, changes between signatures); changes no bytes.",
    "showRedactionMarks:":
      "Staged marks are review-only and change no bytes; Apply removes reviewed text/regions in one transaction and the save barrier prevents unapplied marks from reading as secure; hidden/OCR scope is explicit.",
    "showFormRulesPanel:":
      "Rules are declarative app-specific sum/number/date keys producing static /V values and appearances; no JavaScript is ever authored or executed; imported actions are preserved and disclosed; Freeze writes values + appearances in one undoable step.",
    "showFormRichTextEditor:":
      "Rich runs are bold/italic/size/colour over composed-character ranges with bounded RTF /RV, mixed-run appearances for every widget, inherited /DA /DR /Q /MaxLen /TU resolution and embedded TrueType appearance fonts; unsupported fonts/glyphs refuse; fills are one undoable command.",
    "editImageExternally:":
      "Exports one selected image instance with honest provenance, reimports a chosen file only after preview and explicit mask/aspect/reconstruction acknowledgements, keeps placement geometry and byte-identical sibling instances, and commits one transaction/one Undo.",
    "editVectorObject:":
      "Edits one page-level ordinary vector path's fill/stroke or applies a verified coordinate rewrite after preview; gradient shadings, tiling patterns, form XObjects/images, inline images and stale selections refuse without changing content.",
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
    "signExistingSignatureField:": "SPDFDocument.presentSignatureSigningFlow()",
    "showSignatureDetails:": "SPDFDocument.presentSignatureRevisionDetails()",
    "showRedactionMarks:": "SPDFDocument.showRedactionMarks()",
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
    "editImageExternally:": "SPDFDocument.presentExternalImageEditor()",
    "showFormRulesPanel:": "SPDFDocument.showFormRulesPanel()",
    "certifyDocument:": "SPDFDocument.presentSignatureCertification()",
    "showSignatureCertificationStatus:": "SPDFDocument.presentSignatureCertificationStatus()",
    "showSigningWorkflowGuide:": "SPDFDocument.presentSigningWorkflowGuide()",
    "showSignaturePresentation:": "SPDFDocument.showSignaturePresentationPanel()",
    "signHiddenCertificate:": "SPDFDocument.presentHiddenCertificateSigning()",
    "showFormResponses:": "SPDFDocument.showFormResponsesPanel()",
    "showFormAccessibleValidation:": "SPDFDocument.presentFormAccessiblePanel()",
    "showOCRMixedPages:": "SPDFDocument.presentOCRMixedPagesPanel()",
    "showFormRoundTripData:": "SPDFDocument.presentFormRoundTripPanel()",
    "showBidirectionalTextInsertion:": "SPDFDocument.showBidirectionalTextInsertion()",
    "showCJKTextInsertion:": "SPDFDocument.showCJKTextInsertion()",
    "showFormRichTextEditor:": "SPDFDocument.showFormRichTextFieldEditor()",
    "editVectorObject:": "SPDFDocument.presentVectorObjectEditor()",
  ]

  private static let specificOutputs: [String: String] = [
    "saveSanitizedCopy:": "Chosen sanitized PDF with hidden data removed; source unchanged.",
    "exportEncryptedCopy:": "Encrypted copy PDF.",
    "redactSelection:": "Applied redactions in a secure-rewrite session.",
    "signExistingSignatureField:": "Signed copy with one added incremental signature; earlier signatures preserved.",
    "showSignatureDetails:": "Signed-revision report and signer identities; no document changes.",
    "showRedactionMarks:": "Reviewable pending marks plus applied secure-rewrite redactions.",
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
    "editImageExternally:": "Previewed one-instance image replacement with unchanged placement geometry.",
    "showFormRulesPanel:": "Rule/action inventory, static recalculation and freeze results; imported actions unchanged.",
    "showFormRichTextEditor:": "Edited rich-text field value with regenerated appearances.",
    "editVectorObject:": "Previewed style/transform change on one ordinary vector path.",
  ]

  /// Selectors whose normal document/viewer service entry point is exercised
  /// by the native smoke or a direct service-level test.
  private static let nativeSelectors: Set<String> = [
    "selectTool:", "textEditTool:", "addTextTool:", "pageTool:", "imageEditTool:",
    "toggleInkTool:", "placeGraphicalSignature:", "manageAttachments:", "manageBookmarks:",
    "exportText:", "exportPageImages:", "exportHTML:", "exportDOCX:", "exportTables:",
    "exportImages:", "exportPrintPDF:", "exportAttachments:", "saveSanitizedCopy:",
    "exportEncryptedCopy:", "lockDocument:", "unlockDocument:", "signDocument:",
    "optimizeDocument:", "compareWithDocument:", "splitDocument:", "combineDocuments:",
    "importPages:", "rotateLeft:", "rotateRight:", "movePageUp:", "movePageDown:",
    "insertBlankPage:", "deletePage:", "organizePages:", "addPageMark:", "flattenForm:",
    "renameFormField:", "deleteFormField:", "duplicateFormField:", "alignFormFields:",
    "editFormTabOrder:", "copyAsRichText:", "copyTextBox:", "pasteTextBox:",
    "duplicateTextBox:", "showFind:", "editSelectedText:",
    "reflowParagraph:", "redactSelection:", "selectNextPageObject:",
    "selectPreviousPageObject:", "highlightSelection:", "exportReviewSummary:",
    "showCompatibilityReport:", "exportFormValues:", "importFormValues:",
    "addBookmark:", "editBookmark:", "removeBookmark:", "exportOutline:",
    "noteSelection:", "underlineSelection:", "strikeoutSelection:", "flattenAnnotations:",
    "runOCR:", "runOCRAllPages:", "findNext:", "findPrevious:", "togglePageTextBold:",
    "togglePageTextItalic:", "createPDFFromImages:", "createPDFFromText:",
    "documentMetadata:", "addTextField:", "addCheckbox:", "addRadioGroup:",
    "addChoiceField:", "addPushButton:", "addSignatureField:", "editFormFieldProperties:",
    "recalculateForm:", "distributeFormFields:", "cropPages:", "removePageMark:",
    "batesNumberingBatch:", "showRedactionMarks:", "showOCRReview:", "showOCRBatch:",
    "signExistingSignatureField:", "showSignatureDetails:",
    "showReviewReports:", "exportReviewSummaryPDF:", "exportComparisonReportPDF:",
    "toggleArrangeObjects:", "arrangeSelectedObjects:",
    "editImageExternally:", "editVectorObject:",
    "showFormRulesPanel:", "showFormRichTextEditor:",
    "showFormResponses:", "showFormAccessibleValidation:",
    "showBidirectionalTextInsertion:", "showCJKTextInsertion:",
    "showRedactionSanitization:",
    "certifyDocument:", "showSignatureCertificationStatus:", "showSigningWorkflowGuide:",
    "showSignaturePresentation:", "signHiddenCertificate:", "showFormResponses:",
    "showOCRMixedPages:", "showFormRoundTripData:",
    "showFormDesignPanel:", "detectFormFields:", "showCreatePDFPanel:",
    "showScanCleanup:", "showScannedTextReconstruction:",
    "repairDocument:", "reviewTables:", "previewDOCX:", "convertColors:",
    "createArchivalCopy:", "exportComments:", "importComments:", "printDocument:",
  ]

  /// Selectors whose operation is covered only by an owned-core suite.
  private static let coreSelectors: Set<String> = []

  private static let menuSelectors: Set<String> = []

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
      let native = nativeSelectors.contains(contract.selector)
      let core = coreSelectors.contains(contract.selector)
      let menuOnly = menuSelectors.contains(contract.selector)
      let classifications = [native, core, menuOnly].filter { $0 }.count
      if classifications == 0 {
        issues.append("Capability contract has no execution evidence: \(contract.menuPath)")
      } else if classifications > 1 {
        issues.append("Capability contract has conflicting execution evidence: \(contract.menuPath)")
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

  static func execution(for selector: String)
    -> (CapabilityContract.ExecutionEvidence?, String)
  {
    let native = nativeSelectors.contains(selector)
    let core = coreSelectors.contains(selector)
    let menu = menuSelectors.contains(selector)
    let count = [native, core, menu].filter { $0 }.count
    guard count == 1 else { return (nil, "Unclassified") }
    if native {
      return (
        .nativeService,
        "Native smoke or a direct service-level test invokes the document/viewer entry point."
      )
    }
    if core {
      return (
        .coreSuite,
        "Owned-core suite covers the operation and limits; the document dialog is not driven end-to-end."
      )
    }
    return (.menuWindow, "Menu/window route exercised; the full operation awaits user input.")
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
      let execution = execution(for: selector)
      contracts.append(
        CapabilityContract(
          title: item.title, menuPath: itemPath.joined(separator: " → "),
          selector: selector, group: group,
          service: specificServices[selector],
          limits: specificLimits[selector],
          output: specificOutputs[selector],
          execution: execution.0 ?? .menuWindow,
          executionEvidence: execution.1))
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
