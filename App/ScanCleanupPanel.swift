import AppKit
import MacServices
import PDFEditing
import SwiftUI

/// OCR-04: scan cleanup panel with before/after previews and selective page
/// application. Options only change previews; Apply writes one transaction.
struct ScanCleanupPanel: View {
  @ObservedObject var model: ScanCleanupModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Clean Up Scan")
          .font(.headline)
        Spacer()
        Text(model.message ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      GroupBox("Cleanup") {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          GridRow {
            Toggle(
              "Auto deskew",
              isOn: Binding(
                get: { model.options.deskew != .none },
                set: { enabled in
                  model.options.deskew = enabled ? .automatic : .none
                  model.refreshPreviewsKeepingSelection()
                }))
            Picker(
              "Orientation",
              selection: Binding(
                get: { orientationSelection },
                set: { selection in
                  model.options.orientation = orientation(for: selection)
                  model.refreshPreviewsKeepingSelection()
                })
            ) {
              Text("Auto").tag(0)
              Text("Upright (no rotation)").tag(1)
              Text("Rotate 90 degrees").tag(2)
              Text("Rotate 180 degrees").tag(3)
              Text("Rotate 270 degrees").tag(4)
            }
          }
          GridRow {
            Picker(
              "Crop",
              selection: Binding(
                get: { cropSelection },
                set: { selection in
                  model.options.crop = selection == 0 ? .automaticMargins : .none
                  model.refreshPreviewsKeepingSelection()
                })
            ) {
              Text("Trim margins automatically").tag(0)
              Text("Keep full scan").tag(1)
            }
            HStack(spacing: 12) {
              Toggle(
                "Contrast",
                isOn: Binding(
                  get: { model.options.contrast },
                  set: { value in
                    model.options.contrast = value
                    model.refreshPreviewsKeepingSelection()
                  }))
              Toggle(
                "Whiten background",
                isOn: Binding(
                  get: { model.options.backgroundCleanup },
                  set: { value in
                    model.options.backgroundCleanup = value
                    model.refreshPreviewsKeepingSelection()
                  }))
            }
          }
        }
        .padding(4)
      }

      HStack(spacing: 8) {
        Button("Select All Supported") { model.selectAllSupported() }
        Button("Deselect All") { model.deselectAll() }
        Spacer()
        Text("\(model.supportedSelectedCount) of \(model.selectedCount) selected page(s) ready")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      List {
        ForEach(model.items) { item in
          HStack(alignment: .top, spacing: 8) {
            Toggle(
              "",
              isOn: Binding(
                get: { item.isSelected },
                set: { model.toggleSelection(pageIndex: item.id, selected: $0) }))
              .labelsHidden()
              .disabled(!(item.preview?.isSupported ?? false))
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 8) {
                Text("Page \(item.id + 1)")
                  .font(.subheadline.weight(.semibold))
                if let refusal = item.preview?.refusal {
                  Text(refusal.message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                } else if let detection = item.preview?.detection, let report = item.preview?.report {
                  Text(
                    String(
                      format: "skew %.1f deg, orientation %d, ink %d-%d",
                      detection.skewDegrees, report.appliedOrientationQuarterTurns,
                      report.inkPixelsBefore, report.inkPixelsAfter))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              HStack(spacing: 8) {
                previewImage(item.preview?.beforePNG, label: "Before")
                previewImage(item.preview?.afterPNG, label: "After")
              }
            }
          }
          .padding(.vertical, 2)
        }
      }
      .frame(minHeight: 240)

      HStack {
        Spacer()
        Button("Close") { model.requestClose?() }
        Button("Apply Selected") { model.apply() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canApply)
      }
    }
    .padding(14)
    .frame(minWidth: 620, idealWidth: 700, maxWidth: 900)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Clean Up Scan")
  }

  private var orientationSelection: Int {
    switch model.options.orientation {
    case .automatic: return 0
    case .none: return 1
    case .quarterTurns(let turns):
      switch ((turns % 4) + 4) % 4 {
      case 1: return 2
      case 2: return 3
      default: return 4
      }
    }
  }

  private func orientation(for selection: Int) -> ScanCleanupOptions.Orientation {
    switch selection {
    case 0: return .automatic
    case 1: return .none
    case 2: return .quarterTurns(1)
    case 3: return .quarterTurns(2)
    default: return .quarterTurns(3)
    }
  }

  private var cropSelection: Int {
    if case .none = model.options.crop { return 1 }
    return 0
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
          .frame(width: 150, height: 100)
          .border(Color.secondary.opacity(0.25))
      } else {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.secondary.opacity(0.12))
          .frame(width: 150, height: 100)
          .overlay(Text("No preview").font(.caption2).foregroundStyle(.tertiary))
      }
    }
  }
}

/// OCR-04: utility window that hosts the cleanup panel.
@MainActor
final class ScanCleanupPanelController: NSWindowController {
  let model: ScanCleanupModel

  init(model: ScanCleanupModel) {
    self.model = model
    let hosting = NSHostingController(rootView: ScanCleanupPanel(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Clean Up Scan"
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 720, height: 640))
    window.isReleasedWhenClosed = false
    super.init(window: window)
    model.requestClose = { [weak self] in self?.close() }
  }

  required init?(coder: NSCoder) { nil }

  func refreshPresentation() {
    model.reload()
  }
}
