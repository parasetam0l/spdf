import AppKit
import MacServices
import SwiftUI
import UniformTypeIdentifiers

/// OCR-07: the multi-file OCR queue panel.
struct OCRBatchPanel: View {
  @ObservedObject var model: OCRBatchModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("OCR Files")
          .font(.headline)
        Spacer()
        if model.isRunning {
          ProgressView().controlSize(.small)
        }
        Text(model.progressText)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      HStack {
        Button("Add PDFs…") { model.addFiles() }
          .disabled(model.isRunning)
        Spacer()
        Text(
          "\(model.items.count) file\(model.items.count == 1 ? "" : "s") · "
          + "\(model.successCount) done · \(model.failedCount) failed")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if model.items.isEmpty {
        Text("Add PDF files to recognize them into verified searchable copies.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(model.items) { item in
              HStack(spacing: 8) {
                statusSymbol(item.status)
                VStack(alignment: .leading, spacing: 1) {
                  Text(item.url.lastPathComponent)
                    .font(.caption.monospaced())
                  if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                }
                Spacer()
                Button {
                  model.remove(item)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .accessibilityLabel("Remove \(item.url.lastPathComponent) from the OCR queue")
              }
            }
          }
        }
        .frame(minHeight: 120, maxHeight: 220)
      }

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
        GridRow {
          Text("Output folder").font(.caption)
          HStack(spacing: 6) {
            Text(model.outputDirectory.path)
              .font(.caption2.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
            Button("Choose…") { model.chooseOutputDirectory() }
              .font(.caption)
              .disabled(model.isRunning)
          }
        }
        GridRow {
          Text("Name template").font(.caption)
          TextField("{name}-OCR.pdf", text: $model.nameTemplate)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .disabled(model.isRunning)
            .help("Available tokens: {name} (input file name) and {index} (1-based order)")
        }
        GridRow {
          Text("Language").font(.caption)
          Picker("", selection: $model.selectedLanguage) {
            ForEach(model.languages, id: \.self) { language in
              Text(language).tag(language)
            }
          }
          .labelsHidden()
          .frame(width: 170)
          .disabled(model.isRunning || model.languages.isEmpty)
        }
        GridRow {
          Text("Quality").font(.caption)
          Picker("", selection: $model.level) {
            Text("Accurate").tag(OCRRecognitionLevel.accurate)
            Text("Fast").tag(OCRRecognitionLevel.fast)
          }
          .pickerStyle(.segmented)
          .frame(width: 170)
          .disabled(model.isRunning)
        }
        GridRow {
          Text("Confidence").font(.caption)
          HStack(spacing: 6) {
            Text(String(format: "%.2f", model.minimumConfidence))
              .font(.caption2.monospacedDigit())
            Slider(value: $model.minimumConfidence, in: 0...1, step: 0.05)
              .frame(width: 150)
              .disabled(model.isRunning)
            Text("below = suspect word")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        GridRow {
          Text("Overwrite").font(.caption)
          Toggle("Replace existing outputs", isOn: $model.overwriteExisting)
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(model.isRunning)
        }
      }

      if let message = model.message {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("OCR batch status")
      }
      if !model.failureSummary.isEmpty {
        Text(model.failureSummary)
          .font(.caption2.monospaced())
          .foregroundStyle(.orange)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !model.reportPath.isEmpty {
        Text("Report: \(model.reportPath)")
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      HStack {
        Button("Close") { model.close() }
        Spacer()
        if model.isRunning {
          Button("Cancel") { model.cancel() }
            .keyboardShortcut(.escape, modifiers: [])
        }
        Button("Run OCR Queue") { model.run() }
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(!model.canRun)
      }

      Text(
        "Each file is written to its own verified copy; a failed file never changes a completed "
        + "output. Cancelling keeps finished files, and running again resumes the rest. "
        + "Every output gets searchable text plus review confidence data."
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(minWidth: 600, idealWidth: 680, maxWidth: 900)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("OCR Files")
  }

  @ViewBuilder
  private func statusSymbol(_ status: OCRBatchItemStatus) -> some View {
    switch status {
    case .completed:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .resumed:
      Image(systemName: "arrow.clockwise.circle").foregroundStyle(.blue)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
    case .cancelled:
      Image(systemName: "xmark.circle").foregroundStyle(.secondary)
    case .pending:
      Image(systemName: "circle").foregroundStyle(.secondary)
    }
  }
}

/// OCR-07: hosts the batch queue panel for one document window.
@MainActor
final class OCRBatchPanelController: NSWindowController {
  let model: OCRBatchModel

  init(model: OCRBatchModel) {
    self.model = model
    let hosting = NSHostingController(rootView: OCRBatchPanel(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "OCR Files"
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 680, height: 640))
    window.isReleasedWhenClosed = false
    super.init(window: window)
    model.requestClose = { [weak self] in self?.close() }
  }

  required init?(coder: NSCoder) { nil }
}
