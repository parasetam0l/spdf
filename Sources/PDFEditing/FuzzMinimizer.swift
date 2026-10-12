import Foundation

/// P38-023: deterministic delta debugging for failing inputs. The minimizer
/// shrinks an input that still satisfies a failure predicate, so a discovered
/// failure becomes a small, redistributable regression fixture.
public enum FuzzMinimizer {
  public struct Result: Sendable, Equatable {
    public let data: Data
    public let originalBytes: Int
    public let attempts: Int

    public var summary: String {
      "minimized \(originalBytes) → \(data.count) bytes in \(attempts) attempts"
    }
  }

  /// Shrink `data` while `stillFails` holds. Chunk sizes halve down to one
  /// byte; every attempt is bounded by `maxAttempts`.
  public static func minimize(
    _ data: Data, maxAttempts: Int = 4_000, stillFails: (Data) -> Bool
  ) -> Result {
    var current = data
    var attempts = 0
    var chunk = max(current.count / 2, 1)
    while chunk >= 1, attempts < maxAttempts {
      var index = 0
      var progress = false
      while index < current.count, attempts < maxAttempts {
        attempts += 1
        let start = current.startIndex + index
        let end = current.index(start, offsetBy: min(chunk, current.count - index))
        var candidate = current
        candidate.removeSubrange(start..<end)
        if !candidate.isEmpty, stillFails(candidate) {
          current = candidate
          progress = true
        } else {
          index += chunk
        }
      }
      if !progress { chunk /= 2 }
    }
    return Result(data: current, originalBytes: data.count, attempts: attempts)
  }
}
