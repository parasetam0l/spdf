import AppKit
import Combine
import Sparkle

/// Updates from GitHub Releases with Sparkle. The feed (`SUFeedURL`) is the
/// `appcast.xml` attached to the latest published release; every update is
/// signed with the EdDSA key whose public half is `SUPublicEDKey` and must
/// carry the same Developer ID signature as the running app. sPDF Editor
/// schedules a daily check once the user allows it and always asks before
/// installing (`SUAllowsAutomaticUpdates` is off). Development builds never
/// check: they are not releases.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = AppUpdater()

  /// Nil in development builds.
  private var controller: SPUStandardUpdaterController?
  private var pendingInstall: (() -> Void)?
  private var installGeneration = UUID()
  @Published private(set) var isInstallDeferred = false
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var lastCheck: Date?
  private var cancellables: Set<AnyCancellable> = []

  var isAvailable: Bool { controller != nil }

  var automaticallyChecksForUpdates: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set {
      objectWillChange.send()
      controller?.updater.automaticallyChecksForUpdates = newValue
    }
  }

  private override init() {
    super.init()
    if CommandLine.arguments.contains("--measure-workspace") {
      // An explicitly requested local measurement never starts network checks
      // or changes the owner's update preference.
      controller = nil
    } else {
      #if DEBUG
        controller = nil
      #else
        controller = SPUStandardUpdaterController(
          startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
      #endif
    }
    if let updater = controller?.updater {
      updater.publisher(for: \.canCheckForUpdates)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
          guard let self else { return }
          canCheckForUpdates = $0 || pendingInstall != nil
        }
        .store(in: &cancellables)
      updater.publisher(for: \.lastUpdateCheckDate)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.lastCheck = $0 }
        .store(in: &cancellables)
    }
  }

  func checkForUpdates() {
    if pendingInstall != nil {
      resumePendingInstall()
      return
    }
    controller?.checkForUpdates(nil)
  }

  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    guard TerminationCoordinator.shared.hasActiveWork,
      !TerminationCoordinator.shared.isPreparing
    else { return false }
    pendingInstall = installHandler
    installGeneration = UUID()
    isInstallDeferred = true
    canCheckForUpdates = true
    resumePendingInstall()
    return true
  }

  private func resumePendingInstall() {
    guard pendingInstall != nil, !TerminationCoordinator.shared.isPreparing else { return }
    let generation = installGeneration
    TerminationCoordinator.shared.postponeUpdate { [weak self] allowed in
      guard let self, generation == installGeneration, allowed,
        let install = pendingInstall
      else { return }
      pendingInstall = nil
      isInstallDeferred = false
      canCheckForUpdates = controller?.updater.canCheckForUpdates ?? false
      // Sparkle subsequently requests AppKit termination. The app-wide gate
      // still reviews pending edits and every document's save decision.
      install()
    }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    installGeneration = UUID()
    pendingInstall = nil
    isInstallDeferred = false
  }

  /// "1.2.0 (1791023807)"
  static var currentVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
  }
}
