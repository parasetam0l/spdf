import Foundation
import Testing

/// P02-025: module boundary check — the canonical core layers
/// (PDFCore, PDFEditing, DocumentSession) must not import UI frameworks.
/// PDFKit/AppKit objects may appear in MacServices (the viewing adapter)
/// and the app, but never as canonical core state.
@Suite("Module boundaries")
struct ModuleBoundaryTests {
  /// UI frameworks that must not appear in core-layer imports.
  private static let bannedImports = [
    "PDFKit", "AppKit", "UIKit", "SwiftUI", "Cocoa", "WatchKit", "WidgetKit",
  ]

  private static let coreModules = ["PDFCore", "PDFEditing", "DocumentSession"]

  private static func packageRoot() throws -> URL {
    // Tests/<Suite>/<file> -> package root.
    let file = URL(fileURLWithPath: #filePath)
    let tests = file.deletingLastPathComponent().deletingLastPathComponent()
    #expect(tests.lastPathComponent == "Tests")
    return tests.deletingLastPathComponent()
  }

  @Test func coreLayersImportNoUIFrameworks() throws {
    let root = try Self.packageRoot()
    var violations: [String] = []
    for module in Self.coreModules {
      let directory = root.appendingPathComponent("Sources/\(module)")
      let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
      for file in files where file.hasSuffix(".swift") {
        let url = directory.appendingPathComponent(file)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for line in text.components(separatedBy: "\n") {
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          guard trimmed.hasPrefix("import ") else { continue }
          let imported = trimmed.dropFirst("import ".count)
            .components(separatedBy: CharacterSet(charactersIn: " (@")).first ?? ""
          if Self.bannedImports.contains(String(imported)) {
            violations.append("\(module)/\(file): \(trimmed)")
          }
        }
      }
    }
    #expect(violations.isEmpty, "UI framework imports in core layers: \(violations)")
  }

  @Test func boundaryScopeDocumentsTheAdapterException() throws {
    // The viewing adapter is the single sanctioned UI boundary: MacServices
    // may import PDFKit/AppKit, and the core layers may not.
    let root = try Self.packageRoot()
    let session = root.appendingPathComponent("Sources/MacServices/PDFViewingSession.swift")
    let text = String(decoding: try Data(contentsOf: session), as: UTF8.self)
    #expect(text.contains("import PDFKit"))
  }
}
