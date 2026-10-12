import Combine
import Foundation

/// P12-021: one background job's progress.
public struct JobProgress: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let title: String
  public let completed: Int
  public let total: Int

  public init(id: UUID = UUID(), title: String, completed: Int, total: Int) {
    self.id = id
    self.title = title
    self.completed = completed
    self.total = total
  }

  public var fraction: Double {
    guard total > 0 else { return 0 }
    return min(1, Double(max(0, completed)) / Double(total))
  }
}

/// P12-021: progress and cancellation for document background jobs (page
/// image export today; more producers later). All methods are synchronous so
/// producers and tests observe exact state.
///
/// Confinement: call and observe from the main thread. The SwiftUI progress
/// view requires main-thread publishing, and every app producer runs on the
/// main actor; a producer whose progress callback arrives on a background
/// executor must hop to the main actor before calling `update` (the page
/// export path does).
public final class JobProgressCenter: ObservableObject {
  @Published public private(set) var jobs: [JobProgress] = []
  private var cancels: [UUID: () -> Void] = [:]

  public init() {}

  /// Start a job; returns its identity.
  @discardableResult
  public func start(title: String, total: Int) -> UUID {
    let job = JobProgress(title: title, completed: 0, total: max(0, total))
    jobs.append(job)
    return job.id
  }

  /// Record completed units for a running job; unknown identities are ignored.
  public func update(id: UUID, completed: Int) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    let job = jobs[index]
    jobs[index] = JobProgress(
      id: job.id, title: job.title, completed: min(max(0, completed), job.total),
      total: job.total)
  }

  /// Attach a canceller (usually the producing task's `cancel`). Replaces any
  /// previous canceller for the job.
  public func attach(id: UUID, cancel: @escaping () -> Void) {
    cancels[id] = cancel
  }

  /// Run the attached canceller, if any. Returns whether one was attached.
  /// The producer still calls `finish` when its task ends.
  @discardableResult
  public func requestCancel(id: UUID) -> Bool {
    guard let cancel = cancels[id] else { return false }
    cancel()
    return true
  }

  /// Remove a finished job and drop its canceller.
  public func finish(id: UUID) {
    jobs.removeAll { $0.id == id }
    cancels[id] = nil
  }
}

/// P12-021: a `Sendable` relay from background producers to a main-confined
/// center. Producers whose progress callbacks arrive off the main actor (the
/// page exporter) call `update` here; delivery hops to the main thread, or
/// runs inline when already there. A released center makes updates no-ops.
public final class JobProgressRelay: @unchecked Sendable {
  private let lock = NSLock()
  private weak var center: JobProgressCenter?

  public init(center: JobProgressCenter) {
    self.center = center
  }

  public func update(id: UUID, completed: Int) {
    lock.lock()
    let center = self.center
    lock.unlock()
    guard let center else { return }
    if Thread.isMainThread {
      center.update(id: id, completed: completed)
    } else {
      DispatchQueue.main.async { center.update(id: id, completed: completed) }
    }
  }
}
