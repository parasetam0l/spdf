import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// PRE-05: color-managed conversion panel. The preview is a dry run of the
// declared conversion; Apply commits it through one document transaction.
// Refusals are shown exactly; nothing is silently flattened.

enum ColorConversionTargetChoice: String, CaseIterable, Identifiable {
  case sRGB
  case gray
  case cmyk
  case lab

  var id: String { rawValue }
  var title: String {
    switch self {
    case .sRGB: return "sRGB"
    case .gray: return "Generic Gray"
    case .cmyk: return "Generic CMYK"
    case .lab: return "Lab (D50)"
    }
  }
  var target: ColorManagementTarget {
    switch self {
    case .sRGB: return .sRGB
    case .gray: return .genericGray
    case .cmyk: return .genericCMYK
    case .lab: return .labD50
    }
  }
}

@MainActor
final class ColorManagedConversionModel: ObservableObject {
  @Published var targetChoice: ColorConversionTargetChoice = .sRGB
  @Published var intent: ColorRenderingIntent = .relativeColorimetric
  @Published var blackPreservation = true
  @Published var blackPointCompensation = true
  @Published var writeOutputIntent = true
  @Published private(set) var preview: ColorManagementReport?
  @Published private(set) var previewError: String?
  @Published private(set) var applicationMessage: String?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    refreshPreview()
  }

  var canApply: Bool { (preview?.convertedImages ?? 0) > 0 }

  var options: ColorManagementOptions {
    ColorManagementOptions(
      intent: intent, blackPreservation: blackPreservation,
      blackPointCompensation: blackPointCompensation,
      writeOutputIntent: writeOutputIntent)
  }

  func refreshPreview() {
    guard let document, let graph = document.editSession.currentGraph else {
      previewError = "This document is not editable by the owned core."
      preview = nil
      return
    }
    do {
      let result = try ColorManagedConversion.convertImages(
        in: graph, pageIDs: document.editSession.pageIDs, to: targetChoice.target,
        options: options)
      preview = result.report
      previewError = nil
      applicationMessage = nil
    } catch {
      preview = nil
      previewError = error.localizedDescription
    }
  }

  func apply() {
    guard let document, canApply else { return }
    let command = ColorManagedConversionCommand(
      target: targetChoice.target, options: options)
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([command]), actionName: "Color-Managed Conversion")
    else {
      previewError = "The color conversion was refused by the document session."
      return
    }
    applicationMessage =
      "Color-managed conversion committed as one transaction; the document is modified, "
      + "not saved. Output intent: " + (writeOutputIntent ? "written" : "not written") + "."
    refreshPreview()
  }

  func exportReport() {
    guard let report = preview else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let base = document?.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-color-conversion.txt"
    let text = report.report()
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        self?.applicationMessage = "Color conversion report exported."
      } catch {
        self?.previewError = error.localizedDescription
      }
    }
  }
}

@MainActor
final class ColorManagedConversionWindowController: NSWindowController {
  let model: ColorManagedConversionModel

  init(document: SPDFDocument) {
    let model = ColorManagedConversionModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Color-Managed Conversion"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: ColorManagedConversionView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for color conversion")
  }

  func refresh() { model.refreshPreview() }
}

struct ColorManagedConversionView: View {
  @ObservedObject var model: ColorManagedConversionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Color-Managed Conversion").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "Uses public CoreGraphics color management. Declared profile: DeviceRGB is read "
          + "as sRGB, DeviceGray as Generic Gray gamma 2.2, DeviceCMYK as Generic CMYK; "
          + "embedded ICC profiles are used as authored. Unsupported images are listed as "
          + "refused, never silently flattened.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        Picker("Target", selection: $model.targetChoice) {
          ForEach(ColorConversionTargetChoice.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }
        Picker("Rendering intent", selection: $model.intent) {
          ForEach(ColorRenderingIntent.allCases, id: \.self) { intent in
            Text(intent.title).tag(intent)
          }
        }
        Toggle("Preserve neutral blacks (K-only)", isOn: $model.blackPreservation)
        Toggle("Black point compensation", isOn: $model.blackPointCompensation)
        Toggle("Write output intent with the target ICC profile", isOn: $model.writeOutputIntent)
      }
      .onChange(of: model.targetChoice) { _, _ in model.refreshPreview() }
      .onChange(of: model.intent) { _, _ in model.refreshPreview() }
      .onChange(of: model.blackPreservation) { _, _ in model.refreshPreview() }
      .onChange(of: model.blackPointCompensation) { _, _ in model.refreshPreview() }
      .onChange(of: model.writeOutputIntent) { _, _ in model.refreshPreview() }
      if let error = model.previewError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      ScrollView {
        Text(model.preview?.report() ?? "No convertible images were found.")
          .font(.caption.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      HStack {
        Button("Refresh Preview") { model.refreshPreview() }
        Spacer()
        Button("Export Report…") { model.exportReport() }
        Button("Apply Conversion") { model.apply() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canApply)
          .accessibilityLabel("Apply color-managed conversion")
      }
      if let message = model.applicationMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(minWidth: 680, minHeight: 480)
    .accessibilityLabel("Color-managed conversion")
  }
}

extension SPDFDocument {
  var canShowColorManagedConversion: Bool { editSession.currentGraph != nil }

  func presentColorManagedConversion() {
    if let controller = windowControllers.compactMap({
      $0 as? ColorManagedConversionWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ColorManagedConversionWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
