import DocumentSession
import Testing

/// SAF-05: every document-level restriction has one actionable explanation
/// and at most one recovery action that can actually change the state.
@Suite("Document editing restrictions")
struct DocumentEditingRestrictionTests {
  @Test func everyRestrictionExplainsWhyAndWhatToDoNext() {
    let restrictions = DocumentEditingRestriction.allCases
    #expect(restrictions.count == 5)
    #expect(Set(restrictions.map(\.message)).count == restrictions.count)
    #expect(Set(restrictions.map(\.shortLabel)).count == restrictions.count)
    for restriction in restrictions {
      #expect(!restriction.message.isEmpty)
      #expect(!restriction.shortLabel.isEmpty)
    }
    #expect(
      DocumentEditingRestriction.permissionDenied.message.contains(
        "Save As does not remove"))
    #expect(DocumentEditingRestriction.digitalSignature.message.contains("unsigned copy"))
    #expect(DocumentEditingRestriction.repairedCopy.message.contains("validated copy"))
    #expect(DocumentEditingRestriction.unsupportedStructure.message.contains("source remains"))
  }

  @Test func onlyPasswordLockOffersAnInAppRecoveryAction() {
    #expect(
      DocumentEditingRestriction.passwordLocked.recoveryAction == .unlockDocument)
    for restriction in DocumentEditingRestriction.allCases where restriction != .passwordLocked {
      #expect(restriction.recoveryAction == nil)
    }
  }
}
