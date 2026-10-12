import Foundation

/// P10-023: window and navigation state, stored separately from document
/// edits so restoring a view never replays transactions.
public struct ViewState: Sendable, Equatable {
  public var windowFrame: [Double]
  public var pageNumber: Int
  public var scale: Double
  public var sidebarVisible: Bool
  public var sidebarMode: String
  /// P12-019: restored sidebar width in points (0 means automatic).
  public var sidebarWidth: Double
  /// P12-019: whether the page layout was continuous.
  public var continuous: Bool

  public init(
    windowFrame: [Double] = [], pageNumber: Int = 1, scale: Double = 0,
    sidebarVisible: Bool = true, sidebarMode: String = "pages",
    sidebarWidth: Double = 0, continuous: Bool = true
  ) {
    self.windowFrame = windowFrame
    self.pageNumber = max(1, pageNumber)
    self.scale = scale
    self.sidebarVisible = sidebarVisible
    self.sidebarMode = sidebarMode
    self.sidebarWidth = max(0, sidebarWidth)
    self.continuous = continuous
  }
}

/// P10-023: owner-only JSON files keyed like recovery records.
public struct ViewStateStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public func save(_ state: ViewState, for key: String) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let payload: [String: Any] = [
      "windowFrame": state.windowFrame,
      "pageNumber": state.pageNumber,
      "scale": state.scale,
      "sidebarVisible": state.sidebarVisible,
      "sidebarMode": state.sidebarMode,
      "sidebarWidth": state.sidebarWidth,
      "continuous": state.continuous,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let url = directory.appendingPathComponent("view-\(key).json")
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public func load(for key: String) -> ViewState? {
    let url = directory.appendingPathComponent("view-\(key).json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return ViewState(
      windowFrame: object["windowFrame"] as? [Double] ?? [],
      pageNumber: object["pageNumber"] as? Int ?? 1,
      scale: object["scale"] as? Double ?? 0,
      sidebarVisible: object["sidebarVisible"] as? Bool ?? true,
      sidebarMode: object["sidebarMode"] as? String ?? "pages",
      sidebarWidth: object["sidebarWidth"] as? Double ?? 0,
      continuous: object["continuous"] as? Bool ?? true)
  }

  public func discard(for key: String) throws {
    let url = directory.appendingPathComponent("view-\(key).json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
