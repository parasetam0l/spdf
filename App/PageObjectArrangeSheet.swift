import AppKit
import PDFEditing
import SwiftUI

/// IMG-04/IMG-05: the explicit arrange panel for a mixed page-object
/// selection. Every button is gated by the same core eligibility matrix the
/// canvas uses, so a refused action explains itself before anything mutates.
struct PageObjectArrangeSheet: View {
  @ObservedObject var controller: PageObjectSelectionController
  @State private var reference: PageObjectArrangementReference = .selection

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          selectionSummary
          if controller.selection != nil {
            referencePicker
            alignSection
            distributeSection
            orderSection
            groupingSection
            editSection
            messages
          }
          profileSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 380, height: 640)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Arrange Objects")
        .font(.system(size: 14, weight: .semibold))
      Text(controller.label)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var selectionSummary: some View {
    if controller.selection == nil {
      VStack(alignment: .leading, spacing: 6) {
        Text("Select page objects first").font(.system(size: 12, weight: .medium))
        Text(
          "Shift-click text boxes, image stamps, rectangles or document images on "
            + "one page, Shift-drag to marquee, or turn on Arrange mode and click "
            + "objects normally."
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    } else if let refusal = controller.refusal(for: .group) {
      Label {
        Text(refusal).fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.system(size: 11))
      .foregroundStyle(.orange)
    }
  }

  private var referencePicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("ALIGN RELATIVE TO").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      Picker("Align relative to", selection: $reference) {
        ForEach(PageObjectArrangementReference.allCases, id: \.self) { value in
          Text(value.displayName).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private var alignSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("ALIGN").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        alignButton(.left, symbol: "align.horizontal.left")
        alignButton(.center, symbol: "align.horizontal.center")
        alignButton(.right, symbol: "align.horizontal.right")
      }
      HStack(spacing: 6) {
        alignButton(.top, symbol: "align.vertical.top")
        alignButton(.middle, symbol: "align.vertical.center")
        alignButton(.bottom, symbol: "align.vertical.bottom")
      }
      .disabled(!controller.canAlign)
    }
  }

  private func alignButton(_ alignment: PageObjectArrangeAlignment, symbol: String) -> some View {
    Button {
      controller.align(alignment, reference: reference)
    } label: {
      Label(alignment.rawValue.capitalized, systemImage: symbol)
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .help(alignment.displayName)
  }

  private var distributeSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("DISTRIBUTE (EQUAL GAPS)").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Button {
          controller.distribute(.horizontal)
        } label: {
          Label("Horizontally", systemImage: "arrow.left.and.right")
            .font(.system(size: 11)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help(PageObjectDistributeAxis.horizontal.displayName)
        Button {
          controller.distribute(.vertical)
        } label: {
          Label("Vertically", systemImage: "arrow.up.and.down")
            .font(.system(size: 11)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help(PageObjectDistributeAxis.vertical.displayName)
      }
      .disabled(!controller.canDistribute)
      Text("Keeps the first and last objects in place.")
        .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
  }

  private var orderSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("PAINT ORDER").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        orderButton(.front, symbol: "square.3.layers.3d.top.filled")
        orderButton(.forward, symbol: "chevron.up")
        orderButton(.backward, symbol: "chevron.down")
        orderButton(.back, symbol: "square.3.layers.3d.bottom.filled")
      }
      .disabled(!controller.canReorder)
      if let refusal = controller.refusal(for: .reorder) {
        Text(refusal).font(.system(size: 10)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func orderButton(_ destination: PageObjectStacking, symbol: String) -> some View {
    Button {
      controller.reorder(destination)
    } label: {
      Image(systemName: symbol).frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .help(destination.displayName)
    .accessibilityLabel(destination.displayName)
  }

  private var groupingSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("GROUP").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Button {
          controller.groupSelection()
        } label: {
          Label("Group", systemImage: "square.on.square.squareshape.controlhandles")
            .font(.system(size: 11)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!controller.canGroup)
        Button {
          controller.ungroupSelection()
        } label: {
          Label("Ungroup", systemImage: "square.dashed")
            .font(.system(size: 11)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!controller.canUngroup)
      }
      Text("Grouping names the objects; the paint itself is never changed.")
        .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
  }

  private var editSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("SELECTION").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Button {
          controller.duplicateSelection()
        } label: {
          Label("Duplicate", systemImage: "plus.square.on.square")
            .font(.system(size: 11)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!controller.canDuplicate)
        Button(role: .destructive) {
          controller.deleteSelection()
        } label: {
          Label("Delete", systemImage: "trash")
            .font(.system(size: 11)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!controller.canDelete)
      }
      if let refusal = controller.refusal(for: .delete) {
        Text(refusal).font(.system(size: 10)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var messages: some View {
    if let refusal = controller.refusalMessage {
      Label {
        Text(refusal).fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.system(size: 11))
      .foregroundStyle(.orange)
    }
    if let status = controller.statusMessage {
      Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var profileSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("PAGE-CONTENT PROFILE").font(.system(size: 10, weight: .semibold))
        .tracking(0.7).foregroundStyle(.secondary)
      Text(controller.declaredProfile)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack {
      Button(controller.isArrangeMode ? "Exit Arrange Mode" : "Arrange Mode") {
        controller.toggleArrangeMode()
      }
      .buttonStyle(.bordered)
      .help("Click and marquee page objects without holding Shift. Esc exits.")
      Spacer()
      Button("Done") {
        controller.dismissArrangeSheet()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(12)
  }
}

extension SPDFDocument {
  /// Menu hook (Edit > Arrange > Arrange Objects...): present the arrange
  /// panel for the current mixed selection, or explain why arrangement is
  /// unavailable. The Lead wires the menu item; this method is the service.
  @MainActor
  func presentPageObjectArrangePanel() {
    pageObjectSelectionController.presentArrangeSheet()
  }

  /// Menu hook: enter or leave the explicit arrange mode that claims plain
  /// clicks and marquee drags for mixed selection.
  @MainActor
  func togglePageObjectArrangeMode() {
    pageObjectSelectionController.toggleArrangeMode()
  }
}
