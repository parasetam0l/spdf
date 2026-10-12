import MacServices
import PDFCore
import PDFEditing
import SwiftUI

/// P22-016: comment list with page, type, and status filtering. Selecting a
/// row navigates the viewer to the comment's page geometry (P22-017).
struct CommentsPanel: View {
  let comments: [Comment]
  let pageCount: Int
  var onSelect: (Comment) -> Void
  var onDelete: (Comment) -> Void
  var onReply: (Comment) -> Void
  var onSetState: (Comment, PDFName?) -> Void

  @State private var pageIndex: Int?
  @State private var subtype: PDFName?
  @State private var state: PDFName?

  private static let subtypes: [PDFName] = [
    PDFName("Highlight"), PDFName("Underline"), PDFName("StrikeOut"), PDFName("Squiggly"),
    PDFName("Text"), PDFName("Square"), PDFName("Circle"), PDFName("Line"), PDFName("Ink"),
    PDFName("Stamp"), PDFName("FileAttachment"),
  ]

  private static let states: [PDFName] = [
    PDFName("None"), PDFName("Accepted"), PDFName("Rejected"), PDFName("Completed"),
    PDFName("Cancelled"),
  ]

  private static let statusOptions: [PDFName] = [
    PDFName("Accepted"), PDFName("Rejected"), PDFName("Completed"), PDFName("Cancelled"),
  ]

  /// Thread rows with their reply depth, so replies render indented.
  private var rows: [(comment: Comment, depth: Int)] {
    let filter = CommentFilter(pageIndex: pageIndex, subtype: subtype, state: state)
    return CommentList.threads(comments, by: filter).flatMap { thread in
      [(thread.root, 0)] + thread.replies.map { ($0, 1) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        filterMenu(
          title: pageIndex == nil ? "All Pages" : "Page \((pageIndex ?? 0) + 1)"
        ) {
          Button("All Pages") { pageIndex = nil }
          Divider()
          ForEach(1...max(1, pageCount), id: \.self) { page in
            Button("Page \(page)") { pageIndex = page - 1 }
          }
        }
        filterMenu(
          title: subtype == nil ? "All Types" : CommentsPanel.label(for: subtype!)
        ) {
          Button("All Types") { subtype = nil }
          Divider()
          ForEach(Array(Self.subtypes.enumerated()), id: \.offset) { _, name in
            Button(Self.label(for: name)) { subtype = name }
          }
        }
        filterMenu(
          title: state == nil ? "All Statuses" : CommentsPanel.stateLabel(for: state!)
        ) {
          Button("All Statuses") { state = nil }
          Divider()
          ForEach(Array(Self.states.enumerated()), id: \.offset) { _, name in
            Button(Self.stateLabel(for: name)) { state = name }
          }
        }
      }
      .padding(8)
      Divider()
      if rows.isEmpty {
        ContentUnavailableView(
          "No Comments", systemImage: "text.bubble",
          description: Text("Select text and use the Annotate menu to add markup."))
      } else {
        List {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Button {
              onSelect(row.comment)
            } label: {
              CommentRow(comment: row.comment, isReply: row.depth > 0)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Reply…") { onReply(row.comment) }
              Menu("Set Status") {
                ForEach(Array(Self.statusOptions.enumerated()), id: \.offset) { _, name in
                  Button(Self.stateLabel(for: name)) { onSetState(row.comment, name) }
                }
                Divider()
                Button("Clear Status") { onSetState(row.comment, nil) }
              }
              Divider()
              Button("Delete Comment", role: .destructive) { onDelete(row.comment) }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Comments")
    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
  }

  private func filterMenu<Content: View>(
    title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    Menu {
      content()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
        Text(title)
        Image(systemName: "chevron.down").font(.caption2)
      }
      .foregroundStyle(.primary)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
  }

  static func label(for subtype: PDFName) -> String {
    switch subtype {
    case PDFName("Highlight"): return "Highlight"
    case PDFName("Underline"): return "Underline"
    case PDFName("StrikeOut"): return "Strikethrough"
    case PDFName("Text"): return "Note"
    case PDFName("Square"): return "Square"
    case PDFName("Circle"): return "Circle"
    case PDFName("Line"): return "Line"
    case PDFName("Ink"): return "Ink"
    case PDFName("Stamp"): return "Stamp"
    case PDFName("FileAttachment"): return "Attachment"
    case PDFName("Squiggly"): return "Squiggly"
    default: return String(decoding: subtype.bytes, as: UTF8.self)
    }
  }

  static func stateLabel(for state: PDFName) -> String {
    switch state {
    case PDFName("None"): return "None"
    default: return String(decoding: state.bytes, as: UTF8.self)
    }
  }

  static func icon(for subtype: PDFName?) -> String {
    guard let subtype else { return "text.bubble" }
    switch subtype {
    case PDFName("Highlight"): return "highlighter"
    case PDFName("Underline"): return "underline"
    case PDFName("StrikeOut"): return "strikethrough"
    case PDFName("Text"): return "note.text"
    case PDFName("Square"): return "square"
    case PDFName("Circle"): return "circle"
    case PDFName("Line"): return "line.diagonal"
    case PDFName("Ink"): return "scribble"
    case PDFName("Stamp"): return "seal"
    default: return "text.bubble"
    }
  }
}

private struct CommentRow: View {
  let comment: Comment
  var isReply = false

  private var summary: String {
    var parts = ["Page \(comment.pageIndex + 1)"]
    if let subtype = comment.subtype { parts.append(CommentsPanel.label(for: subtype)) }
    if comment.reviewState != PDFName("None") {
      parts.append(CommentsPanel.stateLabel(for: comment.reviewState))
    }
    if let author = comment.author, !author.isEmpty { parts.append(author) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(
        systemName: isReply
          ? "arrow.turn.down.right" : CommentsPanel.icon(for: comment.subtype)
      )
      .foregroundStyle(.secondary)
      .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(summary)
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        if let contents = comment.contents, !contents.isEmpty {
          Text(contents).lineLimit(2)
        } else {
          Text("No text").italic().foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, isReply ? 14 : 0)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}
