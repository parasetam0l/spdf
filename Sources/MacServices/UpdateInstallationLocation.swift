import Foundation

/// Locations that cannot safely host an in-place application update.
public enum UpdateInstallationLocation {
  public enum Restriction: Int, Sendable {
    case desktop = 1
    case readOnly
    case translocated
  }

  public static func restriction(
    for application: URL,
    desktop: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
  ) -> Restriction? {
    let location = application.standardizedFileURL.resolvingSymlinksInPath()
    if location.pathComponents.starts(with: ["/", "private", "var", "folders"]),
      location.pathComponents.contains("AppTranslocation")
    { return .translocated }
    if (try? location.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
      return .readOnly
    }
    if let desktop {
      let components = desktop.standardizedFileURL.resolvingSymlinksInPath().pathComponents
      if location.pathComponents.starts(with: components) { return .desktop }
    }
    return nil
  }
}
