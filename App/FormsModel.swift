import Combine
import PDFEditing

/// P24: form-field display state, pushed by the document after loading and
/// every committed edit so the sidebar follows the canonical field tree.
final class FormsModel: ObservableObject {
  @Published var fields: [FormField] = []
  /// P24-028: widgets not linked to any canonical field.
  @Published var orphanedWidgetCount = 0
}
