import AppKit
import SwiftUI

/// Help menu content: an in-app quick reference plus links to the published
/// public documentation. The window is app-owned (not a document window) so it
/// stays open while documents change.
final class HelpWindowController: NSWindowController {
  static let shared = HelpWindowController()

  private static let docsBase = "https://github.com/parasetam0l/spdf/blob/main/Docs/"

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "sPDF Editor Help"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 480)
    window.center()
    window.contentView = NSHostingView(rootView: HelpPanelView())
    super.init(window: window)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the help window")
  }

  @MainActor
  func show() {
    window?.center()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  @MainActor
  static func openDocumentation(_ page: String) {
    guard let url = URL(string: docsBase + page) else { return }
    NSWorkspace.shared.open(url)
  }

  @MainActor
  static func openIssues() {
    guard let url = URL(string: "https://github.com/parasetam0l/spdf/issues/new") else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct HelpPanelView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text("sPDF Editor Help").font(.largeTitle.bold())
          Spacer()
          Text("Version " + Self.version).font(.caption).foregroundStyle(.secondary)
        }
        Text(
          "A native macOS PDF editor for viewing, editing and producing PDFs locally. "
            + "Everything below runs on this Mac; no cloud service is required.")
          .font(.callout).foregroundStyle(.secondary)

        section("Getting started") {
          bullet("Open a PDF with File > Open… or drag it onto the app.")
          bullet("Use Select to copy text; Edit PDF to edit existing text and objects.")
          bullet("Add Text, Images and Comments insert new content without changing the source bytes until Save.")
          bullet("Press ⌘S to save. The status line shows “All changes saved” when there is nothing pending.")
          bullet("Every panel also shows what it does not claim; read those limits before production output.")
        }

        section("Keyboard shortcuts") {
          shortcut("New PDF", "⌘N")
          shortcut("Open…", "⌘O")
          shortcut("Save", "⌘S")
          shortcut("Find", "⌘F")
          shortcut("Find and Replace", "⌥⌘F")
          shortcut("Export Text…", "⌥⌘T")
          shortcut("Redaction Marks…", "⌥⇧⌘R")
          shortcut("Settings…", "⌘,")
          shortcut("This Help", "⌘?")
        }

        section("Supported workflows") {
          bullet("Read, navigate, search, copy text and export text/images/HTML/DOCX/tables/PowerPoint.")
          bullet("Edit existing text and images, add text boxes, shapes, links and comments.")
          bullet("Organize pages, headers/footers, Bates numbering, bookmarks, cropping and rotation.")
          bullet("Fill, author and validate AcroForm fields; collect form responses into a review table.")
          bullet("Review (markup, notes, summaries), redaction with sanitized copies, OCR and scan cleanup.")
          bullet("Sign with local Keychain/Secure Enclave identities, certify, timestamp and inspect evidence.")
          bullet("Production output: preflight, declared PDF/A and PDF/X subsets, colour management, "
            + "separation preview, quality optimization and advanced print plans.")
          bullet("Automation: a declared CLI, Shortcuts/AppleScript, batch recipes and watched folders.")
        }

        section("Known exclusions") {
          bullet("Document JavaScript is never executed; legacy scripts can be inventoried and removed.")
          bullet("XFA is not rendered or filled; AcroForm fallback fields remain usable.")
          bullet("Hosted review, remote signing, cloud storage and enterprise services are explicit exclusions.")
          bullet("No AI/design generation and no automatic linked cross-page reflow in this version.")
          bullet("Fast-web linearized output is not produced; ordinary saves stay correct and non-linearized.")
        }

        Divider()

        HStack(spacing: 10) {
          Button("Daily-Use Guide") { HelpWindowController.openDocumentation("Daily-Use.md") }
          Button("Compatibility Guide") { HelpWindowController.openDocumentation("Compatibility.md") }
          Spacer()
          Button("Report a Problem…") { HelpWindowController.openIssues() }
        }
        Text(
          "The guides open the published documentation in your browser. The app itself never "
            + "uploads a document or fetches help content in the background.")
          .font(.caption2).foregroundStyle(.secondary)
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("sPDF Editor help")
  }

  private static var version: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
  }

  @ViewBuilder
  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      VStack(alignment: .leading, spacing: 4) { content() }
    }
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("•").foregroundStyle(.secondary)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
    .font(.callout)
  }

  private func shortcut(_ title: String, _ keys: String) -> some View {
    HStack {
      Text(title).font(.callout)
      Spacer()
      Text(keys).font(.callout.monospaced()).foregroundStyle(.secondary)
    }
  }
}
