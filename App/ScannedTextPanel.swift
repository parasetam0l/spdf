import AppKit
import MacServices
import PDFEditing
import SwiftUI

/// OCR-05: editable scanned-text reconstruction panel. Pick a recognized word,
/// type the replacement, inspect the before/after preview, then apply.
struct ScannedTextPanel: View {
  @ObservedObject var model: ScannedTextModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Reconstruct Scanned Text")
          .font(.headline)
        Spacer()
        Text(model.pageLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(
        "The selected word's original pixels are erased from the scan and replaced by "
          + "editable, selectable text; untouched words keep their searchable layer."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Recognized words")
            .font(.caption.weight(.semibold))
          List(model.words, id: \.self) { word in
            wordRow(word)
          }
          .frame(minWidth: 220, minHeight: 300)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Replacement")
              .font(.caption.weight(.semibold))
            TextField("Replacement word", text: $model.replacement)
              .textFieldStyle(.roundedBorder)
              .onSubmit { model.updatePreview() }
              .accessibilityLabel("Replacement word")
          }
          HStack(spacing: 8) {
            Button("Preview") { model.updatePreview() }
              .disabled(!model.canPreview)
            Button("Apply") { model.apply() }
              .keyboardShortcut(.defaultAction)
              .disabled(!model.canApply)
          }
          if let message = model.message {
            Text(message)
              .font(.caption2)
              .foregroundStyle(
                model.preview?.isSupported == true ? Color.secondary : Color.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(alignment: .top, spacing: 8) {
            previewImage(model.preview?.beforePNG, label: "Before")
            previewImage(model.preview?.afterPNG, label: "After (preview)")
          }
          if let layout = model.preview?.layout {
            Text(
              String(
                format: "Erased %.1f%% ink; replacement %.1f pt at (%.0f, %.0f)",
                (model.preview?.erasedInkRatio ?? 0) * 100, layout.fontSize,
                layout.x, layout.baseline))
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
          Spacer(minLength: 0)
        }
      }

      HStack {
        Button("Refresh Page") { model.reload() }
        Spacer()
        Button("Close") { model.requestClose?() }
      }
    }
    .padding(14)
    .frame(minWidth: 720, idealWidth: 820, maxWidth: 1_000, minHeight: 480)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Reconstruct Scanned Text")
  }

  @ViewBuilder
  private func wordRow(_ word: ScannedWord) -> some View {
    Button {
      model.select(word)
    } label: {
      HStack(spacing: 6) {
        Image(
          systemName: model.selectedWord == word
            ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(
            model.selectedWord == word ? Color.accentColor : Color.secondary)
        Text(word.text)
          .font(.callout.monospaced())
          .lineLimit(1)
        Spacer()
        Text("line \(word.lineIndex + 1) · word \(word.wordIndex + 1)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func previewImage(_ data: Data?, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      if let data, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 300, height: 200)
          .border(Color.secondary.opacity(0.25))
      } else {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.secondary.opacity(0.12))
          .frame(width: 300, height: 200)
          .overlay(Text("Preview to see pixels").font(.caption2).foregroundStyle(.tertiary))
      }
    }
  }
}

/// OCR-05: utility window that hosts the reconstruction panel.
@MainActor
final class ScannedTextPanelController: NSWindowController {
  let model: ScannedTextModel

  init(model: ScannedTextModel) {
    self.model = model
    let hosting = NSHostingController(rootView: ScannedTextPanel(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Reconstruct Scanned Text"
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 860, height: 560))
    window.isReleasedWhenClosed = false
    super.init(window: window)
    model.requestClose = { [weak self] in self?.close() }
  }

  required init?(coder: NSCoder) { nil }

  func refreshPresentation() {
    model.reload()
  }
}
