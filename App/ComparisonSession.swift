import AppKit
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI

/// P32-002/P32-003/P32-005/P32-008/P32-021: the comparison workspace state.
/// Two read-only viewers follow the explicit page mapping; changes can be
/// navigated with keyboard commands; page pairs can be corrected manually;
/// overlay and blink modes render the same pair.
@MainActor
final class ComparisonSession: ObservableObject {
  enum Mode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case overlay = "Overlay"
    case blink = "Blink"
    var id: String { rawValue }
  }

  @Published var mode: Mode = .sideBySide {
    didSet { updateBlinkTimer() }
  }
  @Published private(set) var result: PDFComparisonResult
  @Published private(set) var mapping: [PDFComparisonResult.PagePair]
  @Published var selectedChangeIndex: Int?
  @Published private(set) var leftPageIndex = 0
  @Published private(set) var rightPageIndex = 0
  @Published private(set) var isBlinking = false

  let leftDocument: PDFDocument
  let rightDocument: PDFDocument
  let options: PDFComparisonOptions
  private let left: (graph: PDFGraph, source: Data)
  private let right: (graph: PDFGraph, source: Data)
  private var blinkTimer: Timer?
  private var differenceCache: [Int: CGImage] = [:]

  init(
    left: (graph: PDFGraph, source: Data), right: (graph: PDFGraph, source: Data),
    options: PDFComparisonOptions = PDFComparisonOptions()
  ) throws {
    self.left = left
    self.right = right
    self.options = options
    let result = try PDFComparison.compare(left: left, right: right, options: options)
    self.result = result
    self.mapping = result.pageMapping
    guard let leftDocument = PDFDocument(data: left.source),
      let rightDocument = PDFDocument(data: right.source)
    else {
      throw PDFError(.malformed, "The comparison documents could not be rendered")
    }
    self.leftDocument = leftDocument
    self.rightDocument = rightDocument
  }

  var changes: [PDFComparisonChange] { result.changes }

  var selectedChange: PDFComparisonChange? {
    guard let index = selectedChangeIndex, changes.indices.contains(index) else { return nil }
    return changes[index]
  }

  // MARK: Synchronized navigation (P32-003)

  func leftPageChanged(to index: Int) {
    leftPageIndex = index
    if let rightIndex = rightIndex(forLeft: index) {
      rightPageIndex = rightIndex
    }
  }

  func rightPageChanged(to index: Int) {
    rightPageIndex = index
    if let leftIndex = leftIndex(forRight: index) {
      leftPageIndex = leftIndex
    }
  }

  func rightIndex(forLeft index: Int) -> Int? {
    mapping.first { $0.leftIndex == index }?.rightIndex
  }

  func leftIndex(forRight index: Int) -> Int? {
    mapping.first { $0.rightIndex == index }?.leftIndex
  }

  // MARK: Change navigation (P32-021)

  func selectNextChange() {
    guard !changes.isEmpty else { return }
    let next = min((selectedChangeIndex ?? -1) + 1, changes.count - 1)
    selectChange(next)
  }

  func selectPreviousChange() {
    guard !changes.isEmpty else { return }
    let previous = max((selectedChangeIndex ?? changes.count) - 1, 0)
    selectChange(previous)
  }

  func selectChange(_ index: Int) {
    guard changes.indices.contains(index) else { return }
    selectedChangeIndex = index
    let change = changes[index]
    if let rightIndex = change.rightPageIndex {
      rightPageIndex = rightIndex
    }
    if let leftIndex = change.leftPageIndex {
      leftPageIndex = leftIndex
    }
  }

  // MARK: Manual mapping correction (P32-005)

  func correctMapping(leftIndex: Int, toRightIndex: Int?) throws {
    var corrected: [PDFComparisonResult.PagePair] = []
    for pair in mapping {
      guard let currentLeft = pair.leftIndex else {
        corrected.append(pair)
        continue
      }
      if currentLeft == leftIndex {
        corrected.append(
          PDFComparisonResult.PagePair(
            leftIndex: leftIndex, rightIndex: toRightIndex,
            status: toRightIndex == nil ? .deleted : .matched))
      } else if let right = pair.rightIndex, right == toRightIndex {
        // The chosen right page is released from its previous pairing.
        corrected.append(
          PDFComparisonResult.PagePair(leftIndex: currentLeft, rightIndex: nil, status: .deleted))
      } else {
        corrected.append(pair)
      }
    }
    mapping = corrected
    result = try PDFComparison.compare(
      left: left, right: right, options: options, mappingOverride: corrected)
    differenceCache.removeAll()
    if let selected = selectedChangeIndex, selected >= changes.count {
      selectedChangeIndex = changes.isEmpty ? nil : changes.count - 1
    }
  }

  func resetMapping() throws {
    result = try PDFComparison.compare(left: left, right: right, options: options)
    mapping = result.pageMapping
    differenceCache.removeAll()
    selectedChangeIndex = nil
  }

  // MARK: Overlay and blink (P32-008)

  func differenceImage(size: NSSize = NSSize(width: 800, height: 1000)) -> CGImage? {
    if let cached = differenceCache[rightPageIndex] { return cached }
    guard
      let difference = PageDifferenceRenderer.difference(
        left: left.source, right: right.source, pageIndex: rightPageIndex, size: size,
        tolerance: options.visualTolerance)
    else { return nil }
    differenceCache[rightPageIndex] = difference.image
    return difference.image
  }

  func differenceRatio() -> Double? {
    PageDifferenceRenderer.difference(
      left: left.source, right: right.source, pageIndex: rightPageIndex,
      size: NSSize(width: 400, height: 520), tolerance: options.visualTolerance)?
      .changedPixelRatio
  }

  private func updateBlinkTimer() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    isBlinking = false
    guard mode == .blink else { return }
    blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.isBlinking.toggle() }
    }
  }

  var blinkShowsLeft: Bool { isBlinking }

  // MARK: Report (P32-022)

  func reportText() -> String {
    PDFComparisonReport.text(result, options: options)
  }
}

/// P32-002: one read-only PDF pane whose page binding follows the mapping.
struct ComparisonPane: NSViewRepresentable {
  let document: PDFDocument
  let pageIndex: Int
  var onPageChanged: (Int) -> Void

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.document = document
    view.displayMode = .singlePage
    view.autoScales = true
    view.backgroundColor = .windowBackgroundColor
    context.coordinator.view = view
    NotificationCenter.default.addObserver(
      context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
      name: .PDFViewPageChanged, object: view)
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
    guard let page = document.page(at: pageIndex), view.currentPage !== page else { return }
    context.coordinator.isProgrammatic = true
    view.go(to: page)
    context.coordinator.isProgrammatic = false
  }

  func makeCoordinator() -> Coordinator { Coordinator(onPageChanged: onPageChanged) }

  final class Coordinator: NSObject {
    var onPageChanged: (Int) -> Void
    var isProgrammatic = false
    weak var view: PDFView?

    init(onPageChanged: @escaping (Int) -> Void) {
      self.onPageChanged = onPageChanged
    }

    @objc func pageChanged(_ notification: Notification) {
      guard !isProgrammatic, let view, let page = view.currentPage,
        let document = view.document
      else { return }
      onPageChanged(document.index(for: page))
    }
  }
}
