import Foundation
import PDFCore

/// P22-001: one annotation on a page, modeled from its dictionary. The raw
/// dictionary is the source of truth: keys this profile does not model stay
/// untouched through inventory, unrelated edits, and saves, and the typed
/// accessors are read-only conveniences over the same value.
public struct Annotation: Sendable, Equatable {
  public let pageID: PDFObjectID
  /// Object identity when the annotation is an indirect object; nil when it
  /// is a direct dictionary inside the page's /Annots array.
  public let objectID: PDFObjectID?
  /// Position within the page's /Annots array, including entries that do not
  /// resolve to dictionaries.
  public let index: Int
  public let dictionary: [PDFName: PDFValue]

  public init(
    pageID: PDFObjectID, objectID: PDFObjectID?, index: Int,
    dictionary: [PDFName: PDFValue]
  ) {
    self.pageID = pageID
    self.objectID = objectID
    self.index = index
    self.dictionary = dictionary
  }

  public var subtype: PDFName? {
    if case .name(let name)? = dictionary[PDFName("Subtype")] { return name }
    return nil
  }

  public var rect: [Double]? {
    Self.numbers(dictionary[PDFName("Rect")], count: 4)
  }

  /// QuadPoints grouped into quadrilaterals of eight numbers, preserving the
  /// conventional order: upper-left, upper-right, lower-left, lower-right.
  public var quadPoints: [[Double]]? {
    guard case .array(let values)? = dictionary[PDFName("QuadPoints")], !values.isEmpty,
      values.count % 8 == 0
    else { return nil }
    let numbers = values.compactMap(Self.number)
    guard numbers.count == values.count else { return nil }
    return stride(from: 0, to: numbers.count, by: 8).map { Array(numbers[$0..<($0 + 8)]) }
  }

  public var contents: String? { Self.text(dictionary[PDFName("Contents")]) }
  public var author: String? { Self.text(dictionary[PDFName("T")]) }
  public var modified: String? { Self.text(dictionary[PDFName("M")]) }
  public var name: String? { Self.text(dictionary[PDFName("NM")]) }
  /// /Subj subject line.
  public var subject: String? { Self.text(dictionary[PDFName("Subj")]) }
  /// /State review status for markup annotations (P22-015 read side).
  public var state: PDFName? {
    if case .name(let name)? = dictionary[PDFName("State")] { return name }
    return nil
  }

  /// P22-014: /IRT reference to the annotation this one replies to.
  public var replyTo: PDFObjectID? {
    if case .reference(let id)? = dictionary[PDFName("IRT")] { return id }
    return nil
  }

  /// /Name icon identifier for text (sticky-note) annotations.
  public var iconName: PDFName? {
    if case .name(let name)? = dictionary[PDFName("Name")] { return name }
    return nil
  }

  /// /C color components: one component is grayscale, three is RGB.
  public var color: [Double]? {
    guard case .array(let values)? = dictionary[PDFName("C")],
      values.count == 1 || values.count == 3
    else { return nil }
    let numbers = values.compactMap(Self.number)
    return numbers.count == values.count ? numbers : nil
  }

  public var opacity: Double? { Self.number(dictionary[PDFName("CA")]) }

  /// Union of the quadrilateral points when present, otherwise the rectangle.
  public var bounds: [Double]? {
    if let quads = quadPoints, !quads.isEmpty {
      let xs = quads.flatMap { [$0[0], $0[2], $0[4], $0[6]] }
      let ys = quads.flatMap { [$0[1], $0[3], $0[5], $0[7]] }
      return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
    }
    return rect
  }

  static func number(_ value: PDFValue?) -> Double? {
    switch value {
    case .integer(let raw): return Double(raw)
    case .real(let raw): return raw
    default: return nil
    }
  }

  static func numbers(_ value: PDFValue?, count: Int) -> [Double]? {
    guard case .array(let values)? = value, values.count == count else { return nil }
    let numbers = values.compactMap(number)
    return numbers.count == count ? numbers : nil
  }

  static func text(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  /// /Subtype of a raw annotation dictionary.
  public static func subtype(of dictionary: [PDFName: PDFValue]) -> PDFName? {
    if case .name(let name)? = dictionary[PDFName("Subtype")] { return name }
    return nil
  }
}

/// P22-001: enumerate a page's annotations in array order. Indirect objects
/// are resolved and direct dictionaries are kept as-is; entries that do not
/// resolve to dictionaries are skipped so one malformed entry cannot hide the
/// rest of a page's review data.
public enum AnnotationInventory {
  public static func annotations(in graph: PDFGraph, pageID: PDFObjectID) throws -> [Annotation] {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let items: [PDFValue]
    switch page[PDFName("Annots")] {
    case .array(let array)?:
      items = array
    case .reference(let id)?:
      guard case .array(let array)? = graph.objects[id] else { return [] }
      items = array
    default:
      return []
    }
    var annotations: [Annotation] = []
    for (index, item) in items.enumerated() {
      switch item {
      case .dictionary(let dictionary):
        annotations.append(
          Annotation(pageID: pageID, objectID: nil, index: index, dictionary: dictionary))
      case .reference(let id):
        if case .dictionary(let dictionary)? = graph.objects[id] {
          annotations.append(
            Annotation(pageID: pageID, objectID: id, index: index, dictionary: dictionary))
        }
      default:
        continue
      }
    }
    return annotations
  }
}

/// PDF text strings: PDFDocEncoding-compatible single bytes for Latin-1 range
/// text, UTF-16BE with a BOM otherwise.
enum AnnotationText {
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

  static func encode(_ string: String) -> Data {
    if string.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) {
      return Data(string.unicodeScalars.map { UInt8($0.value) })
    }
    var data = Data([0xFE, 0xFF])
    for unit in string.utf16 {
      data.append(UInt8(unit >> 8))
      data.append(UInt8(unit & 0xFF))
    }
    return data
  }
}
