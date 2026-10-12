import Foundation
import PDFCore

/// P23-005: rotate pages by adjusting their /Rotate entry. Existing page
/// content, resources, and shared objects stay untouched; a resulting zero
/// rotation removes the key instead of writing an explicit 0. Rotations are
/// normalized to 0/90/180/270, so repeated rotations never accumulate
/// out-of-range values.
public struct RotatePagesCommand: PDFEditCommand, Equatable, Sendable {
  public let pageIDs: [PDFObjectID]
  public let degrees: Int

  public init(pageIDs: [PDFObjectID], byDegrees degrees: Int) {
    self.pageIDs = pageIDs
    self.degrees = degrees
  }

  /// P17-012: the pages this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Rotate Page" }

  public func validate(in graph: PDFGraph) throws {
    guard degrees % 90 == 0 else {
      throw PDFError(.malformed, "Page rotation must be a multiple of 90 degrees")
    }
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "Rotation requires at least one page")
    }
    var seen: Set<PDFObjectID> = []
    for id in pageIDs {
      guard seen.insert(id).inserted else {
        throw PDFError(.malformed, "Rotation lists the same page twice")
      }
      guard case .dictionary(let dictionary)? = graph.objects[id],
        dictionary[PDFName("Type")] == .name(PDFName("Page"))
      else {
        throw PDFError(.malformed, "Rotation target is not a page", offset: nil)
      }
      if let existing = dictionary[PDFName("Rotate")] {
        guard case .integer(let raw) = existing, Int(exactly: raw) != nil else {
          throw PDFError(.malformed, "Existing page rotation is not an integer")
        }
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    for id in pageIDs {
      guard case .dictionary(var dictionary)? = graph.objects[id] else {
        throw PDFError(.malformed, "Rotation target is missing")
      }
      let hadRotation = dictionary[PDFName("Rotate")] != nil
      var current = 0
      if case .integer(let raw)? = dictionary[PDFName("Rotate")] {
        guard let value = Int(exactly: raw) else {
          throw PDFError(.malformed, "Existing page rotation is not an integer")
        }
        current = value
      }
      let normalized = ((current + degrees) % 360 + 360) % 360
      // Preserve representation: an explicit zero stays explicit, while a
      // page that never had /Rotate returns to having no key.
      if normalized == 0, !hadRotation {
        dictionary.removeValue(forKey: PDFName("Rotate"))
      } else {
        dictionary[PDFName("Rotate")] = .integer(Int64(normalized))
      }
      graph.objects[id] = .dictionary(dictionary)
    }
    return graph
  }
}
