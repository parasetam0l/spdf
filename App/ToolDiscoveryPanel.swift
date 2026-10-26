import AppKit
import Combine
import Foundation
import MacServices
import SwiftUI

// UX-03: searchable tool discovery. The panel shows every implemented tool, its
// user-facing limitations, availability reasons, keyboard shortcut, contextual
// controls and recent files. Nothing here is a developer diagnostic.

@MainActor
final class ToolDiscoveryPanelModel: ObservableObject {
  struct ToolRow: Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let summary: String
    let limitations: [String]
    let shortcut: String
    let available: Bool
    let unavailableReason: String
  }

  struct RecentRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
  }

  @Published var query = "" {
    didSet { refresh() }
  }
  @Published var selectedContext: UXToolContext = .documentOpen {
    didSet { refresh() }
  }
  @Published var rows: [ToolRow] = []
  @Published var recentRows: [RecentRow] = []
  @Published var contextualHints: [String] = []
  @Published var statusText = "Search by tool, keyword or limitation."
  @Published var errorText = ""

  init(document: SPDFDocument?) {
    refresh()
    refreshRecent()
  }

  func refresh() {
    let context = selectedContext
    let results = UXToolCatalog.search(query, context: query.isEmpty ? context : nil)
    var filtered = results
    if !query.isEmpty {
      filtered = results.filter { $0.entry.contexts.contains(context) || queryHasExplicitToolMatch(results, context: context) }
    }
    rows = filtered.map { result in
      let entry = result.entry
      return ToolRow(
        id: entry.id, title: entry.title, category: entry.category.rawValue,
        summary: entry.summary, limitations: entry.limitations,
        shortcut: entry.shortcut ?? "no shortcut", available: entry.availability.isAvailable,
        unavailableReason: entry.availability.reason ?? "")
    }
    contextualHints = UXContextualControls.controls(for: context).map {
      $0.title + ": " + $0.hint
    }
    statusText = String(rows.count) + " tool(s); limitations are shown with each tool."
  }

  private func queryHasExplicitToolMatch(
    _ results: [UXToolSearchResult], context: UXToolContext
  ) -> Bool {
    _ = context
    return results.isEmpty ? false : results.contains { result in
      result.entry.title.lowercased().contains(query.lowercased())
    }
  }

  func refreshRecent() {
    recentRows = NSDocumentController.shared.recentDocumentURLs.prefix(8).map { url in
      RecentRow(id: url.path, name: url.lastPathComponent, path: url.path)
    }
  }

  func copyLimitations(for row: ToolRow) {
    let text = row.title + " — limitations:\n" + row.limitations.map { "· " + $0 }
      .joined(separator: "\n")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    statusText = "Copied the limitations for " + row.title + "."
  }
}

@MainActor
final class ToolDiscoveryPanelController: NSWindowController {
  let model: ToolDiscoveryPanelModel
  init(document: SPDFDocument?) {
    let model = ToolDiscoveryPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Find a Tool"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 820, height: 560)
    panel.contentView = NSHostingView(rootView: ToolDiscoveryPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the tool discovery panel")
  }
}

extension SPDFDocument {
  /// UX-03 hook: searchable tool catalog with limitations.
  func showToolDiscoveryPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? ToolDiscoveryPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ToolDiscoveryPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowToolDiscoveryPanel: Bool { true }
}

struct ToolDiscoveryPanelView: View {
  @ObservedObject var model: ToolDiscoveryPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Find a Tool").font(.title3).bold()
          Spacer()
          TextField("Search tool, keyword or limitation", text: $model.query)
            .frame(width: 320)
          Picker("Context", selection: $model.selectedContext) {
            ForEach(UXToolContext.allCases, id: \.self) { context in
              Text(context.rawValue).tag(context)
            }
          }
          .frame(width: 220)
        }
        Text(model.statusText).font(.caption).foregroundStyle(.secondary)
        ForEach(model.rows) { row in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text(row.title).font(.caption.weight(.semibold))
              Text(row.category).font(.caption2).foregroundStyle(.secondary)
              Text(row.shortcut).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
              if !row.available {
                Text("unavailable").font(.caption2).foregroundStyle(.orange)
              }
              Spacer()
              Button("Copy Limitations") { model.copyLimitations(for: row) }
                .buttonStyle(.link)
            }
            Text(row.summary).font(.caption2)
            ForEach(Array(row.limitations.enumerated()), id: \.offset) { item in
              Text("· " + item.element).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !row.unavailableReason.isEmpty {
              Text("Unavailable: " + row.unavailableReason).font(.caption2)
                .foregroundStyle(.orange)
            }
          }
          .padding(8)
          .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        Divider()
        Text("Contextual controls").font(.headline)
        ForEach(Array(model.contextualHints.enumerated()), id: \.offset) { item in
          Text("· " + item.element).font(.caption2)
        }
        Divider()
        HStack {
          Text("Recent files").font(.headline)
          Button("Refresh") { model.refreshRecent() }
        }
        if model.recentRows.isEmpty {
          Text("No recent files yet.").font(.caption2).foregroundStyle(.secondary)
        }
        ForEach(model.recentRows) { row in
          Text(row.name).font(.caption2) + Text("  " + row.path)
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      .padding(16)
    }
    .frame(minWidth: 820, minHeight: 560)
    .accessibilityLabel("Searchable tool catalog with limitations")
  }
}
