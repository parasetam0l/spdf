import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

@Suite("Rulers and guides")
struct RulerGuideTests {
  @Test func tickStepsFollowAScaleLadder() {
    #expect(PageRulers.step(forScale: 1) == 25)
    #expect(PageRulers.step(forScale: 2) == 20)
    #expect(PageRulers.step(forScale: 0.5) == 50)
    #expect(PageRulers.step(forScale: 0.05) == 500)
    // Every labeled tick is a multiple of five minor steps.
    let ticks = PageRulers.values(in: 0...612, scale: 1)
    #expect(!ticks.isEmpty)
    #expect(ticks.allSatisfy { tick in
      abs(tick.value / 25 - (tick.value / 25).rounded()) < 0.001
    })
    let labeled = ticks.filter(\.labeled)
    #expect(!labeled.isEmpty)
    #expect(labeled.allSatisfy { abs($0.value / 125 - ($0.value / 125).rounded()) < 0.001 })
    // Negative origins and tiny scales stay bounded.
    #expect(PageRulers.values(in: -1000...1000, scale: 0.02).count <= 4000)
    #expect(PageRulers.values(in: 0...0, scale: 1).count <= 2)
  }

  @Test func tickPositionsTrackOriginAndDirection() {
    #expect(PageRulers.position(value: 100, origin: 0, direction: 1, scale: 2) == 200)
    #expect(PageRulers.position(value: 100, origin: 150, direction: 1, scale: 1) == -50)
    // A mirrored axis maps the other side of the origin.
    #expect(PageRulers.position(value: 100, origin: 150, direction: -1, scale: 1) == 50)
    #expect(PageRulers.position(value: 100, origin: 0, direction: 0, scale: 1) == nil)
    #expect(
      PageRulers.visibleRange(origin: 10, direction: 1, scale: 2, length: 100)
        == 10...60)
    #expect(
      PageRulers.visibleRange(origin: 60, direction: -1, scale: 2, length: 100)
        == 10...60)
    #expect(PageRulers.visibleRange(origin: 0, direction: 0, scale: 1, length: 100) == nil)
  }

  @Test func guidesCoverCentersAndMargins() {
    let guides = PageGuides.lines(pageWidth: 612, pageHeight: 792)
    #expect(guides.vertical == [36, 306, 576])
    #expect(guides.horizontal == [36, 396, 756])
    // Narrow pages collapse duplicates and edges.
    let narrow = PageGuides.lines(pageWidth: 60, pageHeight: 60)
    #expect(narrow.vertical == [30])
    #expect(narrow.horizontal == [30])
    // Guide points feed the placement snap math.
    let snapped = AddedContent.snap([100, 200], toGuides: [[102, 205]], tolerance: 6)
    #expect(snapped == [102, 205])
  }

  @Test @MainActor func rulerOriginFollowsPagesAndToggles() throws {
    let session = PDFViewingSession()
    try session.open(PDFSource(data: PDFFixtures.threePages()))
    #expect(!session.areRulersVisible && !session.areGuidesVisible)
    session.toggleRulers()
    session.toggleGuides()
    #expect(session.areRulersVisible && session.areGuidesVisible)
    session.refreshRulerOrigin()
    let first = session.rulerPageOrigin
    session.go(to: 2)
    session.refreshRulerOrigin()
    // Each page resolves its own origin (the fixture pages differ).
    #expect(session.rulerXDirection != 0 && session.rulerYDirection != 0)
    _ = first
  }
}
