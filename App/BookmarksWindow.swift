import PDFCore
import PDFEditing
import SwiftUI

/// PAG-09: one flattened bookmark row for the manager window.
struct BookmarkManagerEntry: Identifiable, Equatable {
  let id: PDFObjectID
  let title: String
  let pageIndex: Int?
  let depth: Int
  let previousID: PDFObjectID?
  let nextID: PDFObjectID?
  let parentID: PDFObjectID?
}

@MainActor
final class BookmarksModel: ObservableObject {
  @Published var entries: [BookmarkManagerEntry] = []
}

/// PAG-09: list and hierarchy controls for the document outline. Every
/// mutation is an undoable core command.
struct BookmarksManagerPanel: View {
  @ObservedObject var model: BookmarksModel
  var canEditContent = true
  var editingRestrictionNotice: String?
  var onAdd: () -> Void
  var onEdit: (BookmarkManagerEntry) -> Void
  var onMove: (BookmarkManagerEntry, BookmarkMoveDirection) -> Void
  var onNest: (BookmarkManagerEntry) -> Void
  var onOutdent: (BookmarkManagerEntry) -> Void
  var onRemove: (BookmarkManagerEntry) -> Void
  var onSelect: (BookmarkManagerEntry) -> Void
  var onClose: () -> Void

  @State private var selection: PDFObjectID?

  private var selectedEntry: BookmarkManagerEntry? {
    guard let selection else { return nil }
    return model.entries.first { $0.id == selection }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Bookmarks").font(.headline)
        Text(
          model.entries.count == 1 ? "1 entry" : "\(model.entries.count) entries"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Text("Nest under the previous sibling; outdent one level.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if model.entries.isEmpty {
        WorkspacePanelEmptyState(
          title: "No bookmarks",
          symbol: "list.bullet.indent",
          detail: canEditContent
            ? "Add a bookmark for the current page."
            : "This document has no outline.")
          .frame(minHeight: 240)
      } else {
        List(selection: $selection) {
          ForEach(model.entries) { entry in
            HStack(spacing: 6) {
              Image(systemName: entry.depth == 0 ? "bookmark" : "arrow.turn.down.right")
                .foregroundStyle(.secondary)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let pageIndex = entry.pageIndex {
                  Text("Page \(pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(entry.depth) * 14)
            .contentShape(Rectangle())
            .tag(entry.id)
            .contextMenu {
              Button("Edit…") { onEdit(entry) }
                .disabled(!canEditContent)
              Divider()
              Button("Move Up") { onMove(entry, .up) }
                .disabled(!canEditContent || entry.previousID == nil)
              Button("Move Down") { onMove(entry, .down) }
                .disabled(!canEditContent || entry.nextID == nil)
              Button("Nest Under Previous") { onNest(entry) }
                .disabled(!canEditContent || entry.previousID == nil)
              Button("Outdent") { onOutdent(entry) }
                .disabled(!canEditContent || entry.parentID == nil)
              Divider()
              Button("Remove", role: .destructive) { onRemove(entry) }
                .disabled(!canEditContent)
            }
          }
        }
        .listStyle(.inset)
        .frame(minHeight: 250)
        .onChange(of: selection) { _, value in
          guard let value, let entry = model.entries.first(where: { $0.id == value })
          else { return }
          onSelect(entry)
        }
      }
      Divider()
      HStack(spacing: 8) {
        Button("Add…", action: onAdd)
          .disabled(!canEditContent)
          .help(editingRestrictionNotice ?? "Add a bookmark for the current page")
        Button("Edit…") {
          if let selectedEntry { onEdit(selectedEntry) }
        }
        .disabled(!canEditContent || selectedEntry == nil)
        Button("Move Up") {
          if let selectedEntry { onMove(selectedEntry, .up) }
        }
        .disabled(!canEditContent || selectedEntry?.previousID == nil)
        Button("Move Down") {
          if let selectedEntry { onMove(selectedEntry, .down) }
        }
        .disabled(!canEditContent || selectedEntry?.nextID == nil)
        Menu("Hierarchy") {
          Button("Nest Under Previous") {
            if let selectedEntry { onNest(selectedEntry) }
          }
          .disabled(selectedEntry?.previousID == nil)
          Button("Outdent") {
            if let selectedEntry { onOutdent(selectedEntry) }
          }
          .disabled(selectedEntry?.parentID == nil)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .disabled(!canEditContent || selectedEntry == nil)
        Button("Remove", role: .destructive) {
          if let selectedEntry { onRemove(selectedEntry) }
        }
        .disabled(!canEditContent || selectedEntry == nil)
        Spacer()
        Button("Close", action: onClose)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(16)
    .frame(minWidth: 620, minHeight: 400)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bookmarks")
  }
}
