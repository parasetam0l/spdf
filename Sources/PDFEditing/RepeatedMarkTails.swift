import Foundation
import PDFCore

/// PAG-06: one applied repeated-mark set found in the page content.
public struct RepeatedMarkGroup: Sendable, Equatable {
  public let groupID: String
  public let label: String
  public let pageIDs: [PDFObjectID]

  public init(groupID: String, label: String, pageIDs: [PDFObjectID]) {
    self.groupID = groupID
    self.label = label
    self.pageIDs = pageIDs
  }
}

/// PAG-06: discover the sPDF-authored mark sets that can be removed as a unit.
public enum RepeatedMarkInventory {
  public static func groups(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> [RepeatedMarkGroup] {
    var order: [String] = []
    var labels: [String: String] = [:]
    var pages: [String: [PDFObjectID]] = [:]
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      for reference in contentReferences(page[PDFName("Contents")]) {
        guard case .reference(let streamID) = reference,
          case .stream(let stream)? = graph.objects[streamID],
          case .string(let groupData)? = stream.dictionary[PDFName("SPDFMark")]
        else { continue }
        let groupID = String(decoding: groupData, as: UTF8.self)
        if labels[groupID] == nil {
          order.append(groupID)
          if case .string(let labelData)? = stream.dictionary[PDFName("SPDFMarkLabel")] {
            labels[groupID] = String(decoding: labelData, as: UTF8.self)
          } else {
            labels[groupID] = "Page mark"
          }
        }
        if pages[groupID]?.last != pageID {
          pages[groupID, default: []].append(pageID)
        }
      }
    }
    return order.map {
      RepeatedMarkGroup(
        groupID: $0, label: labels[$0] ?? "Page mark", pageIDs: pages[$0] ?? [])
    }
  }

  static func contentReferences(_ value: PDFValue?) -> [PDFValue] {
    if case .reference(let reference)? = value { return [.reference(reference)] }
    if case .array(let items)? = value { return items }
    return []
  }
}

/// PAG-06: remove every content stream belonging to one mark set. Unrelated
/// content and other mark sets are untouched; the action is one undo step.
public struct RemoveRepeatedMarkCommand: PDFEditCommand, Equatable, Sendable {
  public let groupID: String
  public let pageIDs: [PDFObjectID]

  public init(groupID: String, pageIDs: [PDFObjectID]) {
    self.groupID = groupID
    self.pageIDs = pageIDs
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Remove Page Mark" }

  public func validate(in graph: PDFGraph) throws {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected")
    }
    guard !matchedStreams(in: graph).isEmpty else {
      throw PDFError(.unsupported, "This page mark is no longer present")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    for pageID in pageIDs {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      let references = RepeatedMarkInventory.contentReferences(page[PDFName("Contents")])
      let kept = references.filter { reference in
        guard case .reference(let streamID) = reference,
          case .stream(let stream)? = graph.objects[streamID],
          case .string(let group)? = stream.dictionary[PDFName("SPDFMark")]
        else { return true }
        return String(decoding: group, as: UTF8.self) != groupID
      }
      guard kept.count != references.count else { continue }
      switch kept.count {
      case 0: page[PDFName("Contents")] = nil
      case 1: page[PDFName("Contents")] = kept[0]
      default: page[PDFName("Contents")] = .array(kept)
      }
      graph.objects[pageID] = .dictionary(page)
    }
    return graph
  }

  private func matchedStreams(in graph: PDFGraph) -> [PDFObjectID] {
    var result: [PDFObjectID] = []
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      for reference in RepeatedMarkInventory.contentReferences(page[PDFName("Contents")]) {
        guard case .reference(let streamID) = reference,
          case .stream(let stream)? = graph.objects[streamID],
          case .string(let group)? = stream.dictionary[PDFName("SPDFMark")],
          String(decoding: group, as: UTF8.self) == groupID
        else { continue }
        result.append(streamID)
      }
    }
    return result
  }
}
