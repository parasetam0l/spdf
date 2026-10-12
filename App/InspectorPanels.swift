import MacServices
import SwiftUI

/// P12-011: a properties inspector that follows the current page selection.
struct SelectionInspectorPanel: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    Form {
      Section("Selection") {
        if let summary = viewer.selectedObjectSummary,
          let details = viewer.selectionDetails
        {
          LabeledContent("Summary") { Text(summary).textSelection(.enabled) }
          LabeledContent("Page") { Text("\(details.pageNumber)") }
          LabeledContent("Text") { Text(details.text).textSelection(.enabled) }
          if let bounds = details.bounds, bounds.count == 4 {
            LabeledContent("Bounds") {
              Text(
                "\(Int(bounds[0])), \(Int(bounds[1])) – \(Int(bounds[2])), \(Int(bounds[3])) pt"
              ).textSelection(.enabled)
            }
          }
          if viewer.activeTool != .select {
            LabeledContent("Tool") { Text(viewer.activeTool.rawValue) }
          }
        } else {
          Text("Nothing selected. Select page text to inspect it here.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .accessibilityLabel("Selection inspector")
  }
}

/// P12-020: a document-information panel from the core inventory.
struct DocumentInfoPanel: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    Form {
      if let info = viewer.documentInfo {
        Section("Document") {
          LabeledContent("File") { Text(info.fileName).textSelection(.enabled) }
          LabeledContent("Pages") { Text("\(info.pageCount)") }
          row("Title", info.title)
          row("Author", info.author)
          row("Subject", info.subject)
          row("Keywords", info.keywords)
          row("Creator", info.creator)
          row("Producer", info.producer)
          row("Language", info.language)
        }
        if let capability = info.capabilitySummary, !capability.isEmpty {
          Section("Capabilities") {
            Text(capability).foregroundStyle(.secondary)
          }
        }
      } else {
        Text("Document information is unavailable.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .accessibilityLabel("Document information")
  }

  private func row(_ title: String, _ value: String?) -> some View {
    LabeledContent(title) {
      Text(value ?? "—").foregroundStyle(value == nil ? .secondary : .primary)
        .textSelection(.enabled)
    }
  }
}
