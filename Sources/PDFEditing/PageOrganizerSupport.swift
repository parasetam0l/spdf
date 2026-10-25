import Foundation
import PDFCore

// MARK: - PAG-01 thumbnail organizer core

/// Display metadata for one page tile in the organizer. Labels come from the
/// document's /PageLabels number tree; size and rotation are the resolved page
/// attributes so mixed-size and rotated pages are predictable in the grid.
public struct PageOrganizerPageInfo: Identifiable, Sendable, Equatable {
  public var id: PDFObjectID { pageID }
  public let pageID: PDFObjectID
  public let pageIndex: Int
  /// Document label (for example "iv" or "A-3"), falling back to the physical
  /// page number.
  public let label: String
  public let physicalLabel: String
  public let mediaBox: [Double]
  public let rotation: Int
  /// Size after applying the page rotation (what the thumbnail shows).
  public let displaySize: [Double]

  public init(
    pageID: PDFObjectID, pageIndex: Int, label: String, physicalLabel: String,
    mediaBox: [Double], rotation: Int, displaySize: [Double]
  ) {
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.label = label
    self.physicalLabel = physicalLabel
    self.mediaBox = mediaBox
    self.rotation = rotation
    self.displaySize = displaySize
  }
}

public enum PageOrganizerInfo {
  public static func pages(in graph: PDFGraph) throws -> [PageOrganizerPageInfo] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let attributes = try PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    var result: [PageOrganizerPageInfo] = []
    for (index, pageID) in pageIDs.enumerated() {
      let attribute = attributes[index]
      let display = PageOrganizerGeometry.displaySize(
        mediaBox: attribute.mediaBox, rotation: attribute.rotation)
      result.append(
        PageOrganizerPageInfo(
          pageID: pageID, pageIndex: index,
          label: PDFPageLabels.label(forPageIndex: index, in: graph),
          physicalLabel: String(index + 1),
          mediaBox: attribute.mediaBox, rotation: attribute.rotation,
          displaySize: display))
    }
    return result
  }
}

enum PageOrganizerGeometry {
  static func displaySize(mediaBox: [Double], rotation: Int) -> [Double] {
    guard mediaBox.count == 4 else { return [612, 792] }
    let width = abs(mediaBox[2] - mediaBox[0])
    let height = abs(mediaBox[3] - mediaBox[1])
    let normalized = ((rotation % 360) + 360) % 360
    if normalized == 90 || normalized == 270 { return [height, width] }
    return [width, height]
  }
}

/// PAG-01: move any set of selected pages as one contiguous block to a target
/// position. The block keeps the document order of the selection, surrounding
/// pages keep their order, and the whole action is one command/one undo step.
public struct MovePagesCommand: PDFEditCommand, Equatable, Sendable {
  public let pageIDs: [PDFObjectID]
  /// Target position in the flattened order of the remaining pages (0...count).
  public let toIndex: Int

  public init(pageIDs: [PDFObjectID], toIndex: Int) {
    self.pageIDs = pageIDs
    self.toIndex = toIndex
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Move Pages" }

  public func validate(in graph: PDFGraph) throws {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "Move requires at least one page")
    }
    var seen: Set<PDFObjectID> = []
    for id in pageIDs {
      guard seen.insert(id).inserted else {
        throw PDFError(.malformed, "Move lists the same page twice")
      }
    }
    let view = try PageTreeView(graph: graph)
    for id in pageIDs where !view.pages.contains(id) {
      throw PDFError(.malformed, "A move target is not a page")
    }
    let remaining = view.pages.filter { !seen.contains($0) }.count
    guard toIndex >= 0, toIndex <= remaining else {
      throw PDFError(.malformed, "The move destination is outside the remaining pages")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try PageOrganizer.moveBlock(pageIDs: pageIDs, toIndex: toIndex, in: graph)
  }
}

/// PAG-01: duplicate every selected page as one block after the last selected
/// page. Shallow resource sharing matches the existing single-page duplicate
/// command; the entire batch is one command/one undo step.
public struct DuplicatePagesCommand: PDFEditCommand, Equatable, Sendable {
  public let pageIDs: [PDFObjectID]
  public let duplicateResources: Bool

  public init(pageIDs: [PDFObjectID], duplicateResources: Bool = false) {
    self.pageIDs = pageIDs
    self.duplicateResources = duplicateResources
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Duplicate Pages" }

  public func validate(in graph: PDFGraph) throws {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "Duplication requires at least one page")
    }
    guard Set(pageIDs).count == pageIDs.count else {
      throw PDFError(.malformed, "Duplication lists the same page twice")
    }
    let view = try PageTreeView(graph: graph)
    for id in pageIDs where !view.pages.contains(id) {
      throw PDFError(.malformed, "A duplicate target is not a page")
    }
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    guard next + pageIDs.count * 2 <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for duplicated pages")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let view = try PageTreeView(graph: graph)
    let selected = Set(pageIDs)
    let orderedSelection = view.pages.filter { selected.contains($0) }
    var result = graph
    var newPageIDs: [PDFObjectID] = []
    for pageID in orderedSelection {
      let duplicated = try DocumentAssembly.duplicatePage(
        pageID, in: result, duplicateResources: duplicateResources)
      result = duplicated.graph
      newPageIDs.append(duplicated.newPageID)
    }
    guard let lastSelected = orderedSelection.last else { return result }
    let currentPages = try PDFPageTree.pageIDs(in: result)
    let newPageSet = Set(newPageIDs)
    // The duplicated pages are moved as a block; originals stay in place.
    let remaining = currentPages.filter { !newPageSet.contains($0) }
    guard let lastIndex = remaining.firstIndex(of: lastSelected) else { return result }
    return try PageOrganizer.moveBlock(
      pageIDs: newPageIDs, toIndex: lastIndex + 1, in: result)
  }
}

enum PageOrganizer {
  /// Move a set of pages as one block. Shared by MovePagesCommand and the
  /// Replace Pages command (which places imported pages at a destination
  /// position). Selected pages keep their current document order.
  static func moveBlock(
    pageIDs: [PDFObjectID], toIndex: Int, in graph: PDFGraph
  ) throws -> PDFGraph {
    let selected = Set(pageIDs)
    guard !selected.isEmpty else { return graph }
    var editor = try PageTreeEditor(graph: graph)
    let view = editor.view
    let block = view.pages.filter { selected.contains($0) }
    let remaining = view.pages.filter { !selected.contains($0) }
    let target = min(max(toIndex, 0), remaining.count)
    var kids = view.kids
    for (node, children) in kids {
      kids[node] = children.filter { !selected.contains($0) }
    }
    let anchorParent: PDFObjectID
    var insertIndex: Int
    if remaining.isEmpty {
      anchorParent = view.rootID
      insertIndex = kids[anchorParent]?.count ?? 0
    } else if target == 0 {
      let anchor = remaining[0]
      anchorParent = view.parents[anchor]!
      insertIndex = kids[anchorParent]!.firstIndex(of: anchor) ?? 0
    } else {
      let anchor = remaining[target - 1]
      anchorParent = view.parents[anchor]!
      insertIndex = (kids[anchorParent]!.firstIndex(of: anchor) ?? 0) + 1
    }
    var children = kids[anchorParent] ?? []
    for (offset, pageID) in block.enumerated() {
      children.insert(pageID, at: min(insertIndex + offset, children.count))
    }
    kids[anchorParent] = children
    for (node, nodeChildren) in kids {
      try editor.setKids(node, nodeChildren)
    }
    try editor.refreshCounts()
    return editor.graph
  }
}
