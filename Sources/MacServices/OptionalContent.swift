import Foundation
import PDFCore
import PDFEditing

/// P11-018: optional-content (layer) visibility for the display path.
///
/// The owned inventory (`PDFDocumentInventory.optionalContent`) lists the
/// document's groups. This policy resolves each group's *default* visibility
/// from `/OCProperties /D /ON` and `/OFF` (absent lists mean visible, per the
/// specification's default configuration) and records how the display path
/// treats it: neither the Core Graphics snapshot renderer nor the PDFKit
/// viewing adapter applies ON/OFF filtering, so the viewer shows the
/// renderer's default output. That limit is explicit — the policy never
/// claims a group was hidden when it was not.
public struct OptionalContentDisplayGroup: Sendable, Equatable {
  public let name: String?
  /// Visibility from the default configuration (`/D`'s `/OFF` hides,
  /// `/ON` shows, absence means visible).
  public let visibleByDefault: Bool

  public init(name: String?, visibleByDefault: Bool) {
    self.name = name
    self.visibleByDefault = visibleByDefault
  }
}

public struct OptionalContentDisplayPolicy: Sendable, Equatable {
  public let groups: [OptionalContentDisplayGroup]
  /// Whether the display renderer filters content by this policy.
  /// Always false for the current renderers (see `reason`).
  public let appliesFiltering: Bool
  public let reason: String

  public init(groups: [OptionalContentDisplayGroup], appliesFiltering: Bool, reason: String) {
    self.groups = groups
    self.appliesFiltering = appliesFiltering
    self.reason = reason
  }

  public var isEmpty: Bool { groups.isEmpty }

  /// Resolve the display policy for a core graph. Never throws: an absent
  /// or malformed `/OCProperties` yields no groups rather than a failure,
  /// so viewing never depends on layer syntax.
  public static func resolve(in graph: PDFGraph) -> OptionalContentDisplayPolicy {
    let groups = displayGroups(in: graph)
    return OptionalContentDisplayPolicy(
      groups: groups,
      appliesFiltering: false,
      reason:
        "The Core Graphics snapshot renderer and the PDFKit viewing adapter "
        + "do not apply optional-content filtering; pages render with the "
        + "renderer default. Group visibility above is the default "
        + "configuration, recorded for inspection, not enforced.")
  }

  private static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    guard let value else { return nil }
    if case .reference(let id) = value { return graph.objects[id] }
    return value
  }

  private static func displayGroups(in graph: PDFGraph) -> [OptionalContentDisplayGroup] {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .dictionary(let properties)? = resolved(catalog[PDFName("OCProperties")], in: graph)
    else { return [] }
    guard case .array(let entries)? = properties[PDFName("OCGs")] else { return [] }
    var offNames = Set<String>()
    var onNames = Set<String>()
    if case .dictionary(let defaults)? = resolved(properties[PDFName("D")], in: graph) {
      if case .array(let off)? = resolved(defaults[PDFName("OFF")], in: graph) {
        offNames = Set(off.compactMap { groupName($0, in: graph) })
      }
      if case .array(let on)? = resolved(defaults[PDFName("ON")], in: graph) {
        onNames = Set(on.compactMap { groupName($0, in: graph) })
      }
    }
    var groups: [OptionalContentDisplayGroup] = []
    for entry in entries {
      let name = groupName(entry, in: graph)
      let visible: Bool
      if let name, offNames.contains(name) {
        visible = false
      } else if let name, onNames.contains(name) {
        visible = true
      } else {
        visible = true
      }
      let displayName: String?
      if case .dictionary(let group)? = resolved(entry, in: graph),
        case .string(let data)? = group[PDFName("Name")]
      {
        let decoded = OptionalContentDisplayPolicy.decode(data)
        displayName = decoded.isEmpty ? nil : decoded
      } else {
        displayName = nil
      }
      groups.append(OptionalContentDisplayGroup(name: displayName, visibleByDefault: visible))
    }
    return groups
  }

  /// PDF text-string decoding shared with the annotation inventory
  /// (PDFDocEncoding-compatible Latin-1 bytes, UTF-16BE with a BOM
  /// otherwise). Local so the display policy does not depend on the
  /// annotation module's internals.
  static func decode(_ data: Data) -> String {
    let bytes = Array(data)
    if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
      var units: [UInt16] = []
      var index = 2
      while index + 1 < bytes.count {
        units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        index += 2
      }
      return String(decoding: units, as: UTF16.self)
    }
    return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
  }

  private static func groupName(_ value: PDFValue, in graph: PDFGraph) -> String? {
    guard case .dictionary(let group)? = resolved(value, in: graph),
      case .string(let data)? = group[PDFName("Name")]
    else { return nil }
    let decoded = OptionalContentDisplayPolicy.decode(data)
    return decoded.isEmpty ? nil : decoded
  }
}
