import AppKit
import MacServices

/// OCR-07: document route for the multi-file OCR queue. The queue itself is
/// document-independent (files on disk); this menu hook opens one panel per
/// window.
private enum OCRBatchAssociationKeys {
  /// Associated-object address only; the value is never read.
  nonisolated(unsafe) static var model: UInt8 = 0
}

extension SPDFDocument {
  var ocrBatchModel: OCRBatchModel {
    if let existing = objc_getAssociatedObject(
      self, &OCRBatchAssociationKeys.model) as? OCRBatchModel
    {
      return existing
    }
    let model = OCRBatchModel()
    objc_setAssociatedObject(
      self, &OCRBatchAssociationKeys.model, model,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return model
  }

  var canShowOCRBatchPanel: Bool { true }

  /// Menu hook (Tools > OCR > OCR Files...): open the multi-file OCR queue.
  func showOCRBatch() {
    if let controller = windowControllers.compactMap({
      $0 as? OCRBatchPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = OCRBatchPanelController(model: ocrBatchModel)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
