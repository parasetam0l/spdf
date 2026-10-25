import AppKit
import DocumentSession
import PDFCore
import PDFEditing
import SwiftUI

/// PAG-07: one ordered source file in the batch window.
struct BatesBatchSource: Identifiable, Equatable {
  let url: URL
  let pageCount: Int

  var id: String { url.path }
  var name: String { url.lastPathComponent }
}

/// PAG-07: the ordered file list and settings for a Bates batch. The document
/// is not involved: the batch reads the chosen files, writes numbered copies
/// and a filename/mapping report to a chosen folder.
@MainActor
final class BatesBatchModel: ObservableObject {
  @Published var files: [BatesBatchSource]
  @Published var prefix = ""
  @Published var suffix = ""
  @Published var startNumber = "1"
  @Published var digits = "6"
  @Published var placementIndex = 4
  @Published var margin = "36"
  @Published var fontIndex = 0
  @Published var size = "9"
  @Published var opacity = "1"
  @Published var continuesAcrossFiles = true
  @Published var excludedPages = ""
  @Published var leadingExcludedPages = "0"

  var onRun: ((BatesBatchSettings) -> Void)?
  var onCancel: (() -> Void)?

  init(files: [BatesBatchSource]) {
    self.files = files
  }

  var totalPages: Int { files.reduce(0) { $0 + $1.pageCount } }

  func moveUp(_ id: BatesBatchSource.ID) {
    guard let index = files.firstIndex(where: { $0.id == id }), index > 0 else { return }
    files.swapAt(index, index - 1)
  }

  func moveDown(_ id: BatesBatchSource.ID) {
    guard let index = files.firstIndex(where: { $0.id == id }),
      index + 1 < files.count
    else { return }
    files.swapAt(index, index + 1)
  }

  func remove(_ id: BatesBatchSource.ID) {
    files.removeAll { $0.id == id }
  }

  /// PAG-07: the settings collected by the window. Excluded-page validation and
  /// digit-width disclosure happen again in the core planner.
  var settings: BatesBatchSettings {
    let largestPageCount = max(files.map(\.pageCount).max() ?? 1, 1)
    let exclusions = PageRange.parse(excludedPages, pageCount: largestPageCount)
      .map { $0 + 1 }
    let family = [
      AddedTextStyle.Family.helvetica, .times, .courier,
    ][max(0, min(fontIndex, 2))]
    let placement = RepeatedMarkPlacement.allCases[
      max(0, min(placementIndex, RepeatedMarkPlacement.allCases.count - 1))]
    return BatesBatchSettings(
      prefix: prefix, suffix: suffix,
      startNumber: Int(startNumber) ?? 1, digits: Int(digits) ?? 6,
      style: AddedTextStyle(
        family: family, size: Double(size) ?? 9, opacity: Double(opacity) ?? 1),
      placement: placement, margin: Double(margin) ?? 36,
      continuesAcrossFiles: continuesAcrossFiles,
      excludedPages: exclusions,
      leadingExcludedPages: Int(leadingExcludedPages) ?? 0)
  }
}

/// PAG-07: the ordered-file window. Files are numbered top to bottom; moving a
/// file changes its place in the requested sequence.
struct BatesBatchPanel: View {
  @ObservedObject var model: BatesBatchModel
  @State private var selection: BatesBatchSource.ID?

  private var summary: String {
    let fileWord = model.files.count == 1 ? "file" : "files"
    let pageWord = model.totalPages == 1 ? "page" : "pages"
    return "Files are numbered top to bottom. "
      + "\(model.files.count) \(fileWord), \(model.totalPages) \(pageWord)."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Bates Numbering (Batch)").font(.headline)
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
      List(selection: $selection) {
        ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
          HStack {
            Text("\(index + 1).")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(file.pageCount == 1 ? "1 page" : "\(file.pageCount) pages")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(file.id)
        }
      }
      .frame(minHeight: 150)
      HStack {
        Button("Move Up") {
          if let selection { model.moveUp(selection) }
        }
        .disabled(selection == nil)
        Button("Move Down") {
          if let selection { model.moveDown(selection) }
        }
        .disabled(selection == nil)
        Button("Remove") {
          if let selection {
            model.remove(selection)
            self.selection = nil
          }
        }
        .disabled(selection == nil)
        Spacer()
      }
      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
        GridRow {
          Text("Prefix:").gridColumnAlignment(.trailing)
          TextField("Bates-", text: $model.prefix).frame(width: 160)
          Text("Suffix:").gridColumnAlignment(.trailing)
          TextField("", text: $model.suffix).frame(width: 160)
        }
        GridRow {
          Text("Start number:").gridColumnAlignment(.trailing)
          TextField("1", text: $model.startNumber).frame(width: 90)
          Text("Digits:").gridColumnAlignment(.trailing)
          TextField("6", text: $model.digits).frame(width: 90)
        }
        GridRow {
          Text("Placement:").gridColumnAlignment(.trailing)
          Picker("", selection: $model.placementIndex) {
            ForEach(Array(RepeatedMarkPlacement.allCases.enumerated()), id: \.offset) {
              index, placement in
              Text(placement.displayName).tag(index)
            }
          }
          .labelsHidden()
          .frame(width: 160)
          Text("Margin:").gridColumnAlignment(.trailing)
          TextField("36", text: $model.margin).frame(width: 90)
        }
        GridRow {
          Text("Font:").gridColumnAlignment(.trailing)
          Picker("", selection: $model.fontIndex) {
            Text("Helvetica").tag(0)
            Text("Times").tag(1)
            Text("Courier").tag(2)
          }
          .labelsHidden()
          .frame(width: 160)
          Text("Size:").gridColumnAlignment(.trailing)
          TextField("9", text: $model.size).frame(width: 90)
        }
        GridRow {
          Text("Excluded pages:").gridColumnAlignment(.trailing)
          TextField("1, 3-5", text: $model.excludedPages).frame(width: 160)
          Text("Opacity:").gridColumnAlignment(.trailing)
          TextField("1", text: $model.opacity).frame(width: 90)
        }
        GridRow {
          Text("Leading excluded:").gridColumnAlignment(.trailing)
          TextField("0", text: $model.leadingExcludedPages).frame(width: 90)
          Text("Continuity:").gridColumnAlignment(.trailing)
          Toggle("Continue across files", isOn: $model.continuesAcrossFiles)
            .toggleStyle(.checkbox)
        }
      }
      .font(.caption)
      HStack {
        Spacer()
        Button("Cancel") { model.onCancel?() }
        Button("Number and Save…") { model.onRun?(model.settings) }
          .keyboardShortcut(.defaultAction)
          .disabled(model.files.isEmpty)
      }
    }
    .padding(16)
    .frame(minWidth: 620, minHeight: 620)
    .accessibilityLabel("Bates numbering batch")
  }
}

/// PAG-07: a Sendable error carrier for the background batch task.
private struct BatesBatchFailure: Error, Sendable {
  let message: String
}

/// PAG-07: the completed batch, including where the numbered copies and the
/// filename/mapping report were written.
struct BatesBatchRunResult {
  let report: BatesMappingReport
  let outputDirectory: URL
  let outputs: [URL]
  let mappingCSVURL: URL
  let mappingJSONURL: URL
  let skipped: [String]
}

/// PAG-07: read the ordered input files, write numbered copies through the
/// verified writer, verify each output, and write the CSV/JSON mapping report.
enum BatesBatchService {
  static func run(
    inputURLs: [URL], settings: BatesBatchSettings, outputDirectory: URL,
    limits: PDFLimits = PDFLimits()
  ) throws -> BatesBatchRunResult {
    // Deduplicate identical paths while preserving the user's order.
    var seen: Set<String> = []
    var ordered: [URL] = []
    for url in inputURLs where seen.insert(url.standardizedFileURL.path).inserted {
      ordered.append(url)
    }
    var eligible: [(url: URL, pageCount: Int)] = []
    var skipped: [String] = []
    for url in ordered {
      do {
        let data = try SPDFDocumentResourcePolicy.readPDFData(at: url)
        let parsed = try PDFParser.parse(data, limits: limits)
        guard parsed.encryption == nil else {
          skipped.append(
            "\(url.lastPathComponent): encrypted files are not rewritten by this batch.")
          continue
        }
        let facts = PDFDocumentInventory.documentFacts(
          in: parsed.graph, pageCount: parsed.pageCount)
        guard facts.security.signatureCount == 0 else {
          skipped.append(
            "\(url.lastPathComponent): digitally signed; adding marks would invalidate "
              + "the signature.")
          continue
        }
        eligible.append((url, parsed.pageCount))
      } catch {
        skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    guard !eligible.isEmpty else {
      throw PDFError(
        .malformed,
        "No eligible PDFs remain: " + skipped.joined(separator: "; "))
    }
    let plan = try BatesBatchPlanner.plan(
      files: eligible.map {
        BatesBatchFile(name: $0.url.lastPathComponent, pageCount: $0.pageCount)
      }, settings: settings)
    do {
      try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
    } catch {
      throw PDFError(
        .malformed,
        "The output folder could not be created: \(error.localizedDescription)")
    }
    let batchID = UUID().uuidString
    var outputs: [URL] = []
    var verifications: [BatesBatchVerification] = []
    var issues = skipped + plan.issues
    for (index, assignment) in plan.files.enumerated() {
      let sourceURL = eligible[index].url
      let groupID = "SPDFBATES-\(batchID)-\(index)"
      do {
        let data = try SPDFDocumentResourcePolicy.readPDFData(at: sourceURL)
        let parsed = try PDFParser.parse(data, limits: limits)
        guard parsed.pageCount == assignment.pageCount else {
          issues.append(
            "\(assignment.name): the page count changed after it was read; skipped.")
          continue
        }
        guard let command = assignment.command(
          pageIDs: parsed.pageIDs, groupID: groupID)
        else {
          issues.append("\(assignment.name): every page is excluded; no output written.")
          continue
        }
        let updated = try PDFEditingEngine.commit(
          PDFTransaction([command]), to: parsed.graph, limits: limits)
        let bytes = try PDFWriter.write(updated)
        let outputURL = outputURL(
          for: sourceURL, order: index + 1, in: outputDirectory)
        try VerifiedFileWriter.write(
          bytes, to: outputURL, expectedGraph: updated, limits: limits)
        let written = try PDFParser.parse(
          try Data(contentsOf: outputURL), limits: limits)
        let verification = BatesBatchVerifier.verify(
          graph: written.graph, pageIDs: written.pageIDs,
          assignment: assignment, groupID: groupID)
        if !verification.isVerified {
          issues.append(contentsOf: verification.issues.map {
            "\(assignment.name): \($0)"
          })
        }
        outputs.append(outputURL)
        verifications.append(verification)
      } catch {
        issues.append("\(assignment.name): \(error.localizedDescription)")
      }
    }
    guard !outputs.isEmpty else {
      throw PDFError(
        .malformed,
        "No numbered files were written: " + issues.joined(separator: "; "))
    }
    let report = BatesMappingReport(
      plan: plan, verifications: verifications, issues: issues)
    let csvURL = outputDirectory.appendingPathComponent("bates-mapping.csv")
    let jsonURL = outputDirectory.appendingPathComponent("bates-mapping.json")
    try Data(report.csv().utf8).write(to: csvURL, options: .atomic)
    try report.jsonData().write(to: jsonURL, options: .atomic)
    return BatesBatchRunResult(
      report: report, outputDirectory: outputDirectory, outputs: outputs,
      mappingCSVURL: csvURL, mappingJSONURL: jsonURL, skipped: skipped)
  }

  /// PAG-07: predictable, order-prefixed output names so same-named inputs in
  /// different folders never collide in the output folder.
  static func outputURL(
    for source: URL, order: Int, in directory: URL
  ) -> URL {
    let base = source.deletingPathExtension().lastPathComponent
    return directory.appendingPathComponent(
      String(format: "%03d-", order) + base + "-bates.pdf")
  }
}

extension ApplicationDelegate {
  /// PAG-07: choose PDFs, order them, choose settings and a destination, then
  /// number the files and write the mapping report. No open document is needed.
  func presentBatesBatch() {
    let open = NSOpenPanel()
    open.allowedContentTypes = [.pdf]
    open.allowsMultipleSelection = true
    open.message = "Choose PDFs, then order them in the Bates numbering window."
    open.prompt = "Choose"
    open.begin { [weak self] response in
      guard response == .OK, !open.urls.isEmpty, let self else { return }
      var sources: [BatesBatchSource] = []
      var skipped: [String] = []
      for url in open.urls {
        do {
          let data = try SPDFDocumentResourcePolicy.readPDFData(at: url)
          let parsed = try PDFParser.parse(
            data, limits: SPDFDocumentResourcePolicy.parsingLimits)
          sources.append(BatesBatchSource(url: url, pageCount: parsed.pageCount))
        } catch {
          skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
      guard !sources.isEmpty else {
        NSDocumentController.shared.presentError(
          PDFError(
            .malformed,
            "None of the selected PDFs could be read: " + skipped.joined(separator: "; ")))
        return
      }
      self.showBatesBatchWindow(sources: sources)
    }
  }

  private func showBatesBatchWindow(sources: [BatesBatchSource]) {
    let model = BatesBatchModel(files: sources)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 660),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Bates Numbering (Batch)"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: BatesBatchPanel(model: model))
    model.onCancel = { [weak self, weak window] in
      window?.close()
      self?.batesBatchModel = nil
      self?.batesBatchWindow = nil
    }
    model.onRun = { [weak self, weak window] settings in
      guard let self, let window else { return }
      self.chooseBatesBatchDestination(
        model: model, settings: settings, parent: window)
    }
    batesBatchModel = model
    batesBatchWindow = window
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func chooseBatesBatchDestination(
    model: BatesBatchModel, settings: BatesBatchSettings, parent: NSWindow
  ) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Number Files"
    panel.message =
      "Choose the folder for the numbered PDFs and the mapping report. "
      + "Existing files with the same names are replaced."
    panel.beginSheetModal(for: parent) { [weak self] response in
      guard response == .OK, let directory = panel.url, let self else { return }
      parent.close()
      self.batesBatchModel = nil
      self.batesBatchWindow = nil
      self.runBatesBatch(
        sources: model.files.map(\.url), settings: settings,
        outputDirectory: directory, parent: nil)
    }
  }

  private func runBatesBatch(
    sources: [URL], settings: BatesBatchSettings, outputDirectory: URL,
    parent: NSWindow?
  ) {
    let progressWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 90),
      styleMask: [.titled], backing: .buffered, defer: false)
    progressWindow.title = "Bates Numbering"
    progressWindow.isReleasedWhenClosed = false
    let label = NSTextField(
      labelWithString: "Numbering \(sources.count) file"
        + (sources.count == 1 ? "" : "s") + "…")
    label.frame = NSRect(x: 20, y: 54, width: 340, height: 20)
    let indicator = NSProgressIndicator(
      frame: NSRect(x: 20, y: 26, width: 340, height: 20))
    indicator.style = .bar
    indicator.isIndeterminate = true
    indicator.startAnimation(nil)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
    content.addSubview(label)
    content.addSubview(indicator)
    progressWindow.contentView = content
    let host = parent ?? NSApp.keyWindow
    if let host {
      host.beginSheet(progressWindow)
    } else {
      progressWindow.center()
      progressWindow.makeKeyAndOrderFront(nil)
    }
    Task { @MainActor in
      let outcome: Result<BatesBatchRunResult, BatesBatchFailure> = await Task.detached(
        priority: .userInitiated
      ) {
        do {
          return .success(
            try BatesBatchService.run(
              inputURLs: sources, settings: settings,
              outputDirectory: outputDirectory,
              limits: SPDFDocumentResourcePolicy.parsingLimits))
        } catch {
          return .failure(
            BatesBatchFailure(message: error.localizedDescription))
        }
      }.value
      if let host {
        host.endSheet(progressWindow)
      }
      progressWindow.orderOut(nil)
      switch outcome {
      case .success(let result):
        self.presentBatesBatchResult(result)
      case .failure(let failure):
        NSDocumentController.shared.presentError(
          PDFError(.malformed, failure.message))
      }
    }
  }

  private func presentBatesBatchResult(_ result: BatesBatchRunResult) {
    let alert = NSAlert()
    let verified = result.report.isVerified && result.skipped.isEmpty
    alert.messageText = verified
      ? "Bates Numbering Complete"
      : "Bates Numbering Finished with Checks"
    var detail = result.report.summary
    detail += "\n\nNumbered PDFs: \(result.outputs.count) in \(result.outputDirectory.path)"
    detail += "\nMapping report: \(result.mappingCSVURL.lastPathComponent)"
    detail += " and \(result.mappingJSONURL.lastPathComponent)"
    if !result.skipped.isEmpty {
      detail += "\n\nSkipped inputs:\n" + result.skipped.joined(separator: "\n")
    }
    if detail.count > 4_000 {
      detail = String(detail.prefix(4_000)) + "\n…"
    }
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Show Output Folder")
    if alert.runModal() == .alertSecondButtonReturn {
      NSWorkspace.shared.open(result.outputDirectory)
    }
  }
}
