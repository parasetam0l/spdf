import Combine
import PDFEditing

/// P12-012 annotation tools the app can create from a text selection.
enum AnnotationKind: String, CaseIterable, Sendable {
  case highlight
  case underline
  case strikeout
  case note
}

/// P22-016: comment-list display state, pushed by the document after loading,
/// editing, and undo/redo so the sidebar follows the committed graph.
final class CommentsModel: ObservableObject {
  @Published var comments: [Comment] = []
}
