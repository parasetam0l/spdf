import Foundation
import PDFCore

/// SPC-05: interactive multimedia and 3D scope decision.
///
/// Safe detection and preservation are supported as inventory data; playback,
/// annotation editing and 3D model interaction are explicit exclusions. The app
/// does not claim any media format plays through a user action, and it never
/// removes or rewrites these objects implicitly.
public enum MediaObjectKind: String, Sendable, Equatable, CaseIterable {
  case movie
  case sound
  case screen
  case richMedia
  case threeD
  case embeddedFile
}

public struct MediaUse: Sendable, Equatable {
  public let kind: MediaObjectKind
  public let pageIndex: Int?
  public let objectID: PDFObjectID?
  public let subtype: String
  /// True when the object carries an interactive action that a viewer could run.
  public let hasInteractiveAction: Bool
  public let preserved: Bool
}

public struct MultimediaScopeReport: Sendable, Equatable {
  public let pageCount: Int
  public let uses: [MediaUse]
  public let embeddedFileCount: Int
  public let warnings: [String]

  public var has3D: Bool { uses.contains { $0.kind == .threeD } }
  public var hasRichMedia: Bool { uses.contains { $0.kind == .richMedia } }
  public var hasLegacyMovie: Bool { uses.contains { $0.kind == .movie } }
  public var hasSound: Bool { uses.contains { $0.kind == .sound } }

  public func report() -> String {
    var lines = [
      "Multimedia/3D scope — " + String(uses.count) + " media object(s), "
        + String(embeddedFileCount) + " embedded file(s) on " + String(pageCount) + " page(s)"
    ]
    for use in uses {
      lines.append(
        "  " + use.kind.rawValue + " (" + use.subtype + ") on page "
          + (use.pageIndex.map { String($0 + 1) } ?? "document")
          + "; interactive=" + String(use.hasInteractiveAction)
          + "; preserved=" + String(use.preserved))
    }
    for warning in warnings { lines.append("  Warning: " + warning) }
    lines.append(MultimediaScope.policy.profile)
    return lines.joined(separator: "\n")
  }
}

public struct MultimediaScopePolicy: Sendable, Equatable {
  public enum Decision: String, Sendable, Equatable {
    case excluded
    case preserved
  }

  public let playback: Decision
  public let annotationEditing: Decision
  public let modelInteraction: Decision
  public let preservation: Decision
  public let profile: String
}

public enum MultimediaScope {
  public static let policy = MultimediaScopePolicy(
    playback: .excluded,
    annotationEditing: .excluded,
    modelInteraction: .excluded,
    preservation: .preserved,
    profile:
      "Scope: media/3D objects are detected and preserved, never played or edited. "
      + "Playback, movie/sound controls, rich-media annotation editing and 3D model "
      + "interaction are explicit disclosed exclusions; preservation alone is not playback "
      + "parity and no media format is claimed to work through a user action. The app does "
      + "not remove these objects implicitly; PDF structure is preserved on save unless a "
      + "separate explicit edit changes it."
  )

  static let maximumAnnotationsPerPage = 5_000
  static let maximumUses = 10_000
  static let maximumEmbeddedFiles = 10_000

  public static func inventory(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) -> MultimediaScopeReport {
    var uses: [MediaUse] = []
    var warnings: [String] = []

    func resolvedDictionary(_ value: PDFValue) -> ([PDFName: PDFValue], PDFObjectID?)? {
      switch value {
      case .dictionary(let dictionary): return (dictionary, nil)
      case .reference(let id):
        guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
        return (dictionary, id)
      default: return nil
      }
    }

    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else {
        warnings.append("Page " + String(pageIndex + 1) + " is missing.")
        continue
      }
      guard let annotationsValue = page[PDFName("Annots")] else { continue }
      let annotations: [PDFValue]
      switch annotationsValue {
      case .array(let values):
        annotations = values
      case .reference(let id):
        guard case .array(let values)? = graph.objects[id] else {
          warnings.append("Page " + String(pageIndex + 1) + " has an unreadable annotation array.")
          continue
        }
        annotations = values
      default:
        warnings.append("Page " + String(pageIndex + 1) + " has a malformed annotation array.")
        continue
      }
      if annotations.count > maximumAnnotationsPerPage {
        warnings.append("Page " + String(pageIndex + 1) + " has too many annotations to inspect.")
      }
      for (annotationIndex, annotationValue) in
        annotations.prefix(maximumAnnotationsPerPage).enumerated()
      {
        guard let (dictionary, objectID) = resolvedDictionary(annotationValue) else {
          warnings.append(
            "Page " + String(pageIndex + 1) + " annotation " + String(annotationIndex + 1)
              + " is malformed.")
          continue
        }
        let subtype = subtypeName(dictionary)
        guard let kind = kind(for: subtype) else { continue }
        let interactive = hasInteractiveAction(dictionary, kind: kind)
        uses.append(
          MediaUse(
            kind: kind, pageIndex: pageIndex, objectID: objectID, subtype: subtype,
            hasInteractiveAction: interactive, preserved: true))
        if uses.count >= maximumUses {
          warnings.append("Media inventory stopped at the supported object limit.")
          break
        }
      }
      if uses.count >= maximumUses { break }
    }
    let embeddedCount = embeddedFiles(graph)
    return MultimediaScopeReport(
      pageCount: pageIDs.count, uses: uses, embeddedFileCount: embeddedCount,
      warnings: warnings.sorted())
  }

  static func subtypeName(_ dictionary: [PDFName: PDFValue]) -> String {
    guard case .name(let name)? = dictionary[PDFName("Subtype")] else { return "" }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  static func kind(for subtype: String) -> MediaObjectKind? {
    switch subtype {
    case "Movie": return .movie
    case "Sound": return .sound
    case "Screen": return .screen
    case "RichMedia": return .richMedia
    case "3D": return .threeD
    default: return nil
    }
  }

  static func hasInteractiveAction(
    _ dictionary: [PDFName: PDFValue], kind: MediaObjectKind
  ) -> Bool {
    if dictionary[PDFName("A")] != nil || dictionary[PDFName("AA")] != nil {
      return true
    }
    if dictionary[PDFName("Action")] != nil { return true }
    switch kind {
    case .movie, .sound, .richMedia, .threeD:
      // These annotation classes are inherently interactive even without an
      // explicit action; the scope decision treats them as excluded playback.
      return true
    case .screen, .embeddedFile:
      return false
    }
  }

  static func resolvedDictionary(
    _ value: PDFValue, in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary): return dictionary
    case .reference(let id):
      guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
      return dictionary
    default: return nil
    }
  }

  static func embeddedFiles(_ graph: PDFGraph) -> Int {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      let catalog = resolvedDictionary(.reference(rootID), in: graph),
      let names = resolvedDictionary(catalog[PDFName("Names")] ?? .null, in: graph),
      let embedded = resolvedDictionary(names[PDFName("EmbeddedFiles")] ?? .null, in: graph)
    else { return 0 }
    return countNameTree(embedded, in: graph, limit: maximumEmbeddedFiles)
  }

  static func countNameTree(
    _ node: [PDFName: PDFValue], in graph: PDFGraph, limit: Int
  ) -> Int {
    var count = 0
    if case .array(let names)? = node[PDFName("Names")] {
      count += names.count / 2
    }
    if case .array(let kids)? = node[PDFName("Kids")] {
      for kid in kids {
        guard count < limit else { break }
        if let dictionary = resolvedDictionary(kid, in: graph) {
          count += countNameTree(dictionary, in: graph, limit: limit - count)
        }
      }
    }
    return min(count, limit)
  }
}
