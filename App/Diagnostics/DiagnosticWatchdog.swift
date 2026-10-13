import Foundation

/// Diagnostic deadlines must fire even when the main thread is blocked.
@MainActor
enum DiagnosticWatchdog {
  nonisolated static func schedule(after seconds: TimeInterval, message: String)
    -> DispatchWorkItem
  {
    // Construct the callback outside the caller's actor. DispatchWorkItem's
    // block otherwise inherits MainActor and traps on the global queue.
    let item = DispatchWorkItem {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(1)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    return item
  }
}
