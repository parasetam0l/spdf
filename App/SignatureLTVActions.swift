import AppKit
import PDFCore
import PDFEditing
import SwiftUI

/// SIG-04: read-only long-term validation (PAdES/DSS) report. Embedded
/// evidence is evaluated offline; nothing is fetched and no state is added to
/// SPDFDocument. Menu wiring is described in the task SESSION.md.
@MainActor
final class SignatureLongTermValidationModel: ObservableObject {
  @Published private(set) var report: PDFLongTermValidationReport?
  @Published private(set) var problem: String?

  private let reportProvider: @MainActor () -> PDFLongTermValidationReport?

  init(reportProvider: @escaping @MainActor () -> PDFLongTermValidationReport?) {
    self.reportProvider = reportProvider
  }

  func reload() {
    report = reportProvider()
    problem = report == nil ? "No PDF graph or source bytes are available." : nil
  }

  var profile: PDFLongTermValidationProfile { report?.profile ?? .noSignatures }
  var disclosure: String {
    report?.disclosure ?? PDFLongTermValidationDisclosure.supportedProfile
  }
  var signatures: [PDFLongTermSignatureEvidence] { report?.signatures ?? [] }
  var documentTimestamps: [PDFDocumentTimestampEvidence] {
    report?.documentTimestamps ?? []
  }
  var dss: PDFDSSInventory {
    report?.dss
      ?? PDFDSSInventory(
        hasDSS: false, certificateDER: [], ocspDER: [], crlDER: [], vri: [:])
  }
  var warnings: [String] { report?.warnings ?? [] }
  var isLongTermValid: Bool { report?.isLongTermValid ?? false }
}

extension SPDFDocument {
  /// Hook: call from the "Long-Term Validation Evidence…" menu item.
  @MainActor
  func signatureLongTermValidationModel() -> SignatureLongTermValidationModel {
    SignatureLongTermValidationModel { [weak self] in
      guard let self else { return nil }
      let graph: PDFGraph?
      let sourceData: Data?
      if let editing = self.editSession.currentGraph {
        graph = editing
        sourceData = (try? self.editSession.bytesForSave()) ?? self.sourceStore.snapshot()?.data
      } else if let saved = self.sourceStore.snapshot()?.data {
        sourceData = saved
        graph = try? PDFParser.parse(
          saved, limits: SPDFDocumentResourcePolicy.parsingLimits).graph
      } else {
        return nil
      }
      guard let graph, let sourceData else { return nil }
      return PDFLongTermValidationValidator.report(in: graph, sourceData: sourceData)
    }
  }

  /// Menu validation hook.
  var canShowSignatureLongTermValidationPanel: Bool {
    editSession.currentGraph != nil || sourceStore.snapshot()?.data != nil
  }

  /// Hook: Tools > Security > Long-Term Validation Evidence…
  @MainActor
  func showSignatureLongTermValidationPanel() {
    let model = signatureLongTermValidationModel()
    model.reload()
    let hosting = NSHostingView(rootView: SignatureLTVPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 520)
    let alert = NSAlert()
    alert.messageText = "Long-Term Validation Evidence"
    alert.alertStyle = .informational
    alert.informativeText =
      "Embedded DSS evidence is evaluated offline. The report names the exact supported "
      + "PAdES/DSS subset and marks incomplete or unsupported cases; it never fetches evidence."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }
}
