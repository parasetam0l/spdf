import Foundation
import PDFEditing
import SwiftUI

/// P36-009: the review grid's state. Corrections rewrite the extracted data
/// only; the PDF is never modified.
@MainActor
final class TableReviewModel: ObservableObject {
  @Published var reviews: [TableReview]
  @Published var selectedIndex = 0
  @Published var message: String?

  init(reviews: [TableReview]) {
    self.reviews = reviews
  }

  var selected: TableReview? {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return nil }
    return reviews[selectedIndex]
  }

  var selectedTable: ExtractedTable? { selected?.table }

  /// P36-010: rejected detections are excluded from export.
  var exportable: [ExtractedTable] { TableReview.exportable(reviews) }

  func setText(row: Int, column: Int, text: String) {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    do {
      try reviews[selectedIndex].setCellText(row: row, column: column, text: text)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  func deleteRow(_ row: Int) {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    do {
      try reviews[selectedIndex].deleteRow(row)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  func deleteColumn(_ column: Int) {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    do {
      try reviews[selectedIndex].deleteColumn(column)
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }

  func accept() {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    reviews[selectedIndex].accept()
    message = nil
  }

  func reject() {
    guard selectedIndex >= 0, selectedIndex < reviews.count else { return }
    reviews[selectedIndex].reject()
    message = nil
  }

  /// A short status line for the panel.
  var statusText: String {
    guard let table = selectedTable else { return "No table selected" }
    let state = selected?.isRejected == true ? "rejected" : (selected?.isAccepted == true ? "accepted" : "unreviewed")
    let confidence = String(format: "%.2f", table.confidence)
    return "\(table.rowCount)×\(table.columnCount) · \(table.detection.rawValue) · confidence \(confidence) · \(state)"
  }
}
