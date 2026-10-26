import AppKit
import MacServices
import PDFCore
import PDFEditing
import SwiftUI

// MARK: - OCR-06 mixed-page recognition panel

@MainActor
final class OCRMixedPagesModel: ObservableObject {
  @Published var profiles: [OCRMixedPageProfile] = []
  @Published var selectedPageIndexes: Set<Int> = []
  @Published var replaceExistingLayers = true
  @Published var languages: [String] = []
  @Published var language = "en-US"
  @Published var quality: OCRRecognitionLevel = .accurate
  @Published var statusText: String?
  @Published var errorText: String?
  @Published var isRunning = false

  private weak var document: SPDFDocument?
  private var documentRevision: UInt64 = 0

  init(document: SPDFDocument) {
    self.document = document
    load()
  }

  var workProfiles: [OCRMixedPageProfile] {
    profiles.filter(\.canRunOCR)
  }

  var selectedWorkProfiles: [OCRMixedPageProfile] {
    profiles.filter { selectedPageIndexes.contains($0.pageIndex) && $0.canRunOCR }
  }

  var summaryLine: String {
    "\(profiles.count) pages; \(selectedWorkProfiles.count) selected for bounded OCR; "
      + "\(profiles.filter { $0.action == .skip }.count) skipped."
  }

  func load() {
    guard let document, let graph = document.editSession.currentGraph else {
      profiles = []
      return
    }
    documentRevision = document.editSession.documentRevision
    do {
      let pageIDs = document.editSession.pageIDs
      let plan = try OCRMixedPageService.plan(
        graph: graph, pageIDs: pageIDs,
        options: OCRMixedPageOptions(
          replaceExistingGeneratedLayers: replaceExistingLayers))
      profiles = plan.profiles
      selectedPageIndexes = Set(profiles.filter(\.canRunOCR).map(\.pageIndex))
      statusText = plan.summaryLines.first
      errorText = nil
    } catch {
      profiles = []
      errorText = error.localizedDescription
    }
    if languages.isEmpty {
      languages = (try? VisionTextRecognizer.supportedLanguages()) ?? []
      if let preferred = languages.first(where: { $0 == "en-US" }) {
        language = preferred
      } else if let first = languages.first {
        language = first
      }
    }
  }

  func toggle(_ pageIndex: Int) {
    if selectedPageIndexes.contains(pageIndex) {
      selectedPageIndexes.remove(pageIndex)
    } else {
      selectedPageIndexes.insert(pageIndex)
    }
  }

  func run() {
    guard !isRunning, let document, let graph = document.editSession.currentGraph else {
      return
    }
    let targets = selectedWorkProfiles
    guard !targets.isEmpty else {
      errorText = "Select at least one page that can gain or replace a bounded layer."
      return
    }
    let pageIndexes = targets.map(\.pageIndex).sorted()
    let languages = language.isEmpty ? ["en-US"] : [language]
    let level = quality
    documentRevision = document.editSession.documentRevision
    // A protected session's decrypted graph is rendered only in memory; clear
    // the marker only in the private OCR snapshot (as the document OCR route
    // does), never in the edit session.
    var snapshot = graph
    if document.editSession.isProtected {
      snapshot.trailer[PDFName("Encrypt")] = nil
    }
    let bytes: Data
    do {
      bytes = try PDFWriter.write(
        snapshot, limits: SPDFDocumentResourcePolicy.parsingLimits)
    } catch {
      errorText = error.localizedDescription
      return
    }
    isRunning = true
    statusText = "Recognizing \(pageIndexes.count) page(s) locally..."
    errorText = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { isRunning = false }
      do {
        let results = try await OCRJob.run(
          data: bytes, pageIndexes: pageIndexes, languages: languages, level: level)
        guard document.editSession.documentRevision == documentRevision else {
          errorText = "The document changed during recognition. Run it again on the current pages."
          return
        }
        guard let currentGraph = document.editSession.currentGraph else {
          errorText = "The document is no longer editable."
          return
        }
        let pageIDs = document.editSession.pageIDs
        let plan = try OCRMixedPageService.plan(
          graph: currentGraph, pageIDs: pageIDs,
          options: OCRMixedPageOptions(
            replaceExistingGeneratedLayers: replaceExistingLayers))
        let prepared = OCRMixedPageService.commands(
          results: results, graph: currentGraph, pageIDs: pageIDs, plan: plan)
        guard !prepared.commands.isEmpty else {
          statusText = nil
          errorText = prepared.summaryLines.joined(separator: " ")
          return
        }
        let transaction = PDFTransaction(
          prepared.commands.map { $0 as any PDFEditCommand })
        guard
          document.applyPageOrganizerTransaction(
            transaction, actionName: "Recognize Text (Mixed Pages)")
        else {
          errorText = "The bounded OCR layer was refused by the document session."
          return
        }
        load()
        statusText =
          "Applied \(prepared.commands.count) bounded layer(s): "
          + "\(prepared.acceptedLineCount) line(s) accepted, "
          + "\(prepared.droppedLineCount) dropped as outside scan bounds or duplicate text."
      } catch is CancellationError {
        statusText = "Recognition cancelled; nothing was changed."
      } catch {
        errorText = error.localizedDescription
      }
    }
  }
}

// MARK: - Window

@MainActor
final class OCRMixedPagesWindowController: NSWindowController {
  let model: OCRMixedPagesModel

  init(document: SPDFDocument) {
    let model = OCRMixedPagesModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Recognize Mixed Pages"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 700, height: 480)
    panel.contentView = NSHostingView(rootView: OCRMixedPagesView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the mixed OCR panel")
  }

  func refresh() { model.load() }
}

// MARK: - View

struct OCRMixedPagesView: View {
  @ObservedObject var model: OCRMixedPagesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Recognize Mixed Pages").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "Scanned pages with no text gain a bounded searchable layer; pages that mix a scan "
          + "with selectable digital text gain a layer only inside the scan image bounds, so "
          + "the existing text is never duplicated. Re-recognizing a page replaces only its "
          + "generated layer and never changes pixels, coordinates or image placements.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      controls
      if let error = model.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let status = model.statusText {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      if model.profiles.isEmpty {
        Text("No pages are available.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.profiles.enumerated()), id: \.offset) { _, profile in
              row(profile)
            }
          }
        }
      }
    }
    .padding(16)
    .frame(minWidth: 700, minHeight: 480)
    .accessibilityLabel("Mixed scanned and digital page recognition")
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Toggle(
        "Replace existing generated layers",
        isOn: Binding(
          get: { model.replaceExistingLayers },
          set: { newValue in
            model.replaceExistingLayers = newValue
            model.load()
          }))
        .toggleStyle(.checkbox)
        .accessibilityLabel("Replace existing generated OCR layers")
      Picker("Language", selection: $model.language) {
        ForEach(model.languages, id: \.self) { code in
          Text(code).tag(code)
        }
      }
      .frame(width: 150)
      Picker("Quality", selection: $model.quality) {
        Text("Accurate").tag(OCRRecognitionLevel.accurate)
        Text("Fast").tag(OCRRecognitionLevel.fast)
      }
      .frame(width: 140)
      Spacer()
      Text(model.summaryLine)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Button("Select All Workable") {
        model.selectedPageIndexes = Set(model.workProfiles.map(\.pageIndex))
      }
      Button("Recognize Selected") { model.run() }
        .buttonStyle(.borderedProminent)
        .disabled(model.isRunning || model.selectedWorkProfiles.isEmpty)
        .accessibilityLabel("Recognize selected mixed pages")
    }
  }

  private func row(_ profile: OCRMixedPageProfile) -> some View {
    let selected = model.selectedPageIndexes.contains(profile.pageIndex)
    return HStack(alignment: .top, spacing: 8) {
      Toggle(
        "",
        isOn: Binding(
          get: { selected },
          set: { newValue in
            if newValue {
              model.selectedPageIndexes.insert(profile.pageIndex)
            } else {
              model.selectedPageIndexes.remove(profile.pageIndex)
            }
          }))
        .labelsHidden()
        .disabled(!profile.canRunOCR)
        .accessibilityLabel("Select page \(profile.pageIndex + 1) for OCR")
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("Page \(profile.pageIndex + 1)")
            .font(.caption.weight(.semibold))
          Text(profile.kind.title)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(profile.action.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(
              profile.action == .skip ? Color.secondary : Color.accentColor)
          if !profile.boundedRegions.isEmpty {
            Text("\(profile.boundedRegions.count) bound(s)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Text(profile.summaryLine)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
    .padding(6)
    .background(
      selected && profile.canRunOCR
        ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 6))
  }
}

// MARK: - Document route

extension SPDFDocument {
  var canShowOCRMixedPagesPanel: Bool {
    editSession.currentGraph != nil && !editSession.pageIDs.isEmpty
  }

  func presentOCRMixedPagesPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? OCRMixedPagesWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = OCRMixedPagesWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
