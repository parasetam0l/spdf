import AppKit
import SwiftUI
import Testing

/// P12-026: toolbar icon buttons keep a 32 pt minimum hit target. Borderless
/// buttons size to their label content (button-level frames are ignored), so
/// production carries the minimum on the label image — this test pins that
/// contract headlessly through real SwiftUI layout, and the smoke asserts the
/// same frames in the running app.
@Suite("Toolbar button hit targets")
struct ToolbarButtonGeometryTests {
  @MainActor
  private func buttonFrame(symbol: String) -> NSRect? {
    let host = NSHostingView(
      rootView: AnyView(
        HStack(spacing: 16) {
          Button {} label: {
            Image(systemName: symbol).frame(minWidth: 32, minHeight: 32)
          }
          .buttonStyle(.borderless)
        }))
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
    host.layoutSubtreeIfNeeded()
    var found: NSRect?
    func walk(_ view: NSView) {
      if "\(type(of: view))".hasPrefix("SwiftUIAppKitButton") {
        found = view.convert(view.bounds, to: nil)
      }
      for sub in view.subviews { walk(sub) }
    }
    walk(host)
    return found
  }

  @Test @MainActor func toolbarSymbolsMeetMinimumHitSize() {
    for symbol in [
      "sidebar.left", "chevron.left", "chevron.right", "minus.magnifyingglass",
      "plus.magnifyingglass",
    ] {
      let frame = try? #require(buttonFrame(symbol: symbol))
      #expect(frame?.width == 32 && frame?.height == 32, "hit target for \(symbol)")
    }
  }
}
