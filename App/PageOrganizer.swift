import AppKit
import PDFCore
import PDFEditing
import SwiftUI

/// P23-023: a native page organizer. Every action is one transaction, so a
/// multi-page delete or a move is a single compound undo step.
@MainActor
final class PageOrganizerModel: ObservableObject {
  @Published var pages: [PDFObjectID] = []
  @Published var selection: Set<PDFObjectID> = []
  @Published var message: String?

  var onApply: ((PDFTransaction) -> Void)?
  var onExtract: (([PDFObjectID]) -> Void)?

  func refresh(from document: SPDFDocument) {
    pages = document.editSession.pageIDs
    selection = selection.filter { pages.contains($0) }
  }

  func moveUp(_ pageID: PDFObjectID) {
    guard let index = pages.firstIndex(of: pageID), index > 0 else { return }
    apply([ReorderPagesCommand(pageID: pageID, toIndex: index - 1)])
  }

  func moveDown(_ pageID: PDFObjectID) {
    guard let index = pages.firstIndex(of: pageID), index < pages.count - 1 else { return }
    apply([ReorderPagesCommand(pageID: pageID, toIndex: index + 1)])
  }

  func duplicate(_ pageID: PDFObjectID) {
    apply([DuplicatePageCommand(pageID: pageID)])
  }

  func delete(_ pageIDs: Set<PDFObjectID>) {
    guard !pageIDs.isEmpty, pageIDs.count < pages.count else {
      message = "At least one page must remain."
      return
    }
    apply([DeletePagesCommand(pageIDs: Array(pageIDs))])
  }

  func extract(_ pageIDs: Set<PDFObjectID>) {
    guard !pageIDs.isEmpty else {
      message = "Select pages to extract."
      return
    }
    onExtract?(pages.filter { pageIDs.contains($0) })
  }

  private func apply(_ commands: [any PDFEditCommand]) {
    guard !commands.isEmpty else { return }
    onApply?(PDFTransaction(commands))
  }
}

struct PageOrganizerPanel: View {
  @ObservedObject var model: PageOrganizerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Pages").font(.headline)
      List(selection: $model.selection) {
        ForEach(Array(model.pages.enumerated()), id: \.element) { index, pageID in
          HStack {
            Text("Page \(index + 1)")
            Spacer()
            Text("obj \(pageID.number)").font(.caption).foregroundStyle(.secondary)
          }
          .tag(pageID)
        }
      }
      .frame(minHeight: 260)
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Button("Move Up") {
          if let page = model.selection.first { model.moveUp(page) }
        }
        Button("Move Down") {
          if let page = model.selection.first { model.moveDown(page) }
        }
        Button("Duplicate") {
          if let page = model.selection.first { model.duplicate(page) }
        }
        Button("Delete") { model.delete(model.selection) }
        Spacer()
        Button("Extract…") { model.extract(model.selection) }
        Button("Close") { NSApp.keyWindow?.close() }
      }
    }
    .padding(14)
    .frame(minWidth: 420, minHeight: 380)
  }
}
