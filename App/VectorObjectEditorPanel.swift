import AppKit
import MacServices
import PDFCore
import PDFEditing
import SwiftUI

/// IMG-07: the App-side vector object editor. Selection is inventory-driven
/// (ordinary page-level paths only); style and transform edits are previewed on
/// the renderer and committed as one transaction with one Undo. Unsupported
/// paint (gradients, patterns, forms, inline images, rotated page transforms)
/// is listed with its reason instead of being approximated.
@MainActor
final class VectorObjectEditorController: ObservableObject {
  private weak var document: SPDFDocument?
  @Published private(set) var objects: [SelectableVectorObject] = []
  @Published private(set) var refusals: [VectorPaintRefusal] = []
  @Published var selectedIdentity: String?
  @Published var applyFill = false
  @Published var fillColor = Color(red: 1, green: 0, blue: 0)
  @Published var applyStroke = false
  @Published var strokeColor = Color(red: 0, green: 0, blue: 1)
  @Published var applyLineWidth = false
  @Published var lineWidth = 1.0
  @Published var applyMove = false
  @Published var translateX = 0.0
  @Published var translateY = 0.0
  @Published var applyScale = false
  @Published var scale = 1.0
  @Published private(set) var statusMessage: String?
  @Published private(set) var errorMessage: String?
  private var pageIndex = 0
  private var previewActive = false

  init(document: SPDFDocument) {
    self.document = document
  }

  var selectedObject: SelectableVectorObject? {
    guard let selectedIdentity else { return nil }
    return objects.first { $0.id.identity == selectedIdentity }
  }

  var pageLabel: String { "Page \(pageIndex + 1)" }

  var selectionSummary: String {
    guard let object = selectedObject else {
      return objects.isEmpty
        ? "No editable vector objects on this page." : "Select a vector object above."
    }
    return "\(object.summary). \(object.style.notes.joined(separator: " "))"
  }

  func loadPage() {
    guard let document, let viewer = document.viewer,
      let graph = document.editSession.currentGraph
    else { return }
    pageIndex = max(0, viewer.pageNumber - 1)
    guard document.editSession.pageIDs.indices.contains(pageIndex) else { return }
    let pageID = document.editSession.pageIDs[pageIndex]
    do {
      objects = try VectorObjectInventory.selectable(pageID: pageID, in: graph)
      refusals = try VectorObjectInventory.refusals(pageID: pageID, in: graph)
      if selectedIdentity == nil || !objects.contains(where: { $0.id.identity == selectedIdentity })
      {
        selectedIdentity = objects.first?.id.identity
      }
      errorMessage = nil
      statusMessage =
        objects.isEmpty
        ? "No editable vector paths found on this page."
        : "\(objects.count) editable vector path\(objects.count == 1 ? "" : "s")."
    } catch {
      objects = []
      refusals = []
      selectedIdentity = nil
      errorMessage = error.localizedDescription
    }
  }

  /// Build the exact command transaction for the current controls.
  func buildCommands() throws -> [any PDFEditCommand] {
    guard let object = selectedObject else {
      throw PDFError(.unsupported, "Select an editable vector object first")
    }
    var style = VectorObjectStyle()
    if applyFill, object.paintKind.hasFill {
      style.fillColor = rgbComponents(fillColor)
    }
    if applyStroke, object.paintKind.hasStroke {
      style.strokeColor = rgbComponents(strokeColor)
    }
    if applyLineWidth, object.paintKind.hasStroke {
      guard lineWidth.isFinite, lineWidth >= 0, lineWidth <= 100 else {
        throw PDFError(.malformed, "The line width must be between 0 and 100 pt")
      }
      style.lineWidth = lineWidth
    }
    var commands: [any PDFEditCommand] = []
    if !style.isEmpty {
      commands.append(SetVectorObjectStyleCommand(objectID: object.id, style: style))
    }
    if applyMove || applyScale {
      guard scale.isFinite, scale > 0 else {
        throw PDFError(.malformed, "The vector scale must be a positive number")
      }
      let dx = applyMove ? translateX : 0
      let dy = applyMove ? translateY : 0
      let factor = applyScale ? scale : 1
      guard abs(dx) > 1e-9 || abs(dy) > 1e-9 || abs(factor - 1) > 1e-9 else {
        throw PDFError(.malformed, "The vector transform changes nothing")
      }
      if factor != 1, !object.transformEditingSupported {
        throw PDFError(
          .unsupported,
          object.refusal ?? "This vector object cannot be scaled in this profile")
      }
      let anchor = [
        (object.bounds[0] + object.bounds[2]) / 2,
        (object.bounds[1] + object.bounds[3]) / 2,
      ]
      commands.append(
        TransformVectorObjectCommand(
          objectID: object.id, translateX: dx, translateY: dy, scale: factor,
          anchorX: anchor[0], anchorY: anchor[1]))
    }
    guard !commands.isEmpty else {
      throw PDFError(.malformed, "Choose at least one style or transform change")
    }
    guard let document, let graph = document.editSession.currentGraph else {
      throw PDFError(.unsupported, "The document is not editable")
    }
    for command in commands { try command.validate(in: graph) }
    return commands
  }

  func preview() {
    do {
      let commands = try buildCommands()
      guard let document, let graph = document.editSession.currentGraph,
        let viewer = document.viewer
      else { return }
      let preview = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
      let data = try PDFWriter.write(preview)
      viewer.previewAnnotationStyle(data)
      previewActive = true
      errorMessage = nil
      statusMessage = "Previewing \(commands.count) change\(commands.count == 1 ? "" : "s")."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func apply() {
    do {
      let commands = try buildCommands()
      guard let document else { return }
      endPreview()
      guard document.applyPageObjectCommands(
        commands, pageIndex: pageIndex, actionName: "Edit Vector Object")
      else {
        errorMessage = "The vector edit was refused or the document changed."
        return
      }
      statusMessage = "Applied the vector edit. One Undo restores the previous paint."
      loadPage()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func cancel() {
    endPreview()
    dismissSheet()
  }

  func dismissSheet() {
    guard let document, let window = document.windowControllers.first?.window,
      let sheet = window.attachedSheet
    else { return }
    window.endSheet(sheet)
  }

  private func endPreview() {
    guard previewActive else { return }
    document?.viewer?.endAnnotationStylePreview()
    previewActive = false
  }

  private func rgbComponents(_ color: Color) -> [Double] {
    let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.black
    return [
      Double(native.redComponent), Double(native.greenComponent),
      Double(native.blueComponent),
    ]
  }
}

/// IMG-07 dialog: inventory list, style/transform controls and previewed apply.
struct VectorObjectEditorSheet: View {
  @ObservedObject var controller: VectorObjectEditorController

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          objectList
          selectionSummary
          styleSection
          transformSection
          refusalsSection
          messagesSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 460, height: 640)
    .onAppear { controller.loadPage() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Edit Vector Object")
        .font(.system(size: 14, weight: .semibold))
      Text("\(controller.pageLabel). Style and transform edits keep the path as vector content.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var objectList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("EDITABLE PATHS").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      if controller.objects.isEmpty {
        Text("No ordinary page-level paths on this page.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      ForEach(controller.objects, id: \.id.identity) { object in
        Button {
          controller.selectedIdentity = object.id.identity
        } label: {
          HStack {
            Image(systemName: controller.selectedIdentity == object.id.identity
              ? "largecircle.fill.circle" : "circle")
            Text(object.summary).font(.system(size: 11))
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var selectionSummary: some View {
    Text(controller.selectionSummary)
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var styleSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("STYLE").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      Toggle("Fill color", isOn: $controller.applyFill)
      ColorPicker("Fill", selection: $controller.fillColor, supportsOpacity: false)
        .disabled(!controller.applyFill)
      Toggle("Stroke color", isOn: $controller.applyStroke)
      ColorPicker("Stroke", selection: $controller.strokeColor, supportsOpacity: false)
        .disabled(!controller.applyStroke)
      Toggle("Line width", isOn: $controller.applyLineWidth)
      HStack {
        TextField("Width", value: $controller.lineWidth, format: .number)
          .frame(width: 80)
        Text("pt").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      .disabled(!controller.applyLineWidth)
      Text("Unrelated gradients, patterns, clips and transparency are never rewritten.")
        .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
    .font(.system(size: 11))
    .toggleStyle(.checkbox)
  }

  private var transformSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("TRANSFORM").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      Toggle("Move", isOn: $controller.applyMove)
      HStack {
        TextField("dx", value: $controller.translateX, format: .number)
          .frame(width: 80)
        TextField("dy", value: $controller.translateY, format: .number)
          .frame(width: 80)
        Text("pt").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      .disabled(!controller.applyMove)
      Toggle("Uniform scale", isOn: $controller.applyScale)
      HStack {
        TextField("Scale", value: $controller.scale, format: .number)
          .frame(width: 80)
        Text("about the object center").font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      .disabled(!controller.applyScale)
      if let object = controller.selectedObject, !object.transformEditingSupported {
        Text(object.refusal ?? "This path cannot be transformed.")
          .font(.system(size: 10)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.system(size: 11))
    .toggleStyle(.checkbox)
  }

  @ViewBuilder
  private var refusalsSection: some View {
    if !controller.refusals.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("UNSUPPORTED PAINT (\(controller.refusals.count))")
          .font(.system(size: 10, weight: .semibold)).tracking(0.7)
          .foregroundStyle(.secondary)
        ForEach(Array(controller.refusals.prefix(5).enumerated()), id: \.offset) {
          _, refusal in
          Text(refusal.reason)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var messagesSection: some View {
    if let error = controller.errorMessage {
      Label {
        Text(error).fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.system(size: 11)).foregroundStyle(.red)
    }
    if let status = controller.statusMessage {
      Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack {
      Button("Preview") { controller.preview() }
        .buttonStyle(.bordered)
      Button("Apply") { controller.apply() }
        .buttonStyle(.borderedProminent)
      Spacer()
      Button("Close") { controller.cancel() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(12)
  }
}

extension SPDFDocument {
  /// Menu hook (Edit/Images): present the vector object editor for the visible
  /// page. Ordinary page-level paths only; unsupported paint is listed.
  @MainActor
  func presentVectorObjectEditor() {
    guard let window = windowControllers.first?.window else { return }
    if window.attachedSheet != nil { return }
    let controller = VectorObjectEditorController(document: self)
    let hosting = NSHostingController(rootView: VectorObjectEditorSheet(controller: controller))
    let sheet = NSWindow(contentViewController: hosting)
    sheet.styleMask = [.titled, .closable]
    sheet.title = "Edit Vector Object"
    sheet.setContentSize(NSSize(width: 460, height: 640))
    window.beginSheet(sheet) { _ in }
  }

  var canEditVectorObjects: Bool {
    guard canEditContent, viewer != nil else { return false }
    return true
  }
}
