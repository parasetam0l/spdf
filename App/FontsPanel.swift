import MacServices
import SwiftUI

/// P43-002/P43-004: the font inspector with embedding/installed/missing states,
/// paid-font warnings, and an explicit Google Fonts provisioning action.
struct FontsPanel: View {
  @ObservedObject var model: FontsModel
  var onProvision: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Fonts")
          .font(.headline)
        Spacer()
        if model.isBusy {
          ProgressView().controlSize(.small)
        } else if !model.entries.isEmpty {
          Text("\(model.entries.count)").font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
      if let message = model.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
      }
      if model.entries.isEmpty {
        WorkspacePanelEmptyState(
          title: "No document fonts", symbol: "textformat",
          detail: "No fonts are listed in this PDF.")
      } else {
        List {
          Section("Used Fonts") {
            ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  Text(entry.font.familyName)
                    .font(.caption.monospaced())
                  Text(entry.stateLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.installed || entry.font.isEmbedded ? .green : .orange)
                  if entry.font.isSubset {
                    Text("subset").font(.caption2).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text("p\(entry.font.pageIndices.map { String($0 + 1) }.joined(separator: ","))")
                    .font(.caption2).foregroundStyle(.tertiary)
                }
                if let warning = entry.warning {
                  Text(warning).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Fallback: \(entry.fallback)")
                  .font(.caption2).foregroundStyle(.tertiary)
                if entry.needsProvisioning {
                  Button("Get “\(entry.font.familyName)” from Google Fonts…") {
                    onProvision(entry.font.familyName)
                  }
                  .buttonStyle(.borderless)
                  .font(.caption)
                  .disabled(model.isBusy)
                  .accessibilityLabel("Get \(entry.font.familyName) from Google Fonts")
                }
              }
              .padding(.vertical, 2)
            }
          }
          Section {
            Text(
              "Fonts are installed only when you ask, after the license is shown. Commercially licensed fonts are never downloaded or bundled."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Fonts")
  }
}
