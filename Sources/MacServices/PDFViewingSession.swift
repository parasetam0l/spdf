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
  public let runIndices: [Int]
  public let paragraph: PageTextParagraph?

  public init(
    pageIndex: Int, runIndex: Int, rect: [Double], text: String,
    style: TextInputStyle? = nil, runIndices: [Int]? = nil,
    paragraph: PageTextParagraph? = nil
  ) {
    self.pageIndex = pageIndex
    self.runIndex = runIndex
    self.rect = rect
    self.text = text
    self.style = style
    self.runIndices = runIndices ?? [runIndex]
    self.paragraph = paragraph
  }
}

/// Whole-block formatting; the existing font is retained for imported text.
public struct PageTextStyle: Sendable, Equatable {
  public var fontFamily: String
  public var fontSize: Double
  public var color: [Double]
  public var opacity: Double

  public init(
    fontFamily: String = "Helvetica", fontSize: Double = 12,
    color: [Double] = [0, 0, 0], opacity: Double = 1
  )
  {
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.color = color
    self.opacity = opacity
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
  /// Optional visible hit bounds, narrower than `rect` when the PDF clips an
  /// existing image. Geometry edits still use the full transform rectangle.
  public let hitRect: [Double]?
  /// Set only for a directly editable image already present in the PDF.
  /// App-created graphics remain identified by their content-stream object.
  public let imagePlacementIndex: Int?

  public init(
    pageIndex: Int, streamID: PDFObjectID, kind: String, rect: [Double],
    imagePlacementIndex: Int? = nil, hitRect: [Double]? = nil
  ) {
    self.pageIndex = pageIndex
    self.streamID = streamID
    self.kind = kind
    self.rect = rect
    self.imagePlacementIndex = imagePlacementIndex
    self.hitRect = hitRect
  }

  public var identity: String {
    "\(pageIndex):\(streamID.number):\(streamID.generation):\(imagePlacementIndex ?? -1)"
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
  @Published public private(set) var searchedText: String?
  @Published public private(set) var searchMatchCount = 0
  @Published public private(set) var searchIndex = 0
  @Published public private(set) var isSearchVisible = false
  @Published public var sidebarMode: SidebarMode = .pages
  @Published public var isSidebarVisible = true
  @Published public var isInkToolActive = false
  /// The document publishes its current core editing permission to the workspace.
  @Published public var allowsContentEditing = false
  /// A visible explanation when document-level policy keeps editing disabled.
  @Published public var editingRestrictionNotice: String?
  /// Point-of-use explanation for an image target the canvas deliberately refuses.
  @Published public private(set) var graphicEditRefusal: String?
  /// Point-of-use explanation when rendered page text is outside the inline editor profile.
  @Published public private(set) var textEditRefusal: String?
  @Published public private(set) var activeTool: ViewerToolMode = .select
  /// P12-013: hook the app installs to finish (commit or cancel) a pending
  /// edit before the active tool changes. Returning false vetoes the switch
  /// and keeps the current tool.
  public var pendingEditFinisher: (() -> Bool)?
  @Published public var pageTextStyle = PageTextStyle()
  /// Verified embedded fonts available for the active inline text selection.
  @Published public var pageTextAvailableSourceFonts: [PageTextSourceFont] = []
  /// User-accepted, locally provisioned fonts that pass inline embedding checks.
  @Published public var pageTextAvailableLicensedFonts: [CustomTextFont] = []
  @Published public var isEditingPageText = false
  @Published public var isTypingPageText = false
  @Published public var hasPendingPageTextChanges = false
  @Published public var canUndoPageTyping = false
  @Published public var canRedoPageTyping = false
  @Published public var pageTextPosition = [0.0, 0.0]
  @Published public var pageTextWidth = 0.0
  @Published public var canFormatPageText = false
  @Published public var pageTextMixedFormatting = Set<String>()
  @Published public var pageTextSelectionScope = "Whole text box"
  @Published public var pageTextFormattingIssue: String?
  public var pageTextFormattingApplier: ((PageTextFormatChange) -> Void)?
  @Published public var canChangePageTextTraits = true
  public var pageTextBeginTyping: (() -> Void)?
  public var pageTextCancel: (() -> Void)?
  /// Undo and redo uncommitted inline text operations even while focus is in
  /// the inspector. The document edit stack is not the owner of these drafts.
  public var pageTextUndo: (() -> Bool)?
  public var pageTextRedo: (() -> Bool)?
  public var pageTextPositionApplier: ((Double, Double) -> Void)?
  public var pageTextAlignmentApplier: ((PageObjectAlignment) -> Void)?
  public var pageTextWidthApplier: ((Double) -> Void)?
  public var pageTextStyleApplier: ((PageTextStyle) -> Void)?
  public var hasPendingTextGesture: (() -> Bool)?
  public var onTextBlockPreview: ((PageTextTarget) -> Data?)?
  /// A single atomic content transaction: replacement, formatting and movement.
  public var onTextBlockCommit: ((PageTextTarget, String, PageTextStyle, Double, Double, [PageTextLine]?, PageTextBox?) -> Bool)?
  public var onNewTextBlockCommit: ((Int, [Double], String, PageTextStyle, [PageTextLine], PageTextBox) -> Bool)?
  public var onPendingPageTextChange: ((Bool) -> Void)?
  public var textBlockEditStarter: ((PageTextTarget) -> Void)?
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
  /// Explain why visible text under a page point cannot be edited inline.
  public var textEditRefusalProvider: ((Int, [Double]) -> String?)?
  /// Editable text blocks on a page, in any order; the viewer sorts these by
  /// their visible position before keyboard traversal.
  public var textTargetsProvider: ((Int) -> [PageTextTarget])?
  /// P18-021: commit an in-place text-run replacement.
  public var onTextRunCommit: ((Int, Int, String) -> Bool)?
  /// Add real page text at a rectangle chosen in the workspace.
  public var onAddPageText: ((Int, [Double], String) -> Bool)?
  /// P12-017: resolve an app-created graphic under a page point.
  public var graphicTargetProvider: ((Int, [Double]) -> AddedGraphicTarget?)?
  /// P12-017: list every selectable app-created graphic on a page, in
  /// content order, for rubber-band drag selection.
  public var graphicsListProvider: ((Int) -> [AddedGraphicTarget])?
  /// Explain why a visible image cannot participate in the canvas profile.
  public var graphicRefusalProvider: ((Int, [Double]) -> String?)?
  /// P12-017: commit graphic moves/resizes/rotates (stream identities plus
  /// the mappings the overlay computed; the app runs the core commands).
  /// Moves and resizes arrive batched so a multi-selection drag commits as
  /// one transaction with one undo step.
  public var onMoveGraphics:
    (([(target: AddedGraphicTarget, dx: Double, dy: Double)]) -> Void)?
  public var onResizeGraphics:
    (
      ([(target: AddedGraphicTarget, dx: Double, dy: Double, scaleX: Double, scaleY: Double)])
        -> Void
    )?
  /// Produces a display-only PDF at the proposed geometry. Its data is never
  /// adopted by the edit session; release commits once through the callback.
  public var graphicPreviewProvider:
    (([(target: AddedGraphicTarget, dx: Double, dy: Double, scaleX: Double, scaleY: Double)])
      -> Data?)?
  public var onRotateGraphic: ((AddedGraphicTarget) -> Void)?
  public var onDeleteGraphics: (([AddedGraphicTarget]) -> Void)?
  public var onInsertImage: (() -> Void)?
  public var graphicSelectionFocuser: (() -> Void)?
  private var searchMatches: [PDFSelection] = []
  private var observations: Set<AnyCancellable> = []
  private var graphicPreviewState:
    (document: PDFDocument, scale: CGFloat, autoScales: Bool, page: Int, scroll: NSPoint?)?

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
    graphicPreviewState = nil
    editingRestrictionNotice = nil
    graphicEditRefusal = nil
    textEditRefusal = nil
    selectedObjectSummary = nil
    selectionDetails = nil
    selectedGraphics = []
    activeTool = .select
    documentState = .loading
    guard let document = PDFDocument(data: source.data) else {
      documentState = .failed("Apple's renderer could not open this PDF")
      throw PDFError(.malformed, "Apple's renderer could not open this PDF")
    }
    // PDFKit widgets belong to this disposable renderer document. Letting
    // them mutate would change only PDFKit's copy, while Save serializes the
    // canonical edit-session graph. Keep renderer widgets read-only; supported
    // edits go through the app's form panel or the inline text-field overlay.
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where annotation.type == "Widget" {
        annotation.isReadOnly = true
      }
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
    graphicPreviewState = nil
    onPendingPageTextChange?(false)
    isEditingPageText = false
    isTypingPageText = false
    hasPendingPageTextChanges = false
    canUndoPageTyping = false
    canRedoPageTyping = false
    pageTextBeginTyping = nil
    pageTextCancel = nil
    pageTextUndo = nil
    pageTextRedo = nil
    pageTextPositionApplier = nil
    pageTextAlignmentApplier = nil
    pageTextWidthApplier = nil
    pageTextStyleApplier = nil
    pageTextFormattingApplier = nil
    canFormatPageText = false
    pageTextMixedFormatting = []
    pageTextAvailableSourceFonts = []
    pageTextAvailableLicensedFonts = []
    pageTextFormattingIssue = nil
    editingRestrictionNotice = nil
    graphicEditRefusal = nil
    textEditRefusal = nil
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
    searchedText = searchText
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
    searchedText = nil
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

  /// Command-wheel zoom stays anchored to the page point under the pointer.
  /// Other wheel events retain normal scrolling, including in text editors.
  @discardableResult
  public func handleCommandScroll(_ event: NSEvent) -> Bool {
    guard event.type == .scrollWheel, event.modifierFlags.contains(.command),
      view.document != nil, !isLocked else { return false }
    // Inertial events must not keep zooming after the gesture ends.
    guard event.momentumPhase.isEmpty else { return true }
    let delta = event.scrollingDeltaY
    guard delta.isFinite, delta != 0 else { return true }
    let pointer = view.convert(event.locationInWindow, from: nil)
    let page = view.page(for: pointer, nearest: true) ?? view.currentPage
    let anchor = page.map { view.convert(pointer, to: $0) }
    let speed = event.hasPreciseScrollingDeltas ? 0.003 : 0.1
    let factor = exp(min(0.4, max(-0.4, Double(delta) * speed)))
    view.autoScales = false
    view.scaleFactor = CGFloat(min(Self.maxZoom, max(Self.minZoom, Double(view.scaleFactor) * factor)))
    view.layoutSubtreeIfNeeded()
    if let page, let anchor, let documentView = view.documentView,
      let scroll = documentView.enclosingScrollView {
      let mapped = view.convert(anchor, from: page)
      let clip = scroll.contentView
      let desired = clip.convert(pointer, from: view)
      let actual = clip.convert(mapped, from: view)
      var bounds = clip.bounds
      bounds.origin.x += actual.x - desired.x
      bounds.origin.y += actual.y - desired.y
      clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
      scroll.reflectScrolledClipView(clip)
    }
    refresh()
    return true
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
    if tool != .imageEdit { graphicEditRefusal = nil }
    if tool != .textEdit { textEditRefusal = nil }
    // Text and graphic objects are selected through different native layers.
    // Keep one active selection so a tool switch cannot leave a stale object
    // highlighted behind the new inspector.
    switch tool {
    case .textEdit:
      clearGraphicSelection()
      refreshSelectionSummary()
    case .addText, .imageEdit:
      view.clearSelection()
      refreshSelectionSummary()
      if tool == .addText { clearGraphicSelection() }
    case .select, .annotate, .page:
      break
    }
    activeTool = tool
    return true
  }

  /// P12-024: refresh the selection summary from the view's current
  /// selection (page number plus bounded text).
  public func refreshSelectionSummary() {
    let text = (view.currentSelection?.string ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      // PDFKit posts selection changes asynchronously. If clearing its text
      // selection was part of selecting a graphic, keep the graphic summary.
      guard selectedGraphics.isEmpty, graphicEditRefusal == nil,
        textEditRefusal == nil else { return }
      selectedObjectSummary = nil
      selectionDetails = nil
      return
    }
    // A new native text selection replaces an earlier graphic selection.
    // This keeps the contextual inspector and canvas highlight in agreement.
    if !selectedGraphics.isEmpty { selectedGraphics = [] }
    graphicEditRefusal = nil
    textEditRefusal = nil
    guard let document = view.document,
      let selection = view.currentSelection,
      let page = selection.pages.first else {
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
        ? nil
        : [
          Double(box.origin.x), Double(box.origin.y),
          Double(box.maxX), Double(box.maxY),
        ])
  }

  /// P12-017: replace the graphics selection and publish its summary for
  /// the inspector and VoiceOver. An empty selection clears the summary
  /// only when no text selection is active, so the two never fight.
  public func selectGraphics(_ targets: [AddedGraphicTarget]) {
    // A shared transform belongs to a single page. Deduplicate identities so
    // keyboard and inspector actions never transform the same stream twice.
    var seen = Set<String>()
    let targets = targets.filter {
      $0.pageIndex == targets.first?.pageIndex && $0.rect.count == 4
        && $0.rect.allSatisfy(\.isFinite) && $0.rect[2] > $0.rect[0] && $0.rect[3] > $0.rect[1]
        && seen.insert($0.identity).inserted
    }
    selectedGraphics = targets
    graphicEditRefusal = nil
    textEditRefusal = nil
    if !targets.isEmpty {
      // Graphic selection takes ownership from PDFKit text/search selection.
      // Publish the graphic details after clearing the native highlight.
      view.clearSelection()
    }
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

  /// Page-object traversal is available only in an explicit editing mode.
  /// The menu commands are then usable through keyboard navigation and
  /// assistive technology without stealing Tab from normal window controls.
  public var canSelectAdjacentPageObject: Bool {
    guard allowsContentEditing, !isLocked, !isEditingPageText,
      (view.document?.pageCount ?? 0) > 0
    else { return false }
    switch activeTool {
    case .textEdit: return textTargetsProvider != nil
    case .imageEdit: return graphicsListProvider != nil
    default: return false
    }
  }

  /// Whether the active text block selected in Edit PDF can be opened directly
  /// for typing without requiring another pointer click.
  public var canEditSelectedPageText: Bool {
    guard activeTool == .textEdit, canSelectAdjacentPageObject,
      textBlockEditStarter != nil, let page = view.currentPage,
      let document = view.document
    else { return false }
    let pageIndex = document.index(for: page)
    guard pageIndex >= 0 else { return false }
    let targets = (textTargetsProvider?(pageIndex) ?? []).filter { isValidTextTarget($0) }
    return selectedTextTarget(from: targets, on: page) != nil
  }

  /// Start typing in the currently selected text block. This action is
  /// exposed to assistive technology alongside page-object traversal.
  @discardableResult
  public func editSelectedPageText() -> Bool {
    guard canEditSelectedPageText, let page = view.currentPage,
      let document = view.document
    else { return false }
    let pageIndex = document.index(for: page)
    guard pageIndex >= 0,
      let target = selectedTextTarget(
        from: (textTargetsProvider?(pageIndex) ?? []).filter { isValidTextTarget($0) },
        on: page),
      let textBlockEditStarter
    else { return false }
    textBlockEditStarter(target)
    return isEditingPageText && isTypingPageText
  }

  private func isValidTextTarget(_ target: PageTextTarget) -> Bool {
    target.rect.count == 4 && target.rect.allSatisfy(\.isFinite)
      && target.rect[2] >= target.rect[0] && target.rect[3] > target.rect[1]
  }

  private func selectedTextTarget(
    from targets: [PageTextTarget], on page: PDFPage
  ) -> PageTextTarget? {
    guard let selection = view.currentSelection,
      selection.pages.contains(where: { $0 === page })
    else { return nil }
    let bounds = selection.bounds(for: page)
    let intersections = targets.map { target -> (PageTextTarget, CGFloat) in
      let overlap = bounds.intersection(pageRect(target.rect))
      let area = overlap.isNull ? 0 : max(0, overlap.width) * max(0, overlap.height)
      return (target, area)
    }
    guard let best = intersections.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
    return best.0
  }

  /// Select the next or previous editable text block or supported graphic on
  /// the visible page. The active Edit PDF / Images tool determines the kind.
  @discardableResult
  public func selectAdjacentPageObject(reverse: Bool = false) -> Bool {
    guard canSelectAdjacentPageObject, let page = view.currentPage,
      let document = view.document
    else { return false }
    let pageIndex = document.index(for: page)
    guard pageIndex >= 0 else { return false }

    switch activeTool {
    case .textEdit:
      let targets = (textTargetsProvider?(pageIndex) ?? []).filter { isValidTextTarget($0) }
      let ordered = targets.sorted { visuallyPrecedes($0.rect, $1.rect, on: page) }
      guard !ordered.isEmpty else { return false }
      let selectedTarget = selectedTextTarget(from: ordered, on: page)
      let selectedIndex = selectedTarget.flatMap { ordered.firstIndex(of: $0) }
      let next = adjacentIndex(count: ordered.count, current: selectedIndex, reverse: reverse)
      let target = ordered[next]
      var rect = pageRect(target.rect)
      if rect.width < 8 {
        rect.size.width = max(60, Double(target.text.count) * rect.height * 0.55)
      }
      guard let selection = page.selection(for: rect) else { return false }
      clearGraphicSelection()
      view.setCurrentSelection(selection, animate: false)
      view.window?.makeFirstResponder(view)
      refreshSelectionSummary()
      return true

    case .imageEdit:
      let targets = (graphicsListProvider?(pageIndex) ?? []).filter {
        $0.rect.count == 4 && $0.rect.allSatisfy(\.isFinite)
          && $0.rect[2] > $0.rect[0] && $0.rect[3] > $0.rect[1]
      }
      let ordered = targets.sorted { visuallyPrecedes($0.rect, $1.rect, on: page) }
      guard !ordered.isEmpty else { return false }
      let currentIdentity = selectedGraphics.first?.identity
      let currentIndex = currentIdentity.flatMap { identity in
        ordered.firstIndex(where: { $0.identity == identity })
      }
      let next = adjacentIndex(count: ordered.count, current: currentIndex, reverse: reverse)
      selectGraphics([ordered[next]])
      graphicSelectionFocuser?()
      return true

    default:
      return false
    }
  }

  private func adjacentIndex(count: Int, current: Int?, reverse: Bool) -> Int {
    guard count > 0 else { return 0 }
    guard let current else { return reverse ? count - 1 : 0 }
    return (current + (reverse ? count - 1 : 1)) % count
  }

  private func pageRect(_ values: [Double]) -> CGRect {
    CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
  }

  private func visuallyPrecedes(_ lhs: [Double], _ rhs: [Double], on page: PDFPage) -> Bool {
    let a = view.convert(pageRect(lhs), from: page)
    let b = view.convert(pageRect(rhs), from: page)
    let aTop = view.isFlipped ? a.minY : -a.maxY
    let bTop = view.isFlipped ? b.minY : -b.maxY
    if aTop != bTop { return aTop < bTop }
    return a.minX < b.minX
  }

  /// P12-017: drop the graphics selection without touching text selection.
  public func clearGraphicSelection() {
    selectGraphics([])
  }

  public func reportGraphicUnavailable(pageIndex: Int, reason: String) {
    selectedGraphics = []
    textEditRefusal = nil
    graphicEditRefusal = reason
    selectedObjectSummary = "Page \(pageIndex + 1): editing unavailable"
    selectionDetails = SelectionDetails(
      pageNumber: pageIndex + 1, text: reason, bounds: nil)
  }

  public func reportTextEditUnavailable(pageIndex: Int, reason: String) {
    selectedGraphics = []
    graphicEditRefusal = nil
    textEditRefusal = reason
    selectedObjectSummary = "Page \(pageIndex + 1): inline text editing unavailable"
    selectionDetails = SelectionDetails(
      pageNumber: pageIndex + 1, text: reason, bounds: nil)
  }

  public func clearTextEditRefusal() {
    textEditRefusal = nil
  }

  public var selectedGraphicBounds: CGRect? {
    GraphicSelectionModel.union(selectedGraphics.map {
      CGRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2] - $0.rect[0], height: $0.rect[3] - $0.rect[1])
    })
  }

  /// Deleting an existing PDF image is a separate content-removal operation.
  /// The canvas currently exposes geometry editing for those placements.
  public var canDeleteSelectedGraphics: Bool {
    !selectedGraphics.isEmpty && selectedGraphics.allSatisfy { $0.imagePlacementIndex == nil }
  }

  /// Inspector changes and pointer drags share the same atomic group mapping.
  public func setGraphicBounds(_ bounds: CGRect) {
    guard activeTool == .imageEdit, allowsContentEditing, !isLocked,
      let group = selectedGraphicBounds else { return }
    let mappings = graphicResizeMappings(from: group, to: bounds)
    if mappings.count == selectedGraphics.count { onResizeGraphics?(mappings) }
  }

  public func graphicResizeMappings(
    from group: CGRect, to bounds: CGRect
  ) -> [(target: AddedGraphicTarget, dx: Double, dy: Double, scaleX: Double, scaleY: Double)] {
    selectedGraphics.compactMap { target -> (target: AddedGraphicTarget,
      dx: Double, dy: Double, scaleX: Double, scaleY: Double)? in
      let member = CGRect(x: target.rect[0], y: target.rect[1],
        width: target.rect[2] - target.rect[0], height: target.rect[3] - target.rect[1])
      guard let m = GraphicSelectionModel.mapping(member: member, from: group, to: bounds) else { return nil }
      return (target, m.dx, m.dy, m.scaleX, m.scaleY)
    }
  }

  /// Render a proposed object transform into a temporary PDF. The canonical
  /// document and edit session are untouched; this method only gives the
  /// overlay a visible, correctly layered preview until the gesture ends.
  public func previewGraphicTransform(
    _ mappings: [(target: AddedGraphicTarget, dx: Double, dy: Double,
      scaleX: Double, scaleY: Double)]
  ) {
    guard let data = graphicPreviewProvider?(mappings),
      let original = view.document,
      let preview = PDFDocument(data: data)
    else { return }
    if graphicPreviewState == nil {
      graphicPreviewState = (
        document: original, scale: view.scaleFactor, autoScales: view.autoScales,
        page: currentPageIndex, scroll: documentScrollOrigin)
    }
    let state = graphicPreviewState!
    view.document = preview
    view.autoScales = false
    view.scaleFactor = state.scale
    view.layoutDocumentView()
    restoreDocumentScroll(state.scroll)
    if state.page >= 0, state.page < preview.pageCount,
      let page = preview.page(at: state.page) {
      view.go(to: page)
    }
  }

  public func endGraphicPreview() {
    guard let state = graphicPreviewState else { return }
    graphicPreviewState = nil
    view.document = state.document
    view.autoScales = false
    view.scaleFactor = state.scale
    view.layoutDocumentView()
    restoreDocumentScroll(state.scroll)
    if state.page >= 0, let page = state.document.page(at: state.page) {
      view.go(to: page)
    }
    view.autoScales = state.autoScales
  }

  public var isPreviewingGraphic: Bool { graphicPreviewState != nil }

  private var currentPageIndex: Int {
    guard let page = view.currentPage, let document = view.document else { return -1 }
    return document.index(for: page)
  }

  private var documentScrollOrigin: NSPoint? {
    view.documentView?.enclosingScrollView?.contentView.bounds.origin
  }

  private func restoreDocumentScroll(_ origin: NSPoint?) {
    guard let origin,
      let clip = view.documentView?.enclosingScrollView?.contentView
    else { return }
    clip.scroll(to: origin)
    clip.enclosingScrollView?.reflectScrolledClipView(clip)
  }

  public func alignGraphics(_ alignment: PageObjectAlignment) {
    guard let bounds = selectedGraphicBounds, let target = selectedGraphics.first,
      let page = view.document?.page(at: target.pageIndex) else { return }
    let delta = alignment.delta(for: bounds, in: page.bounds(for: view.displayBox))
    setGraphicBounds(bounds.offsetBy(dx: delta.x, dy: delta.y))
  }

  public func deleteSelectedGraphics() {
    guard activeTool == .imageEdit, allowsContentEditing, !isLocked,
      !selectedGraphics.isEmpty else { return }
    onDeleteGraphics?(selectedGraphics)
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
  private var commandScrollMonitor: AnyCancellable?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    commandScrollMonitor = nil
    guard window != nil else { return }
    // PDFKit's internal scroll view consumes wheels before PDFView receives
    // them. Intercept only this window's visible document canvas, so sidebars
    // and property controls keep their own scrolling behavior.
    if let token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
      let consumed = MainActor.assumeIsolated {
        guard let self, let window = self.window, event.window === window,
          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
        return self.session?.handleCommandScroll(event) == true
      }
      return consumed ? nil : event
    }) {
      commandScrollMonitor = AnyCancellable { NSEvent.removeMonitor(token) }
    }
  }

  override func scrollWheel(with event: NSEvent) {
    if session?.handleCommandScroll(event) != true { super.scrollWheel(with: event) }
  }

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
      annotation.type == "Widget"
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
