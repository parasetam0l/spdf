import Combine
import Foundation
import PDFEditing

/// P33-006/P33-007: the structure/reading-order inspector state.
final class StructureModel: ObservableObject {
  struct Entry: Identifiable {
    let id: String
    let element: PDFStructureElement
    let depth: Int
  }

  @Published var entries: [Entry] = []
  @Published var issues: [PDFStructureIssue] = []
  @Published var isTagged = false
  @Published var language: String?
  /// P33-022: pending assisted-tagging suggestions under review. They never
  /// appear in `entries` (the confirmed reading order) until accepted and
  /// applied.
  @Published var review: TaggingReview?

  var suggestions: [TaggingSuggestion] { review?.suggestions ?? [] }

  func update(with inventory: PDFStructureInventory?) {
    guard let inventory else {
      entries = []
      issues = []
      isTagged = false
      language = nil
      return
    }
    isTagged = inventory.isTagged
    language = inventory.language
    issues = inventory.issues
    var entries: [Entry] = []
    func walk(_ element: PDFStructureElement, depth: Int) {
      guard depth <= 24 else { return }
      entries.append(
        Entry(id: "\(element.objectID?.number ?? -1)-\(entries.count)", element: element, depth: depth))
      for child in element.children {
        if case .element(let nested) = child { walk(nested, depth: depth + 1) }
      }
    }
    for element in inventory.elements { walk(element, depth: 0) }
    self.entries = entries
  }
}
