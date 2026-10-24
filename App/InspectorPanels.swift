import Foundation
import MacServices
import SwiftUI

/// P12-011: a properties inspector that follows the current page selection.
struct SelectionInspectorPanel: View {
  @ObservedObject var viewer: PDFViewingSession
  var onImageGeometry: ((Int, Int, Double, Double, Double, Double) -> Void)?
  var onImageFlip: ((Int, Int, Bool) -> Void)?
  var onImageRotate: ((Int, Int, Int) -> Void)?

  var body: some View {
    Form {
      Section("Selection") {
        if let summary = viewer.selectedObjectSummary,
          let details = viewer.selectionDetails
        {
          LabeledContent("Summary") { Text(summary).textSelection(.enabled) }
          LabeledContent("Page") { Text("\(details.pageNumber)") }
          LabeledContent("Text") { Text(details.text).textSelection(.enabled) }
          if let bounds = details.bounds, bounds.count == 4 {
            LabeledContent("Bounds") {
              Text(
                "\(Int(bounds[0])), \(Int(bounds[1])) – \(Int(bounds[2])), \(Int(bounds[3])) pt"
              ).textSelection(.enabled)
            }
          }
          if viewer.activeTool != .select {
            LabeledContent("Tool") { Text(viewer.activeTool.rawValue) }
          }
        } else {
          Text("Nothing selected. Select page text to inspect it here.")
            .foregroundStyle(.secondary)
        }
      }
      if let target = viewer.selectedGraphics.first(where: { $0.imagePlacementIndex != nil }),
        let placementIndex = target.imagePlacementIndex
      {
        ImageInspectorSection(
          target: target, placementIndex: placementIndex,
          onGeometry: onImageGeometry, onFlip: onImageFlip, onRotate: onImageRotate)
      }
    }
    .formStyle(.grouped)
    .accessibilityLabel("Selection inspector")
  }
}

/// IMG-01: numeric page-space geometry plus rotate/flip for the selected image
/// placement. Applying uses the document's existing undoable image commands.
private struct ImageInspectorSection: View {
  let target: AddedGraphicTarget
  let placementIndex: Int
  let onGeometry: ((Int, Int, Double, Double, Double, Double) -> Void)?
  let onFlip: ((Int, Int, Bool) -> Void)?
  let onRotate: ((Int, Int, Int) -> Void)?
  @State private var x: String
  @State private var y: String
  @State private var width: String
  @State private var height: String

  init(
    target: AddedGraphicTarget, placementIndex: Int,
    onGeometry: ((Int, Int, Double, Double, Double, Double) -> Void)?,
    onFlip: ((Int, Int, Bool) -> Void)?,
    onRotate: ((Int, Int, Int) -> Void)?
  ) {
    self.target = target
    self.placementIndex = placementIndex
    self.onGeometry = onGeometry
    self.onFlip = onFlip
    self.onRotate = onRotate
    let rect = target.rect
    _x = State(initialValue: rect.count == 4 ? String(format: "%.2f", rect[0]) : "")
    _y = State(initialValue: rect.count == 4 ? String(format: "%.2f", rect[1]) : "")
    _width = State(
      initialValue: rect.count == 4 ? String(format: "%.2f", rect[2] - rect[0]) : "")
    _height = State(
      initialValue: rect.count == 4 ? String(format: "%.2f", rect[3] - rect[1]) : "")
  }

  private var values: (Double, Double, Double, Double)? {
    guard let x = Double(x), let y = Double(y),
      let width = Double(width), let height = Double(height),
      width > 0, height > 0
    else { return nil }
    return (x, y, width, height)
  }

  var body: some View {
    Section("Image") {
      LabeledContent("Placement") { Text("\(placementIndex + 1)") }
      LabeledContent("Page") { Text("\(target.pageIndex + 1)") }
      LabeledContent("X") { TextField("X", text: $x) }
      LabeledContent("Y") { TextField("Y", text: $y) }
      LabeledContent("Width") { TextField("Width", text: $width) }
      LabeledContent("Height") { TextField("Height", text: $height) }
      HStack {
        Button("Apply") {
          guard let values else { return }
          onGeometry?(target.pageIndex, placementIndex, values.0, values.1, values.2, values.3)
        }
        .disabled(values == nil)
        Button("Rotate −90°") {
          onRotate?(target.pageIndex, placementIndex, -90)
        }
        Button("Rotate 90°") {
          onRotate?(target.pageIndex, placementIndex, 90)
        }
      }
      HStack {
        Button("Flip Horizontal") {
          onFlip?(target.pageIndex, placementIndex, true)
        }
        Button("Flip Vertical") {
          onFlip?(target.pageIndex, placementIndex, false)
        }
      }
      Text("Page-space points. Rotated or clipped placements may refuse a transform.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .onChange(of: target.rect) { _, rect in
      guard rect.count == 4 else { return }
      x = String(format: "%.2f", rect[0])
      y = String(format: "%.2f", rect[1])
      width = String(format: "%.2f", rect[2] - rect[0])
      height = String(format: "%.2f", rect[3] - rect[1])
    }
  }
}

/// P12-020: a document-information panel from the core inventory.
struct DocumentInfoPanel: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    Form {
      if let info = viewer.documentInfo {
        Section("Document") {
          LabeledContent("File") { Text(info.fileName).textSelection(.enabled) }
          LabeledContent("Pages") { Text("\(info.pageCount)") }
          row("Title", info.title)
          row("Author", info.author)
          row("Subject", info.subject)
          row("Keywords", info.keywords)
          row("Creator", info.creator)
          row("Producer", info.producer)
          row("Language", info.language)
        }
        if let restriction = viewer.editingRestrictionNotice {
          Section("Editing") {
            Label {
              Text(restriction).fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "exclamationmark.lock.fill").foregroundStyle(.orange)
            }
            .accessibilityLabel("Editing unavailable")
            .accessibilityValue(restriction)
          }
        }
        if let capability = info.capabilitySummary, !capability.isEmpty {
          Section("Capabilities") {
            Text(capability).foregroundStyle(.secondary)
          }
        }
      } else {
        Text("Document information is unavailable.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .accessibilityLabel("Document information")
  }

  private func row(_ title: String, _ value: String?) -> some View {
    LabeledContent(title) {
      Text(value ?? "—").foregroundStyle(value == nil ? .secondary : .primary)
        .textSelection(.enabled)
    }
  }
}
