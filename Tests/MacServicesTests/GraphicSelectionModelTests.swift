import CoreGraphics
import Foundation
import MacServices
import Testing

/// P12-017 evidence: resize-handle layout, readable hit targets, rubber-band
/// intersection, and handle-to-command mappings for graphics selection. All
/// math is in one shared space; the overlay converts before calling in.
@Suite("Graphic selection model")
struct GraphicSelectionModelTests {
  @Test func groupResizePreservesRelativePositionsAndSharedScale() throws {
    let first = CGRect(x: 10, y: 20, width: 40, height: 30)
    let second = CGRect(x: 80, y: 70, width: 30, height: 10)
    let group = try #require(GraphicSelectionModel.union([first, second]))
    let destination = CGRect(x: 50, y: 60, width: 200, height: 90)
    let a = try #require(GraphicSelectionModel.mapping(member: first, from: group, to: destination))
    let b = try #require(GraphicSelectionModel.mapping(member: second, from: group, to: destination))
    #expect(a.dx == 40 && a.dy == 40 && a.scaleX == 2 && a.scaleY == 1.5)
    #expect(b.dx == 110 && b.dy == 65 && b.scaleX == 2 && b.scaleY == 1.5)
    #expect((second.minX + b.dx) - (first.minX + a.dx + first.width * a.scaleX) == 60)
    #expect(GraphicSelectionModel.mapping(member: first, from: group, to: .zero) == nil)
    #expect(GraphicSelectionModel.union([CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)]) == nil)
  }

  @Test func pageAlignmentRespectsCropOriginAndObjectExtent() {
    let page = CGRect(x: 30, y: 50, width: 600, height: 800)
    let object = CGRect(x: 100, y: 200, width: 140, height: 60)
    #expect(PageObjectAlignment.left.delta(for: object, in: page) == CGPoint(x: -70, y: 0))
    #expect(PageObjectAlignment.center.delta(for: object, in: page) == CGPoint(x: 160, y: 0))
    #expect(PageObjectAlignment.right.delta(for: object, in: page) == CGPoint(x: 390, y: 0))
    #expect(PageObjectAlignment.top.delta(for: object, in: page) == CGPoint(x: 0, y: 590))
    #expect(PageObjectAlignment.middle.delta(for: object, in: page) == CGPoint(x: 0, y: 220))
    #expect(PageObjectAlignment.bottom.delta(for: object, in: page) == CGPoint(x: 0, y: -150))
  }
  @Test func eightHandlesCoverCornersAndEdges() {
    let bounds = CGRect(x: 10, y: 20, width: 100, height: 60)
    let centers = GraphicSelectionModel.handleCenters(bounds: bounds)
    #expect(centers.count == 8)
    #expect(centers.map(\.0) == GraphicHandle.allCases)
    let lookup = Dictionary(uniqueKeysWithValues: centers)
    #expect(lookup[.northWest] == CGPoint(x: 10, y: 80))
    #expect(lookup[.north] == CGPoint(x: 60, y: 80))
    #expect(lookup[.northEast] == CGPoint(x: 110, y: 80))
    #expect(lookup[.east] == CGPoint(x: 110, y: 50))
    #expect(lookup[.southEast] == CGPoint(x: 110, y: 20))
    #expect(lookup[.south] == CGPoint(x: 60, y: 20))
    #expect(lookup[.southWest] == CGPoint(x: 10, y: 20))
    #expect(lookup[.west] == CGPoint(x: 10, y: 50))
  }

  @Test func handleHitTargetsStayReadable() {
    // Visuals stay compact while hit areas grow past them.
    #expect(GraphicSelectionModel.handleVisualSize == 12)
    #expect(GraphicSelectionModel.handleHitSize == 24)
    #expect(GraphicSelectionModel.handleHitSize >= GraphicSelectionModel.handleVisualSize)
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
    // 12 pt from a corner center (the slop radius) still grabs the handle.
    #expect(
      GraphicSelectionModel.handle(at: CGPoint(x: 12, y: 188), selection: bounds)
        == .northWest)
    // Past the slop, the same ray misses every handle.
    #expect(
      GraphicSelectionModel.handle(at: CGPoint(x: 12.5, y: 187.5), selection: bounds)
        == nil)
    // Mid-edge handles resolve on their own axis.
    #expect(
      GraphicSelectionModel.handle(at: CGPoint(x: 100, y: 205), selection: bounds)
        == .north)
    #expect(
      GraphicSelectionModel.handle(at: CGPoint(x: 195, y: 100), selection: bounds)
        == .east)
    // The empty middle hits no handle (the body owns it).
    #expect(
      GraphicSelectionModel.handle(at: CGPoint(x: 100, y: 100), selection: bounds)
        == nil)
    #expect(GraphicSelectionModel.bodyContains(CGPoint(x: 100, y: 100), selection: bounds))
    #expect(!GraphicSelectionModel.bodyContains(CGPoint(x: 250, y: 100), selection: bounds))
  }

  @Test func rubberBandSelectsIntersectingCandidates() {
    let candidates = [
      CGRect(x: 0, y: 0, width: 50, height: 50),
      CGRect(x: 100, y: 100, width: 50, height: 50),
      CGRect(x: 200, y: 200, width: 50, height: 50),
    ]
    // A click-sized rect never multi-selects.
    #expect(
      GraphicSelectionModel.rubberBandSelect(
        rect: CGRect(x: 10, y: 10, width: 1, height: 1), candidates: candidates).isEmpty)
    // Touching the first two selects both, in content order.
    #expect(
      GraphicSelectionModel.rubberBandSelect(
        rect: CGRect(x: 10, y: 10, width: 120, height: 120), candidates: candidates)
        == [0, 1])
    // Direction does not matter: dragging up-left normalizes.
    #expect(
      GraphicSelectionModel.rubberBandSelect(
        rect: CGRect(x: 130, y: 130, width: -120, height: -120), candidates: candidates)
        == [0, 1])
    // Missing everything selects nothing.
    #expect(
      GraphicSelectionModel.rubberBandSelect(
        rect: CGRect(x: 300, y: 300, width: 40, height: 40), candidates: candidates).isEmpty)
  }

  @Test func cornerDragsScaleAboutTheGraphicOrigin() {
    let start = CGRect(x: 10, y: 20, width: 100, height: 60)
    // South-east to double size: the width doubles rightward, the height
    // doubles downward (the south edge moves the origin).
    let doubled = try? #require(
      GraphicSelectionModel.resize(
        handle: .southEast, startBounds: start, current: CGPoint(x: 210, y: -40)))
    #expect(doubled?.dx == 0)
    #expect(doubled?.dy == -60)
    #expect(doubled?.scaleX == 2)
    #expect(doubled?.scaleY == 2)
    // West edge inward: the origin moves right and the width halves.
    let halved = try? #require(
      GraphicSelectionModel.resize(
        handle: .west, startBounds: start, current: CGPoint(x: 60, y: 50)))
    #expect(halved?.dx == 50)
    #expect(halved?.dy == 0)
    #expect(halved?.scaleX == 0.5)
    #expect(halved?.scaleY == 1)
    // North edge upward grows the height without moving the origin.
    let taller = try? #require(
      GraphicSelectionModel.resize(
        handle: .north, startBounds: start, current: CGPoint(x: 60, y: 140)))
    #expect(taller?.dx == 0)
    #expect(taller?.dy == 0)
    #expect(taller?.scaleX == 1)
    #expect(taller?.scaleY == 2)
  }

  @Test func uniformCornersKeepAspectAndClampSafely() {
    let start = CGRect(x: 0, y: 0, width: 100, height: 50)
    // A non-uniform corner drag with Shift constrains to the dominant axis.
    let uniformed = try? #require(
      GraphicSelectionModel.resize(
        handle: .southEast, startBounds: start, current: CGPoint(x: 150, y: 10),
        uniform: true))
    #expect(uniformed?.scaleX == uniformed?.scaleY)
    #expect(uniformed?.scaleX == 1.5)
    // Dragging past the opposite edge clamps to a 1-point extent instead of
    // flipping or producing a non-positive scale the command must refuse.
    let clamped = try? #require(
      GraphicSelectionModel.resize(
        handle: .east, startBounds: start, current: CGPoint(x: -500, y: 25)))
    #expect(clamped?.scaleX == 0.01)
    #expect(clamped?.dx == 0)
    // Degenerate and non-finite inputs refuse instead of mapping.
    #expect(
      GraphicSelectionModel.resize(
        handle: .southEast, startBounds: .zero, current: CGPoint(x: 10, y: 10))
        == nil)
    #expect(
      GraphicSelectionModel.resize(
        handle: .southEast, startBounds: start,
        current: CGPoint(x: CGFloat.infinity, y: 10)) == nil)
  }
}
