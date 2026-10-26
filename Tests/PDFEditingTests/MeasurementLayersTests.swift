import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// SPC-02: calibrated distance/perimeter/area measurements, snapping, supported
/// geographic metadata, and measurement annotation round-trips.
@Suite("Calibrated measurements and geospatial (SPC-02)")
struct MeasurementCalibrationTests {
  @Test func definedUnitAndRatioConversions() throws {
    let mmPerPoint = 25.4 / 72.0
    let mm = try MeasurementCalibration(
      unitsPerPoint: mmPerPoint, unit: .millimeter)
    let distance = try MeasurementCalculator.measure(
      .distance(from: [0, 0], to: [100, 0]), calibration: mm)
    #expect(abs(distance.value - 100 * mmPerPoint) < 1e-9)
    #expect(distance.unitLabel == "mm")
    let area = try MeasurementCalculator.measure(
      .area(points: [[0, 0], [100, 0], [100, 50], [0, 50]]), calibration: mm)
    #expect(abs(area.value - 5_000 * mmPerPoint * mmPerPoint) < 1e-9)
    #expect(area.unitLabel == "mm2")
    #expect(abs(area.formatted.count > 0 ? 1 : 0) == 1)
    let perimeter = try MeasurementCalculator.measure(
      .perimeter(points: [[0, 0], [3, 0], [3, 4]]), calibration: mm)
    #expect(abs(perimeter.value - 12 * mmPerPoint) < 1e-9)
    // 1:100 in millimeters: one page point is 100 physical points in mm.
    let ratio = try MeasurementCalibration.ratio(100, unit: .millimeter)
    #expect(abs(ratio.unitsPerPoint - 100 * mmPerPoint) < 1e-9)
    // 72 points at one inch per 72 points is exactly one inch.
    let inch = try MeasurementCalibration(unitsPerPoint: 1.0 / 72.0, unit: .inch)
    #expect(
      abs(try MeasurementCalculator.measure(
        .distance(from: [0, 0], to: [72, 0]), calibration: inch).value - 1) < 1e-9)
    #expect(MeasurementUnit.point.metersPerUnit == 0.0254 / 72)
    #expect(MeasurementUnit.nauticalMile.metersPerUnit == 1_852)
  }

  @Test func invalidCalibrationsAndGeometryAreRefused() {
    #expect(throws: PDFError.self) {
      _ = try MeasurementCalibration(unitsPerPoint: 0, unit: .millimeter)
    }
    #expect(throws: PDFError.self) {
      _ = try MeasurementCalibration(unitsPerPoint: .infinity, unit: .point)
    }
    #expect(throws: PDFError.self) {
      _ = try MeasurementCalculator.measure(
        .area(points: [[0, 0], [1, 1]]), calibration: .uncalibratedPoints)
    }
    #expect(throws: PDFError.self) {
      _ = try MeasurementCalibration.ratio(0, unit: .inch)
    }
  }

  @Test func pdfMeasureRatioSyntaxesAreParsedOnlyWhenSupported() throws {
    let mm = try #require(
      MeasurementCalibration.fromPDFMeasureDictionary([
        PDFName("R"): .string(Data("1:100".utf8)),
        PDFName("X"): .string(Data("mm".utf8)),
        PDFName("D"): .array([.integer(3)]),
      ]))
    #expect(mm.source == .pdfMeasureDictionary)
    #expect(abs(mm.unitsPerPoint - 100 * 25.4 / 72.0) < 1e-9)
    #expect(mm.displayPrecision == 3)
    let imperial = try #require(
      MeasurementCalibration.fromPDFMeasureDictionary([
        PDFName("R"): .string(Data("1 in = 10 ft".utf8)),
        PDFName("X"): .string(Data("ft".utf8)),
      ]))
    #expect(abs(imperial.unitsPerPoint - 10.0 / 72.0) < 1e-9)
    #expect(
      MeasurementCalibration.fromPDFMeasureDictionary([
        PDFName("R"): .string(Data("nonsense".utf8))
      ]) == nil)
    #expect(
      MeasurementCalibration.fromPDFMeasureDictionary([
        PDFName("R"): .array([.integer(1)])
      ]) == nil)
  }

  @Test func snappingAndClampingUseDeclaredTolerance() {
    let anchors = [
      MeasurementAnchor(point: [10, 10], label: "corner"),
      MeasurementAnchor(point: [100, 100], label: "far"),
    ]
    let near = MeasurementSnapping.snap([12, 11], to: anchors, tolerance: 6)
    #expect(near.didSnap)
    #expect(near.anchor?.label == "corner")
    #expect(near.point == [10, 10])
    let far = MeasurementSnapping.snap([50, 50], to: anchors, tolerance: 6)
    #expect(!far.didSnap)
    #expect(far.point == [50, 50])
    #expect(MeasurementSnapping.clamp([-5, 200], to: [0, 0, 100, 100]) == [0, 100])
  }

  @Test func distanceAnnotationRoundTrips() throws {
    let base = try PDFParser.parse(PDFFixtures.onePage())
    let calibration = try MeasurementCalibration(
      unitsPerPoint: 25.4 / 72.0, unit: .millimeter)
    let command = AddMeasurementAnnotationCommand(
      pageID: base.pageIDs[0],
      shape: .distance(from: [100, 100], to: [200, 100]),
      calibration: calibration, contents: "Door width")
    var graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: base.graph)
    let report = try MeasurementAnnotationInventory.inventory(
      in: graph, pageIDs: base.pageIDs)
    #expect(report.issues.isEmpty)
    let measurement = try #require(report.measurements.first)
    #expect(measurement.kind == .distance)
    #expect(measurement.annotation.subtype == PDFName("Line"))
    #expect(measurement.annotation.dictionary[PDFName("Measure")] != nil)
    #expect(measurement.contents == "Door width")
    #expect(abs(measurement.result.value - 100 * 25.4 / 72.0) < 1e-9)
    // Save/reparse: the annotation and its calibration survive exactly.
    let data = try PDFWriter.write(graph)
    let reparsed = try PDFParser.parse(data)
    let roundTripped = try MeasurementAnnotationInventory.inventory(
      in: reparsed.graph, pageIDs: reparsed.pageIDs)
    let copy = try #require(roundTripped.measurements.first)
    #expect(copy.kind == .distance)
    #expect(copy.annotation.subtype == PDFName("Line"))
    #expect(abs(copy.calibration.unitsPerPoint - calibration.unitsPerPoint) < 1e-12)
    #expect(abs(copy.result.value - measurement.result.value) < 1e-9)
    graph = reparsed.graph
    #expect(graph.objects.count > 0)
  }

  @Test func perimeterAndAreaAnnotationsRoundTripWithoutTouchingOtherAnnotations() throws {
    let base = try PDFParser.parse(PDFFixtures.onePage())
    let highlight = AddHighlightCommand(
      pageID: base.pageIDs[0],
      quads: [10, 10, 100, 10, 10, 30, 100, 30])
    var graph = try PDFEditingEngine.commit(
      PDFTransaction([highlight]), to: base.graph)
    let annotationCountBefore = try AnnotationInventory.annotations(
      in: graph, pageID: base.pageIDs[0]).count
    let calibration = MeasurementCalibration.uncalibratedPoints
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddMeasurementAnnotationCommand(
          pageID: base.pageIDs[0],
          shape: .perimeter(points: [[0, 0], [30, 0], [30, 40]]),
          calibration: calibration),
        AddMeasurementAnnotationCommand(
          pageID: base.pageIDs[0],
          shape: .area(points: [[0, 0], [40, 0], [40, 30], [0, 30]]),
          calibration: calibration),
      ]), to: graph)
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: base.pageIDs[0])
    #expect(annotations.count == annotationCountBefore + 2)
    #expect(annotations.contains { $0.subtype == PDFName("Highlight") })
    let inventory = try MeasurementAnnotationInventory.inventory(
      in: graph, pageIDs: base.pageIDs)
    #expect(inventory.measurements.count == 2)
    let perimeter = try #require(inventory.measurements.first { $0.kind == .perimeter })
    #expect(abs(perimeter.result.value - 120) < 1e-9)
    let area = try #require(inventory.measurements.first { $0.kind == .area })
    #expect(abs(area.result.value - 1_200) < 1e-9)
    let reparsed = try PDFParser.parse(try PDFWriter.write(graph))
    let copy = try MeasurementAnnotationInventory.inventory(
      in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(copy.measurements.count == 2)
    #expect(copy.issues.isEmpty)
  }

  @Test func pageMeasureDictionaryResolvesCalibrationAndUserUnit() throws {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(4): .stream(PDFStream(bytes: Data("0 0 m 10 10 l S".utf8))),
    ]
    objects[PDFObjectID(3)] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("UserUnit"): .real(2),
      PDFName("Contents"): .reference(PDFObjectID(4)),
      PDFName("Measure"): .dictionary([
        PDFName("R"): .string(Data("1:100".utf8)),
        PDFName("X"): .string(Data("mm".utf8)),
      ]),
    ])
    let graph = PDFGraph(version: "1.7", objects: objects, trailer: [
      PDFName("Root"): .reference(PDFObjectID(1))
    ])
    let calibration = try #require(
      MeasurementCalibration.resolve(pageID: PDFObjectID(3), graph: graph))
    #expect(calibration.source == .pdfMeasureDictionary)
    #expect(abs(calibration.unitsPerPoint - 2 * 100 * 25.4 / 72.0) < 1e-9)
    let noMeasureGraph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(100), .integer(100),
          ]),
        ]),
      ], trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    #expect(MeasurementCalibration.resolve(pageID: PDFObjectID(3), graph: noMeasureGraph) == nil)
  }

  @Test func geospatialMetadataMapsKnownCoordinates() throws {
    let geo: [PDFName: PDFValue] = [
      PDFName("GEO"): .dictionary([
        PDFName("GPTS"): .array([
          .real(40.0), .real(29.0),
          .real(40.001), .real(29.0),
          .real(40.0), .real(29.001),
        ]),
        PDFName("LPTS"): .array([
          .integer(0), .integer(0),
          .integer(100), .integer(0),
          .integer(0), .integer(100),
        ]),
      ])
    ]
    let objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(100), .integer(100),
        ]),
        PDFName("VP"): .array([
          .dictionary([
            PDFName("Type"): .name(PDFName("Viewport")),
            PDFName("BBox"): .array([
              .integer(0), .integer(0), .integer(100), .integer(100),
            ]),
            PDFName("Measure"): .dictionary(geo),
          ])
        ]),
      ]),
    ]
    let graph = PDFGraph(version: "1.7", objects: objects, trailer: [
      PDFName("Root"): .reference(PDFObjectID(1))
    ])
    let inspection = try #require(
      GeospatialInspectionService.inspect(
        pageID: PDFObjectID(3), pageIndex: 0, graph: graph))
    let origin = try #require(inspection.coordinate(forPagePoint: [0, 0]))
    #expect(abs(origin.latitude - 40.0) < 1e-6)
    #expect(abs(origin.longitude - 29.0) < 1e-6)
    let east = try #require(inspection.coordinate(forPagePoint: [50, 0]))
    #expect(abs(east.latitude - 40.0005) < 1e-6)
    #expect(abs(east.longitude - 29.0) < 1e-6)
    #expect(inspection.report.contains("no projection or datum conversion"))
    // Missing GEO evidence is nil, never a guessed coordinate.
    let noGeo: [PDFName: PDFValue] = [
      PDFName("GEO"): .dictionary([PDFName("GPTS"): .array([.real(1), .real(2)])])
    ]
    #expect(GeospatialReference.from(measureDictionary: noGeo) == nil)
  }
}

/// SPC-03: audited layer inventory and supported authoring: naming, defaults,
/// flat order, membership marking, print/view states and definition merge.
@Suite("Optional content layer authoring (SPC-03)")
struct OptionalContentAuthoringTests {
  struct Fixture {
    let graph: PDFGraph
    let pageID: PDFObjectID
    let layerA: PDFObjectID
    let layerB: PDFObjectID
  }

  private func layeredGraph() -> Fixture {
    let layerA = PDFObjectID(10)
    let layerB = PDFObjectID(11)
    let annotation = PDFObjectID(7)
    let pageID = PDFObjectID(4)
    let content = PDFObjectID(3)
    let objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("OCProperties"): .dictionary([
          PDFName("OCGs"): .array([.reference(layerA), .reference(layerB)]),
          PDFName("D"): .dictionary([
            PDFName("ON"): .array([.reference(layerA)]),
            PDFName("OFF"): .array([.reference(layerB)]),
            PDFName("Order"): .array([.reference(layerA), .reference(layerB)]),
          ]),
        ]),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(pageID)]),
      ]),
      content: .stream(
        PDFStream(bytes: Data("/OC /A BDC\n0 0 10 10 re f\nEMC\n".utf8))),
      pageID: .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(200), .integer(200),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Properties"): .dictionary([
            PDFName("A"): .reference(layerA)
          ])
        ]),
        PDFName("Contents"): .reference(content),
        PDFName("Annots"): .array([.reference(annotation)]),
      ]),
      annotation: .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Square")),
        PDFName("Rect"): .array([
          .integer(10), .integer(10), .integer(30), .integer(30),
        ]),
        PDFName("OC"): .reference(layerB),
      ]),
      layerA: .dictionary([
        PDFName("Type"): .name(PDFName("OCG")),
        PDFName("Name"): .string(Data("Layer A".utf8)),
        PDFName("Usage"): .dictionary([
          PDFName("Print"): .dictionary([PDFName("PrintState"): .name(PDFName("ON"))])
        ]),
      ]),
      layerB: .dictionary([
        PDFName("Type"): .name(PDFName("OCG")),
        PDFName("Name"): .string(Data("Layer B".utf8)),
        PDFName("Usage"): .dictionary([
          PDFName("Print"): .dictionary([PDFName("PrintState"): .name(PDFName("OFF"))])
        ]),
      ]),
    ]
    return Fixture(
      graph: PDFGraph(version: "1.7", objects: objects, trailer: [
        PDFName("Root"): .reference(PDFObjectID(1))
      ]), pageID: pageID, layerA: layerA, layerB: layerB)
  }

  @Test func inventoryAuditsDefaultsOrderMembershipAndUsage() {
    let fixture = layeredGraph()
    let inventory = OptionalContentInventory.inspect(in: fixture.graph)
    #expect(inventory.layers.count == 2)
    let a = inventory.layer(fixture.layerA)
    #expect(a?.name == "Layer A")
    #expect(a?.defaultVisible == true)
    #expect(a?.printState == .on)
    #expect(a?.orderIndex == 0)
    #expect(a?.membershipCount == 1)
    let b = inventory.layer(fixture.layerB)
    #expect(b?.defaultVisible == false)
    #expect(b?.printState == .off)
    #expect(b?.orderIndex == 1)
    #expect(b?.annotationCount == 1)
    #expect(inventory.issues.isEmpty)
    let audit = OptionalContentAuditService.audit(in: fixture.graph)
    #expect(audit.report.contains("Layer A"))
    #expect(audit.report.contains("Supported profile: flat /Order"))
    #expect(audit.report.contains("composite"))
  }

  @Test func renameLayerPreservesOtherLayersAndRefusesDuplicates() throws {
    let fixture = layeredGraph()
    var graph = try PDFEditingEngine.commit(
      PDFTransaction([
        RenameLayerCommand(layerID: fixture.layerA, name: "Base map")
      ]), to: fixture.graph)
    let inventory = OptionalContentInventory.inspect(in: graph)
    #expect(inventory.layer(fixture.layerA)?.name == "Base map")
    #expect(inventory.layer(fixture.layerB)?.name == "Layer B")
    #expect(
      inventory.layer(fixture.layerB)?.printState == .off)
    #expect(throws: PDFError.self) {
      try RenameLayerCommand(layerID: fixture.layerA, name: "Layer B")
        .validate(in: graph)
    }
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        RenameLayerCommand(layerID: fixture.layerB, name: "Notes")
      ]), to: graph)
    #expect(OptionalContentInventory.inspect(in: graph).layer(fixture.layerB)?.name == "Notes")
  }

  @Test func addLayerUpdatesCollectionsDefaultsAndOrderWithoutDisturbingExisting() throws {
    let fixture = layeredGraph()
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLayerCommand(
          name: "Annotations", defaultVisible: false, printState: .off,
          orderIndex: 1)
      ]), to: fixture.graph)
    let inventory = OptionalContentInventory.inspect(in: graph)
    #expect(inventory.layers.count == 3)
    let added = try #require(inventory.layer(named: "Annotations"))
    #expect(added.defaultVisible == false)
    #expect(added.printState == .off)
    #expect(added.orderIndex == 1)
    #expect(inventory.layer(fixture.layerA)?.orderIndex == 0)
    #expect(inventory.layer(fixture.layerB)?.orderIndex == 2)
    #expect(inventory.defaultOff.contains(added.objectID))
    #expect(inventory.defaultOn.contains(fixture.layerA))
    #expect(throws: PDFError.self) {
      try AddLayerCommand(name: "Layer A").validate(in: graph)
    }
  }

  @Test func visibilityAndPrintStatePersistForOnlyTheSelectedLayer() throws {
    let fixture = layeredGraph()
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetLayerVisibilityCommand(
          layerID: fixture.layerB, screenVisible: true, printVisible: false,
          viewVisible: true)
      ]), to: fixture.graph)
    let inventory = OptionalContentInventory.inspect(in: graph)
    #expect(inventory.layer(fixture.layerB)?.defaultVisible == true)
    #expect(inventory.layer(fixture.layerB)?.printState == .off)
    #expect(inventory.layer(fixture.layerB)?.viewState == .on)
    // The unrelated layer keeps its own state.
    #expect(inventory.layer(fixture.layerA)?.defaultVisible == true)
    #expect(inventory.layer(fixture.layerA)?.printState == .on)
    #expect(inventory.defaultOn.contains(fixture.layerB))
    #expect(!inventory.defaultOff.contains(fixture.layerB))
    let reparsed = try PDFParser.parse(try PDFWriter.write(graph))
    let copy = OptionalContentInventory.inspect(in: reparsed.graph)
    #expect(copy.layer(fixture.layerB)?.printState == .off)
    #expect(copy.layer(fixture.layerB)?.viewState == .on)
  }

  @Test func reorderRequiresExactFlatLayerListAndPreservesStates() throws {
    let fixture = layeredGraph()
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReorderLayersCommand(orderedLayerIDs: [fixture.layerB, fixture.layerA])
      ]), to: fixture.graph)
    let inventory = OptionalContentInventory.inspect(in: graph)
    #expect(inventory.layers.first { $0.objectID == fixture.layerB }?.orderIndex == 0)
    #expect(inventory.layers.first { $0.objectID == fixture.layerA }?.orderIndex == 1)
    #expect(inventory.layer(fixture.layerB)?.printState == .off)
    #expect(throws: PDFError.self) {
      try ReorderLayersCommand(orderedLayerIDs: [fixture.layerA])
        .validate(in: graph)
    }
  }

  @Test func markingContentOnLayerAddsResourceAndMembership() throws {
    let fixture = layeredGraph()
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        MarkContentOnLayerCommand(
          pageID: fixture.pageID, layerID: fixture.layerB,
          instructionRange: 1..<3)
      ]), to: fixture.graph)
    let inventory = OptionalContentInventory.inspect(in: graph)
    #expect((inventory.layer(fixture.layerB)?.membershipCount ?? 0) >= 1)
    #expect(inventory.issues.isEmpty)
    guard case .dictionary(let page)? = graph.objects[fixture.pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let properties)? = resources[PDFName("Properties")]
    else {
      Issue.record("properties missing")
      return
    }
    #expect(properties.values.contains(.reference(fixture.layerB)))
    guard case .reference(let contentID)? = page[PDFName("Contents")],
      case .stream(let stream)? = graph.objects[contentID]
    else {
      Issue.record("content missing")
      return
    }
    let text = String(decoding: stream.bytes, as: UTF8.self)
    #expect(text.contains("BDC"))
    #expect(text.contains("EMC"))
    #expect(text.contains("0 0 10 10 re f"))
  }

  @Test func mergeImportsDefinitionsWithoutRenamingOrReorderingTargetLayers() throws {
    let fixture = layeredGraph()
    let source = fixture.graph
    // Target has one unrelated layer named C and no conflict.
    let target = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
          PDFName("OCProperties"): .dictionary([
            PDFName("OCGs"): .array([.reference(PDFObjectID(20))]),
            PDFName("D"): .dictionary([
              PDFName("ON"): .array([.reference(PDFObjectID(20))]),
              PDFName("OFF"): .array([]),
              PDFName("Order"): .array([.reference(PDFObjectID(20))]),
            ]),
          ]),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(0),
          PDFName("Kids"): .array([]),
        ]),
        PDFObjectID(20): .dictionary([
          PDFName("Type"): .name(PDFName("OCG")),
          PDFName("Name"): .string(Data("Layer C".utf8)),
        ]),
      ], trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let (merged, report) = try OptionalContentLayerMerge.merge(source, into: target)
    #expect(report.imported.count == 2)
    let inventory = OptionalContentInventory.inspect(in: merged)
    #expect(inventory.layers.count == 3)
    #expect(inventory.layer(named: "Layer C") != nil)
    #expect(inventory.layer(named: "Layer A")?.printState == .on)
    #expect(inventory.layer(named: "Layer B")?.defaultVisible == false)
    #expect(inventory.layers.first { $0.name == "Layer C" }?.orderIndex == 0)
    #expect(report.report.contains("source content is not copied"))
    // Conflict handling: merging the same source again renames, never duplicates.
    let (again, second) = try OptionalContentLayerMerge.merge(source, into: merged)
    #expect(second.imported.contains { $0.contains("imported") })
    #expect(OptionalContentInventory.inspect(in: again).issues.isEmpty)
  }

  @Test func unsupportedStructuresAreAuditedAndRefusedRatherThanRewritten() throws {
    var fixture = layeredGraph()
    guard case .reference(let catalogID)? = fixture.graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = fixture.graph.objects[catalogID],
      case .dictionary(var properties)? = catalog[PDFName("OCProperties")],
      case .dictionary(var defaults)? = properties[PDFName("D")]
    else {
      Issue.record("fixture missing")
      return
    }
    // Nested /Order entries.
    defaults[PDFName("Order")] = .array([
      .array([.reference(fixture.layerA)]),
      .reference(fixture.layerB),
    ])
    properties[PDFName("D")] = .dictionary(defaults)
    catalog[PDFName("OCProperties")] = .dictionary(properties)
    var nested = fixture.graph
    nested.objects[catalogID] = .dictionary(catalog)
    let audit = OptionalContentAuditService.audit(in: nested)
    #expect(audit.findings.contains { $0.detail.contains("Nested /Order") })
    #expect(throws: PDFError.self) {
      try ReorderLayersCommand(orderedLayerIDs: [fixture.layerA, fixture.layerB])
        .validate(in: nested)
    }
    // Automatic state /AS blocks authoring.
    var automaticGraph = fixture.graph
    properties[PDFName("AS")] = .array([])
    catalog[PDFName("OCProperties")] = .dictionary(properties)
    automaticGraph.objects[catalogID] = .dictionary(catalog)
    #expect(throws: PDFError.self) {
      try AddLayerCommand(name: "Blocked").validate(in: automaticGraph)
    }
  }
}
