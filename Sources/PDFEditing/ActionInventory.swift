import Foundation
import PDFCore

/// P08-019: one inventoried document action. The inventory is strictly
/// read-only: no action is ever executed by the owned core, and the viewer
/// blocks non-GoTo action execution (P22-024).
public struct DocumentAction: Sendable, Equatable {
  public enum Location: Sendable, Equatable {
    case catalog
    case page(index: Int)
    case annotation(pageIndex: Int, annotationIndex: Int)
  }

  public let location: Location
  /// /S action type, when present.
  public let kind: PDFName?
  /// Where the action hangs: /OpenAction, /A, or an /AA trigger key.
  public let trigger: PDFName
  /// Automatic triggers run without user interaction (/OpenAction, /AA).
  public let isAutomatic: Bool

  public var isJavaScript: Bool { kind == PDFName("JavaScript") }
  public var isLaunch: Bool { kind == PDFName("Launch") }
  public var isURI: Bool { kind == PDFName("URI") }
}

/// P08-019: enumerate catalog, page, and annotation actions with their
/// triggers. Scanning never executes or mutates anything.
public enum ActionInventory {
  /// Additional-action trigger keys that run automatically.
  public static let additionalActionTriggers: Set<PDFName> = [
    PDFName("O"), PDFName("C"), PDFName("WC"), PDFName("WS"), PDFName("DS"), PDFName("WP"),
    PDFName("DP"),
  ]

  public static func actions(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [DocumentAction] {
    var actions: [DocumentAction] = []
    // Catalog: /OpenAction and /AA.
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    {
      if let value = catalog[PDFName("OpenAction")] {
        collect(
          value, location: .catalog, trigger: PDFName("OpenAction"), isAutomatic: true,
          in: graph, into: &actions)
      }
      if let aa = dictionary(catalog[PDFName("AA")], in: graph) {
        for key in aa.keys.sorted() {
          collect(
            aa[key]!, location: .catalog, trigger: key, isAutomatic: true, in: graph,
            into: &actions)
        }
      }
    }
    // Pages and their annotations.
    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      if let aa = dictionary(page[PDFName("AA")], in: graph) {
        for key in aa.keys.sorted() {
          collect(
            aa[key]!, location: .page(index: pageIndex), trigger: key, isAutomatic: true,
            in: graph, into: &actions)
        }
      }
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations {
        let location = DocumentAction.Location.annotation(
          pageIndex: pageIndex, annotationIndex: annotation.index)
        if let value = annotation.dictionary[PDFName("A")] {
          collect(
            value, location: location, trigger: PDFName("A"), isAutomatic: false, in: graph,
            into: &actions)
        }
        if let aa = dictionary(annotation.dictionary[PDFName("AA")], in: graph) {
          for key in aa.keys.sorted() {
            collect(
              aa[key]!, location: location, trigger: key, isAutomatic: true, in: graph,
              into: &actions)
          }
        }
      }
    }
    return actions
  }

  /// Resolve a reference and record the action type plus any /Next chain.
  private static func collect(
    _ value: PDFValue, location: DocumentAction.Location, trigger: PDFName,
    isAutomatic: Bool, in graph: PDFGraph, into actions: inout [DocumentAction], depth: Int = 0
  ) {
    guard depth <= 8 else { return }
    guard let dictionary = dictionary(value, in: graph) else { return }
    var kind: PDFName?
    if case .name(let name)? = dictionary[PDFName("S")] { kind = name }
    actions.append(
      DocumentAction(
        location: location, kind: kind, trigger: trigger, isAutomatic: isAutomatic))
    if let next = dictionary[PDFName("Next")] {
      switch next {
      case .array(let values):
        for value in values {
          collect(
            value, location: location, trigger: trigger, isAutomatic: isAutomatic, in: graph,
            into: &actions, depth: depth + 1)
        }
      default:
        collect(
          next, location: location, trigger: trigger, isAutomatic: isAutomatic, in: graph,
          into: &actions, depth: depth + 1)
      }
    }
  }

  private static func dictionary(_ value: PDFValue?, in graph: PDFGraph) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }
}
