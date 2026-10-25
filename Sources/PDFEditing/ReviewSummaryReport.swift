import Foundation
import PDFCore

// MARK: - REV-04 review summary report

/// One rendered page image supplied for the review summary's page context.
public struct ReviewSummaryPageImage: Sendable, Equatable {
  public let pageIndex: Int
  public let image: ReportRasterImage

  public init(pageIndex: Int, image: ReportRasterImage) {
    self.pageIndex = pageIndex
    self.image = image
  }
}

/// What the printable review summary includes. Filters reuse the comment
/// sidebar's CommentFilter; the report records the chosen filters and options
/// so a reader knows exactly which review state it represents.
public struct ReviewSummaryOptions: Sendable, Equatable {
  public var title: String
  public var subtitle: String?
  /// For example the source file name.
  public var sourceDescription: String?
  /// The document session revision the report was built from, when known.
  public var documentRevision: UInt64?
  /// Human-readable generation time supplied by the caller; nil keeps the
  /// report bytes deterministic.
  public var generatedOn: String?
  public var filter: CommentFilter
  /// Restrict the report to these zero-based page indices.
  public var pageIndices: Set<Int>?
  public var includeReplyThreads: Bool
  public var includePageImages: Bool
  public var format: ReportPageFormat

  public init(
    title: String = "Review Summary",
    subtitle: String? = nil,
    sourceDescription: String? = nil,
    documentRevision: UInt64? = nil,
    generatedOn: String? = nil,
    filter: CommentFilter = CommentFilter(),
    pageIndices: Set<Int>? = nil,
    includeReplyThreads: Bool = true,
    includePageImages: Bool = true,
    format: ReportPageFormat = .letter
  ) {
    self.title = title
    self.subtitle = subtitle
    self.sourceDescription = sourceDescription
    self.documentRevision = documentRevision
    self.generatedOn = generatedOn
    self.filter = filter
    self.pageIndices = pageIndices
    self.includeReplyThreads = includeReplyThreads
    self.includePageImages = includePageImages
    self.format = format
  }
}

/// One reply listed under its thread root.
public struct ReviewSummaryReply: Sendable, Equatable, Identifiable {
  public var id: String { identity }
  public let identity: String
  public let replyToIdentity: String?
  public let pageIndex: Int
  public let author: String?
  public let modified: String?
  public let state: String
  public let contents: String
  public let bounds: [Double]?

  public init(
    identity: String, replyToIdentity: String?, pageIndex: Int, author: String?,
    modified: String?, state: String, contents: String, bounds: [Double]?
  ) {
    self.identity = identity
    self.replyToIdentity = replyToIdentity
    self.pageIndex = pageIndex
    self.author = author
    self.modified = modified
    self.state = state
    self.contents = contents
    self.bounds = bounds
  }
}

/// One anchor-numbered review comment in the report.
public struct ReviewSummaryEntry: Sendable, Equatable, Identifiable {
  public var id: Int { anchor }
  public let anchor: Int
  public let identity: String
  public let replyToIdentity: String?
  public let pageIndex: Int
  public let pageLabel: String
  public let subtype: String
  public let state: String
  public let author: String?
  public let modified: String?
  public let subject: String?
  public let contents: String
  public let bounds: [Double]?
  public let replies: [ReviewSummaryReply]

  public init(
    anchor: Int, identity: String, replyToIdentity: String?, pageIndex: Int,
    pageLabel: String, subtype: String, state: String, author: String?,
    modified: String?, subject: String?, contents: String, bounds: [Double]?,
    replies: [ReviewSummaryReply]
  ) {
    self.anchor = anchor
    self.identity = identity
    self.replyToIdentity = replyToIdentity
    self.pageIndex = pageIndex
    self.pageLabel = pageLabel
    self.subtype = subtype
    self.state = state
    self.author = author
    self.modified = modified
    self.subject = subject
    self.contents = contents
    self.bounds = bounds
    self.replies = replies
  }
}

/// The generated review summary plus its manifest. The manifest lets the app
/// and tests check filter behaviour without re-parsing the PDF; the report PDF
/// itself remains the portable deliverable.
public struct ReviewSummaryReport: Sendable, Equatable {
  public let data: Data
  public let pageCount: Int
  public let entries: [ReviewSummaryEntry]
  public let pagesWithComments: [Int]
  public let pagesWithImages: [Int]
  public let totalDocumentComments: Int
  public let includedCommentCount: Int
  public let includedReplyCount: Int
  public let filterDescription: String
  public let optionsDescription: [String]

  public var isEmpty: Bool { entries.isEmpty }

  public var summary: String {
    if entries.isEmpty {
      return "Review summary PDF: no comments match the current filters (\(pageCount) page(s))."
    }
    return
      "Review summary PDF: \(includedCommentCount) comment(s) and \(includedReplyCount) reply(ies) "
      + "on \(pagesWithComments.count) page(s); \(pageCount) report page(s)."
  }
}

public enum ReviewSummaryReportBuilder {
  public static let maximumIncludedComments = 400
  public static let maximumTextLength = 4_000

  /// Build the printable review summary without mutating the source graph.
  public static func build(
    graph: PDFGraph, pageIDs: [PDFObjectID],
    pageImages: [ReviewSummaryPageImage] = [],
    options: ReviewSummaryOptions = ReviewSummaryOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> ReviewSummaryReport {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "The document has no pages to summarize")
    }
    let attributes = try PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    guard attributes.count == pageIDs.count else {
      throw PDFError(.malformed, "The page inventory does not match the page list")
    }
    let allComments = CommentList.comments(in: graph, pageIDs: pageIDs)
    let identityByObjectID: [PDFObjectID: String] = Dictionary(
      uniqueKeysWithValues: allComments.compactMap { comment -> (PDFObjectID, String)? in
        guard let objectID = comment.annotation.objectID else { return nil }
        return (objectID, CommentExchange.identity(for: comment))
      })
    func identity(for comment: Comment) -> String {
      CommentExchange.identity(for: comment)
    }
    func parentIdentity(for comment: Comment) -> String? {
      guard let parent = comment.annotation.replyTo else { return nil }
      return identityByObjectID[parent] ?? "spdf-\(parent.number)"
    }

    var pageFiltered = allComments
    if let pageIndices = options.pageIndices {
      pageFiltered = pageFiltered.filter { pageIndices.contains($0.pageIndex) }
    }
    let filtered = CommentList.filter(pageFiltered, by: options.filter)
    let includedObjectIDs = Set(filtered.compactMap(\.annotation.objectID))

    var roots: [Comment] = []
    var repliesByRoot: [PDFObjectID: [Comment]] = [:]
    var orphanReplies: [Comment] = []
    for comment in filtered {
      guard options.includeReplyThreads, let parent = comment.annotation.replyTo else {
        roots.append(comment)
        continue
      }
      if includedObjectIDs.contains(parent) {
        repliesByRoot[parent, default: []].append(comment)
      } else {
        orphanReplies.append(comment)
      }
    }
    roots.append(contentsOf: orphanReplies)
    guard filtered.count <= maximumIncludedComments else {
      throw PDFError(
        .limitExceeded,
        "This report would include \(filtered.count) comments; the profile supports up to \(maximumIncludedComments)")
    }

    var entries: [ReviewSummaryEntry] = []
    var anchor = 0
    for root in roots {
      anchor += 1
      let rootReplies: [Comment] = root.annotation.objectID.flatMap { repliesByRoot[$0] } ?? []
      let replyEntries = rootReplies.map { reply in
        ReviewSummaryReply(
          identity: identity(for: reply),
          replyToIdentity: parentIdentity(for: reply),
          pageIndex: reply.pageIndex,
          author: reply.author,
          modified: reply.annotation.modified,
          state: name(reply.reviewState),
          contents: clipText(reply.contents ?? ""),
          bounds: reply.bounds)
      }
      entries.append(
        ReviewSummaryEntry(
          anchor: anchor,
          identity: identity(for: root),
          replyToIdentity: parentIdentity(for: root),
          pageIndex: root.pageIndex,
          pageLabel: PDFPageLabels.label(forPageIndex: root.pageIndex, in: graph),
          subtype: name(root.subtype ?? PDFName("Annot")),
          state: name(root.reviewState),
          author: root.author,
          modified: root.annotation.modified,
          subject: root.subject,
          contents: clipText(root.contents ?? ""),
          bounds: root.bounds,
          replies: replyEntries))
    }

    let filterDescription = describe(
      filter: options.filter, pageIndices: options.pageIndices)
    let imageByPage: [Int: ReportRasterImage] = Dictionary(
      uniqueKeysWithValues: pageImages.map { ($0.pageIndex, $0.image) })
    for image in pageImages where !image.image.isValid {
      throw PDFError(.malformed, "A supplied review page image has invalid dimensions or samples")
    }
    var pagesWithImages: [Int] = []
    var composer = ReportComposer(
      format: options.format, title: options.title,
      subject: "Review summary")
    try composer.titleBlock(
      options.title,
      subtitles: [
        options.subtitle ?? "Comments, page context and reply threads",
        options.sourceDescription.map { "Document: \($0)" }
          ?? "Document: open session",
      ])
    var provenance: [String] = []
    if let revision = options.documentRevision {
      provenance.append("Document revision: \(revision)")
    }
    if let generatedOn = options.generatedOn, !generatedOn.isEmpty {
      provenance.append("Generated: \(generatedOn)")
    }
    for line in provenance {
      try composer.paragraph(line, size: ReportComposer.Typography.smallSize)
    }
    try composer.divider()
    try composer.paragraph("Summary", size: ReportComposer.Typography.subheadingSize, bold: true)
    try composer.paragraph("Comments in document: \(allComments.count)")
    try composer.paragraph(
      "Included in this report: \(roots.count) anchor(s) and "
        + "\(entries.reduce(0) { $0 + $1.replies.count }) reply(ies).")
    try composer.paragraph("Filters: \(filterDescription)")
    try composer.paragraph(
      "Reply threads: \(options.includeReplyThreads ? "shown under their root comment" : "not grouped (each comment listed on its own)").")
    let suppliedImages = pagesWithImageCount(entries: entries, imageByPage: imageByPage)
    try composer.paragraph(
      "Page context images: "
        + (options.includePageImages
          ? (suppliedImages > 0
            ? "\(suppliedImages) rendered page image(s) supplied"
            : "none supplied; page outlines with anchors are shown")
          : "disabled"))
    try composer.paragraph(
      "Character policy: printable text uses the standard-14 WinAnsi profile. Characters outside "
        + "that profile are shown as '?' together with the exact UTF-8 bytes as a hex appendix.")
    if entries.isEmpty {
      try composer.paragraph(
        "No review comments match the current filters. This report still records the chosen filters "
          + "and the document it was generated from.")
    } else {
      try composer.heading("Included comment index")
      for entry in entries {
        try composer.paragraph(
          "Anchor \(entry.anchor) | \(entry.identity) | page \(entry.pageLabel) | "
            + "\(entry.subtype) | \(entry.state)"
            + (entry.author.map { " | \($0)" } ?? ""),
          size: ReportComposer.Typography.smallSize, spacingAfter: 1)
      }
      // Page context sections with numbered anchors.
      var pagesInOrder: [Int] = []
      for entry in entries where !pagesInOrder.contains(entry.pageIndex) {
        pagesInOrder.append(entry.pageIndex)
      }
      if !pagesInOrder.isEmpty {
        try composer.heading("Page context")
        for pageIndex in pagesInOrder {
          guard pageIndex >= 0, pageIndex < attributes.count else { continue }
          let pageEntries = entries.filter { $0.pageIndex == pageIndex }
          let attribute = attributes[pageIndex]
          let pageLabel = PDFPageLabels.label(forPageIndex: pageIndex, in: graph)
          let anchors = pageEntries.compactMap { entry -> ReportComposer.Anchor? in
            guard let bounds = entry.bounds else { return nil }
            return ReportComposer.Anchor(label: String(entry.anchor), contentRect: bounds)
          }
          var raster: ReportRasterImage?
          if options.includePageImages, let supplied = imageByPage[pageIndex],
            supplied.isValid
          {
            raster = supplied
            pagesWithImages.append(pageIndex)
          }
          let legend = pageEntries.map { entry in
            "Anchor \(entry.anchor) | \(entry.identity) | \(entry.subtype) | "
              + "\(entry.state)" + (entry.author.map { " | \($0)" } ?? "")
              + (entry.bounds == nil ? " | no geometry" : "")
          }
          // Keep the section heading with at least the page image/schematic so
          // a printable report never leaves a heading alone at a page bottom.
          composer.ensureSpace(raster != nil ? 360 : 170)
          try composer.pageContext(
            heading: "Page \(ReportText.display(pageLabel)) (index \(pageIndex + 1))"
              + " | \(pageEntries.count) anchor(s)",
            displayBox: attribute.displayBox, rotation: attribute.rotation,
            raster: raster, anchors: anchors, legend: legend)
        }
      }
      // Flowing comment details with reply threads.
      try composer.heading("Comment details")
      for entry in entries {
        try commentDetail(entry, composer: &composer)
      }
      try composer.divider()
      try composer.paragraph(
        "Every included annotation is identified by its stable comment identity above; anchor "
          + "numbers match the numbered markers in the page-context section.",
        size: ReportComposer.Typography.smallSize)
    }
    try composer.paragraph(
      "Generated locally by sPDF Editor. No document content left this machine.",
      size: ReportComposer.Typography.smallSize)
    if composer.pageCount > 250 {
      throw PDFError(
        .limitExceeded, "The review summary would exceed the 250-page report limit")
    }
    let data = try composer.finish(limits: limits)
    let report = ReviewSummaryReport(
      data: data,
      pageCount: composer.pageCount,
      entries: entries,
      pagesWithComments: orderedUnique(entries.flatMap { [$0.pageIndex] + $0.replies.map(\.pageIndex) }),
      pagesWithImages: orderedUnique(pagesWithImages),
      totalDocumentComments: allComments.count,
      includedCommentCount: filtered.count,
      includedReplyCount: entries.reduce(0) { $0 + $1.replies.count },
      filterDescription: filterDescription,
      optionsDescription: [
        "replyThreads=\(options.includeReplyThreads)",
        "pageImages=\(options.includePageImages)",
        "format=\(options.format.rawValue)",
      ])
    return report
  }

  // MARK: Details

  private static func commentDetail(
    _ entry: ReviewSummaryEntry, composer: inout ReportComposer
  ) throws {
    try composer.paragraph(
      "Anchor \(entry.anchor) | \(entry.identity)",
      size: 10.5, bold: true, spacingAfter: 1)
    var meta = "Page \(entry.pageLabel) | \(entry.subtype) | \(entry.state)"
    if let author = entry.author, !author.isEmpty { meta += " | Author: \(author)" }
    if let modified = entry.modified, !modified.isEmpty { meta += " | Modified: \(modified)" }
    if let bounds = entry.bounds {
      meta += " | Bounds: " + bounds.map { formatNumber($0) }.joined(separator: ", ")
    }
    try composer.paragraph(
      meta, size: ReportComposer.Typography.smallSize, indent: 10, spacingAfter: 1)
    if let replyTo = entry.replyToIdentity {
      try composer.paragraph(
        "Reply to \(replyTo); the parent comment is not included in this filtered report.",
        size: ReportComposer.Typography.smallSize, indent: 10, spacingAfter: 1)
    }
    if let subject = entry.subject, !subject.isEmpty {
      try composer.paragraph(
        "Subject: \(ReportText.display(subject))",
        size: ReportComposer.Typography.smallSize, indent: 10, spacingAfter: 1)
    }
    if entry.contents.isEmpty {
      try composer.paragraph(
        "(no text)", size: ReportComposer.Typography.smallSize, indent: 10)
    } else {
      try composer.paragraph(
        ReportText.display(entry.contents),
        size: ReportComposer.Typography.bodySize, indent: 10, spacingAfter: 1)
      if let hex = ReportText.exactHexIfNeeded(entry.contents) {
        try composer.paragraph(
          "Exact UTF-8: \(hex)", size: ReportComposer.Typography.tinySize, indent: 10,
          color: [0.25, 0.25, 0.28], spacingAfter: 1)
      }
    }
    for reply in entry.replies {
      try composer.paragraph(
        "Reply | \(reply.identity)"
          + (reply.author.map { " | Author: \($0)" } ?? "")
          + " | \(reply.state)"
          + (reply.modified.map { " | Modified: \($0)" } ?? "")
          + " | page \(reply.pageIndex + 1)",
        size: ReportComposer.Typography.smallSize, bold: false, indent: 22, spacingAfter: 1)
      if reply.contents.isEmpty {
        try composer.paragraph(
          "(no text)", size: ReportComposer.Typography.smallSize, indent: 32)
      } else {
        try composer.paragraph(
          ReportText.display(reply.contents),
          size: ReportComposer.Typography.smallSize, indent: 32, spacingAfter: 1)
        if let hex = ReportText.exactHexIfNeeded(reply.contents) {
          try composer.paragraph(
            "Exact UTF-8: \(hex)", size: ReportComposer.Typography.tinySize, indent: 32,
            color: [0.25, 0.25, 0.28], spacingAfter: 1)
        }
      }
    }
    try composer.spacer(8)
  }

  // MARK: Helpers

  static func name(_ name: PDFName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
  }

  static func clipText(_ text: String) -> String {
    ReportText.clipped(ReportText.normalized(text), maximum: maximumTextLength).text
  }

  static func formatNumber(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    return String(rounded)
  }

  static func orderedUnique(_ values: [Int]) -> [Int] {
    var seen = Set<Int>()
    var result: [Int] = []
    for value in values where seen.insert(value).inserted {
      result.append(value)
    }
    return result
  }

  static func pagesWithImageCount(
    entries: [ReviewSummaryEntry], imageByPage: [Int: ReportRasterImage]
  ) -> Int {
    var pages = Set<Int>()
    for entry in entries where imageByPage[entry.pageIndex] != nil {
      pages.insert(entry.pageIndex)
    }
    return pages.count
  }

  /// Human-readable filter description printed in the report and recorded in
  /// the manifest.
  public static func describe(filter: CommentFilter, pageIndices: Set<Int>?) -> String {
    var parts: [String] = []
    if let pageIndices, !pageIndices.isEmpty {
      parts.append(
        "pages " + pageIndices.sorted().map { String($0 + 1) }.joined(separator: ", "))
    } else {
      parts.append("all pages")
    }
    if let page = filter.pageIndex { parts.append("single page \(page + 1)") }
    if let subtype = filter.subtype { parts.append("type \(name(subtype))") }
    if let state = filter.state { parts.append("state \(name(state))") }
    if let text = filter.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
      parts.append("text \"\(text)\"")
    }
    if let author = filter.author, !author.trimmingCharacters(in: .whitespaces).isEmpty {
      parts.append("author \"\(author)\"")
    }
    if filter.modifiedOnOrAfter != nil || filter.modifiedOnOrBefore != nil {
      var range = "modified"
      if let after = filter.modifiedOnOrAfter {
        range += " on/after \(formatDate(after))"
      }
      if let before = filter.modifiedOnOrBefore {
        range += " on/before \(formatDate(before))"
      }
      parts.append(range)
    }
    return parts.joined(separator: "; ")
  }

  static func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
