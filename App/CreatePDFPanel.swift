import AppKit
import Combine
import MacServices
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PAG-08 creation panel model

@MainActor
final class CreatePDFModel: ObservableObject {
  struct ImageItem: Identifiable {
    let id = UUID()
    let name: String
    let source: ImagePDFCreation.Source
  }

  @Published var images: [ImageItem] = []
  @Published var text = ""
  @Published var pageSize: PDFCreationPageOptions.PageSize = .letter
  @Published var orientation: PDFCreationPageOptions.Orientation = .automatic
  @Published var marginsText = "36"
  @Published var fontSizeText = "12"
  @Published var status: String?
  @Published var errorMessage: String?
  @Published var clipboardSummary = "Clipboard not loaded yet."
  @Published var guidance = PDFScannerHandoff.guidance

  private(set) weak var document: SPDFDocument?
  private(set) var clipboardContent: ClipboardPDFCreation.Content = .empty

  init(document: SPDFDocument?) {
    self.document = document
  }

  func refresh(document: SPDFDocument?) {
    self.document = document
  }

  // MARK: Inputs

  func addImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .pdf]
    panel.allowsMultipleSelection = true
    panel.message = "Choose images in the order they should become pages."
    panel.prompt = "Add Images"
    guard panel.runModal() == .OK else { return }
    var added = 0
    var skipped: [String] = []
    for url in panel.urls {
      guard let data = try? Data(contentsOf: url) else {
        skipped.append(url.lastPathComponent)
        continue
      }
      guard let raster = ImageImport.decode(data) else {
        skipped.append(url.lastPathComponent)
        continue
      }
      images.append(
        ImageItem(
          name: url.lastPathComponent,
          source: ImagePDFCreation.Source(
            width: raster.width, height: raster.height, rgb8: raster.rgb8,
            alpha8: raster.alpha8)))
      added += 1
    }
    if added > 0 {
      status = "Added \(added) image(s) in the chosen order."
      errorMessage = nil
    }
    if !skipped.isEmpty {
      errorMessage = "Skipped unsupported or unreadable file(s): " + skipped.joined(separator: ", ")
    }
  }

  func removeImage(_ item: ImageItem) {
    images.removeAll { $0.id == item.id }
  }

  func useClipboardText() {
    if let string = NSPasteboard.general.string(forType: .string),
      !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      text = string
      clipboardContent = .text(string)
      clipboardSummary = "Clipboard text loaded (\(string.count) characters)."
      status = nil
      errorMessage = nil
      return
    }
    // Fall back to an image on the pasteboard.
    useClipboardImage()
  }

  func useClipboardImage() {
    let pasteboard = NSPasteboard.general
    let candidates: [NSPasteboard.PasteboardType] = [.tiff, .png]
    for type in candidates {
      guard let data = pasteboard.data(forType: type),
        let raster = ImageImport.decode(data)
      else { continue }
      let source = ImagePDFCreation.Source(
        width: raster.width, height: raster.height, rgb8: raster.rgb8,
        alpha8: raster.alpha8)
      clipboardContent = .images([source])
      clipboardSummary =
        "Clipboard image loaded (\(raster.width)×\(raster.height) pixels)."
      status = nil
      errorMessage = nil
      return
    }
    clipboardContent = .empty
    clipboardSummary = "Clipboard does not contain plain text or a supported image."
    errorMessage = clipboardSummary
  }

  func scanHandoff() {
    if PDFScannerHandoff.openImageCapture() {
      status = "Image Capture opened. Scan to PDF or images, then use Add Images… to import them."
      errorMessage = nil
    } else {
      errorMessage = "Image Capture was not found on this system."
    }
  }

  func printServiceHandoff() {
    if PDFScannerHandoff.openPrintScanSettings() {
      status = PDFScannerHandoff.printServiceGuidance
      errorMessage = nil
    } else {
      errorMessage = "The Print & Scan settings could not be opened."
    }
  }

  // MARK: Creation

  func createFromImages() {
    guard !images.isEmpty else {
      errorMessage = "Add at least one image first."
      return
    }
    guard let options = resolvedOptions() else { return }
    do {
      let result = try MultiImagePDFCreation.make(
        sources: images.map(\.source), options: options)
      try finish(result, description: "\(images.count) image page(s)")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createFromText() {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = "Type or load text first."
      return
    }
    guard let options = resolvedOptions() else { return }
    do {
      let result = try TextPDFCreationWithLayout.make(text: text, options: options)
      try finish(result, description: "\(result.pageCount) text page(s)")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createFromClipboard() {
    guard let options = resolvedOptions() else { return }
    do {
      let result = try ClipboardPDFCreation.make(clipboardContent, options: options)
      try finish(result, description: "\(result.pageCount) clipboard page(s)")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func finish(_ result: PDFCreationResult, description: String) throws {
    try CreatePDFActions.openAsDocument(result)
    status = "Created a new untitled PDF from " + description + "."
    errorMessage = nil
  }

  private func resolvedOptions() -> PDFCreationPageOptions? {
    let margins = Double(marginsText.trimmingCharacters(in: .whitespaces)) ?? -1
    let fontSize = Double(fontSizeText.trimmingCharacters(in: .whitespaces)) ?? -1
    guard margins.isFinite, margins >= 0, margins <= 1_000 else {
      errorMessage = "Enter page margins between 0 and 1000 points."
      return nil
    }
    guard fontSize.isFinite, (6...72).contains(fontSize) else {
      errorMessage = "Enter a font size between 6 and 72 points."
      return nil
    }
    return PDFCreationPageOptions(
      pageSize: pageSize, orientation: orientation, margins: margins,
      textFontSize: fontSize)
  }

  var imageSummary: String {
    images.isEmpty ? "No images selected" : "\(images.count) image(s) in order"
  }
}

// MARK: - Window controller

@MainActor
final class CreatePDFPanelController: NSWindowController {
  let model: CreatePDFModel

  init(document: SPDFDocument?) {
    let model = CreatePDFModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 880, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Create PDF"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 720, height: 620)
    panel.contentView = NSHostingView(rootView: CreatePDFView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the create-PDF panel")
  }

  func refresh(document: SPDFDocument?) {
    model.refresh(document: document)
  }
}

// MARK: - View

struct CreatePDFView: View {
  @ObservedObject var model: CreatePDFModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        Divider()
        outputOptions
        Divider()
        imagesSection
        Divider()
        textSection
        Divider()
        clipboardSection
        Divider()
        scannerSection
      }
      .padding(18)
    }
    .frame(minWidth: 720, minHeight: 620)
    .accessibilityLabel("Create PDF from images, text, clipboard or scanner")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Create PDF").font(.title2.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "Create a new untitled PDF from images, typed text, clipboard content, or a local "
          + "scan/print handoff. Everything is produced locally through the owned writer; "
          + "page size, orientation and margins are explicit.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let status = model.status {
        Label(status, systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var outputOptions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Page options").font(.headline)
      HStack(spacing: 14) {
        Picker("Page size", selection: $model.pageSize) {
          ForEach(PDFCreationPageOptions.PageSize.allCases, id: \.self) { size in
            Text(size.title).tag(size)
          }
        }
        .frame(width: 210)
        .accessibilityLabel("Created page size")
        Picker("Orientation", selection: $model.orientation) {
          ForEach(PDFCreationPageOptions.Orientation.allCases, id: \.self) { orientation in
            Text(orientation.title).tag(orientation)
          }
        }
        .frame(width: 220)
        .accessibilityLabel("Created page orientation")
        HStack(spacing: 4) {
          Text("Margins").font(.caption)
          TextField("36", text: $model.marginsText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .accessibilityLabel("Created page margins")
          Text("pt").font(.caption2).foregroundStyle(.secondary)
        }
        HStack(spacing: 4) {
          Text("Font").font(.caption)
          TextField("12", text: $model.fontSizeText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .accessibilityLabel("Created text font size")
          Text("pt").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
  }

  private var imagesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("From images").font(.headline)
        Spacer()
        Text(model.imageSummary).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Add Images…") { model.addImages() }
          .accessibilityLabel("Add images to create PDF")
        Button("Create from Images") { model.createFromImages() }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel("Create PDF from images")
        Spacer()
      }
      if !model.images.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(model.images) { item in
            HStack(spacing: 8) {
              Text(item.name).font(.caption)
              Text("\(item.source.width)×\(item.source.height)")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Remove") { model.removeImage(item) }
                .buttonStyle(.link)
                .accessibilityLabel("Remove image " + item.name)
            }
          }
        }
      }
    }
  }

  private var textSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("From text").font(.headline)
        Spacer()
        Button("Create from Text") { model.createFromText() }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel("Create PDF from text")
      }
      TextEditor(text: $model.text)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 120, maxHeight: 200)
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.secondary.opacity(0.3)))
        .accessibilityLabel("Text to create a PDF from")
    }
  }

  private var clipboardSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("From clipboard").font(.headline)
        Spacer()
        Text(model.clipboardSummary).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Load Clipboard Text") { model.useClipboardText() }
          .accessibilityLabel("Load clipboard text")
        Button("Load Clipboard Image") { model.useClipboardImage() }
          .accessibilityLabel("Load clipboard image")
        Button("Create from Clipboard") { model.createFromClipboard() }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel("Create PDF from clipboard")
        Spacer()
      }
      Text("Clipboard text becomes paginated editable text; a clipboard image becomes one page.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var scannerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("From a scanner or the local print service").font(.headline)
      Text(PDFScannerHandoff.guidance)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Open Image Capture…") { model.scanHandoff() }
          .accessibilityLabel("Open Image Capture for scanning")
        Button("Open Print & Scan Settings…") { model.printServiceHandoff() }
          .accessibilityLabel("Open print service handoff")
        Spacer()
      }
      Text(PDFScannerHandoff.printServiceGuidance)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
