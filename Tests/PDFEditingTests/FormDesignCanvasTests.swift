import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-02 evidence: direct form-design canvas geometry, widget edits with
/// regenerated appearances, guide snapping, tab order and multi-widget
/// selection that commits as one transaction.
@Suite("Form design canvas")
struct FormDesignCanvasTests {
  private let pageBounds: [Double] = [0, 0, 612, 792]

  private func fixture() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    return (parsed.graph, parsed.pageIDs[0])
  }

  private func withTextFields(_ specs: [(name: String, rect: [Double])]) throws
    -> (graph: PDFGraph, pageID: PDFObjectID)
  {
    var (graph, pageID) = try fixture()
    let commands = specs.map { spec in
      AddTextFieldCommand(pageID: pageID, rect: spec.rect, name: spec.name)
    }
    graph = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    return (graph, pageID)
  }

  // MARK: Widget move/resize

  @Test func moveWidgetKeepsFieldAndValueAndRegeneratesAppearance() throws {
    var (graph, pageID) = try fixture()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 600, 272, 624], name: "FullName", defaultValue: "Jane Doe")
      ]), to: graph)
    let before = try FormDesignInventory.widgets(in: graph, pageIDs: [pageID])
    #expect(before.count == 1)
    guard let widget = before.first else { return }
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormWidgetRectCommand(
          fieldName: "FullName", widgetObjectID: widget.widgetObjectID,
          widgetIndex: widget.widgetIndex, rect: [100, 500, 300, 524])
      ]), to: graph)
    let after = try FormDesignInventory.widgets(in: moved, pageIDs: [pageID])
    #expect(after.count == 1)
    #expect(after.first?.rect == [100, 500, 300, 524])
    let fields = try FormInventory.fields(in: moved, pageIDs: [pageID])
    #expect(fields.first?.stringValue == "Jane Doe")
    #expect(fields.first?.widgets.count == 1)
    // The normal appearance was rebuilt at the new size.
    guard let widgetID = after.first?.widgetObjectID,
      case .dictionary(let dictionary)? = moved.objects[widgetID],
      case .dictionary(let appearance)? = dictionary[PDFName("AP")],
      case .reference(let streamID)? = appearance[PDFName("N")],
      case .stream(let stream)? = moved.objects[streamID],
      case .array(let bbox)? = stream.dictionary[PDFName("BBox")]
    else {
      Issue.record("Expected a regenerated normal appearance")
      return
    }
    let bboxNumbers = bbox.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    #expect(bboxNumbers == [0, 0, 200, 24])
  }

  @Test func multilineResizeRewrapsAppearanceAndKeepsValue() throws {
    var (graph, pageID) = try fixture()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 600, 372, 660], name: "Notes", multiline: true,
          defaultValue: "one two three four five six seven eight")
      ]), to: graph)
    guard let widget = try FormDesignInventory.widgets(in: graph, pageIDs: [pageID]).first
    else {
      Issue.record("Expected a widget")
      return
    }
    let resized = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormWidgetRectCommand(
          fieldName: "Notes", widgetObjectID: widget.widgetObjectID,
          widgetIndex: widget.widgetIndex, rect: [72, 600, 172, 660])
      ]), to: graph)
    let fields = try FormInventory.fields(in: resized, pageIDs: [pageID])
    #expect(fields.first?.stringValue == "one two three four five six seven eight")
    #expect(fields.first?.isMultiline == true)
    #expect(try FormDesignInventory.widgets(in: resized, pageIDs: [pageID]).first?.rect
      == [72, 600, 172, 660])
  }

  @Test func moveOutsidePageIsRefusedAndInsideIsClampedAtCanvasLevel() throws {
    let (graph, pageID) = try withTextFields([("Name", [72, 600, 272, 624])])
    guard let widget = try FormDesignInventory.widgets(in: graph, pageIDs: [pageID]).first
    else {
      Issue.record("Expected a widget")
      return
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormWidgetRectCommand(
            fieldName: "Name", widgetObjectID: widget.widgetObjectID,
            widgetIndex: widget.widgetIndex, rect: [-40, 600, 160, 624])
        ]), to: graph)
    }
    let clamped = FormDesignGeometry.clamped([-40, 600, 160, 624], to: pageBounds)
    #expect(clamped == [0, 600, 200, 624])
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormWidgetRectCommand(
            fieldName: "Name", widgetObjectID: widget.widgetObjectID, widgetIndex: 0,
            rect: [72, 600, 74, 602])
        ]), to: graph)
    }
  }

  @Test func tooltipCommandRoundTripsThroughInventory() throws {
    var (graph, pageID) = try withTextFields([("Name", [72, 600, 272, 624])])
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormFieldTooltipCommand(fieldName: "Name", tooltip: "Full name")]),
      to: graph)
    #expect(try FormDesignInventory.widgets(in: graph, pageIDs: [pageID]).first?.label
      == "Full name")
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormFieldTooltipCommand(fieldName: "Name", tooltip: "")]), to: graph)
    #expect(try FormDesignInventory.widgets(in: graph, pageIDs: [pageID]).first?.label == nil)
  }

  // MARK: Geometry and guides

  @Test func snapAlignsEdgesAndCentersToGuides() {
    let guides = FormDesignGeometry.guides(
      pageBounds: pageBounds, widgetRects: [[100, 500, 200, 520], [300, 400, 400, 420]])
    let near = FormDesignGeometry.snap(
      [98, 498, 198, 518], guides: guides, tolerance: 4)
    #expect(near.rect[0] == 100)
    #expect(near.rect[1] == 500)
    #expect(near.verticalGuide == 100)
    #expect(near.horizontalGuide == 500)
    let far = FormDesignGeometry.snap([160, 560, 260, 580], guides: guides, tolerance: 4)
    #expect(far.rect == [160, 560, 260, 580])
    #expect(far.verticalGuide == nil)
  }

  @Test func resizeHandleAnchorsOppositeEdgeAndHonoursMinimum() {
    let rect: [Double] = [100, 100, 200, 150]
    #expect(FormDesignGeometry.resized(rect, handle: .topRight, by: [20, 10])
      == [100, 100, 220, 160])
    #expect(FormDesignGeometry.resized(rect, handle: .left, by: [40, 0])
      == [140, 100, 200, 150])
    // Dragging far past the anchor stops at the minimum size instead of
    // inverting the rectangle.
    #expect(FormDesignGeometry.resized(rect, handle: .right, by: [-500, 0])
      == [100, 100, 106, 150])
  }

  @Test func scaledGroupKeepsRelativePositions() {
    let rects: [[Double]] = [[10, 10, 20, 20], [40, 40, 60, 60]]
    let scaled = FormDesignGeometry.scaled(rects, from: [0, 0, 100, 100], to: [0, 0, 200, 100])
    #expect(scaled[0] == [20, 10, 40, 20])
    #expect(scaled[1] == [80, 40, 120, 60])
  }

  // MARK: Selection

  @Test func marqueeSelectsIntersectingWidgetsAndHitTestPicksTopmost() throws {
    let (graph, pageID) = try withTextFields([
      ("First", [72, 600, 272, 624]), ("Second", [72, 500, 272, 524]),
    ])
    let widgets = try FormDesignInventory.widgets(in: graph, pageIDs: [pageID])
    #expect(widgets.count == 2)
    var selection = FormWidgetSelection()
    selection.selectIntersecting([60, 480, 300, 540], of: widgets)
    #expect(selection.count == 1)
    #expect(selection.widgets.first?.fieldName == "Second")
    let hit = FormWidgetSelection.widget(at: [100, 610], among: widgets)
    #expect(hit?.fieldName == "First")
    #expect(FormWidgetSelection.widget(at: [500, 700], among: widgets) == nil)
  }

  @Test func multiWidgetMoveBuildsOneCommandPerWidget() throws {
    let (graph, pageID) = try withTextFields([
      ("First", [72, 600, 272, 624]), ("Second", [72, 500, 272, 524]),
    ])
    let widgets = try FormDesignInventory.widgets(in: graph, pageIDs: [pageID])
    var selection = FormWidgetSelection()
    for widget in widgets { selection.select(widget) }
    let commands = selection.moveCommands(by: [10, -20])
    #expect(commands.count == 2)
    let moved = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    let after = try FormDesignInventory.widgets(in: moved, pageIDs: [pageID])
    #expect(after.map(\.rect) == [[82, 580, 282, 604], [82, 480, 282, 504]])
  }

  @Test func multiWidgetResizeScalesEachRectProportionally() throws {
    let (graph, pageID) = try withTextFields([
      ("First", [72, 600, 172, 620]), ("Second", [72, 540, 172, 560]),
    ])
    let widgets = try FormDesignInventory.widgets(in: graph, pageIDs: [pageID])
    var selection = FormWidgetSelection()
    for widget in widgets { selection.select(widget) }
    let commands = selection.resizeCommands(handle: .topRight, by: [100, 40])
    let resized = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    let after = try FormDesignInventory.widgets(in: resized, pageIDs: [pageID])
    #expect(after.count == 2)
    #expect(after[0].rect[0] == 72)
    #expect(after[1].rect[3] > 560)
  }

  // MARK: Tab order

  @Test func tabOrderSuggestionFollowsReadingOrderAndValidates() throws {
    var (graph, pageID) = try fixture()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 500, 272, 524], name: "Low"),
        AddTextFieldCommand(pageID: pageID, rect: [300, 700, 500, 724], name: "TopRight"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 700, 272, 724], name: "TopLeft"),
      ]), to: graph)
    let fields = try FormInventory.fields(in: graph, pageIDs: [pageID])
    let suggested = FormTabOrder.suggested(pageIDs: [pageID], fields: fields)
    #expect(suggested == ["TopLeft", "TopRight", "Low"])
    #expect(FormTabOrder.validate(suggested, fields: fields) == nil)
    #expect(FormTabOrder.validate(["TopLeft", "TopLeft", "Low"], fields: fields) != nil)
    #expect(FormTabOrder.validate(["TopLeft"], fields: fields) != nil)
    #expect(FormTabOrder.transaction(order: suggested, fields: fields) != nil)
  }

  // MARK: Drawing new fields

  @Test func radioRectsFitInsideDraggedRow() {
    let rects = FormCanvasAuthoring.radioRects(in: [72, 400, 192, 420], count: 3)
    #expect(rects.count == 3)
    #expect(rects[0][0] == 72)
    #expect(rects[2][2] <= 192 + 0.001)
    #expect(rects.allSatisfy { $0[2] - $0[0] == 20 })
    #expect(rects[0][0] < rects[1][0] && rects[1][0] < rects[2][0])
    #expect(rects.allSatisfy { $0[1] == 400 && $0[3] == 420 })
  }

  @Test func draggedRectNormalizesDirectionAndMinimumSize() {
    #expect(FormCanvasAuthoring.draggedRect(from: [200, 200], to: [100, 150])
      == [100, 150, 200, 200])
    let tiny = FormCanvasAuthoring.draggedRect(from: [100, 100], to: [101, 102])
    #expect(tiny[2] - tiny[0] >= 12)
    #expect(tiny[3] - tiny[1] >= 12)
  }

  @Test func drawnFieldCreatesLabelledFieldInOneCommand() throws {
    let (graph, pageID) = try fixture()
    let buttons = FormCanvasAuthoring.commands(
      kind: .checkbox, pageID: pageID, rect: [72, 500, 90, 518], baseName: "Agree",
      label: "Agree to terms")
    let edited = try PDFEditingEngine.commit(PDFTransaction(buttons), to: graph)
    let fields = try FormInventory.fields(in: edited, pageIDs: [pageID])
    #expect(fields.count == 1)
    #expect(fields.first?.kind == .button)
    let descriptors = try FormDesignInventory.widgets(in: edited, pageIDs: [pageID])
    #expect(descriptors.first?.label == "Agree to terms")
    let radios = FormCanvasAuthoring.commands(
      kind: .radio, pageID: pageID, rect: [300, 500, 420, 520], baseName: "Plan", label: "Plan",
      radioOptionCount: 3)
    let withRadio = try PDFEditingEngine.commit(PDFTransaction(radios), to: edited)
    let radioFields = try FormInventory.fields(in: withRadio, pageIDs: [pageID])
    #expect(radioFields.contains { $0.name == "Plan" && $0.widgets.count == 3 })
  }
}
