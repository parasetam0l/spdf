import AppKit
import PDFCore
import PDFEditing
import UniformTypeIdentifiers

// MARK: - PAG-08 scanner/print handoff

/// PAG-08: documented local acquisition handoffs. sPDF never embeds a scanner
/// driver or a print engine; it hands acquisition to the macOS Image Capture
/// app (scan to a file, then import the files here) and to the system print
/// service (Print → Save as PDF, then import the resulting PDF/images). Both
/// handoffs are explicit buttons with the same instructions the docs carry.
enum PDFScannerHandoff {
  static let imageCapturePath = "/System/Applications/Image Capture.app"
  static let printScanSettingsURL = "x-apple.systempreferences:com.apple.Print-Scan"

  static var guidance: String {
    "Image Capture handoff: opens macOS Image Capture. Scan pages there (PDF or images), "
      + "then return here and add the saved files with Add Images… or choose them in "
      + "File → Create PDF → From Images…. sPDF never talks to the scanner hardware directly."
  }

  static var printServiceGuidance: String {
    "Local print service handoff: opens Print & Scan settings. Any application that can print "
      + "can produce a PDF with its Print dialog's Save as PDF action; add that file here with "
      + "Add Images… (raster PDF pages) or open it directly in sPDF. No keychain or network "
      + "service is involved."
  }

  @discardableResult
  static func openImageCapture() -> Bool {
    let url = URL(fileURLWithPath: imageCapturePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return NSWorkspace.shared.open(url)
  }

  @discardableResult
  static func openPrintScanSettings() -> Bool {
    guard let url = URL(string: printScanSettingsURL) else { return false }
    return NSWorkspace.shared.open(url)
  }
}

// MARK: - PAG-08 document routes

extension SPDFDocument {
  var canCreatePDF: Bool { true }

  /// File → Create PDF → Clipboard / Scanner…: the creation panel (also works
  /// without an open document; it creates a new untitled PDF).
  func presentCreatePDFPanel() {
    CreatePDFPanelHost.present(document: self)
  }
}

@MainActor
enum CreatePDFActions {
  /// Open generated PDF bytes as a new untitled editable document.
  static func openAsDocument(_ result: PDFCreationResult) throws {
    guard let controller = NSDocumentController.shared as? DocumentController else {
      throw PDFError(.unsupported, "The document controller is unavailable")
    }
    _ = try controller.newDocument(fromPDFData: result.data)
  }
}

// MARK: - Panel host

@MainActor
enum CreatePDFPanelHost {
  private static var controller: CreatePDFPanelController?

  static func present(document: SPDFDocument?) {
    if let controller {
      controller.refresh(document: document)
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = CreatePDFPanelController(document: document)
    self.controller = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  static func panelDidClose(_ controller: CreatePDFPanelController) {
    if self.controller === controller { self.controller = nil }
  }
}
