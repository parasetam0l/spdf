import AppKit
import MacServices
import SwiftUI

/// FNT-02: the user-facing approval step for missing glyphs. It lists the
/// characters the current font cannot represent and the exact font changes a
/// fallback would make. Compatible same-face subsets are labelled as such; a
/// different face is only applied after the user approves this dialog.
///
/// Hook: the inline text canvas installs
/// formatting.fallbackApprovalHandler = { preview in
///   FontFallbackApprovalPanel.present(preview, over: window)
/// }
/// and calls insertionPlan(_:replacing:requestingFallbackApproval: true).
@MainActor
enum FontFallbackApprovalPanel {
  /// Present the preview and return the user's decision. Nil means the text is
  /// not inserted with a changed font.
  static func present(
    _ preview: NativeFallbackPreview, over window: NSWindow? = nil
  ) -> NativeFallbackApproval? {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Missing Glyphs in the Current Font"
    alert.informativeText = preview.message
    alert.addButton(withTitle: preview.canApply ? "Use Fallback Font" : "OK")
    if preview.canApply { alert.addButton(withTitle: "Cancel") }
    let hosting = NSHostingView(rootView: FontFallbackApprovalView(preview: preview))
    hosting.frame = NSRect(x: 0, y: 0, width: 460, height: height(for: preview))
    alert.accessoryView = hosting
    _ = window
    let response = alert.runModal()
    guard preview.canApply, response == .alertFirstButtonReturn else { return nil }
    return .approving(
      preview.changes.filter(\.requiresExplicitApproval).map(\.toFontName))
  }

  private static func height(for preview: NativeFallbackPreview) -> CGFloat {
    let rows = max(1, preview.changes.count + (preview.canApply ? 0 : 1))
    return min(240, CGFloat(28 + rows * 26))
  }
}

/// Convenience handler for the canvas hook, using the key window.
@MainActor
func presentFontFallbackApproval(_ preview: NativeFallbackPreview) -> NativeFallbackApproval? {
  FontFallbackApprovalPanel.present(preview, over: NSApp.keyWindow)
}

private struct FontFallbackApprovalView: View {
  let preview: NativeFallbackPreview

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Missing characters: \(missingList)")
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
      if preview.changes.isEmpty {
        Text("No supported font can represent these characters. Choose another font or remove them.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(preview.changes.enumerated()), id: \.offset) { _, change in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("“\(change.characters)”")
              .font(.caption.monospaced())
            Image(systemName: "arrow.right").font(.caption2)
            Text(change.toFontName).font(.caption)
            Text(
              change.requiresExplicitApproval
                ? "changed face" : "compatible same-face subset"
            )
            .font(.caption2)
            .foregroundStyle(change.requiresExplicitApproval ? .orange : .secondary)
            Spacer()
          }
        }
        if preview.changes.contains(where: \.requiresExplicitApproval) {
          Text(
            "Applying this inserts the characters in the listed fallback face. The rest of the text keeps its font."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.top, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(preview.message)
  }

  private var missingList: String {
    var seen = Set<String>()
    let unique = preview.requirements.map(\.character).filter { seen.insert($0).inserted }
    return unique.map { "“\($0)”" }.joined(separator: ", ")
  }
}
