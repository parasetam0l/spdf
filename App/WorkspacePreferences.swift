import Foundation
import PDFCore

enum WorkspacePreferences {
  static let paperKey = "newPDFPaperFormat"
  static let landscapeKey = "newPDFLandscape"
  static let continuousKey = "defaultContinuousLayout"

  static var paper: BlankPageFormat {
    BlankPageFormat(rawValue: UserDefaults.standard.string(forKey: paperKey) ?? "") ?? .a4
  }
  static var landscape: Bool { UserDefaults.standard.bool(forKey: landscapeKey) }
  static var continuous: Bool {
    UserDefaults.standard.object(forKey: continuousKey) as? Bool ?? true
  }
}
