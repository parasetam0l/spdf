import PDFEditing
import SwiftUI

/// P32-002/P32-005/P32-008/P32-021: the comparison workspace window. The
/// change list navigates both panes through the explicit mapping, page pairs
/// can be corrected manually, and overlay/blink modes compare the same pair.
struct ComparisonWindowView: View {
  @ObservedObject var session: ComparisonSession
  var onSaveReport: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      HSplitView {
        sidebar
          .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
        panes
          .frame(minWidth: 520)
      }
    }
    .frame(minWidth: 860, minHeight: 560)
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Picker("Mode", selection: $session.mode) {
        ForEach(ComparisonSession.Mode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 280)
      .accessibilityLabel("Comparison mode")
      Divider().frame(height: 18)
      Button {
        session.selectPreviousChange()
      } label: {
        Label("Previous Change", systemImage: "chevron.left")
      }
      .disabled(session.changes.isEmpty)
      Button {
        session.selectNextChange()
      } label: {
        Label("Next Change", systemImage: "chevron.right")
      }
      .disabled(session.changes.isEmpty)
      Text(changeLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Text("Page \(session.leftPageIndex + 1) ↔ "
        + (session.rightIndex(forLeft: session.leftPageIndex).map { "\($0 + 1)" } ?? "—"))
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Reset Mapping") { try? session.resetMapping() }
        .font(.caption)
      Button("Save Report…", action: onSaveReport)
        .font(.caption)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var changeLabel: String {
    guard let index = session.selectedChangeIndex, let change = session.selectedChange else {
      return "\(session.changes.count) difference(s)"
    }
    return "\(index + 1)/\(session.changes.count): \(change.kind.rawValue)"
  }

  private var sidebar: some View {
    List {
      Section("Changes") {
        ForEach(Array(session.changes.enumerated()), id: \.offset) { index, change in
          Button {
            session.selectChange(index)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(changeTitle(change))
                .font(.caption.weight(index == session.selectedChangeIndex ? .semibold : .regular))
              Text(change.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .buttonStyle(.plain)
        }
      }
      Section("Page Mapping") {
        ForEach(Array(session.mapping.enumerated()), id: \.offset) { _, pair in
          if let leftIndex = pair.leftIndex {
            HStack {
              Text("L\(leftIndex + 1)")
                .font(.caption.monospaced())
              Picker(
                "maps to",
                selection: Binding(
                  get: { pair.rightIndex ?? -1 },
                  set: { newValue in
                    try? session.correctMapping(
                      leftIndex: leftIndex, toRightIndex: newValue < 0 ? nil : newValue)
                  })
              ) {
                Text("— (none)").tag(-1)
                ForEach(0..<session.rightDocument.pageCount, id: \.self) { rightIndex in
                  Text("R\(rightIndex + 1)").tag(rightIndex)
                }
              }
              .labelsHidden()
              .font(.caption)
              Text(pair.status.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          } else if let rightIndex = pair.rightIndex {
            Text("— ↔ R\(rightIndex + 1) [inserted]")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func changeTitle(_ change: PDFComparisonChange) -> String {
    let page = change.rightPageIndex.map { "R\($0 + 1)" }
      ?? change.leftPageIndex.map { "L\($0 + 1)" } ?? "document"
    return "\(page) · \(change.kind.rawValue)" + (change.isOCRSourced ? " [OCR]" : "")
  }

  @ViewBuilder
  private var panes: some View {
    switch session.mode {
    case .sideBySide:
      HStack(spacing: 1) {
        ComparisonPane(
          document: session.leftDocument, pageIndex: session.leftPageIndex,
          onPageChanged: { session.leftPageChanged(to: $0) })
        ComparisonPane(
          document: session.rightDocument, pageIndex: session.rightPageIndex,
          onPageChanged: { session.rightPageChanged(to: $0) })
      }
    case .overlay:
      ZStack {
        ComparisonPane(
          document: session.rightDocument, pageIndex: session.rightPageIndex,
          onPageChanged: { session.rightPageChanged(to: $0) })
        if let image = session.differenceImage() {
          GeometryReader { geometry in
            Image(decorative: image, scale: 1)
              .resizable()
              .interpolation(.none)
              .opacity(0.65)
              .frame(width: geometry.size.width, height: geometry.size.height)
          }
          .allowsHitTesting(false)
          .accessibilityLabel("Differences overlaid in red")
        }
      }
    case .blink:
      ComparisonPane(
        document: session.blinkShowsLeft ? session.leftDocument : session.rightDocument,
        pageIndex: session.blinkShowsLeft ? session.leftPageIndex : session.rightPageIndex,
        onPageChanged: { index in
          if session.blinkShowsLeft {
            session.leftPageChanged(to: index)
          } else {
            session.rightPageChanged(to: index)
          }
        })
    }
  }
}
