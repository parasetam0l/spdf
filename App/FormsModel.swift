import Combine
import Foundation
import PDFEditing

/// Thread-safe dirty-state mirror for form text drafts, which are edited in
/// SwiftUI state before they are committed to the PDF graph.
final class PendingFormTextState: @unchecked Sendable {
  private let lock = NSLock()
  private var fields = Set<String>()

  var hasChanges: Bool { lock.withLock { !fields.isEmpty } }

  func setPending(_ pending: Bool, for fieldName: String) {
    lock.withLock {
      if pending { fields.insert(fieldName) }
      else { fields.remove(fieldName) }
    }
  }
}

/// P24: form-field display state, pushed by the document after loading and
/// every committed edit so the sidebar follows the canonical field tree.
final class FormsModel: ObservableObject {
  @Published var fields: [FormField] = []
  /// P24-028: widgets not linked to any canonical field.
  @Published var orphanedWidgetCount = 0
  /// Text typed in the sidebar before Return must participate in Save/Quit.
  var pendingText: [String: String] = [:]
}
