import Foundation
import MacServices
import Testing

struct UpdateInstallationLocationTests {
  @Test func desktopAndPathBoundary() {
    let desktop = URL(fileURLWithPath: "/Users/example/Desktop")
    #expect(UpdateInstallationLocation.restriction(
      for: desktop.appendingPathComponent("sPDF.app"), desktop: desktop) == .desktop)
    #expect(UpdateInstallationLocation.restriction(
      for: URL(fileURLWithPath: "/Users/example/Desktop-backup/sPDF.app"), desktop: desktop) == nil)
  }

  @Test func followsSymlinksIntoDesktop() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let desktop = root.appendingPathComponent("Desktop")
    try FileManager.default.createDirectory(
      at: desktop.appendingPathComponent("sPDF.app"), withIntermediateDirectories: true)
    let link = root.appendingPathComponent("Shortcut")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
    #expect(UpdateInstallationLocation.restriction(
      for: link.appendingPathComponent("sPDF.app"), desktop: desktop) == .desktop)
  }

  @Test func writableLocationsAreAllowed() {
    let desktop = URL(fileURLWithPath: "/Users/example/Desktop")
    for path in ["/Applications/sPDF.app", "/Users/example/Applications/sPDF.app",
      "/private/tmp/sPDF.app", "/Users/example/AppTranslocation/sPDF.app"]
    {
      #expect(UpdateInstallationLocation.restriction(
        for: URL(fileURLWithPath: path), desktop: desktop) == nil)
    }
  }

  @Test func systemTranslocationNeedsInstallation() {
    #expect(UpdateInstallationLocation.restriction(
      for: URL(fileURLWithPath: "/private/var/folders/aa/bb/T/AppTranslocation/id/d/sPDF.app"),
      desktop: nil) == .translocated)
  }
}
