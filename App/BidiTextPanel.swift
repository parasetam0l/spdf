import AppKit
import MacServices
import PDFEditing
import SwiftUI

/// FNT-05/FNT-06: a compact insertion panel for bidirectional text, horizontal
/// CJK with kinsoku wrapping, and vertical CJK columns. The heavy lifting and
/// all refusals live in the PDFEditing core; this panel only collects a choice.
struct BidiTextPanel: View {
  @ObservedObject var model: ShapedTextInsertionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Insert Shaped Text")
          .font(.headline)
        Spacer()
        Text(model.pageLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Picker("Profile", selection: $model.mode) {
        ForEach(ShapedTextInsertionModel.Mode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Text")
            .font(.caption.weight(.semibold))
          TextEditor(text: $model.text)
            .font(.body.monospaced())
            .frame(minWidth: 320, minHeight: 120)
            .overlay(
              RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.35)))
            .accessibilityLabel("Shaped text to insert")
        }
        VStack(alignment: .leading, spacing: 8) {
          Picker("Font", selection: $model.fontID) {
            ForEach(ShapedTextInsertionModel.fontChoices) { font in
              Text(font.label).tag(font.id)
            }
          }
          HStack {
            Text("Size")
            TextField("18", value: $model.pointSize, format: .number)
              .frame(width: 60)
            Text("pt").foregroundStyle(.secondary)
          }
          if model.mode == .bidirectional {
            Picker("Direction", selection: $model.baseDirection) {
              Text("Automatic").tag(BidiBaseDirection.automatic)
              Text("Left to right").tag(BidiBaseDirection.leftToRight)
              Text("Right to left").tag(BidiBaseDirection.rightToLeft)
            }
            TextField("Language (optional)", text: $model.language)
              .textFieldStyle(.roundedBorder)
          }
          if model.mode == .verticalCJK {
            HStack {
              Text("Column height")
              TextField("320", value: $model.columnHeight, format: .number)
                .frame(width: 70)
              Text("pt").foregroundStyle(.secondary)
            }
          }
          Text(profileNote)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 240, alignment: .leading)
      }

      if let message = model.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Refresh Page") { model.reload() }
        Spacer()
        Button("Close") { model.requestClose?() }
        Button("Insert") { model.insert() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canInsert)
      }
    }
    .padding(14)
    .frame(minWidth: 680, idealWidth: 760, maxWidth: 900)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Insert Shaped Text")
  }

  private var profileNote: String {
    switch model.mode {
    case .bidirectional:
      return "Shaped by Core Text with explicit logical/visual ordering; the logical text is "
        + "stored as /ActualText so copy, search and extraction keep reading order."
    case .horizontalCJK:
      return "Kinsoku line breaking keeps punctuation with its line; lines are ordinary "
        + "Identity-H runs from the embedded font."
    case .verticalCJK:
      return "True vertical writing mode: Identity-V with /W2 and /DW2, top-to-bottom "
        + "columns ordered right-to-left and declaratively rotated punctuation. "
        + "CJK characters and punctuation only; Latin runs refuse."
    }
  }
}

/// FNT-05/FNT-06: utility window hosting the shaped text insertion panel.
@MainActor
final class ShapedTextInsertionPanelController: NSWindowController {
  let model: ShapedTextInsertionModel

  init(model: ShapedTextInsertionModel) {
    self.model = model
    let hosting = NSHostingController(rootView: BidiTextPanel(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Insert Shaped Text"
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 780, height: 460))
    window.isReleasedWhenClosed = false
    super.init(window: window)
    model.requestClose = { [weak self] in self?.close() }
  }

  required init?(coder: NSCoder) { nil }

  func refreshPresentation() {
    model.reload()
  }
}
