import Foundation
import PDFCore

/// PAG-07: settings for one Bates-numbering batch over ordered input files.
public struct BatesBatchSettings: Sendable, Equatable {
  /// Text placed before the sequence number.
  public var prefix: String
  /// Text placed after the sequence number.
  public var suffix: String
  public var startNumber: Int
  /// Minimum number width; a wider number is kept rather than cut.
  public var digits: Int
  public var style: AddedTextStyle
  public var placement: RepeatedMarkPlacement
  public var margin: Double
  /// PAG-07: continue one sequence across the ordered files (true), or restart
  /// at `startNumber` for every file (false).
  public var continuesAcrossFiles: Bool
  /// 1-based pages excluded from every file.
  public var excludedPages: [Int]
  /// Leading pages excluded from every file (for example front matter).
  public var leadingExcludedPages: Int

  public init(
    prefix: String = "", suffix: String = "", startNumber: Int = 1, digits: Int = 6,
    style: AddedTextStyle = AddedTextStyle(size: 9, alignment: .center),
    placement: RepeatedMarkPlacement = .bottomCenter, margin: Double = 36,
    continuesAcrossFiles: Bool = true, excludedPages: [Int] = [],
    leadingExcludedPages: Int = 0
  ) {
    self.prefix = prefix
    self.suffix = suffix
    self.startNumber = startNumber
    self.digits = digits
    self.style = style
    self.placement = placement
    self.margin = margin
    self.continuesAcrossFiles = continuesAcrossFiles
    self.excludedPages = excludedPages
    self.leadingExcludedPages = leadingExcludedPages
  }

  /// PAG-07: the sequence format in one human-readable phrase.
  public var formatDescription: String {
    let sample = RepeatedMark.batesText(
      prefix: prefix, suffix: suffix, number: startNumber, digits: digits)
    return "\(sample) (starts at \(startNumber), \(digits) digits, "
      + "\(continuesAcrossFiles ? "continues across files" : "restarts per file"))"
  }
}

/// PAG-07: one ordered input file for a Bates batch.
public struct BatesBatchFile: Sendable, Equatable {
  public let name: String
  public let pageCount: Int
  /// Extra 1-based pages excluded only in this file.
  public let excludedPages: [Int]

  public init(name: String, pageCount: Int, excludedPages: [Int] = []) {
    self.name = name
    self.pageCount = pageCount
    self.excludedPages = excludedPages
  }
}

/// PAG-07: the computed sequence for an ordered list of files. The plan is pure
/// data: the same plan drives the marks, the mapping report and verification.
public struct BatesBatchPlan: Sendable, Equatable {
  public struct PageAssignment: Sendable, Equatable {
    /// 1-based page number inside the source file.
    public let pageIndex: Int
    public let number: Int
    public let text: String

    public init(pageIndex: Int, number: Int, text: String) {
      self.pageIndex = pageIndex
      self.number = number
      self.text = text
    }
  }

  public struct FileAssignment: Sendable, Equatable {
    public let order: Int
    public let name: String
    public let pageCount: Int
    /// 1-based pages without a mark, sorted.
    public let excludedPages: [Int]
    /// Included pages in page order with their assigned numbers.
    public let pages: [PageAssignment]
    /// The mark used for this file (nil when every page is excluded).
    public let mark: RepeatedMark?
    public let placement: RepeatedMarkPlacement
    public let margin: Double

    public init(
      order: Int, name: String, pageCount: Int, excludedPages: [Int],
      pages: [PageAssignment], mark: RepeatedMark?,
      placement: RepeatedMarkPlacement, margin: Double
    ) {
      self.order = order
      self.name = name
      self.pageCount = pageCount
      self.excludedPages = excludedPages
      self.pages = pages
      self.mark = mark
      self.placement = placement
      self.margin = margin
    }

    public var numberedPages: [Int] { pages.map(\.pageIndex) }
    public var firstNumber: Int? { pages.first?.number }
    public var lastNumber: Int? { pages.last?.number }
    public var firstPage: Int? { pages.first?.pageIndex }
    public var lastPage: Int? { pages.last?.pageIndex }

    /// PAG-07: the command that paints the planned numbers on one parsed file.
    public func command(pageIDs: [PDFObjectID], groupID: String) -> AddRepeatedMarkCommand? {
      guard let mark, !pages.isEmpty, pageIDs.count == pageCount else { return nil }
      let selected = pages.map { pageIDs[$0.pageIndex - 1] }
      return AddRepeatedMarkCommand(
        pageIDs: selected, mark: mark, margin: margin, groupID: groupID,
        placement: placement)
    }
  }

  public let settings: BatesBatchSettings
  public let files: [FileAssignment]
  /// Non-fatal disclosures (empty included pages, digit-width overflow).
  public let issues: [String]

  public init(
    settings: BatesBatchSettings, files: [FileAssignment], issues: [String]
  ) {
    self.settings = settings
    self.files = files
    self.issues = issues
  }

  public var totalPages: Int { files.reduce(0) { $0 + $1.pageCount } }
  public var numberedPages: Int { files.reduce(0) { $0 + $1.pages.count } }
  public var sequenceStart: Int? { files.compactMap(\.firstNumber).min() }
  public var sequenceEnd: Int? { files.compactMap(\.lastNumber).max() }

  public var summary: String {
    let fileWord = files.count == 1 ? "file" : "files"
    let pageWord = numberedPages == 1 ? "page" : "pages"
    var text = "\(files.count) \(fileWord), \(numberedPages) \(pageWord) numbered"
    if let first = sequenceStart, let last = sequenceEnd {
      text += " (\(first)-\(last))"
    }
    return text
  }
}

/// PAG-07: build a continuous (or per-file restarting) sequence over ordered
/// files. Excluded pages receive no mark and do not consume a number, so the
/// sequence stays continuous on the pages that are numbered.
public enum BatesBatchPlanner {
  public static func plan(
    files: [BatesBatchFile], settings: BatesBatchSettings
  ) throws -> BatesBatchPlan {
    guard !files.isEmpty else {
      throw PDFError(.malformed, "No input files were selected")
    }
    guard settings.startNumber >= 0, settings.startNumber <= 9_999_999_999 else {
      throw PDFError(.limitExceeded, "The Bates start number is outside the supported range")
    }
    guard (1...12).contains(settings.digits) else {
      throw PDFError(.malformed, "Bates digits must be between 1 and 12")
    }
    guard settings.margin.isFinite, settings.margin >= 0, settings.margin <= 500 else {
      throw PDFError(.malformed, "The mark margin is outside the supported range")
    }
    guard settings.prefix.utf8.count <= 200, settings.suffix.utf8.count <= 200 else {
      throw PDFError(.limitExceeded, "The Bates prefix or suffix exceeds the size limit")
    }
    guard settings.leadingExcludedPages >= 0 else {
      throw PDFError(.malformed, "The leading excluded page count cannot be negative")
    }
    guard settings.excludedPages.allSatisfy({ $0 >= 1 }) else {
      throw PDFError(.malformed, "Excluded page numbers are 1-based and must be positive")
    }
    let style = settings.style
    guard style.size.isFinite, style.size >= 2, style.size <= 400 else {
      throw PDFError(.malformed, "The mark font size is outside the supported range")
    }
    guard style.opacity.isFinite, style.opacity >= 0, style.opacity <= 1 else {
      throw PDFError(.malformed, "The mark opacity is outside 0-1")
    }
    guard style.color.count == 3,
      style.color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
    else {
      throw PDFError(.malformed, "The mark color must be three finite RGB components")
    }
    var next = settings.startNumber
    var issues: [String] = []
    var assignments: [BatesBatchPlan.FileAssignment] = []
    for (order, file) in files.enumerated() {
      guard file.pageCount > 0 else {
        throw PDFError(.malformed, "\(file.name) has no pages")
      }
      guard file.excludedPages.allSatisfy({ $0 >= 1 }) else {
        throw PDFError(.malformed, "Excluded page numbers are 1-based and must be positive")
      }
      let excluded = excludedPageNumbers(settings: settings, file: file)
      let included = (1...file.pageCount).filter { !excluded.contains($0) }
      if included.isEmpty {
        issues.append("\(file.name): every page is excluded; nothing will be numbered.")
      }
      let base = settings.continuesAcrossFiles ? next : settings.startNumber
      let pages = included.enumerated().map { offset, pageIndex in
        BatesBatchPlan.PageAssignment(
          pageIndex: pageIndex, number: base + offset,
          text: RepeatedMark.batesText(
            prefix: settings.prefix, suffix: settings.suffix,
            number: base + offset, digits: settings.digits))
      }
      let mark: RepeatedMark? = pages.first.map {
        .bates(
          prefix: settings.prefix, suffix: settings.suffix, start: $0.number,
          digits: settings.digits, style: settings.style)
      }
      if settings.continuesAcrossFiles, let last = pages.last {
        next = last.number + 1
      }
      if let last = pages.last, String(last.number).count > settings.digits {
        issues.append(
          "\(file.name): the last number \(last.number) is wider than the requested "
            + "\(settings.digits) digits; the full number is kept rather than cut.")
      }
      assignments.append(
        BatesBatchPlan.FileAssignment(
          order: order, name: file.name, pageCount: file.pageCount,
          excludedPages: excluded, pages: pages, mark: mark,
          placement: settings.placement, margin: settings.margin))
    }
    return BatesBatchPlan(settings: settings, files: assignments, issues: issues)
  }

  static func excludedPageNumbers(
    settings: BatesBatchSettings, file: BatesBatchFile
  ) -> [Int] {
    var excluded = Set(settings.excludedPages.filter { $0 <= file.pageCount })
    excluded.formUnion(file.excludedPages.filter { $0 <= file.pageCount })
    if settings.leadingExcludedPages > 0 {
      let upper = min(settings.leadingExcludedPages, file.pageCount)
      if upper >= 1 { excluded.formUnion(1...upper) }
    }
    return excluded.sorted()
  }

  /// Compress sorted 1-based page numbers to a compact list such as "1-3, 5".
  public static func formatPageList(_ pages: [Int]) -> String {
    let sorted = Array(Set(pages)).sorted()
    guard !sorted.isEmpty else { return "" }
    var parts: [String] = []
    var start = sorted[0]
    var previous = sorted[0]
    for page in sorted.dropFirst() {
      if page == previous + 1 {
        previous = page
        continue
      }
      parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
      start = page
      previous = page
    }
    parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
    return parts.joined(separator: ", ")
  }
}

/// PAG-07: the verification result for one written batch output.
public struct BatesBatchVerification: Sendable, Equatable {
  public let order: Int
  public let name: String
  public let expectedPages: [Int]
  public let matchedPages: [Int]
  public let missingPages: [Int]
  /// Pages that carry the set but were not planned to be numbered.
  public let unexpectedPages: [Int]
  public let issues: [String]

  public var isVerified: Bool {
    missingPages.isEmpty && unexpectedPages.isEmpty && issues.isEmpty
  }

  public init(
    order: Int, name: String, expectedPages: [Int], matchedPages: [Int],
    missingPages: [Int], unexpectedPages: [Int], issues: [String]
  ) {
    self.order = order
    self.name = name
    self.expectedPages = expectedPages
    self.matchedPages = matchedPages
    self.missingPages = missingPages
    self.unexpectedPages = unexpectedPages
    self.issues = issues
  }

  public var summary: String {
    if isVerified {
      return "\(name): verified \(matchedPages.count) page"
        + (matchedPages.count == 1 ? "" : "s")
    }
    var lines = ["\(name): verification needs attention"]
    if !missingPages.isEmpty {
      lines.append("  missing on page(s): \(BatesBatchPlanner.formatPageList(missingPages))")
    }
    if !unexpectedPages.isEmpty {
      lines.append(
        "  unexpected on page(s): \(BatesBatchPlanner.formatPageList(unexpectedPages))")
    }
    lines.append(contentsOf: issues.map { "  ! \($0)" })
    return lines.joined(separator: "\n")
  }
}

/// PAG-07: verify a written output file against its planned assignment. The
/// check binds to the group identity written by the batch, so unrelated
/// existing content and other mark sets are never counted as this batch's
/// marks.
public enum BatesBatchVerifier {
  public static func verify(
    graph: PDFGraph, pageIDs: [PDFObjectID],
    assignment: BatesBatchPlan.FileAssignment, groupID: String
  ) -> BatesBatchVerification {
    let groups = RepeatedMarkInventory.groups(in: graph, pageIDs: pageIDs)
    let expectedByPage = Dictionary(
      uniqueKeysWithValues: assignment.pages.map { ($0.pageIndex, $0.text) })
    let expectedPages = assignment.pages.map(\.pageIndex)
    guard let group = groups.first(where: { $0.groupID == groupID }) else {
      return BatesBatchVerification(
        order: assignment.order, name: assignment.name, expectedPages: expectedPages,
        matchedPages: [], missingPages: expectedPages, unexpectedPages: [],
        issues: ["the saved output has no sPDF Bates mark set"])
    }
    let groupPageNumbers = Dictionary(
      uniqueKeysWithValues: pageIDs.enumerated().map { ($0.element, $0.offset + 1) })
    let groupedPages = Set(group.pageIDs.compactMap { groupPageNumbers[$0] })
    var matched: [Int] = []
    var missing: [Int] = []
    var issues: [String] = []
    for pageID in group.pageIDs {
      guard let page = groupPageNumbers[pageID] else { continue }
      let streams = RepeatedMarkInventory.streamIDs(
        groupID: groupID, pageID: pageID, in: graph)
      if streams.count > 1 {
        issues.append(
          "page \(page) carries the Bates mark \(streams.count) times")
      }
      guard let expected = expectedByPage[page] else { continue }
      let layout = try? PageTextLayout.build(pageID: pageID, in: graph)
      let painted = layout.map { layout in
        layout.clusters.map(\.text).joined().filter { !$0.isWhitespace }
      } ?? ""
      let normalized = expected.filter { !$0.isWhitespace }
      if painted.contains(normalized) {
        matched.append(page)
      } else {
        missing.append(page)
        issues.append("page \(page) does not show the planned text \"\(expected)\"")
      }
    }
    let seen = Set(group.pageIDs.compactMap { groupPageNumbers[$0] })
    for page in expectedPages where !seen.contains(page) {
      if !missing.contains(page) {
        missing.append(page)
        issues.append("page \(page) has no Bates mark")
      }
    }
    let unexpected = groupedPages.subtracting(expectedPages).sorted()
    if !unexpected.isEmpty {
      issues.append(
        "the set marks unplanned page(s): \(BatesBatchPlanner.formatPageList(Array(unexpected)))")
    }
    matched.sort()
    missing.sort()
    return BatesBatchVerification(
      order: assignment.order, name: assignment.name, expectedPages: expectedPages,
      matchedPages: matched, missingPages: missing, unexpectedPages: unexpected,
      issues: issues)
  }
}

/// PAG-07: the filename-to-sequence mapping written next to a batch's PDFs.
public struct BatesMappingReport: Sendable, Equatable {
  public let plan: BatesBatchPlan
  public let verifications: [BatesBatchVerification]
  public let issues: [String]

  public init(
    plan: BatesBatchPlan, verifications: [BatesBatchVerification],
    issues: [String] = []
  ) {
    self.plan = plan
    self.verifications = verifications
    self.issues = issues
  }

  public var isVerified: Bool {
    issues.isEmpty && plan.issues.isEmpty
      && verifications.count == plan.files.count
      && verifications.allSatisfy(\.isVerified)
  }

  public var summary: String {
    var lines = [
      "Bates numbering batch: \(plan.summary)",
      "Format: \(plan.settings.formatDescription)",
      "Mapping: \(plan.files.count) file"
        + (plan.files.count == 1 ? "" : "s")
        + ", \(verifications.filter(\.isVerified).count) verified",
    ]
    for file in plan.files {
      let pages = BatesBatchPlanner.formatPageList(file.numberedPages)
      let range: String
      if let first = file.firstNumber, let last = file.lastNumber {
        range = first == last ? "\(first)" : "\(first)-\(last)"
      } else {
        range = "not numbered"
      }
      lines.append("  \(file.order + 1). \(file.name) — pages \(pages) — \(range)")
    }
    if !plan.issues.isEmpty {
      lines.append(contentsOf: plan.issues.map { "  note: \($0)" })
    }
    for verification in verifications where !verification.isVerified {
      lines.append(contentsOf: verification.summary.split(separator: "\n").map { "  \($0)" })
    }
    if !issues.isEmpty {
      lines.append(contentsOf: issues.map { "  ! \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  /// PAG-07: comma-separated mapping (one row per input file).
  public func csv() -> String {
    var lines = [
      "Order,File,Pages,NumberedPages,ExcludedPages,FirstPage,LastPage,Prefix,"
        + "FirstBates,LastBates,Suffix,Digits,Continuity,Verified"
    ]
    let settings = plan.settings
    for file in plan.files {
      let verification = verifications.first { $0.order == file.order }
      let firstPage = file.firstPage.map { String($0) } ?? ""
      let lastPage = file.lastPage.map { String($0) } ?? ""
      let firstBates = file.firstNumber.map { String($0) } ?? ""
      let lastBates = file.lastNumber.map { String($0) } ?? ""
      let continuity = settings.continuesAcrossFiles ? "continuous" : "restart-per-file"
      let values: [String] = [
        String(file.order + 1), file.name, String(file.pageCount),
        BatesBatchPlanner.formatPageList(file.numberedPages),
        BatesBatchPlanner.formatPageList(file.excludedPages),
        firstPage, lastPage, settings.prefix, firstBates, lastBates,
        settings.suffix, String(settings.digits), continuity,
        verification?.isVerified == true ? "yes" : "no",
      ]
      lines.append(Self.csvLine(values))
    }
    for issue in plan.issues + issues {
      lines.append(Self.csvLine(["note", issue]))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// One CSV row padded to the report's 14 columns.
  static func csvLine(_ values: [String]) -> String {
    var fields = values
    while fields.count < 14 { fields.append("") }
    return fields.map(escapeCSV).joined(separator: ",")
  }

  /// PAG-07: JSON mapping with the per-page assignments and verification.
  public func jsonData() throws -> Data {
    let settings = plan.settings
    var object: [String: Any] = [
      "version": 1,
      "generatedBy": "sPDF Editor",
      "sequenceStart": plan.sequenceStart.map { $0 as Any } ?? NSNull(),
      "sequenceEnd": plan.sequenceEnd.map { $0 as Any } ?? NSNull(),
      "totalPages": plan.totalPages,
      "numberedPages": plan.numberedPages,
      "settings": [
        "prefix": settings.prefix,
        "suffix": settings.suffix,
        "startNumber": settings.startNumber,
        "digits": settings.digits,
        "placement": settings.placement.rawValue,
        "margin": settings.margin,
        "continuesAcrossFiles": settings.continuesAcrossFiles,
        "excludedPages": settings.excludedPages,
        "leadingExcludedPages": settings.leadingExcludedPages,
      ] as [String: Any],
      "files": plan.files.map { file -> [String: Any] in
        let verification = verifications.first { $0.order == file.order }
        return [
          "order": file.order + 1,
          "file": file.name,
          "pages": file.pageCount,
          "numberedPageCount": file.pages.count,
          "excludedPages": file.excludedPages,
          "firstPage": file.firstPage.map { $0 as Any } ?? NSNull(),
          "lastPage": file.lastPage.map { $0 as Any } ?? NSNull(),
          "firstBatesNumber": file.firstNumber.map { $0 as Any } ?? NSNull(),
          "lastBatesNumber": file.lastNumber.map { $0 as Any } ?? NSNull(),
          "verified": verification?.isVerified == true,
          "verificationIssues": verification?.issues ?? [],
          "pageAssignments": file.pages.map { page -> [String: Any] in
            [
              "page": page.pageIndex,
              "batesNumber": page.number,
              "text": page.text,
            ]
          },
        ] as [String: Any]
      },
      "issues": plan.issues + issues,
    ]
    object["verified"] = plan.issues.isEmpty && issues.isEmpty
      && verifications.count == plan.files.count
      && verifications.allSatisfy(\.isVerified)
    do {
      return try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    } catch {
      throw PDFError(.malformed, "The Bates mapping report could not be encoded")
    }
  }

  static func escapeCSV(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n")
      || value.contains("\r")
    else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
