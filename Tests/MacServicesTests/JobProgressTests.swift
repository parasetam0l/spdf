import Foundation
import MacServices
import Testing

@Suite("Job progress center")
struct JobProgressTests {
  @Test func jobsStartUpdateFinishAndCancel() {
    let center = JobProgressCenter()
    #expect(center.jobs.isEmpty)
    let id = center.start(title: "Export", total: 4)
    #expect(center.jobs.count == 1)
    #expect(center.jobs[0].fraction == 0)
    center.update(id: id, completed: 1)
    #expect(center.jobs[0].fraction == 0.25)
    // Out-of-range completions clamp; unknown identities are ignored.
    center.update(id: id, completed: 99)
    #expect(center.jobs[0].fraction == 1)
    center.update(id: UUID(), completed: 2)
    #expect(center.jobs.count == 1)
    // Cancellation runs the attached producer closure.
    #expect(center.requestCancel(id: id) == false)
    var cancelled = false
    center.attach(id: id) { cancelled = true }
    #expect(center.requestCancel(id: id) == true)
    #expect(cancelled)
    center.finish(id: id)
    #expect(center.jobs.isEmpty)
    // Finishing drops the canceller too.
    #expect(center.requestCancel(id: id) == false)
  }

  @Test @MainActor func relayDeliversToTheCenter() {
    let center = JobProgressCenter()
    let relay = JobProgressRelay(center: center)
    let id = center.start(title: "Export", total: 2)
    relay.update(id: id, completed: 2)
    #expect(center.jobs.first?.fraction == 1)
  }

  @Test func relaySurvivesAReleasedCenter() {
    let relay: JobProgressRelay = {
      let center = JobProgressCenter()
      return JobProgressRelay(center: center)
    }()
    let id = UUID()
    // No crash and no delivery when the center is gone.
    relay.update(id: id, completed: 1)
  }
}
