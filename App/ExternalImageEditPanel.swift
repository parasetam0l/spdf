import AppKit
import CoreGraphics
import ImageIO
import MacServices
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// IMG-06: explicit external-image-edit round trip.
///
/// The user selects one image instance (Images mode), exports it to a file
/// whose provenance is labelled (original encoded bytes, lossless stored
/// samples, or a rendered reconstruction), opens it in their chosen editor,
/// then reimports the returned file as a previewed replacement. Apply commits
/// one transaction/one Undo; Cancel restores the exact previous renderer.
/// The placement geometry is never changed, so size and orientation survive;
/// transparency is preserved through the returned alpha plane or an explicit
/// discard acknowledgement.
@MainActor
final class ExternalImageEditController: ObservableObject {
  private weak var document: SPDFDocument?
  @Published private(set) var target: ExternalImageTarget?
  @Published private(set) var exportedURL: URL?
  @Published private(set) var returnedFileName: String?
  @Published private(set) var plan: ExternalImageReplacementPlan?
  @Published private(set) var statusMessage: String?
  @Published private(set) var errorMessage: String?
  @Published var allowReconstructedSource = false
  @Published var discardExistingMask = false
  @Published var allowStretching = false
  private var pageIndex = 0
  private var previewActive = false

  init(document: SPDFDocument) {
    self.document = document
  }

  var provenanceLabel: String {
    target?.exportPlan.provenance.displayName ?? "No image selected"
  }

  var exportNotes: [String] { target?.exportPlan.notes ?? [] }

  var maskLabel: String { target?.mask.displayName ?? "No mask" }

  var sourceSummary: String {
    guard let target else { return "Select an image instance in the Images tool." }
    return "Page image \(target.resourceName): \(target.summary)"
  }

  var canPlanReturnedFile: Bool {
    guard let target else { return false }
    if target.exportPlan.provenance == .renderedReconstruction && !allowReconstructedSource {
      return false
    }
    if target.mask == .softMask && plan == nil && !discardExistingMask {
      // The returned file may carry alpha; planning decides. Keep enabled.
      return true
    }
    return true
  }

  /// Resolve the currently selected image instance (Images mode drag/handles).
  func loadSelection() {
    guard let document, let viewer = document.viewer else {
      statusMessage = "Open a document first."
      return
    }
    guard let graph = document.editSession.currentGraph else { return }
    pageIndex = max(0, (viewer.pageNumber - 1))
    guard document.editSession.pageIDs.indices.contains(pageIndex) else { return }
    let pageID = document.editSession.pageIDs[pageIndex]
    let selectedPlacement = viewer.selectedGraphics.first {
      $0.imagePlacementIndex != nil && $0.pageIndex == pageIndex
    }?.imagePlacementIndex
    do {
      let targets = try ExternalImageEdit.targets(pageID: pageID, in: graph)
      guard !targets.isEmpty else {
        statusMessage = "This page has no addressable image instance."
        return
      }
      if let selectedPlacement,
        let match = targets.first(where: { $0.placementIndex == selectedPlacement })
      {
        target = match
      } else if let first = targets.first(where: { $0.canReimport }) {
        target = first
        statusMessage =
          "No image was selected; using the first reimportable image on this page. "
          + "Select an image in the Images tool to choose a different instance."
      } else {
        target = targets.first
      }
      statusMessage = nil
      errorMessage = nil
    } catch {
      target = nil
      errorMessage = error.localizedDescription
    }
  }

  /// Write the selected instance to a file with the plan's provenance and open
  /// it in the user's default external editor.
  func exportSelectedImage() {
    guard let document, let target, let graph = document.editSession.currentGraph else {
      statusMessage = "Select an image instance first."
      return
    }
    do {
      let data = try exportData(target: target, graph: graph)
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "external-edit-\(target.resourceName).\(target.exportPlan.suggestedFileExtension)"
      if let type = UTType(filenameExtension: target.exportPlan.suggestedFileExtension) {
        panel.allowedContentTypes = [type]
      }
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try data.write(to: url, options: .atomic)
      exportedURL = url
      statusMessage =
        "Exported \(target.exportPlan.provenance.displayName.lowercased()). "
        + "Opening in the default editor; return the edited file below."
      NSWorkspace.shared.open(url)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Choose the file returned by the external editor and build a preview.
  func chooseReturnedFile() {
    guard let document, let target, let graph = document.editSession.currentGraph else {
      statusMessage = "Select an image instance first."
      return
    }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
    panel.message = "Choose the edited image returned by the external editor."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      guard let raster = ImageImport.decode(data) else {
        throw PDFError(.unsupported, "The chosen file could not be decoded as an image")
      }
      let request = ExternalImageReplacementRequest(
        width: raster.width, height: raster.height, rgb8: raster.rgb8,
        alpha8: raster.alpha8, sourceLabel: url.lastPathComponent)
      let options = ExternalImageReplacementOptions(
        allowReconstructedExport: allowReconstructedSource,
        discardExistingSoftMask: discardExistingMask,
        requireMatchingAspectRatio: !allowStretching)
      let replacement = try ExternalImageEdit.planReplacement(
        target: target, returned: request, options: options, in: graph)
      plan = replacement
      returnedFileName = url.lastPathComponent
      errorMessage = nil
      try showPreview(replacement, graph: graph, pageIndex: pageIndex)
      statusMessage = replacement.maskOutcome.displayName
    } catch {
      plan = nil
      endPreview()
      errorMessage = error.localizedDescription
    }
  }

  func apply() {
    guard let document, let plan else { return }
    _ = document
    let commands = plan.commands
    endPreview()
    guard document.applyPageObjectCommands(
      commands, pageIndex: pageIndex, actionName: "Replace Image from External Editor")
    else {
      errorMessage = "The replacement was refused or the document changed."
      return
    }
    statusMessage = "Replaced \(plan.target.resourceName) from \(returnedFileName ?? "the external file")."
    self.plan = nil
    dismissSheet()
  }

  func cancel() {
    endPreview()
    plan = nil
    returnedFileName = nil
    dismissSheet()
  }

  func dismissSheet() {
    guard let document, let window = document.windowControllers.first?.window,
      let sheet = window.attachedSheet
    else { return }
    window.endSheet(sheet)
  }

  // MARK: - Export payload

  private func exportData(target: ExternalImageTarget, graph: PDFGraph) throws -> Data {
    switch target.exportPlan.provenance {
    case .originalEncodedBytes:
      guard let bytes = target.exportPlan.originalBytes else {
        throw PDFError(.malformed, "The original image bytes are unavailable")
      }
      return bytes
    case .originalStoredSamples:
      guard let samples = target.exportPlan.losslessSamples else {
        throw PDFError(.malformed, "The stored image samples are unavailable")
      }
      return try pngData(from: samples)
    case .renderedReconstruction:
      guard let document, document.editSession.pageIDs.indices.contains(pageIndex) else {
        throw PDFError(.malformed, "The image page is unavailable")
      }
      return try PageImageExport.regionImageData(
        pageID: document.editSession.pageIDs[pageIndex], in: graph,
        region: target.bounds,
        options: PageImageExportOptions(format: .png, dpi: 144))
    }
  }

  /// Wrap stored samples into a PNG without resampling or color conversion.
  private func pngData(from samples: ExternalImageLosslessSamples) throws -> Data {
    let components = samples.components == .gray ? 1 : 3
    let colorSpace =
      samples.components == .gray
      ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let expected = samples.width * samples.height * components
    guard samples.samples.count >= expected,
      let provider = CGDataProvider(data: Data(samples.samples.prefix(expected)) as CFData),
      let image = CGImage(
        width: samples.width, height: samples.height, bitsPerComponent: 8,
        bitsPerPixel: 8 * components, bytesPerRow: samples.width * components,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw PDFError(.unsupported, "The stored samples could not be wrapped into a PNG")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)
    else {
      throw PDFError(.unsupported, "A PNG encoder is unavailable")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PDFError(.unsupported, "The PNG export could not be finalized")
    }
    return data as Data
  }

  // MARK: - Preview

  private func showPreview(
    _ plan: ExternalImageReplacementPlan, graph: PDFGraph, pageIndex: Int
  ) throws {
    guard let document, let viewer = document.viewer else { return }
    let preview = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: graph)
    let data = try PDFWriter.write(preview)
    viewer.previewAnnotationStyle(data)
    previewActive = true
  }

  private func endPreview() {
    guard previewActive else { return }
    document?.viewer?.endAnnotationStylePreview()
    previewActive = false
  }
}

/// IMG-06: the App-side screenshotless dialog: provenance, export, open in
/// editor, return, preview, apply/cancel.
struct ExternalImageEditSheet: View {
  @ObservedObject var controller: ExternalImageEditController

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          sourceSection
          provenanceSection
          exportSection
          returnSection
          optionsSection
          planSection
          messagesSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 460, height: 620)
    .onAppear { controller.loadSelection() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Edit Image in External Editor")
        .font(.system(size: 14, weight: .semibold))
      Text("One instance only. Placement size, orientation and clip are preserved.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("IMAGE INSTANCE").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      Text(controller.sourceSummary)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var provenanceSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("EXPORT PROVENANCE").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      Text(controller.provenanceLabel).font(.system(size: 12, weight: .medium))
      ForEach(controller.exportNotes, id: \.self) { note in
        Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Mask: \(controller.maskLabel)")
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }

  private var exportSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        controller.exportSelectedImage()
      } label: {
        Label("Export and Open in Editor…", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      if let url = controller.exportedURL {
        Text("Exported: \(url.lastPathComponent)")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }

  private var returnSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        controller.chooseReturnedFile()
      } label: {
        Label("Choose Edited File and Preview…", systemImage: "arrow.down.doc")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      if let name = controller.returnedFileName {
        Text("Returned file: \(name)")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }

  private var optionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        "The exported source is a reconstruction; reimport it as a lossy replacement",
        isOn: $controller.allowReconstructedSource)
      Toggle(
        "Discard the original soft mask when the returned image has no alpha",
        isOn: $controller.discardExistingMask)
      Toggle(
        "Allow stretching when the returned aspect ratio differs",
        isOn: $controller.allowStretching)
    }
    .font(.system(size: 11))
    .toggleStyle(.checkbox)
  }

  @ViewBuilder
  private var planSection: some View {
    if let plan = controller.plan {
      VStack(alignment: .leading, spacing: 6) {
        Text("PREVIEWED REPLACEMENT").font(.system(size: 10, weight: .semibold))
          .tracking(0.7).foregroundStyle(.secondary)
        Text(plan.summary).font(.system(size: 11))
          .fixedSize(horizontal: false, vertical: true)
        Text(plan.maskOutcome.displayName)
          .font(.system(size: 10)).foregroundStyle(.secondary)
        ForEach(plan.warnings, id: \.self) { warning in
          Text(warning).font(.system(size: 10)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
          Button("Apply Replacement") { controller.apply() }
            .buttonStyle(.borderedProminent)
          Button("Cancel Preview") { controller.cancel() }
            .buttonStyle(.bordered)
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
      Spacer()
      Button("Close") { controller.cancel() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(12)
  }
}

extension SPDFDocument {
  /// Menu hook (Images/Edit): present the external image edit round trip for
  /// the currently selected image instance.
  @MainActor
  func presentExternalImageEditor() {
    guard let window = windowControllers.first?.window else { return }
    if window.attachedSheet != nil { return }
    let controller = ExternalImageEditController(document: self)
    let hosting = NSHostingController(rootView: ExternalImageEditSheet(controller: controller))
    let sheet = NSWindow(contentViewController: hosting)
    sheet.styleMask = [.titled, .closable]
    sheet.title = "Edit Image in External Editor"
    sheet.setContentSize(NSSize(width: 460, height: 620))
    window.beginSheet(sheet) { _ in }
  }

  var canEditSelectedImageExternally: Bool {
    guard canEditContent, viewer != nil else { return false }
    return viewer?.selectedGraphics.contains { $0.imagePlacementIndex != nil } == true
  }
}
