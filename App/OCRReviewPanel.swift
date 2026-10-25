import AppKit
import MacServices
import PDFEditing
import PDFKit
import SwiftUI

/// OCR-03: the keyboard review panel. The queue is driven by Next/Previous,
/// Return stages the correction for the current word, and Apply writes all
/// staged corrections as one undoable document transaction.
struct OCRReviewPanel: View {
  @ObservedObject var model: OCRReviewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Review OCR Text")
          .font(.headline)
        Spacer()
        Text(model.positionLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if model.stagedCount > 0 {
          Text("· \(model.stagedCount) staged")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      if !model.qualityNote.isEmpty {
        Text(model.qualityNote)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let word = model.currentWord {
        VStack(alignment: .leading, spacing: 4) {
          Text("Suspect word")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(word.text)
              .font(.title3.monospaced())
              .textSelection(.enabled)
            Spacer()
            Text(model.provenanceLabel)
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text("p\(word.pageIndex + 1) · line \(word.lineIndex + 1) · word \(word.wordIndex + 1)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
          HStack(spacing: 8) {
            TextField("Corrected word", text: $model.draft)
              .textFieldStyle(.roundedBorder)
              .onSubmit { _ = model.stageCurrentCorrection() }
              .accessibilityLabel("Corrected OCR word")
            Button("Stage") { _ = model.stageCurrentCorrection() }
              .disabled(!model.canCorrect)
              .accessibilityLabel("Stage correction for the current word")
          }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
      } else {
        Text(
          model.hasSession
            ? "No suspect words remain. Apply the staged corrections or close the review."
            : "No OCR review data for this document."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button("Previous") { model.previous() }
          .keyboardShortcut(.leftArrow, modifiers: [.option])
          .disabled(model.remainingCount == 0)
        Button("Next") { model.next() }
          .keyboardShortcut(.rightArrow, modifiers: [.option])
          .disabled(model.remainingCount == 0)
        Button("Skip") { model.skip() }
          .disabled(model.currentWord == nil)
        Spacer()
        Button("Undo Staged") { _ = model.undoLastCorrection() }
          .disabled(model.stagedCount == 0)
      }

      if !model.pageSuspects.isEmpty {
        Text("Suspects on page \(model.pageIndex + 1)")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(model.pageSuspects) { word in
              Button {
                model.select(word)
              } label: {
                HStack(spacing: 6) {
                  Text(word.text)
                    .font(.caption.monospaced())
                  Spacer()
                  Text(word.confidenceLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxHeight: 120)
      }

      if let message = model.message {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("OCR review status")
      }

      HStack {
        Button("Close") { model.requestClose?() }
        Spacer()
        Button("Apply Corrections") { _ = model.applyStagedCorrections() }
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(!model.canApply)
      }

      Text(
        "Corrections rewrite only the invisible searchable layer: the scanned page image is not changed. "
        + "Saved corrections survive reopen and are picked up by search and copy."
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(minWidth: 480, idealWidth: 540, maxWidth: 720)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Review OCR Text")
  }
}

/// OCR-03: hosts the review panel in a utility window and owns its page overlay.
@MainActor
final class OCRReviewPanelController: NSWindowController {
  let model: OCRReviewModel
  private let overlay = OCRReviewOverlayView()
  weak var viewer: PDFViewingSession?

  init(model: OCRReviewModel, viewer: PDFViewingSession?) {
    self.model = model
    self.viewer = viewer
    let hosting = NSHostingController(rootView: OCRReviewPanel(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Review OCR Text"
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 560, height: 560))
    window.isReleasedWhenClosed = false
    super.init(window: window)
    model.requestClose = { [weak self] in self?.closePanel() }
  }

  required init?(coder: NSCoder) { nil }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    attachOverlay()
    refreshOverlay()
  }

  func refreshOverlay() {
    overlay.viewer = viewer
    overlay.update(
      pageIndex: model.currentWord?.pageIndex ?? model.pageIndex,
      suspectRects: model.pageSuspects.map(\.rect),
      currentRect: model.currentWord?.rect)
  }

  func closePanel() {
    overlay.removeFromSuperview()
    close()
  }

  private func attachOverlay() {
    guard let view = viewer?.view else { return }
    overlay.frame = view.bounds
    overlay.autoresizingMask = [.width, .height]
    if overlay.superview !== view {
      view.addSubview(overlay, positioned: .above, relativeTo: nil)
    }
  }
}
