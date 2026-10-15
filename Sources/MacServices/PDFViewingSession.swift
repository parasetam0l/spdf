import AppKit
import Combine
import PDFCore
import PDFEditing
import PDFKit

/// P24-013: an editable text field under a page point, resolved by the app so
/// the overlay can position a native editor over the widget geometry.
public struct FormFieldTarget: Sendable, Equatable {
  public let fieldName: String
  public let pageIndex: Int
  /// Widget rectangle in page space.
  public let rect: [Double]
  public let value: String
  public let isReadOnly: Bool

  public init(
    fieldName: String, pageIndex: Int, rect: [Double], value: String, isReadOnly: Bool
  ) {
    self.fieldName = fieldName
    self.pageIndex = pageIndex
    self.rect = rect
    self.value = value
    self.isReadOnly = isReadOnly
  }
}

/// P18-021: a document text run under a page point, for in-place editing
/// over the run geometry.
public struct PageTextTarget: Sendable, Equatable {
  public let pageIndex: Int
  public let runIndex: Int
  /// Run bounds in page space.
  public let rect: [Double]
  public let text: String
  /// P15-024: the run's input style for the native editor; nil for callers
  /// that predate style resolution (the overlay then uses system defaults).
  public let style: TextInputStyle?

  public init(
    pageIndex: Int, runIndex: Int, rect: [Double], text: String,
    style: TextInputStyle? = nil
  ) {
    self.pageIndex = pageIndex
    self.runIndex = runIndex
    self.rect = rect
    self.text = text
    self.style = style
  }
}

/// P12-017: an app-created graphic (image stamp or rectangle) under a page
/// point, resolved by the app so the overlay can draw handles over it.
public struct AddedGraphicTarget: Sendable, Equatable {
  public let pageIndex: Int
  public let streamID: PDFObjectID
  public let kind: String
  /// Axis-aligned page-space bounds ([x0, y0, x1, y1]).
  public let rect: [Double]

  public init(pageIndex: Int, streamID: PDFObjectID, kind: String, rect: [Double]) {
    self.pageIndex = pageIndex
    self.streamID = streamID
    self.kind = kind
    self.rect = rect
  }
}

extension TextInputStyle {
  /// P15-024: the native control font for an editor of `viewHeight` view
  /// points: the run's family at the on-screen size when installed, else the
  /// system font at that size. Sizing matches the overlay's height-derived
  /// rule so styled and unstyled editors measure identically.
  public func nativeFont(viewHeight: Double) -> NSFont {
    let size = max(9, min(28, viewHeight * 0.62))
    if let fontFamily, !fontFamily.isEmpty,
      let font = NSFont(name: fontFamily, size: size)
    {
      return font
    }
    return NSFont.systemFont(ofSize: size)
  }

  /// P15-024: the native control text color: the run's fill color, clamped
  /// to finite 0...1 components, or the label color when the stored color
  /// is malformed.
  public var nativeTextColor: NSColor {
    guard fillColor.count == 3, fillColor.allSatisfy({ $0.isFinite }) else {
      return .labelColor
    }
    let clamped = fillColor.map { min(1, max(0, $0)) }
    return NSColor(
      calibratedRed: clamped[0], green: clamped[1], blue: clamped[2], alpha: 1)
  }
}

/// P12-022: what the viewer surface shows. Failures and locks are states,
/// not dead ends: the document stays open for inspection where possible and
/// the state tells the UI which surface to show.
public enum ViewerDocumentState: Sendable, Equatable {
  case empty
  case loading
  case ready
  case locked
  case failed(String)
}

/// P12-012: document tool modes. `.select` is neutral; the edit modes arm
/// their overlay. Exactly one tool is active at a time; the ink overlay
/// toggle stays separate and orthogonal.
public enum ViewerToolMode: String, Sendable, Equatable, CaseIterable {
  case select
  case textEdit
  case addText
  case imageEdit
  case annotate
  case page
}

/// P22-016: which sidebar the workspace shows.
public enum SidebarMode: String, Sendable, Equatable, CaseIterable {
  case pages
  case comments
  case forms
  case signatures
  case structure
  case fonts
  /// P12-011: selection inspector.
  case inspector
  /// P12-020: document information.
  case info

  /// P12-019: persistence names for per-document view state.
  public var storedName: String { rawValue }

  public init?(storedName: String) {
    self.init(rawValue: storedName)
  }
}

/// P12-011: structured selection details for the properties inspector:
/// the page, the bounded text, and the page-space bounds when available.
public struct SelectionDetails: Sendable, Equatable {
  public let pageNumber: Int
  public let text: String
  public let bounds: [Double]?

  public init(pageNumber: Int, text: String, bounds: [Double]?) {
    self.pageNumber = pageNumber
    self.text = text
    self.bounds = bounds
  }
}

/// P12-020: document facts for the info panel, installed per document by
/// the app from the core inventory.
public struct ViewerDocumentInfo: Sendable, Equatable {
  public let fileName: String
  public let pageCount: Int
  public let title: String?
  public let author: String?
  public let subject: String?
  public let keywords: String?
  public let creator: String?
  public let producer: String?
  public let language: String?
  public let capabilitySummary: String?

  public init(
    fileName: String, pageCount: Int, title: String? = nil, author: String? = nil,
    subject: String? = nil, keywords: String? = nil, creator: String? = nil,
    producer: String? = nil, language: String? = nil, capabilitySummary: String? = nil
  ) {
    self.fileName = fileName
    self.pageCount = pageCount
    self.title = title
    self.author = author
    self.subject = subject
    self.keywords = keywords
    self.creator = creator
    self.producer = producer
    self.language = language
    self.capabilitySummary = capabilitySummary
  }
}

@MainActor
public final class PDFViewingSession: NSObject, ObservableObject, PDFViewDelegate {
  /// P12-004: the explicit zoom range. The view's own limits are also set
  /// from these, but PDFKit adjusts its limits while autoScales is on, so
  /// `setZoom` clamps against these constants to keep its contract.
  public static let minZoom = 0.1
  public static let maxZoom = 8.0
  public let view: PDFView = ReadOnlyPDFView(frame: .zero)
  public let thumbnails = PDFThumbnailView(frame: .zero)
  @Published public private(set) var pageNumber = 0
  @Published public private(set) var pageCount = 0
  @Published public private(set) var scale = 1.0
  @Published public private(set) var isLocked = false
  @Published public var searchText = ""
  @Published public private(set) var searchMatchCount = 0
  @Published public private(set) var searchIndex = 0
  @Published public private(set) var isSearchVisible = false
  @Published public var sidebarMode: SidebarMode = .pages
  @Published public var isSidebarVisible = true
  @Published public var isInkToolActive = false
  /// The document publishes its current core editing permission to the workspace.
  @Published public var allowsContentEditing = false
  @Published public private(set) var activeTool: ViewerToolMode = .select
  /// P12-013: hook the app installs to finish (commit or cancel) a pending
  /// edit before the active tool changes. Returning false vetoes the switch
  /// and keeps the current tool.
  public var pendingEditFinisher: (() -> Bool)?
  /// A pointer transaction cannot be abandoned by an update mid-drag.
  public var hasPendingInkGesture: (() -> Bool)?
  public var hasPendingGraphicGesture: (() -> Bool)?
  /// P12-024: human-readable description of the current page selection for
  /// inspectors and VoiceOver; nil when nothing is selected.
  @Published public private(set) var selectedObjectSummary: String?
  /// P12-011: structured selection details for the inspector.
  @Published public private(set) var selectionDetails: SelectionDetails?
  /// P12-017: selected app-created graphics (rubber-band drags select
  /// several; handle drags transform the whole set as one transaction).
  @Published public private(set) var selectedGraphics: [AddedGraphicTarget] = []
  /// P12-020: document facts for the info panel.
  @Published public var documentInfo: ViewerDocumentInfo?
  /// P12-018: optional page rulers and snapping guides.
  @Published public var areRulersVisible = false
  @Published public var areGuidesVisible = false
  /// P12-018: the page-space point under the view origin, refreshed on
  /// page/scale changes and on scrolling. Rulers render from it.
  @Published public private(set) var rulerPageOrigin: CGPoint = .zero
  /// P12-018: the measured page-space direction of each view axis (+1/-1,
  /// 0 when degenerate), so rulers map correctly for flipped and rotated
  /// pages on any view configuration.
  @Published public private(set) var rulerXDirection = 1.0
  @Published public private(set) var rulerYDirection = 1.0
  @Published public private(set) var documentState: ViewerDocumentState = .empty
  /// P12-019: restored sidebar width in points (0 means automatic).
  @Published public var sidebarWidth: Double = 0
  /// P12-008: outline entries installed per document by the app.
  public var outlineItems: [PDFOutlineItem] = []
  /// P12-009: navigation-history state for menu validation.
  @Published public private(set) var canGoBackInHistory = false
  @Published public private(set) var canGoForwardInHistory = false
  /// P12-007: display labels per page (from the core `/PageLabels` number
  /// tree, installed by the app); empty means physical numbers only.
  public var pageLabels: [String] = []
  private var backStack: [Int] = []
  private var forwardStack: [Int] = []
  /// P22-008: native pointer input callback (page index, flat page-space
  /// points). The App layer commits the stroke through the edit session.
  public var onInkStroke: ((Int, [Double]) -> Void)?
  /// P12-015: provider for the page context menu (page index, page point in
  /// page space). Returning nil falls back to PDFKit's default menu.
  public var pageMenuProvider: ((Int, [Double]) -> NSMenu?)?
  /// P24-013: resolve an editable text field under a page point.
  public var formFieldProvider: ((Int, [Double]) -> FormFieldTarget?)?
  /// P24-013: commit inline form text (field name, new text).
  public var onFormFieldCommit: ((String, String) -> Bool)?
  /// P18-021: resolve an editable document text run under a page point.
  public var textRunProvider: ((Int, [Double]) -> PageTextTarget?)?
  /// P18-021: commit an in-place text-run replacement.
  public var onTextRunCommit: ((Int, Int, String) -> Bool)?
  /// Add real page text at a rectangle chosen in the workspace.
  public var onAddPageText: ((Int, [Double], String) -> Bool)?
  /// P12-017: resolve an app-created graphic under a page point.
  public var graphicTargetProvider: ((Int, [Double]) -> AddedGraphicTarget?)?
  /// P12-017: list every selectable app-created graphic on a page, in
  /// content order, for rubber-band drag selection.
  public var graphicsListProvider: ((Int) -> [AddedGraphicTarget])?
  /// P12-017: commit graphic moves/resizes/rotates (stream identities plus
  /// the mappings the overlay computed; the app runs the core commands).
  /// Moves and resizes arrive batched so a multi-selection drag commits as
  /// one transaction with one undo step.
  public var onMoveGraphics: (([(streamID: PDFObjectID, dx: Double, dy: Double)]) -> Void)?
  public var onResizeGraphics: (
    ([(streamID: PDFObjectID, dx: Double, dy: Double, scaleX: Double, scaleY: Double)]) -> Void
  )?
  public var onRotateGraphic: ((PDFObjectID) -> Void)?
  private var searchMatches: [PDFSelection] = []
  private var observations: Set<AnyCancellable> = []

  public override init() {
    super.init()
    view.delegate = self
    (view as? ReadOnlyPDFView)?.session = self
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    // Limits are set after autoScales: enabling autoScales resets the
    // maximum scale factor, and the limit setters turn autoScales off, so
    // autoScales is re-enabled explicitly last only when limits hold.
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 8
    // PDFKit's min/max setters turn autoScales off, so enable it last.
    view.autoScales = true
    view.backgroundColor = .windowBackgroundColor
    thumbnails.pdfView = view
    thumbnails.thumbnailSize = NSSize(width: 112, height: 148)
    for name in [
      Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged,
      .PDFViewSelectionChanged,
    ] {
      NotificationCenter.default.publisher(for: name, object: view)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
          MainActor.assumeIsolated {
            self?.refresh()
            // P12-024: user-driven selections update the summary too.
            if notification.name == .PDFViewSelectionChanged {
              self?.refreshSelectionSummary()
            }
          }
        }
        .store(in: &observations)
    }
    // P12-018: internal scrolls move the ruler origin. The notification is
    // filtered to views inside the page view; refresh() is idempotent.
    NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: nil)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, let changed = notification.object as? NSView else { return }
          var current: NSView? = changed
          while let view = current {
            if view === self.view {
              self.refreshRulerOrigin()
              break
            }
            current = view.superview
          }
        }
      }
      .store(in: &observations)
  }

  /// P12-018: resolve the page-space point under the view origin and the
  /// page-space direction of each view axis. Called on page/scale changes
  /// (via refresh) and on scrolling.
  public func refreshRulerOrigin() {
    guard let page = view.currentPage, view.document != nil else { return }
    let origin = view.convert(CGPoint.zero, to: page)
    let dx = view.convert(CGPoint(x: 10, y: 0), to: page)
    let dy = view.convert(CGPoint(x: 0, y: 10), to: page)
    rulerPageOrigin = origin
    rulerXDirection = dx.x == origin.x ? 0 : (dx.x > origin.x ? 1 : -1)
    rulerYDirection = dy.y == origin.y ? 0 : (dy.y > origin.y ? 1 : -1)
  }

  public func open(_ source: PDFSource) throws {
    selectedObjectSummary = nil
    selectionDetails = nil
    selectedGraphics = []
    activeTool = .select
    documentState = .loading
    guard let document = PDFDocument(data: source.data) else {
      documentState = .failed("Apple's renderer could not open this PDF")
      throw PDFError(.malformed, "Apple's renderer could not open this PDF")
    }
    clearSearch()
    backStack.removeAll()
    forwardStack.removeAll()
    publishHistoryState()
    // Data detectors are opt-in; leave them disabled for document privacy.
    view.document = document
    isLocked = document.isLocked
    pageCount = document.pageCount
    documentState = document.isLocked ? .locked : .ready
    refresh()
  }

  /// P12-022: close the viewed document without destroying the session.
  public func closeDocument() {
    selectedObjectSummary = nil
    selectionDetails = nil
    selectedGraphics = []
    activeTool = .select
    clearSearch()
    backStack.removeAll()
    forwardStack.removeAll()
    publishHistoryState()
    view.document = nil
    pageCount = 0
    isLocked = false
    documentState = .empty
    refresh()
  }

  /// P28-005: unlock a protected document with a user-supplied password. The
  /// password is used only for this call; it is never logged, stored, or
  /// copied into any model.
  public func unlock(password: String) -> Bool {
    guard let document = view.document, document.isLocked else { return !isLocked }
    guard document.unlock(withPassword: password) else {
      documentState = .locked
      return false
    }
    isLocked = document.isLocked
    pageCount = document.pageCount
    documentState = document.isLocked ? .locked : .ready
    refresh()
    return !isLocked
  }

  // MARK: - Search (viewing adapter)

  /// P12-010: find text through the viewer adapter, highlight every match,
  /// and navigate between them. The owned TextSearch engine remains the core
  /// authority for editing and export paths.
  public func showSearch() {
    isSearchVisible = true
  }

  public func hideSearch() {
    isSearchVisible = false
    clearSearch()
  }

  public func runSearch() {
    guard let document = view.document, !searchText.isEmpty else {
      clearSearch()
      return
    }
    searchMatches = document.findString(searchText, withOptions: [.caseInsensitive])
    searchMatchCount = searchMatches.count
    view.highlightedSelections = searchMatches
    guard !searchMatches.isEmpty else {
      searchIndex = 0
      view.setCurrentSelection(nil, animate: false)
      return
    }
    searchIndex = 1
    select(searchMatches[0])
  }

  public func searchNext() {
    guard !searchMatches.isEmpty else { return }
    searchIndex = searchIndex % searchMatches.count + 1
    select(searchMatches[searchIndex - 1])
  }

  public func searchPrevious() {
    guard !searchMatches.isEmpty else { return }
    searchIndex = searchIndex <= 1 ? searchMatches.count : searchIndex - 1
    select(searchMatches[searchIndex - 1])
  }

  private func select(_ selection: PDFSelection) {
    view.setCurrentSelection(selection, animate: false)
    view.go(to: selection)
    refreshSelectionSummary()
  }

  private func clearSearch() {
    searchMatches = []
    searchMatchCount = 0
    searchIndex = 0
    view.highlightedSelections = nil
    view.setCurrentSelection(nil, animate: false)
    refreshSelectionSummary()
  }

  public var canGoBack: Bool { pageNumber > 1 }
  public var canGoForward: Bool { pageNumber > 0 && pageNumber < pageCount }

  public func go(to page: Int) {
    navigate(to: page, recording: true)
  }

  private func navigate(to page: Int, recording: Bool) {
    guard (1...max(1, pageCount)).contains(page),
      let target = view.document?.page(at: page - 1)
    else { return }
    if recording, pageNumber >= 1, page != pageNumber {
      backStack.append(pageNumber)
      forwardStack.removeAll()
    }
    view.go(to: target)
    refresh()
    publishHistoryState()
  }

  private func publishHistoryState() {
    canGoBackInHistory = !backStack.isEmpty
    canGoForwardInHistory = !forwardStack.isEmpty
  }

  /// P12-009: back/forward across recorded page jumps (internal links,
  /// outline entries, label jumps, and explicit page commands).
  public func goBack() {
    guard let previous = backStack.popLast(), pageNumber >= 1 else {
      publishHistoryState()
      return
    }
    forwardStack.append(pageNumber)
    navigate(to: previous, recording: false)
  }

  public func goForward() {
    guard let next = forwardStack.popLast() else {
      publishHistoryState()
      return
    }
    if pageNumber >= 1 { backStack.append(pageNumber) }
    navigate(to: next, recording: false)
  }

  /// P12-008: jump to an outline entry's page, recorded in history. Entries
  /// without a page target return false.
  @discardableResult
  public func go(toOutlineItem item: PDFOutlineItem) -> Bool {
    guard let page = item.pageIndex else { return false }
    navigate(to: page + 1, recording: true)
    return pageNumber == page + 1
  }

  /// P12-007: jump to a page by its display label (case-insensitive), falling
  /// back to a physical page number. Returns whether the jump happened.
  @discardableResult
  public func go(toLabel label: String) -> Bool {
    let target = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !target.isEmpty else { return false }
    if let index = pageLabels.firstIndex(where: { $0.lowercased() == target }) {
      navigate(to: index + 1, recording: true)
      return true
    }
    if let number = Int(target), (1...max(1, pageCount)).contains(number) {
      navigate(to: number, recording: true)
      return true
    }
    return false
  }

  public func previousPage() { if canGoBack { go(to: pageNumber - 1) } }
  public func nextPage() { if canGoForward { go(to: pageNumber + 1) } }
  public func firstPage() { go(to: 1) }
  public func lastPage() { if pageCount > 0 { go(to: pageCount) } }
  /// P12-005: run a zoom change, then restore the current page so the
  /// visible location survives the scale change. Sub-page scroll anchoring
  /// stays PDFKit-owned; the session guarantees the page does not move.
  private func preservingPageLocation(_ apply: () -> Void) {
    let page = view.currentPage
    apply()
    if let page { view.go(to: page) }
    refresh()
  }

  public func zoomIn() {
    view.autoScales = false
    preservingPageLocation { view.zoomIn(nil) }
  }
  public func zoomOut() {
    view.autoScales = false
    preservingPageLocation { view.zoomOut(nil) }
  }
  public func actualSize() {
    view.autoScales = false
    preservingPageLocation { view.scaleFactor = 1 }
  }

  /// P12-004: an explicit zoom factor, clamped to the session zoom range.
  public func setZoom(_ factor: Double) {
    view.autoScales = false
    preservingPageLocation {
      view.scaleFactor = CGFloat(
        min(Self.maxZoom, max(Self.minZoom, factor)))
    }
  }

  /// P12-004: the scale factor that fits `displayed` into `available` along
  /// one axis (fit-width) or both (fit-page), before clamping to the view's
  /// limits. Pure so the math is testable without a laid-out view.
  public nonisolated static func scaleToFit(
    displayed: CGSize, available: CGSize, fitHeight: Bool, currentScale: CGFloat,
    minScale: CGFloat, maxScale: CGFloat
  ) -> CGFloat {
    guard displayed.width > 0, displayed.height > 0,
      available.width > 0, available.height > 0
    else { return currentScale }
    let ratio =
      fitHeight
      ? min(available.width / displayed.width, available.height / displayed.height)
      : available.width / displayed.width
    return min(maxScale, max(minScale, currentScale * ratio))
  }

  /// P12-004: fit the current page's width to the view (PDFKit's autoScales
  /// only means fit-width in continuous mode, so single-page mode needs this
  /// explicitly).
  public func fitWidth() {
    guard let page = view.currentPage, view.bounds.width > 64 else {
      view.autoScales = true
      return
    }
    view.layoutSubtreeIfNeeded()
    let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
    guard displayed.width > 0 else { return }
    view.autoScales = false
    let target = Self.scaleToFit(
      displayed: displayed.size,
      available: CGSize(width: view.bounds.width - 32, height: view.bounds.height),
      fitHeight: false, currentScale: view.scaleFactor,
      minScale: view.minScaleFactor, maxScale: view.maxScaleFactor)
    preservingPageLocation { view.scaleFactor = target }
    view.go(to: page)
    refresh()
  }
  public func fitPage() {
    guard let page = view.currentPage, view.bounds.width > 64, view.bounds.height > 64 else {
      view.autoScales = true
      return
    }
    view.layoutSubtreeIfNeeded()
    let displayed = view.convert(page.bounds(for: view.displayBox), from: page)
    guard displayed.width > 0, displayed.height > 0 else { return }
    // PDFKit autoScales means fit-width in continuous mode. Fit Page must
    // instead fit this page's rotated bounds in both dimensions.
    let ratio = min(
      (view.bounds.width - 32) / displayed.width,
      (view.bounds.height - 32) / displayed.height)
    view.autoScales = false
    view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, view.scaleFactor * ratio))
    view.go(to: page)
    refresh()
  }
  public func setContinuous(_ continuous: Bool) {
    view.displayMode = continuous ? .singlePageContinuous : .singlePage
    refresh()
  }

  /// Synchronize toolbar metadata after the app restores native window and
  /// zoom values, without waiting for a queued PDFKit notification.
  public func synchronizeViewState() { refresh() }

  public func showComments() { sidebarMode = .comments }
  public func showPages() { sidebarMode = .pages }
  public func showForms() { sidebarMode = .forms }
  public func showSignatures() { sidebarMode = .signatures }
  public func showStructure() { sidebarMode = .structure }
  public func showFonts() { sidebarMode = .fonts }
  public func showInspector() { sidebarMode = .inspector }
  public func showInfo() { sidebarMode = .info }

  /// P12-018: toggle the page rulers and snapping guides.
  public func toggleRulers() { areRulersVisible.toggle() }
  public func toggleGuides() { areGuidesVisible.toggle() }

  /// P22-008: toggle the ink tool; the workspace overlays a pointer-capture
  /// view while it is active.
  public func toggleInkTool() {
    isInkToolActive.toggle()
  }

  /// P12-012/P12-013: switch the active tool, finishing any pending edit
  /// first. A vetoed switch returns false and keeps the current tool.
  @discardableResult
  public func activateTool(_ tool: ViewerToolMode) -> Bool {
    guard tool != activeTool else { return true }
    if activeTool != .select, let finisher = pendingEditFinisher, !finisher() {
      return false
    }
    activeTool = tool
    return true
  }

  /// P12-024: refresh the selection summary from the view's current
  /// selection (page number plus bounded text).
  public func refreshSelectionSummary() {
    let text = (view.currentSelection?.string ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
      let document = view.document,
      let selection = view.currentSelection,
      let page = selection.pages.first
    else {
      selectedObjectSummary = nil
      selectionDetails = nil
      return
    }
    let index = document.index(for: page) + 1
    var short = text.replacingOccurrences(of: "\n", with: " ")
    if short.count > 80 { short = String(short.prefix(80)) + "…" }
    selectedObjectSummary = "Page \(index): \(short)"
    let box = selection.bounds(for: page)
    selectionDetails = SelectionDetails(
      pageNumber: index, text: short,
      bounds: box.isNull
        ? nil : [Double(box.origin.x), Double(box.origin.y),
                 Double(box.maxX), Double(box.maxY)])
  }

  /// P12-017: replace the graphics selection and publish its summary for
  /// the inspector and VoiceOver. An empty selection clears the summary
  /// only when no text selection is active, so the two never fight.
  public func selectGraphics(_ targets: [AddedGraphicTarget]) {
    selectedGraphics = targets
    guard !targets.isEmpty else {
      if view.currentSelection == nil {
        selectedObjectSummary = nil
        selectionDetails = nil
      }
      return
    }
    if targets.count == 1, let target = targets.first {
      selectedObjectSummary = "Page \(target.pageIndex + 1): \(target.kind) graphic"
      selectionDetails = SelectionDetails(
        pageNumber: target.pageIndex + 1, text: "\(target.kind) graphic",
        bounds: target.rect.count == 4 ? target.rect : nil)
    } else {
      selectedObjectSummary = "\(targets.count) graphics selected"
      selectionDetails = SelectionDetails(
        pageNumber: targets[0].pageIndex + 1,
        text: "\(targets.count) graphics selected", bounds: nil)
    }
  }

  /// P12-017: drop the graphics selection without touching text selection.
  public func clearGraphicSelection() {
    selectGraphics([])
  }

  /// P22-017: scroll to a page-space rectangle and select the text inside it
  /// when the page has any, so a comment-list entry lands on its geometry.
  public func focus(onPageIndex index: Int, rect: [Double]) {
    guard let document = view.document, index >= 0, index < document.pageCount,
      let page = document.page(at: index)
    else { return }
    let box: CGRect
    if rect.count == 4 {
      box = CGRect(x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1])
    } else {
      box = .zero
    }
    if box.width > 0.5, box.height > 0.5, let selection = page.selection(for: box),
      let text = selection.string, !text.isEmpty
    {
      view.setCurrentSelection(selection, animate: false)
      view.go(to: selection)
    } else if box != .zero {
      view.go(to: PDFDestination(page: page, at: CGPoint(x: box.midX, y: box.midY)))
    } else {
      view.go(to: page)
    }
    refresh()
  }

  // PDFKit otherwise opens URLs through NSWorkspace. External actions need a future explicit workflow.
  nonisolated public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

  private func refresh() {
    if let page = view.currentPage, let document = view.document {
      pageNumber = document.index(for: page) + 1
    } else {
      pageNumber = 0
    }
    scale = Double(view.scaleFactor)
    refreshRulerOrigin()
  }
}

@MainActor
private final class ReadOnlyPDFView: PDFView {
  weak var session: PDFViewingSession?

  override func perform(_ action: PDFAction) {
    // No Launch, JavaScript, remote-GoTo, URL, or document-driven print actions.
    if action is PDFActionGoTo { super.perform(action) }
  }

  /// P12-015: operation-specific contextual menu for the clicked page point.
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let session, let provider = session.pageMenuProvider, let document else {
      return super.menu(for: event)
    }
    let viewPoint = convert(event.locationInWindow, from: nil)
    guard let page = page(for: viewPoint, nearest: false) else {
      return super.menu(for: event)
    }
    let pagePoint = convert(viewPoint, to: page)
    let index = document.index(for: page)
    return provider(index, [Double(pagePoint.x), Double(pagePoint.y)])
      ?? super.menu(for: event)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let page = page(for: point, nearest: false),
      let annotation = page.annotation(at: convert(point, to: page)),
      annotation.type == PDFAnnotationSubtype.widget.rawValue
    {
      return
    }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    // Avoid PDFKit's form-field tab focus in the initial read-only surface.
    if event.keyCode == 48 {
      window?.selectNextKeyView(nil)
      return
    }
    super.keyDown(with: event)
  }
}
