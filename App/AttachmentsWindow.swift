import PDFEditing
import SwiftUI

/// PAG-09: attachment list state for the manager window.
@MainActor
final class AttachmentsModel: ObservableObject {
  @Published var attachments: [PDFAttachment] = []
}

/// PAG-09: a small Acrobat-style attachment manager. Adding, removing and
/// description edits go through the document's canonical undo stack.
struct AttachmentsManagerPanel: View {
  @ObservedObject var model: AttachmentsModel
  var canEditContent = true
  var editingRestrictionNotice: String?
  var onAdd: () -> Void
  var onEditDescription: (PDFAttachment) -> Void
  var onRemove: (PDFAttachment) -> Void
  var onExportAll: () -> Void
  var onClose: () -> Void

  @State private var selection: String?

  private var selectedAttachment: PDFAttachment? {
    guard let selection else { return nil }
    return model.attachments.first { $0.name == selection }
  }

  private var totalBytes: Int {
    model.attachments.reduce(0) { $0 + max(0, $1.size ?? 0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Attachments").font(.headline)
        Text(
          model.attachments.count == 1
            ? "1 file" : "\(model.attachments.count) files"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        if totalBytes > 0 {
          Text(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if model.attachments.isEmpty {
        WorkspacePanelEmptyState(
          title: "No attachments",
          symbol: "paperclip",
          detail: canEditContent
            ? "Add a file to embed it in this PDF."
            : "This document has no embedded files.")
          .frame(minHeight: 240)
      } else {
        List(selection: $selection) {
          ForEach(model.attachments, id: \.name) { attachment in
            AttachmentRow(attachment: attachment)
              .tag(attachment.name)
              .contextMenu {
                Button("Edit Description…") { onEditDescription(attachment) }
                  .disabled(!canEditContent)
                  .help(editingRestrictionNotice ?? "Edit the attachment description")
                Button("Remove Attachment", role: .destructive) { onRemove(attachment) }
                  .disabled(!canEditContent)
                  .help(editingRestrictionNotice ?? "Remove this attachment")
              }
          }
        }
        .listStyle(.inset)
        .frame(minHeight: 240)
      }
      Divider()
      HStack(spacing: 8) {
        Button("Add…", action: onAdd)
          .disabled(!canEditContent)
          .help(editingRestrictionNotice ?? "Embed a file in this PDF")
        Button("Edit Description…") {
          if let selectedAttachment { onEditDescription(selectedAttachment) }
        }
        .disabled(!canEditContent || selectedAttachment == nil)
        .help(editingRestrictionNotice ?? "Edit the selected attachment description")
        Button("Remove", role: .destructive) {
          if let selectedAttachment { onRemove(selectedAttachment) }
        }
        .disabled(!canEditContent || selectedAttachment == nil)
        .help(editingRestrictionNotice ?? "Remove the selected attachment")
        Spacer()
        Button("Export All…", action: onExportAll)
          .disabled(model.attachments.isEmpty)
        Button("Close", action: onClose)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(16)
    .frame(minWidth: 620, minHeight: 380)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Attachments")
  }
}

private struct AttachmentRow: View {
  let attachment: PDFAttachment

  private var displayName: String {
    attachment.fileName ?? attachment.name
  }

  private var detail: String {
    var parts: [String] = []
    if attachment.name != displayName { parts.append("Name: \(attachment.name)") }
    if let mime = attachment.mimeType, !mime.isEmpty { parts.append(mime) }
    if let description = attachment.description, !description.isEmpty {
      parts.append(description)
    } else {
      parts.append("No description")
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "paperclip")
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName).lineLimit(1).truncationMode(.middle)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      if let size = attachment.size {
        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(displayName), \(detail)")
  }
}
