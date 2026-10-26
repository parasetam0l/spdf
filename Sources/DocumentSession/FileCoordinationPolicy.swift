import Foundation

/// UX-06: the file-coordination conflicts the policy distinguishes. Detection
/// itself stays with the existing fingerprinting, writer and recovery code.
public enum FileConflictKind: String, Codable, Sendable, CaseIterable {
  case externalModification
  case cloudVersionConflict
  case movedFile
  case missingFile
  case lowDiskSpace
  case interruptedWrite
}

/// UX-06: one declared resolution per conflict. The policy never writes; the
/// App performs the write through the existing verified writer and recovery
/// store.
public enum FileSaveDecision: String, Codable, Sendable, CaseIterable {
  case proceedNormally
  case overwriteAfterConfirmation
  case saveCopyWithPreservedDraft
  case reloadFromDisk
  case adoptMovedFile
  case reportMissingFile
  case retryInterruptedWrite
  case retryAfterSpaceAvailable
  case resolveCloudConflictExplicitly
  case refuseAndPreserveWork
  case noActionNeeded
}

/// UX-06: observed state at save/close time. Bytes are compared only when the
/// caller supplies them (for example from a low-disk preflight).
public struct FileCoordinationState: Codable, Sendable, Equatable {
  public let sourceChangedExternally: Bool
  public let cloudConflictPresent: Bool
  public let fileMoved: Bool
  public let fileMissing: Bool
  public let availableBytes: Int64?
  public let requiredBytes: Int64?
  public let writeWasInterrupted: Bool
  public let hasUnsavedWork: Bool
  public let recoveryRecordAvailable: Bool

  public init(
    sourceChangedExternally: Bool = false, cloudConflictPresent: Bool = false,
    fileMoved: Bool = false, fileMissing: Bool = false, availableBytes: Int64? = nil,
    requiredBytes: Int64? = nil, writeWasInterrupted: Bool = false,
    hasUnsavedWork: Bool = false, recoveryRecordAvailable: Bool = false
  ) {
    self.sourceChangedExternally = sourceChangedExternally
    self.cloudConflictPresent = cloudConflictPresent
    self.fileMoved = fileMoved
    self.fileMissing = fileMissing
    self.availableBytes = availableBytes
    self.requiredBytes = requiredBytes
    self.writeWasInterrupted = writeWasInterrupted
    self.hasUnsavedWork = hasUnsavedWork
    self.recoveryRecordAvailable = recoveryRecordAvailable
  }

  public var lowDiskSpace: Bool {
    guard let availableBytes, let requiredBytes else { return false }
    return availableBytes < requiredBytes
  }

  /// Conflicts in the policy's precedence order.
  public var conflicts: [FileConflictKind] {
    var result: [FileConflictKind] = []
    if cloudConflictPresent { result.append(.cloudVersionConflict) }
    if writeWasInterrupted { result.append(.interruptedWrite) }
    if lowDiskSpace { result.append(.lowDiskSpace) }
    if fileMissing { result.append(.missingFile) }
    if fileMoved { result.append(.movedFile) }
    if sourceChangedExternally { result.append(.externalModification) }
    return result
  }
}

public struct FileConflictResolution: Codable, Sendable, Equatable {
  public let conflict: FileConflictKind
  public let decision: FileSaveDecision
  public let requiresUserDecision: Bool
  public let message: String
}

public struct FileCoordinationOutcome: Codable, Sendable, Equatable {
  public let decisions: [FileConflictKind: FileSaveDecision]
  public let resolutions: [FileConflictResolution]
  public let requiresUserDecision: Bool
  /// The policy never discards unsaved work; this records that invariant for
  /// the caller and the report.
  public let preservesUnsavedWork: Bool
  public let isSafeToWriteWithoutAsking: Bool
  public let recoveryMayBeNeeded: Bool
  public let messages: [String]
}

/// UX-06: the pure decision policy over external modifications, cloud-backed
/// conflicts, moved/missing files, low disk space and interrupted writes.
///
/// Boundary: this policy only decides what to present and whether a write may
/// proceed; it never writes, never deletes the recovery record and never
/// silently discards unsaved work. The App wires the decision to the existing
/// VerifiedFileWriter, SourceFingerprint and RecoveryStore.
public enum FileCoordinationPolicy {
  public static let boundary =
    "File coordination surfaces conflicts before any write and never silently "
    + "discards unsaved work. Detection uses the existing source fingerprint; writes "
    + "still go through the verified temporary-file writer; unresolved state may use "
    + "the existing recovery store. The policy itself performs no I/O."

  /// UX-06: evaluate one save/close state. Precedence is cloud conflict,
  /// interrupted write, low disk, missing file, moved file, external
  /// modification; every conflict contributes a resolution instead of being
  /// collapsed into one bit.
  public static func evaluate(_ state: FileCoordinationState) -> FileCoordinationOutcome {
    var resolutions: [FileConflictResolution] = []
    var messages: [String] = []
    for conflict in state.conflicts {
      let resolution = resolution(for: conflict, state: state)
      resolutions.append(resolution)
      messages.append(resolution.message)
    }
    var decisions: [FileConflictKind: FileSaveDecision] = [:]
    for resolution in resolutions {
      decisions[resolution.conflict] = resolution.decision
    }
    let requiresUserDecision = resolutions.contains { $0.requiresUserDecision }
    let safe = resolutions.isEmpty
    return FileCoordinationOutcome(
      decisions: decisions, resolutions: resolutions,
      requiresUserDecision: requiresUserDecision, preservesUnsavedWork: true,
      isSafeToWriteWithoutAsking: safe, recoveryMayBeNeeded:
        state.hasUnsavedWork
        && (state.writeWasInterrupted || state.fileMissing || !state.recoveryRecordAvailable
          && state.conflicts.contains(.interruptedWrite)),
      messages: messages)
  }

  static func resolution(
    for conflict: FileConflictKind, state: FileCoordinationState
  ) -> FileConflictResolution {
    switch conflict {
    case .cloudVersionConflict:
      return FileConflictResolution(
        conflict: conflict, decision: .resolveCloudConflictExplicitly,
        requiresUserDecision: true,
        message: state.hasUnsavedWork
          ? "This file has a cloud version conflict. Keep your draft: review both versions "
            + "before choosing a copy; nothing is overwritten automatically."
          : "This file has a cloud version conflict. Review the versions before reloading or "
            + "replacing it.")
    case .interruptedWrite:
      return FileConflictResolution(
        conflict: conflict, decision: .retryInterruptedWrite, requiresUserDecision: true,
        message: state.recoveryRecordAvailable
          ? "An earlier write was interrupted. Retry from the preserved recovery record; "
            + "the destination is not replaced until a verified write succeeds."
          : "An earlier write was interrupted. Retry the verified write; the destination is "
            + "not replaced until the write completes.")
    case .lowDiskSpace:
      let available = state.availableBytes ?? 0
      let required = state.requiredBytes ?? 0
      return FileConflictResolution(
        conflict: conflict, decision: .retryAfterSpaceAvailable, requiresUserDecision: true,
        message: "Not enough free space: \(available) bytes available, \(required) required. "
          + "Keep the draft and free space or choose another destination; nothing is written.")
    case .missingFile:
      return FileConflictResolution(
        conflict: conflict, decision: .reportMissingFile, requiresUserDecision: true,
        message: state.hasUnsavedWork
          ? "The source file is no longer at that location. Keep the draft and choose whether "
            + "to save it as a new copy; no work is discarded."
          : "The source file is no longer at that location. Locate it again or choose another "
            + "file; no unsaved work exists.")
    case .movedFile:
      return FileConflictResolution(
        conflict: conflict, decision: state.hasUnsavedWork ? .saveCopyWithPreservedDraft
          : .adoptMovedFile,
        requiresUserDecision: true,
        message: state.hasUnsavedWork
          ? "The source file moved. Keep the draft and confirm the new location before saving; "
            + "saving never overwrites an unrelated file."
          : "The source file moved. Adopt its new location before the next save.")
    case .externalModification:
      return FileConflictResolution(
        conflict: conflict, decision: state.hasUnsavedWork ? .saveCopyWithPreservedDraft
          : .reloadFromDisk,
        requiresUserDecision: true,
        message: state.hasUnsavedWork
          ? "The file changed on disk since it was opened. Keep the draft and decide whether "
            + "to overwrite after review or save a copy; nothing is overwritten silently."
          : "The file changed on disk since it was opened. Reload it or keep the untouched "
            + "in-memory copy; no unsaved work exists.")
    }
  }

  /// UX-06: a short declaration of what the policy guarantees, used in reports
  /// and in the SESSION evidence.
  public static let guarantees: [String] = [
    "A conflict is surfaced with a message; no path silently overwrites a changed file.",
    "Unsaved work is never discarded by the policy: every conflict keeps the draft and "
      + "offers a copy, a retry or an explicit choice.",
    "Low disk and interrupted writes are decided before replacing the destination; the "
      + "existing verified writer and recovery store perform the actual work.",
    "Cloud-backed conflicts require an explicit choice; there is no automatic merge or "
      + "overwrite claim.",
  ]
}
