import SwiftUI

/// P41-009: native update settings — check preferences, the current
/// marketing/build version, the last-check state, and a manual check
/// action. State comes from `AppUpdater` (Sparkle in Release builds,
/// unavailable in Debug); preferences persist through Sparkle's standard
/// defaults and survive restarts.
struct UpdateSettingsView: View {
  @ObservedObject private var updater = AppUpdater.shared

  var body: some View {
    Form {
      Section("Version") {
        LabeledContent("Installed version", value: AppUpdater.currentVersion)
      }
      Section("Checking") {
        if updater.isAvailable {
          Toggle(
            "Automatically check for updates",
            isOn: Binding(
              get: { updater.automaticallyChecksForUpdates },
              set: { updater.automaticallyChecksForUpdates = $0 }))
          LabeledContent(
            "Schedule",
            value: "Daily (\(Int(UpdateSettings.checkIntervalHours)) h) once allowed")
          LabeledContent("Last check", value: UpdateSettings.lastCheckText(updater.lastCheck))
          Button("Check for Updates Now") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        } else {
          Text("Update checks are unavailable in development builds.")
            .foregroundStyle(.secondary)
          LabeledContent("Installed version", value: AppUpdater.currentVersion)
        }
      }
      Section("Policy") {
        Text(
          "Stable releases only; automatic installation stays off so every update asks first. "
            + "Downgrades never go through the updater — reinstall the older published DMG by hand."
        ).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .padding()
  }
}

/// Testable formatting behind the settings view (the view itself is
/// build-verified; the rules live in ReleaseTools' `UpdatePreferences`).
enum UpdateSettings {
  static let checkIntervalHours = 24.0

  static func lastCheckText(_ date: Date?) -> String {
    guard let date else { return "Never" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
