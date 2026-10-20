import AppKit
import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

@Suite("Viewer navigation and overlay pinning")
struct ViewerNavigationTests {
  @Test @MainActor func commentFocusNavigatesToARegionWithoutText() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.annotationPages()))
    #expect(session.pageNumber == 1)
    session.focus(onPageIndex: 1, rect: [100, 100, 120, 120])
    #expect(session.pageNumber == 2)
    session.focus(onPageIndex: 0, rect: [100, 100, 120, 120])
    #expect(session.pageNumber == 1)
  }

  // MARK: - Overlay anchors (P11-017)

  @Test func overlayAnchorsResolveAndGoStaleWithRevisions() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let anchor = PageOverlayAnchor(
      documentID: id, revision: 1, pageIndex: 0, contentRect: [100, 100, 200, 150])
    let rect = try await service.displayRect(for: anchor)
    #expect(abs(rect.origin.x - 100) < 0.001 && abs(rect.origin.y - 100) < 0.001)
    #expect(abs(rect.width - 100) < 0.001 && abs(rect.height - 50) < 0.001)
    // An edit advances the revision: the old anchor is refused, not silently
    // remapped, and a fresh anchor resolves.
    try await service.setSnapshot(documentID: id, revision: 2, graph: graph)
    await #expect(throws: PageRenderError.self) {
      _ = try await service.displayRect(for: anchor)
    }
    let fresh = PageOverlayAnchor(
      documentID: id, revision: 2, pageIndex: 0, contentRect: [100, 100, 200, 150])
    let resolved = try await service.displayRect(for: fresh)
    #expect(resolved == rect)
    await service.removeSnapshot(documentID: id)
    await #expect(throws: PageRenderError.self) {
      _ = try await service.displayRect(for: fresh)
    }
  }

  @Test func overlayAnchorHonorsRotation() async throws {
    var parsed = try PDFParser.parse(PDFFixtures.onePage())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: parsed.pageIDs, byDegrees: 90)]),
      to: parsed.graph)
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: edited)
    let anchor = PageOverlayAnchor(
      documentID: id, revision: 1, pageIndex: 0, contentRect: [0, 0, 612, 792])
    let rect = try await service.displayRect(for: anchor)
    // A 90-degree rotation swaps the displayed axes.
    #expect(abs(rect.width - 792) < 0.001 && abs(rect.height - 612) < 0.001)
  }

  // MARK: - Zoom controls (P12-004)

  @Test func scaleToFitMath() {
    let fitWidth = PDFViewingSession.scaleToFit(
      displayed: CGSize(width: 612, height: 792),
      available: CGSize(width: 580, height: 1000),
      fitHeight: false, currentScale: 1, minScale: 0.1, maxScale: 8)
    #expect(abs(fitWidth - 580 / 612) < 0.0001)
    let fitPage = PDFViewingSession.scaleToFit(
      displayed: CGSize(width: 612, height: 792),
      available: CGSize(width: 580, height: 400),
      fitHeight: true, currentScale: 1, minScale: 0.1, maxScale: 8)
    #expect(abs(fitPage - 400 / 792) < 0.0001)
    // Degenerate input keeps the current scale; limits clamp the result.
    let degenerate = PDFViewingSession.scaleToFit(
      displayed: .zero, available: CGSize(width: 580, height: 400),
      fitHeight: true, currentScale: 2, minScale: 0.1, maxScale: 8)
    #expect(degenerate == 2)
    let clamped = PDFViewingSession.scaleToFit(
      displayed: CGSize(width: 10, height: 10),
      available: CGSize(width: 10_000, height: 10_000),
      fitHeight: true, currentScale: 1, minScale: 0.1, maxScale: 8)
    #expect(clamped == 8)
  }

  @Test @MainActor func explicitZoomClampsToViewLimits() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.onePage()))
    session.setZoom(100)
    #expect(session.scale == 8)
    session.setZoom(0.0001)
    #expect(session.scale == 0.1)
    session.setZoom(2)
    #expect(session.scale == 2)
  }

  @Test @MainActor func commandWheelZoomsBothWaysWithoutChangingThePageOrEditor() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    session.go(to: 2)
    session.setZoom(1)
    session.isEditingPageText = true
    session.isTypingPageText = true
    session.hasPendingPageTextChanges = true
    func wheel(_ delta: Int32, command: Bool = true, precise: Bool = false) throws -> NSEvent {
      let cg = try #require(CGEvent(scrollWheelEvent2Source: nil,
        units: precise ? .pixel : .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
      cg.flags = command ? .maskCommand : []
      return try #require(NSEvent(cgEvent: cg))
    }
    #expect(!session.handleCommandScroll(try wheel(3, command: false)))
    #expect(session.scale == 1)
    session.view.scrollWheel(with: try wheel(3))
    #expect(session.scale > 1)
    session.view.scrollWheel(with: try wheel(-3))
    #expect(abs(session.scale - 1) < 0.0001)
    #expect(session.handleCommandScroll(try wheel(20, precise: true)))
    #expect(session.scale > 1 && session.scale < 1.2)
    #expect(session.pageNumber == 2)
    #expect(session.isEditingPageText && session.isTypingPageText && session.hasPendingPageTextChanges)
    session.setZoom(8)
    session.view.scrollWheel(with: try wheel(100))
    #expect(session.scale == 8)
    session.setZoom(0.1)
    session.view.scrollWheel(with: try wheel(-100))
    #expect(session.scale == 0.1)
    session.closeDocument()
    #expect(!session.handleCommandScroll(try wheel(3)))
  }

  // MARK: - Labels and history (P12-007, P12-009)

  @Test @MainActor func labelNavigationFindsLabeledAndNumberedPages() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    session.pageLabels = ["i", "ii", "iii"]
    #expect(session.go(toLabel: "II"))
    #expect(session.pageNumber == 2)
    #expect(session.go(toLabel: "  iii  "))
    #expect(session.pageNumber == 3)
    #expect(session.go(toLabel: "1"))
    #expect(session.pageNumber == 1)
    #expect(!session.go(toLabel: "iv"))
    #expect(session.pageNumber == 1)
    #expect(!session.go(toLabel: ""))
  }

  @Test @MainActor func backAndForwardWalkRecordedJumps() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    #expect(!session.canGoBackInHistory && !session.canGoForwardInHistory)
    session.go(to: 3)
    session.go(to: 1)
    #expect(session.canGoBackInHistory && !session.canGoForwardInHistory)
    session.goBack()
    #expect(session.pageNumber == 3)
    #expect(session.canGoBackInHistory && session.canGoForwardInHistory)
    session.goBack()
    #expect(session.pageNumber == 1)
    #expect(!session.canGoBackInHistory && session.canGoForwardInHistory)
    session.goForward()
    #expect(session.pageNumber == 3)
    session.goForward()
    #expect(session.pageNumber == 1)
    #expect(!session.canGoForwardInHistory)
    // A new jump clears the forward trail.
    session.goBack()
    session.go(to: 2)
    #expect(session.pageNumber == 2)
    #expect(!session.canGoForwardInHistory)
    // Label jumps participate in the same history.
    session.pageLabels = ["i", "ii", "iii"]
    session.go(toLabel: "iii")
    session.goBack()
    #expect(session.pageNumber == 2)
  }
}

extension ViewerNavigationTests {
  // MARK: - Zoom preserves the page (P12-005)

  @Test @MainActor func zoomChangesKeepTheCurrentPage() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    session.go(to: 3)
    session.zoomIn()
    #expect(session.pageNumber == 3)
    session.zoomOut()
    #expect(session.pageNumber == 3)
    session.setZoom(2)
    #expect(session.pageNumber == 3)
    session.actualSize()
    #expect(session.pageNumber == 3)
    session.fitPage()
    #expect(session.pageNumber == 3)
    session.fitWidth()
    #expect(session.pageNumber == 3)
  }

  // MARK: - Outline navigation (P12-008)

  @Test @MainActor func outlineEntriesJumpToTheirPages() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    let chapter = PDFOutlineItem(title: "Chapter", pageIndex: 2, children: [])
    let dangling = PDFOutlineItem(title: "Nowhere", pageIndex: nil, children: [])
    #expect(session.go(toOutlineItem: chapter))
    #expect(session.pageNumber == 3)
    #expect(!session.go(toOutlineItem: dangling))
    #expect(session.pageNumber == 3)
    // Outline jumps participate in history.
    session.goBack()
    #expect(session.pageNumber == 1)
  }

  // MARK: - Document states (P12-022)

  @Test @MainActor func documentStateTracksOpenFailureAndClose() throws {
    let session = PDFViewingSession()
    #expect(session.documentState == .empty)
    try session.open(PDFSource(data: PDFFixtures.onePage()))
    #expect(session.documentState == .ready)
    session.closeDocument()
    #expect(session.documentState == .empty)
    #expect(session.pageCount == 0 && session.pageNumber == 0)
    #expect(!session.canGoBackInHistory && !session.canGoForwardInHistory)
    // Headerless input is rejected by the source gate before loading starts.
    do {
      try session.open(PDFSource(data: Data("not a pdf".utf8)))
      Issue.record("opening garbage should throw")
    } catch {
      #expect(session.documentState == .empty)
    }
    // A PDF header PDFKit cannot parse fails the open with a failed state.
    do {
      try session.open(PDFSource(data: Data("%PDF-1.7\n%garbage-without-objects".utf8)))
      Issue.record("unparseable input should throw")
    } catch {
      print("[DEBUG] header-garbage threw, state \(session.documentState)")
      #expect(session.documentState == .failed("Apple's renderer could not open this PDF"))
    }
    // A failed open leaves the previous page counts cleared, not stale.
    #expect(session.pageCount == 0)
  }
}

extension ViewerNavigationTests {
  // MARK: - Tool modes (P12-012, P12-013)

  @Test @MainActor func toolSwitchingFinishesPendingEdits() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.onePage()))
    #expect(session.activeTool == .select)
    #expect(session.activateTool(.textEdit))
    #expect(session.activeTool == .textEdit)
    // Re-selecting the active tool is a no-op that never consults the hook.
    var calls = 0
    session.pendingEditFinisher = {
      calls += 1
      return true
    }
    #expect(session.activateTool(.textEdit))
    #expect(calls == 0)
    // A veto keeps the current tool.
    session.pendingEditFinisher = { false }
    #expect(!session.activateTool(.select))
    #expect(session.activeTool == .textEdit)
    // A finished edit allows the switch.
    var finished = false
    session.pendingEditFinisher = {
      finished = true
      return true
    }
    #expect(session.activateTool(.page))
    #expect(finished)
    #expect(session.activeTool == .page)
    // Without a hook, switching is always free.
    session.pendingEditFinisher = nil
    #expect(session.activateTool(.annotate))
    #expect(session.activeTool == .annotate)
    // Opening a document resets to the neutral tool.
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    #expect(session.activeTool == .select)
  }

  // MARK: - Selection summary (P12-024)

  @Test @MainActor func selectionSummaryFollowsSearchSelection() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    #expect(session.selectedObjectSummary == nil)
    session.searchText = "fixture - page 2"
    session.runSearch()
    #expect(session.searchMatchCount == 1)
    let summary = try #require(session.selectedObjectSummary)
    #expect(summary.contains("Page 2"))
    #expect(summary.contains("fixture - page 2"))
    session.hideSearch()
    #expect(session.selectedObjectSummary == nil)
  }
}

extension ViewerNavigationTests {
  // MARK: - Inspector details and mode mapping (P12-011, P12-020)

  @Test @MainActor func inspectorDetailsFollowSelection() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    #expect(session.selectionDetails == nil)
    session.searchText = "fixture - page 1"
    session.runSearch()
    let details = try #require(session.selectionDetails)
    #expect(details.pageNumber == 1)
    #expect(details.text.contains("fixture - page 1"))
    if let bounds = details.bounds {
      #expect(bounds.count == 4)
      #expect(bounds[2] > bounds[0] && bounds[3] > bounds[1])
    } else {
      Issue.record("expected page-space bounds for a text selection")
    }
    session.hideSearch()
    #expect(session.selectionDetails == nil)
  }

  @Test @MainActor func textAndGraphicSelectionsReplaceEachOtherAcrossToolSwitches() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.onePage()))
    session.searchText = "fixture - page 1"
    session.runSearch()
    #expect(session.selectionDetails?.text.contains("fixture - page 1") == true)

    let image = AddedGraphicTarget(
      pageIndex: 0, streamID: PDFObjectID(100), kind: "Document image",
      rect: [100, 100, 200, 200], imagePlacementIndex: 0)
    session.selectGraphics([image])
    #expect(session.view.currentSelection?.string == nil)
    #expect(session.selectedGraphics == [image])
    #expect(session.selectionDetails?.text == "Document image graphic")

    // A new native text selection supersedes the image selection and updates
    // the inspector instead of leaving stale graphic details behind.
    session.runSearch()
    #expect(session.selectedGraphics.isEmpty)
    #expect(session.selectionDetails?.text.contains("fixture - page 1") == true)

    session.selectGraphics([image])
    #expect(session.activateTool(.imageEdit))
    #expect(session.selectedGraphics == [image])
    #expect(session.view.currentSelection?.string == nil)

    session.pendingEditFinisher = { false }
    #expect(!session.activateTool(.textEdit))
    #expect(session.activeTool == .imageEdit)
    #expect(session.selectedGraphics == [image])

    session.pendingEditFinisher = { true }
    #expect(session.activateTool(.textEdit))
    #expect(session.activeTool == .textEdit)
    #expect(session.selectedGraphics.isEmpty)

    session.runSearch()
    #expect(session.selectionDetails?.text.contains("fixture - page 1") == true)
    #expect(session.activateTool(.imageEdit))
    #expect(session.view.currentSelection?.string == nil)
    #expect(session.selectionDetails == nil)
  }

  @Test func sidebarModesRoundTripThroughStoredNames() {
    for mode in SidebarMode.allCases {
      #expect(SidebarMode(storedName: mode.storedName) == mode)
    }
    #expect(SidebarMode(storedName: "inspector") == .inspector)
    #expect(SidebarMode(storedName: "info") == .info)
    #expect(SidebarMode(storedName: "pages") == .pages)
    #expect(SidebarMode(storedName: "no-such-mode") == nil)
  }

  @Test @MainActor func documentInfoDefaultsToNil() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.onePage()))
    // The app installs info from the core inventory after opening; the
    // session default is nil and the value type round-trips.
    #expect(session.documentInfo == nil)
    let info = ViewerDocumentInfo(
      fileName: "a.pdf", pageCount: 1, title: "T", capabilitySummary: "C")
    session.documentInfo = info
    #expect(session.documentInfo == info)
    #expect(session.documentInfo?.title == "T")
  }
}
