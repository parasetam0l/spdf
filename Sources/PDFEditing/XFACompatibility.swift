import Foundation
import PDFCore

/// SPC-07: how sPDF reads, fills and flattens XFA forms. The declared decision
/// is an explicit exclusion for XFA rendering and XFA/DOM filling/authoring, plus
/// a bounded AcroForm fallback path: when the document carries AcroForm fields,
/// those ordinary widgets remain fillable and can be flattened into a static
/// copy. Static and dynamic XFA are both detected and disclosed; they are never
/// rendered, evaluated or XML-authored.
public enum XFAKind: String, Sendable, Equatable {
  /// No XFA is present.
  case none
  /// XFA is present as a single XDP stream without dynamic rendering.
  case staticXFA
  /// XFA is present as a packet array or requests dynamic rendering.
  case dynamicXFA
  /// XFA is present but its representation could not be classified.
  case unknown

  public var title: String {
    switch self {
    case .none: return "No XFA"
    case .staticXFA: return "Static XFA"
    case .dynamicXFA: return "Dynamic XFA"
    case .unknown: return "Unclassified XFA"
    }
  }
}

/// SPC-07: the read/fill/authoring decision for one document. This is a
/// read-only report; the caller keeps the original file and only an explicit
/// flatten action produces a new static copy.
public struct XFACompatibilityProfile: Sendable, Equatable {
  public static let profileIdentifier = "spdf-xfa-read-fill-decision-v1"

  public let kind: XFAKind
  public let needsRendering: Bool
  public let packetCount: Int
  public let xfaByteCount: Int
  public let acroFormFieldCount: Int
  public let renderDecision: String
  public let fillDecision: String
  public let authoringDecision: String
  public let flatteningDecision: String
  public let disclosures: [String]
  public let summary: String

  public var hasXFA: Bool { kind != .none }
  public var fallbackAvailable: Bool { acroFormFieldCount > 0 }
  public var flatteningAvailable: Bool { fallbackAvailable }
  /// True when the row's exclusion applies to this document.
  public var isDeclaredExclusion: Bool { hasXFA }
}

public enum XFACompatibility {
  public static let staticRenderDecision =
    "XFA layout is not rendered by sPDF; the ordinary PDF page content and AcroForm "
    + "widgets, when present, are what sPDF displays."
  public static let dynamicRenderDecision =
    "Dynamic XFA layout is not rendered by sPDF; a dynamic XFA document may have little "
    + "or no static page content, so its displayed pages can differ from an Acrobat view."
  public static let noFallbackFillDecision =
    "No AcroForm fallback fields are present. This XFA-only form is preserved for "
    + "display/byte fidelity but cannot be filled in sPDF."
  public static let fallbackFillDecision =
    "AcroForm fallback fields remain fillable and flattenable with ordinary PDF field "
    + "operations; XFA data binding, scripts and validation are not evaluated."
  public static let authoringDecision =
    "XFA/XML authoring is a separate feature and is not supported. Existing XFA bytes "
    + "are preserved untouched by unrelated edits."
  public static let flatteningDecision =
    "An explicit Flatten Form action can burn the AcroForm fallback widgets into page "
    + "content and remove interactivity. The flattened copy is static; the original file "
    + "with XFA is retained by the caller and is not modified."

  public static func profile(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> XFACompatibilityProfile {
    let acroForm = acroFormDictionary(in: graph)
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    guard let value = acroForm?[PDFName("XFA")], !isEmpty(value) else {
      return XFACompatibilityProfile(
        kind: .none, needsRendering: false, packetCount: 0, xfaByteCount: 0,
        acroFormFieldCount: fields.count,
        renderDecision: "No XFA form data is present.",
        fillDecision: "Ordinary AcroForm fields follow the standard field profile.",
        authoringDecision: authoringDecision,
        flatteningDecision: flatteningDecision,
        disclosures: [authoringDecision, flatteningDecision],
        summary: "No XFA form data is present.")
    }
    let needsRendering: Bool
    if case .boolean(let flag)? = acroForm?[PDFName("NeedsRendering")] {
      needsRendering = flag
    } else if case .integer(let flag)? = acroForm?[PDFName("NeedsRendering")] {
      needsRendering = flag != 0
    } else {
      needsRendering = false
    }

    var packetCount = 0
    var xfaBytes = 0
    var kind = XFAKind.unknown
    switch resolve(value, in: graph) {
    case .array(let packets)?:
      packetCount = packets.count / 2
      if packets.count % 2 == 1 { packetCount = max(1, packetCount) }
      xfaBytes = packets.reduce(0) { $0 + byteCount(of: $1, in: graph) }
      kind = .dynamicXFA
    case .stream(let stream)?:
      packetCount = 1
      xfaBytes = stream.bytes.count
      kind = needsRendering ? .dynamicXFA : .staticXFA
    case .string(let data)?:
      packetCount = 1
      xfaBytes = data.count
      kind = needsRendering ? .dynamicXFA : .staticXFA
    case .reference(let id)?:
      let nested = graph.objects[id]
      if case .array(let packets)? = nested {
        packetCount = packets.count / 2
        xfaBytes = packets.reduce(0) { $0 + byteCount(of: $1, in: graph) }
        kind = .dynamicXFA
      } else if case .stream(let stream)? = nested {
        packetCount = 1
        xfaBytes = stream.bytes.count
        kind = needsRendering ? .dynamicXFA : .staticXFA
      }
    default:
      kind = .unknown
    }
    if needsRendering { kind = .dynamicXFA }
    let renderDecision = kind == .dynamicXFA ? dynamicRenderDecision : staticRenderDecision
    let fillDecision = fields.count > 0 ? fallbackFillDecision : noFallbackFillDecision
    var disclosures = [
      renderDecision,
      "XFA data binding, calculations, validation and scripts are never evaluated.",
      fillDecision,
      authoringDecision,
      flatteningDecision,
    ]
    if kind == .dynamicXFA {
      disclosures.append(
        "Dynamic XFA can request rendering that sPDF does not implement; the declared "
          + "replacement is display preservation plus an explicit static flatten when "
          + "AcroForm fallback fields exist.")
    }
    let summary: String
    if kind == .none {
      summary = "No XFA form data is present."
    } else {
      summary =
        "\(kind.title) detected (\(packetCount) \(packetCount == 1 ? "packet" : "packets"), "
        + "\(xfaBytes) bytes). XFA is not rendered or filled; "
        + (fields.isEmpty
          ? "no AcroForm fallback fields are available."
          : "\(fields.count) AcroForm fallback "
            + "\(fields.count == 1 ? "field remains" : "fields remain") fillable and "
            + "flattenable explicitly.")
    }
    return XFACompatibilityProfile(
      kind: kind, needsRendering: needsRendering, packetCount: packetCount,
      xfaByteCount: xfaBytes, acroFormFieldCount: fields.count,
      renderDecision: renderDecision, fillDecision: fillDecision,
      authoringDecision: authoringDecision, flatteningDecision: flatteningDecision,
      disclosures: disclosures, summary: summary)
  }

  static func acroFormDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { return nil }
    switch catalog[PDFName("AcroForm")] {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }

  static func resolve(_ value: PDFValue, in graph: PDFGraph) -> PDFValue? {
    switch value {
    case .reference(let id): return graph.objects[id]
    case .stream, .string, .array: return value
    default: return nil
    }
  }

  static func byteCount(of value: PDFValue, in graph: PDFGraph) -> Int {
    switch value {
    case .string(let data): return data.count
    case .stream(let stream): return stream.bytes.count
    case .reference(let id): return byteCount(of: graph.objects[id] ?? .null, in: graph)
    default: return 0
    }
  }

  static func isEmpty(_ value: PDFValue) -> Bool {
    switch value {
    case .null: return true
    case .string(let data): return data.isEmpty
    case .stream(let stream): return stream.bytes.isEmpty
    case .array(let values): return values.isEmpty
    case .reference(let id): return false
    default: return false
    }
  }
}
