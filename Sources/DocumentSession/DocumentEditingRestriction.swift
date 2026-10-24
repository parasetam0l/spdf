import Foundation

/// SAF-05: one explanation and recovery policy for every document-level
/// reason that prevents content editing. The app presents the same message in
/// the workspace banner, the point-of-use refusal and the pre-commit alert.
public enum DocumentEditingRestriction: String, CaseIterable, Sendable, Equatable {
  /// The renderer is still locked and needs its password.
  case passwordLocked
  /// A repaired source was opened with editing gated by its safety verdict.
  case repairedCopy
  /// The PDF grants read access but not modification permission.
  case permissionDenied
  /// A digital signature would be invalidated by a normal content edit.
  case digitalSignature
  /// The document structure is outside the safe editing profile.
  case unsupportedStructure

  /// The one action that can actually change the document's eligibility.
  /// Other restrictions require an external editable copy.
  public enum RecoveryAction: String, Sendable, Equatable {
    case unlockDocument
  }

  public var recoveryAction: RecoveryAction? {
    self == .passwordLocked ? .unlockDocument : nil
  }

  /// Actionable text: what is blocked, why, and what the user can do next.
  /// It never promises that Save As removes permission restrictions.
  public var message: String {
    switch self {
    case .passwordLocked:
      return "This PDF is password-protected. Choose Tools → Security → Unlock Document to continue, or open an editable copy."
    case .repairedCopy:
      return "This repaired copy did not pass validation, so editing is paused to protect its contents. Open a clean original or review the repair report and create a validated copy."
    case .permissionDenied:
      return "This password allows reading but not modification. Ask the document owner for an editable copy; Save As does not remove the PDF's permission restrictions."
    case .digitalSignature:
      return "This PDF contains a digital signature. Editing would invalidate the signed document, so sPDF keeps it view-only. Open an unsigned copy if you need to make changes."
    case .unsupportedStructure:
      return "sPDF can display this PDF, but its document structure is outside the safe editing profile. The source remains unchanged; open a copy in an editor that supports this structure."
    }
  }

  /// A short label for status surfaces and diagnostics.
  public var shortLabel: String {
    switch self {
    case .passwordLocked: return "Password protected"
    case .repairedCopy: return "Repair validation paused editing"
    case .permissionDenied: return "Editing permission denied"
    case .digitalSignature: return "Digitally signed"
    case .unsupportedStructure: return "Unsupported editing structure"
    }
  }
}
