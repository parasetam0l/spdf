import PDFCore
import SwiftUI

/// One preferences window for document defaults and release updates.
struct SettingsView: View {
  @ObservedObject private var updater = AppUpdater.shared
  @AppStorage(WorkspacePreferences.paperKey) private var paper = BlankPageFormat.a4.rawValue
  @AppStorage(WorkspacePreferences.landscapeKey) private var landscape = false
  @AppStorage(WorkspacePreferences.continuousKey) private var continuous = true

  var body: some View {
    Form {
      Section("Documents") {
        Picker("New PDF paper size", selection: $paper) {
          ForEach(BlankPageFormat.allCases, id: \.rawValue) { format in
            Text(format.title).tag(format.rawValue)
          }
        }
        Toggle("Create new PDFs in landscape", isOn: $landscape)
        Toggle("Open PDFs in continuous view", isOn: $continuous)
      }
      Section("Updates") {
        LabeledContent("Installed version", value: AppUpdater.currentVersion)
        if let guidance = updater.installationGuidance {
          Text(guidance)
          Button("Show Installation Instructions") { updater.checkForUpdates() }
        } else if updater.isAvailable {
          Toggle("Automatically check for updates", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }))
          LabeledContent("Last checked", value: UpdateSettings.lastCheckText(updater.lastCheck))
          Button(updater.isInstallDeferred ? "Resume Update" : "Check for Updates…") {
            updater.checkForUpdates()
          }
          .disabled(!updater.canCheckForUpdates)
          Text("Updates ask before installing.").font(.caption).foregroundStyle(.secondary)
        } else {
          Text("Automatic updates are available in installed release builds.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

enum UpdateSettings {
  static let checkIntervalHours = 24.0

  static func lastCheckText(_ date: Date?) -> String {
    guard let date else { return "Never" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
