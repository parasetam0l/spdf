// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SPDF",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PDFCore", targets: ["PDFCore"]),
    .library(name: "PDFEditing", targets: ["PDFEditing"]),
    .library(name: "DocumentSession", targets: ["DocumentSession"]),
    .library(name: "MacServices", targets: ["MacServices"]),
    .library(name: "ReleaseTools", targets: ["ReleaseTools"]),
    .executable(name: "spdf-fixtures", targets: ["FixtureTool"]),
    .executable(name: "release-tools", targets: ["ReleaseToolsCLI"]),
    .executable(name: "spdf-automation", targets: ["AutomationCLI"]),
  ],
  targets: [
    .target(name: "PDFCore"),
    .target(name: "PDFEditing", dependencies: ["PDFCore"]),
    .target(name: "DocumentSession", dependencies: ["PDFCore", "PDFEditing"]),
    .target(name: "MacServices", dependencies: ["PDFCore", "PDFEditing"]),
    .target(name: "PDFFixtures", dependencies: ["PDFCore"], path: "Tools/PDFFixtures"),
    .executableTarget(
      name: "FixtureTool", dependencies: ["PDFCore", "PDFFixtures"], path: "Tools/FixtureTool"),
    .target(name: "ReleaseTools", path: "Tools/ReleaseTools"),
    .executableTarget(
      name: "ReleaseToolsCLI", dependencies: ["ReleaseTools"], path: "Tools/ReleaseToolsCLI"),
    .executableTarget(
      name: "AutomationCLI", dependencies: ["PDFEditing"], path: "Tools/AutomationCLI"),
    .testTarget(name: "PDFCoreTests", dependencies: ["PDFCore", "PDFFixtures"]),
    .testTarget(name: "ReleaseToolsTests", dependencies: ["ReleaseTools"]),
    .testTarget(name: "PDFEditingTests", dependencies: ["PDFEditing", "PDFCore", "PDFFixtures"]),
    .testTarget(
      name: "DocumentSessionTests",
      dependencies: ["DocumentSession", "PDFCore", "PDFEditing", "PDFFixtures"]),
    .testTarget(
      name: "MacServicesTests",
      dependencies: ["MacServices", "PDFCore", "PDFEditing", "PDFFixtures"]),
  ],
  swiftLanguageModes: [.v6]
)
