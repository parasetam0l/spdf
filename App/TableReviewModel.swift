import AppKit
import Foundation
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// P36-009 + EXP-02: the review grid's state. Corrections rewrite the extracted
/// data only; the PDF is never modified. EXP-02 adds reviewed boundaries,
/// header rows and multipage continuation, and exports CSV/XLSX through
/// ReviewedTable with a TableExportReviewReport sidecar.
@MainActor
final class TableReviewModel: ObservableObject {
  @Published var reviews: [TableReview]
  /// EXP-02: one review session per detected table. Boundary/header/continuation
  /// edits live here; review corrections rebuild the affected session.
  @Published private(set) var sessions: [TableReviewSession]
  @Published var selectedIndex = 0
  @Published var message: String?

  init(reviews: [TableReview]) {
    self.reviews = reviews
    self.sessions = reviews.map(Self.session(for:))
  }

  private static func session(for review: TableReview) -> TableReviewSession {
    TableReviewSession(table: review.reviewedTable() ?? review.table)
  }

  var selected: TableReview? {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return nil }
    return reviews[selectedIndex]
  }

  private var selectedSession: TableReviewSession? {
    guard selectedIndex >= 0, selectedIndex < sessions.count else { return nil }
    return sessions[selectedIndex]
  }

  var selectedTable: ExtractedTable? { selectedSession?.table ?? selected?.table }

  /// P36-010: rejected detections are excluded from the legacy export path.
  var exportable: [ExtractedTable] { TableReview.exportable(reviews) }

  // MARK: - EXP-02 reviewed export

  /// Rejected detections are excluded; every other table is exported through
  /// its reviewed session (spans, headers, continuation and edits preserved).
  var reviewedTables: [ReviewedTable] {
    reviews.indices.compactMap { index in
      guard !reviews[index].isRejected else { return nil }
      return sessions[index].reviewed()
    }
  }

  var selectedHeaderRowCount: Int { selectedSession?.headerRowCount ?? 0 }

  var selectedContinuationPageNumbers: [Int] {
    (selectedSession?.continuationPageIndexes ?? []).map { $0 + 1 }
  }

  /// The next non-rejected table with a matching column count that has not
  /// already been folded in can be attached as a continuation.
  var canMergeContinuation: Bool { continuationCandidate != nil }

  private var continuationCandidate: (index: Int, table: ExtractedTable)? {
    guard let current = selectedSession, reviews.count > 1 else { return nil }
    for offset in 1..<reviews.count {
      let index = (selectedIndex + offset) % reviews.count
      guard index != selectedIndex, !reviews[index].isRejected else { continue }
      let table = sessions[index].table
      guard table.columnCount == current.table.columnCount else { continue }
      guard !current.continuationPageIndexes.contains(table.pageIndex) else { continue }
      return (index, table)
    }
    return nil
  }

  func setHeaderRowCount(_ count: Int) {
    mutateSession { try $0.setHeaderRowCount(count) }
  }

  /// Insert a reviewed row boundary after the given row (default: last row).
  func insertRow(after row: Int? = nil) {
    mutateSession { session in
      let target = row ?? max(0, session.table.rowCount - 1)
      try session.insertRow(after: min(target, session.table.rowCount - 1))
    }
  }

  /// Insert a reviewed column boundary after the given column (default: last).
  func insertColumn(after column: Int? = nil) {
    mutateSession { session in
      let target = column ?? max(0, session.table.columnCount - 1)
      try session.insertColumn(after: min(target, session.table.columnCount - 1))
    }
  }

  func splitCell(row: Int, column: Int) {
    mutateSession { session in
      guard let cell = session.table.cell(row: row, column: column),
        cell.rowSpan > 1 || cell.columnSpan > 1
      else {
        throw PDFError(.malformed, "Select a merged cell before splitting it")
      }
      try session.splitCell(
        row: row, column: column, rows: cell.rowSpan, columns: cell.columnSpan)
    }
  }

  /// Fold the next compatible table in as a continuation of this one.
  func mergeContinuation() {
    guard let candidate = continuationCandidate else {
      message =
        "No other reviewed table has the same column count (or the continuation was "
        + "already folded in)."
      return
    }
    mutateSession { try $0.mergeContinuation(candidate.table) }
  }

  private func mutateSession(_ body: (inout TableReviewSession) throws -> Void) {
    guard selectedIndex >= 0, selectedIndex < sessions.count else { return }
    do {
      try body(&sessions[selectedIndex])
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  private func rebuildSession(_ index: Int) {
    guard index >= 0, index < reviews.count, index < sessions.count else { return }
    let previous = sessions[index]
    var session = Self.session(for: reviews[index])
    _ = try? session.setHeaderRowCount(min(previous.headerRowCount, session.table.rowCount))
    sessions[index] = session
  }

  // MARK: - Review corrections

  func setText(row: Int, column: Int, text: String) {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    do {
      try reviews[selectedIndex].setCellText(row: row, column: column, text: text)
      rebuildSession(selectedIndex)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  func deleteRow(_ row: Int) {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    do {
      try reviews[selectedIndex].deleteRow(row)
      rebuildSession(selectedIndex)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  func deleteColumn(_ column: Int) {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    do {
      try reviews[selectedIndex].deleteColumn(column)
      rebuildSession(selectedIndex)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  func accept() {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    reviews[selectedIndex].accept()
    rebuildSession(selectedIndex)
    message = nil
  }

  func reject() {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    reviews[selectedIndex].reject()
    rebuildSession(selectedIndex)
    message = nil
  }

  // MARK: - EXP-02 CSV/XLSX export with report sidecar

  enum ReviewedExportFormat {
    case csv
    case xlsx

    var fileExtension: String {
      switch self {
      case .csv: return "csv"
      case .xlsx: return "xlsx"
      }
    }
  }

  func exportReviewed(_ format: ReviewedExportFormat) {
    let tables = reviewedTables
    guard !tables.isEmpty else {
      message = "No reviewed tables to export (every detection may be rejected)."
      return
    }
    let panel = NSSavePanel()
    if let type = UTType(filenameExtension: format.fileExtension) {
      panel.allowedContentTypes = [type]
    }
    panel.nameFieldStringValue = "Tables-reviewed.\(format.fileExtension)"
    panel.prompt = "Export"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      Task { @MainActor in
        do {
          let result = try self.exportReviewed(format, to: url)
          let tableWord = result.tableCount == 1 ? "table" : "tables"
          let fileWord = result.reportURLs.count == 1 ? "file" : "files"
          self.message =
            "Exported \(result.tableCount) reviewed \(tableWord) with "
            + "\(result.reportURLs.count) report sidecar \(fileWord)."
        } catch {
          self.message = error.localizedDescription
        }
      }
    }
  }

  /// Testable path behind the panel: writes the reviewed CSV/XLSX plus the
  /// review report sidecars and returns their URLs.
  @discardableResult
  func exportReviewed(
    _ format: ReviewedExportFormat, to url: URL
  ) throws -> (tableCount: Int, reportURLs: [URL]) {
    let tables = reviewedTables
    guard !tables.isEmpty else {
      throw PDFError(.malformed, "There are no reviewed tables to export")
    }
    let data: Data
    switch format {
    case .csv:
      let csv = tables.map { $0.csv() }.joined(separator: "\n")
      data = Data(csv.utf8)
    case .xlsx:
      data = try ReviewedTableExport.xlsx(tables: tables)
    }
    try data.write(to: url, options: .atomic)
    let report = ReviewedTableExport.reviewReport(for: tables)
    let urls = try Self.writeReportSidecars(report: report, nextTo: url)
    return (tables.count, urls)
  }

  static func writeReportSidecars(
    report: TableExportReviewReport, nextTo exported: URL
  ) throws -> [URL] {
    let base = exported.deletingPathExtension()
    let markdown = base.appendingPathExtension("review.md")
    let json = base.appendingPathExtension("review.json")
    try Data(report.markdown().utf8).write(to: markdown, options: .atomic)
    try report.jsonData().write(to: json, options: .atomic)
    return [markdown, json]
  }

  // MARK: - Status

  /// A short status line for the panel.
  var statusText: String {
    guard let table = selectedTable else { return "No table selected" }
    let state = selected?.isRejected == true ? "rejected" : (selected?.isAccepted == true ? "accepted" : "unreviewed")
    let confidence = String(format: "%.2f", table.confidence)
    let geometry = "\(table.rowCount)×\(table.columnCount)"
    var parts: [String] = [
      geometry, table.detection.rawValue, "confidence \(confidence)", state,
      "header rows \(selectedHeaderRowCount)",
    ]
    let continuationPages = selectedContinuationPageNumbers
    if !continuationPages.isEmpty {
      let pages = continuationPages.map { String($0) }.joined(separator: ", ")
      parts.append("continuation from page(s) \(pages)")
    }
    return parts.joined(separator: " · ")
  }
}
