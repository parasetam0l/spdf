import Foundation
import PDFCore

/// P22-016: one review entry in the comment list, tied to its page position
/// and the raw annotation it came from.
public struct Comment: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let annotation: Annotation

  public init(pageID: PDFObjectID, pageIndex: Int, annotation: Annotation) {
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.annotation = annotation
  }

  public var subtype: PDFName? { annotation.subtype }
  public var contents: String? { annotation.contents }
  public var author: String? { annotation.author }
  public var subject: String? { annotation.subject }
  public var bounds: [Double]? { annotation.bounds }

  /// P22-014: /IRT parent object, when this comment is a reply.
  public var replyTo: PDFObjectID? { annotation.replyTo }

  /// P22-015 read side: /State with the conventional "None" default.
  public var reviewState: PDFName { annotation.state ?? PDFName("None") }
}

/// P22-014: one comment thread: a root comment plus its replies in order.
public struct CommentThread: Sendable, Equatable {
  public let root: Comment
  public let replies: [Comment]

  public init(root: Comment, replies: [Comment]) {
    self.root = root
    self.replies = replies
  }
}

/// P22-016: page, type, and status filters for the comment list. A nil field
/// matches everything.
public struct CommentFilter: Sendable, Equatable {
  public var pageIndex: Int?
  public var subtype: PDFName?
  public var state: PDFName?
  /// Case-insensitive text match across contents, author, and subject.
  public var text: String?
  /// Exact, case-insensitive author match.
  public var author: String?

  public init(
    pageIndex: Int? = nil, subtype: PDFName? = nil, state: PDFName? = nil,
    text: String? = nil, author: String? = nil
  ) {
    self.pageIndex = pageIndex
    self.subtype = subtype
    self.state = state
    self.text = text
    self.author = author
  }
}

/// P22-016: enumerate a document's comments in page order and filter them.
/// Link and widget annotations are interactive controls, not review comments,
/// so they are skipped; every other annotation type is listed and can be
/// filtered by type.
public enum CommentList {
  public static let nonCommentSubtypes: Set<PDFName> = [
    PDFName("Link"), PDFName("Widget"), PDFName("Popup"),
  ]

  public static func comments(
    in graph: PDFGraph, pageIDs: [PDFObjectID], filter: CommentFilter = CommentFilter()
  ) -> [Comment] {
    var comments: [Comment] = []
    for (index, pageID) in pageIDs.enumerated() {
      if let wanted = filter.pageIndex, wanted != index { continue }
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations {
        if let subtype = annotation.subtype, nonCommentSubtypes.contains(subtype) { continue }
        comments.append(Comment(pageID: pageID, pageIndex: index, annotation: annotation))
      }
    }
    return Self.filter(comments, by: filter)
  }

  /// In-memory filtering for an already-listed set, used by the comment panel.
  public static func filter(_ comments: [Comment], by filter: CommentFilter) -> [Comment] {
    let query = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let author = filter.author?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return comments.filter { comment in
      if let pageIndex = filter.pageIndex, comment.pageIndex != pageIndex { return false }
      if let subtype = filter.subtype, comment.subtype != subtype { return false }
      if let state = filter.state, comment.reviewState != state { return false }
      if let author, !author.isEmpty {
        guard (comment.author ?? "").lowercased() == author else { return false }
      }
      if let query, !query.isEmpty {
        let searchable = [comment.contents, comment.author, comment.subject]
          .compactMap { $0 }
          .joined(separator: "\n")
          .lowercased()
        guard searchable.contains(query) else { return false }
      }
      return true
    }
  }

  /// P22-014: group comments into threads. Replies attach to their /IRT
  /// parent when it is present in the filtered set; otherwise they appear as
  /// roots so a filter can never hide a comment entirely.
  public static func threads(
    _ comments: [Comment], by filter: CommentFilter = CommentFilter()
  ) -> [CommentThread] {
    let filtered = Self.filter(comments, by: filter)
    let objectIDs = Set(filtered.compactMap(\.annotation.objectID))
    var roots: [Comment] = []
    var repliesByParent: [PDFObjectID: [Comment]] = [:]
    for comment in filtered {
      if let parent = comment.replyTo, objectIDs.contains(parent) {
        repliesByParent[parent, default: []].append(comment)
      } else {
        roots.append(comment)
      }
    }
    return roots.map { root in
      CommentThread(
        root: root,
        replies: root.annotation.objectID.flatMap { repliesByParent[$0] } ?? [])
    }
  }

  public static func threads(
    in graph: PDFGraph, pageIDs: [PDFObjectID], filter: CommentFilter = CommentFilter()
  ) -> [CommentThread] {
    threads(comments(in: graph, pageIDs: pageIDs, filter: filter), by: CommentFilter())
  }
}

/// P22-021: stable, local, human-readable review summary of a comment list.
/// Nothing is uploaded anywhere; the caller writes the text to a local file.
public enum CommentSummary {
  public static func text(comments: [Comment]) -> String {
    var lines = ["sPDF Editor review summary", "Comments: \(comments.count)", ""]
    for comment in comments {
      let type = comment.subtype.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "Annotation"
      let state = String(decoding: comment.reviewState.bytes, as: UTF8.self)
      var header = "Page \(comment.pageIndex + 1) · \(type) · \(state)"
      if let author = comment.author, !author.isEmpty { header += " · \(author)" }
      if let modified = comment.annotation.modified, !modified.isEmpty { header += " · \(modified)" }
      lines.append(header)
      let contents = (comment.contents ?? "").replacingOccurrences(of: "\n", with: " ")
      lines.append("  \(contents.isEmpty ? "(no text)" : contents)")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }
}
