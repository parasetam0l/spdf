import MacServices
import PDFCore
import PDFEditing
import SwiftUI

/// P22-016: comment list with page, type, and status filtering. Selecting a
/// row navigates the viewer to the comment's page geometry (P22-017).
struct CommentsPanel: View {
  let comments: [Comment]
  let pageCount: Int
  var canEditContent = true
  var editingRestrictionNotice: String?
  var onSelect: (Comment) -> Void
  var onDelete: (Comment) -> Void
  var onReply: (Comment) -> Void
  var onSetStateComments: ([Comment], PDFName?) -> Void

  @State private var pageIndex: Int?
  @State private var subtype: PDFName?
  @State private var state: PDFName?
  @State private var author: String?
  @State private var query = ""
  @State private var dateFilter = DateFilter.any
  @State private var selection = Set<String>()

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

  private enum DateFilter: String, CaseIterable {
    case any
    case today
    case last7Days
    case last30Days

    var title: String {
      switch self {
      case .any: return "Any Date"
      case .today: return "Today"
      case .last7Days: return "Last 7 Days"
      case .last30Days: return "Last 30 Days"
      }
    }

    func bounds(now: Date = Date()) -> (after: Date?, before: Date?) {
      guard self != .any else { return (nil, nil) }
      var calendar = Calendar.current
      calendar.timeZone = .current
      let start = calendar.startOfDay(for: now)
      let end = calendar.date(byAdding: .day, value: 1, to: start)?
        .addingTimeInterval(-0.001)
      switch self {
      case .any: return (nil, nil)
      case .today: return (start, end)
      case .last7Days:
        return (calendar.date(byAdding: .day, value: -6, to: start), end)
      case .last30Days:
        return (calendar.date(byAdding: .day, value: -29, to: start), end)
      }
    }
  }

  /// Thread rows with their reply depth, so replies render indented.
  private var rows: [(id: String, comment: Comment, depth: Int)] {
    let bounds = dateFilter.bounds()
    let filter = CommentFilter(
      pageIndex: pageIndex, subtype: subtype, state: state, text: query, author: author,
      modifiedOnOrAfter: bounds.after, modifiedOnOrBefore: bounds.before)
    return CommentList.threads(comments, by: filter).flatMap { thread in
      [(rowID(thread.root), thread.root, 0)]
        + thread.replies.map { (rowID($0), $0, 1) }
    }
  }

  private var authors: [String] {
    Array(Set(comments.compactMap(\.author).filter { !$0.isEmpty })).sorted()
  }

  private var hasDatedComments: Bool {
    comments.contains { $0.annotation.modified != nil }
  }

  private var selectedComments: [Comment] {
    rows.filter { selection.contains($0.id) }.map(\.comment)
  }

  private func rowID(_ comment: Comment) -> String {
    if let objectID = comment.annotation.objectID {
      return "\(objectID.number)-\(objectID.generation)"
    }
    return "\(comment.pageIndex)-\(comment.annotation.index)"
  }

  private func statusTargets(for comment: Comment) -> [Comment] {
    let id = rowID(comment)
    if selection.contains(id), selectedComments.count > 1 { return selectedComments }
    return [comment]
  }

  private func parentComment(of comment: Comment) -> Comment? {
    guard let parentID = comment.replyTo else { return nil }
    return comments.first { $0.annotation.objectID == parentID }
  }

  var body: some View {
    VStack(spacing: 0) {
      if !comments.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(.secondary)
            TextField("Search comments", text: $query)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Search comments")
            if !query.isEmpty {
              Button {
                query = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear comment search")
            }
          }
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
          if !authors.isEmpty {
            filterMenu(title: author ?? "All Authors") {
              Button("All Authors") { author = nil }
              Divider()
              ForEach(authors, id: \.self) { name in
                Button(name) { author = name }
              }
            }
          }
          if hasDatedComments {
            filterMenu(title: dateFilter.title) {
              Button("Any Date") { dateFilter = .any }
              Divider()
              ForEach(DateFilter.allCases.filter { $0 != .any }, id: \.rawValue) { option in
                Button(option.title) { dateFilter = option }
              }
            }
          }
        }
        .padding(8)
        Divider()
      }
      if rows.isEmpty {
        WorkspacePanelEmptyState(
          title: comments.isEmpty ? "No comments" : "No matching comments",
          symbol: "text.bubble",
          detail: comments.isEmpty
            ? "Select text on the page, then choose Highlight or Add Note."
            : "Try another page, type, status, author, date, or search.")
      } else {
        if !selectedComments.isEmpty {
          HStack(spacing: 6) {
            Text("\(selectedComments.count) selected")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Menu("Set Status") {
              ForEach(Array(Self.statusOptions.enumerated()), id: \.offset) { _, name in
                Button(Self.stateLabel(for: name)) {
                  onSetStateComments(selectedComments, name)
                }
              }
              Divider()
              Button("Clear Status") { onSetStateComments(selectedComments, nil) }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .disabled(!canEditContent)
            .help(editingRestrictionNotice ?? "Set status for selected comments")
            Button {
              selection.removeAll()
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear comment selection")
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.quaternary.opacity(0.35))
          Divider()
        }
        List(selection: $selection) {
          ForEach(rows, id: \.id) { row in
            CommentRow(comment: row.comment, isReply: row.depth > 0)
              .tag(row.id)
              .contextMenu {
                if let parent = parentComment(of: row.comment) {
                  Button("Go to Parent Comment") { onSelect(parent) }
                  Divider()
                }
                Button("Reply…") { onReply(row.comment) }
                  .disabled(!canEditContent)
                  .help(editingRestrictionNotice ?? "Reply to this comment")
                Menu("Set Status") {
                  let targets = statusTargets(for: row.comment)
                  ForEach(Array(Self.statusOptions.enumerated()), id: \.offset) { _, name in
                    Button(Self.stateLabel(for: name)) {
                      onSetStateComments(targets, name)
                    }
                  }
                  Divider()
                  Button("Clear Status") { onSetStateComments(targets, nil) }
                }
                .disabled(!canEditContent)
                Divider()
                Button("Delete Comment", role: .destructive) { onDelete(row.comment) }
                  .disabled(!canEditContent)
                  .help(editingRestrictionNotice ?? "Delete this comment")
              }
          }
        }
        .listStyle(.inset)
        .onChange(of: selection) { oldValue, newValue in
          let added = newValue.subtracting(oldValue)
          guard let row = rows.first(where: { added.contains($0.id) }) else { return }
          onSelect(row.comment)
        }
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
