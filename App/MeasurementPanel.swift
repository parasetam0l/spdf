import AppKit
import PDFCore
import PDFEditing
import SwiftUI

// SPC-02: calibrated measurement panel. Calibration is either resolved from the
// page /Measure metadata or declared by the user; nothing is assumed.

@MainActor
final class MeasurementPanelModel: ObservableObject {
  @Published private(set) var pageID: PDFObjectID?
  @Published private(set) var pageInfo: MeasurementPageInfo?
  @Published private(set) var measurements: [MeasurementAnnotation] = []
  @Published private(set) var inspection: GeospatialInspection?
  @Published private(set) var statusText: String?
  @Published private(set) var errorText: String?
  @Published var unit: MeasurementUnit = .millimeter
  @Published var unitsPerPoint = ""
  @Published var kind: MeasurementKind = .distance
  @Published var pointsText = "100,100; 300,100"
  @Published private(set) var resolvedCalibration: MeasurementCalibration?
  @Published private(set) var result: MeasurementResult?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    load()
  }

  var calibration: MeasurementCalibration? {
    if let resolvedCalibration { return resolvedCalibration }
    guard let value = Double(unitsPerPoint), value > 0 else { return nil }
    return try? MeasurementCalibration(unitsPerPoint: value, unit: unit)
  }

  var canAdd: Bool { calibration != nil && parsedPoints.count >= 2 }

  func load() {
    guard let document, let graph = document.editSession.currentGraph,
      let first = document.editSession.pageIDs.first
    else {
      errorText = "This document is not editable by the owned core."
      return
    }
    pageID = first
    pageInfo = MeasurementPageGeometry.info(pageID: first, pageIndex: 0, graph: graph)
    resolvedCalibration = MeasurementCalibration.resolve(pageID: first, graph: graph)
    if let resolvedCalibration {
      unit = resolvedCalibration.unit
      unitsPerPoint = String(format: "%.6f", resolvedCalibration.unitsPerPoint)
    }
    do {
      let report = try MeasurementAnnotationInventory.inventory(
        in: graph, pageIDs: document.editSession.pageIDs)
      measurements = report.measurements
      errorText = report.issues.first
    } catch {
      errorText = error.localizedDescription
    }
    inspection = GeospatialInspectionService.inspect(
      pageID: first, pageIndex: 0, graph: graph)
    statusText = resolvedCalibration == nil
      ? "No page /Measure calibration found; declare the units per point explicitly."
      : "Calibration resolved from the page /Measure metadata."
    errorText = errorText == nil ? nil : errorText
  }

  var parsedPoints: [[Double]] {
    pointsText.split(separator: ";").compactMap { part in
      let numbers = part.split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      return numbers.count == 2 ? numbers : nil
    }
  }

  func calculate() {
    guard let calibration else {
      errorText = "A positive calibration is required before measuring."
      return
    }
    do {
      let shape: MeasurementShape
      switch kind {
      case .distance:
        guard parsedPoints.count == 2 else {
          throw PDFError(.malformed, "Distance needs exactly two points")
        }
        shape = .distance(from: parsedPoints[0], to: parsedPoints[1])
      case .perimeter:
        shape = .perimeter(points: parsedPoints)
      case .area:
        shape = .area(points: parsedPoints)
      }
      result = try MeasurementCalculator.measure(shape, calibration: calibration)
      errorText = nil
    } catch {
      result = nil
      errorText = error.localizedDescription
    }
  }

  func addMeasurement() {
    guard let document, let pageID, let calibration else { return }
    let shape: MeasurementShape
    switch kind {
    case .distance:
      guard parsedPoints.count == 2 else {
        errorText = "Distance needs exactly two points"
        return
      }
      shape = .distance(from: parsedPoints[0], to: parsedPoints[1])
    case .perimeter: shape = .perimeter(points: parsedPoints)
    case .area: shape = .area(points: parsedPoints)
    }
    let command = AddMeasurementAnnotationCommand(
      pageID: pageID, shape: shape, calibration: calibration)
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([command]), actionName: "Add Measurement Annotation")
    else {
      errorText = "The measurement annotation was refused by the document session."
      return
    }
    statusText = "Measurement annotation added as one transaction; the document is not saved."
    load()
  }

  func focus(pageIndex: Int) {
    document?.viewer?.go(to: pageIndex + 1)
  }
}

@MainActor
final class MeasurementPanelWindowController: NSWindowController {
  let model: MeasurementPanelModel

  init(document: SPDFDocument) {
    let model = MeasurementPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Measurements"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: MeasurementPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for measurements")
  }

  func refresh() { model.load() }
}

struct MeasurementPanelView: View {
  @ObservedObject var model: MeasurementPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Calibrated Measurements").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "Supported profile: explicit units per point, page /Measure /R + /X calibration, "
          + "distance/perimeter/area with closed perimeters, snapping, and /Measure /GEO "
          + "latitude/longitude inspection. No projection/datum conversion is claimed.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Picker("Mode", selection: $model.kind) {
          ForEach(MeasurementKind.allCases, id: \.self) { kind in
            Text(kind.title).tag(kind)
          }
        }
        Picker("Unit", selection: $model.unit) {
          ForEach(MeasurementUnit.allCases, id: \.self) { unit in
            Text(unit.title).tag(unit)
          }
        }
        TextField("Units per point", text: $model.unitsPerPoint)
          .textFieldStyle(.roundedBorder)
          .frame(width: 130)
      }
      TextField("Points (x,y; x,y; …)", text: $model.pointsText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Measurement points")
      HStack {
        Button("Calculate") { model.calculate() }
        if let result = model.result {
          Text(result.formatted).font(.headline)
        }
        Spacer()
        Button("Add Measurement") { model.addMeasurement() }
          .disabled(!model.canAdd)
          .accessibilityLabel("Add measurement annotation")
      }
      if let error = model.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
      }
      if let status = model.statusText {
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
      if let inspection = model.inspection {
        GroupBox("Geospatial metadata") {
          Text(inspection.report)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
      }
      GroupBox("Measurement annotations on this document") {
        if model.measurements.isEmpty {
          Text("No measurement annotations were found.").font(.caption)
        } else {
          ForEach(model.measurements, id: \.index) { measurement in
            HStack {
              Text(measurement.kind.title).font(.caption.weight(.semibold))
              Text(measurement.result.formatted).font(.caption.monospaced())
              Text(measurement.calibration.description)
                .font(.caption2).foregroundStyle(.secondary)
              Spacer()
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
      Spacer()
    }
    .padding(14)
    .frame(minWidth: 780, minHeight: 560)
    .accessibilityLabel("Calibrated measurements")
  }
}

extension SPDFDocument {
  var canShowMeasurements: Bool { editSession.currentGraph != nil }

  func presentMeasurementsPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? MeasurementPanelWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = MeasurementPanelWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
