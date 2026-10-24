import AppKit
import SwiftUI

/// PAG-02: ordered source list for the combine workflow. The document owns the
/// merge and verified write; this model only controls order and membership.
@MainActor
final class CombineDocumentsModel: ObservableObject {
  struct File: Identifiable, Equatable {
    let url: URL
    let pageCount: Int
    var id: String { url.path }
    var name: String { url.lastPathComponent }
  }

  @Published var files: [File]
  var onCombine: (([URL]) -> Void)?
  var onCancel: (() -> Void)?

  init(files: [File]) {
    self.files = files
  }

  var totalPages: Int { files.reduce(0) { $0 + $1.pageCount } }

  func moveUp(_ id: File.ID) {
    guard let index = files.firstIndex(where: { $0.id == id }), index > 0 else { return }
    files.swapAt(index, index - 1)
  }

  func moveDown(_ id: File.ID) {
    guard let index = files.firstIndex(where: { $0.id == id }), index + 1 < files.count
    else { return }
    files.swapAt(index, index + 1)
  }

  func remove(_ id: File.ID) {
    files.removeAll { $0.id == id }
  }
}

struct CombineDocumentsPanel: View {
  @ObservedObject var model: CombineDocumentsModel
  @State private var selection: CombineDocumentsModel.File.ID?

  private var summary: String {
    let fileWord = model.files.count == 1 ? "file" : "files"
    let pageWord = model.totalPages == 1 ? "page" : "pages"
    return "Files are combined top to bottom. "
      + "\(model.files.count) \(fileWord), \(model.totalPages) \(pageWord)."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Combine Documents").font(.headline)
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
      List(selection: $selection) {
        ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
          HStack {
            Text("\(index + 1).")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(file.pageCount == 1 ? "1 page" : "\(file.pageCount) pages")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(file.id)
        }
      }
      .frame(minHeight: 220)
      HStack {
        Button("Move Up") {
          if let selection { model.moveUp(selection) }
        }
        .disabled(selection == nil)
        Button("Move Down") {
          if let selection { model.moveDown(selection) }
        }
        .disabled(selection == nil)
        Button("Remove") {
          if let selection {
            model.remove(selection)
            self.selection = nil
          }
        }
        .disabled(selection == nil)
        Spacer()
        Button("Cancel") { model.onCancel?() }
        Button("Review…") {
          model.onCombine?(model.files.map(\.url))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.files.isEmpty)
      }
    }
    .padding(16)
    .frame(minWidth: 520, minHeight: 360)
    .accessibilityLabel("Combine documents")
  }
}
