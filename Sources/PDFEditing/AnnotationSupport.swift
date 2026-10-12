import Foundation
import PDFCore

/// Shared mechanics for annotation commands: object allocation, /Annots
/// appending, validation, dictionaries, and generated appearance forms.
/// Every command appends to existing annotation arrays without touching the
/// entries already there (P22-023).
enum AnnotationSupport {
  struct Allocation {
    let annotation: PDFObjectID
    let appearance: PDFObjectID
    /// First object number after the reserved pair (highest reserved + 1).
    let next: Int
  }

  /// Two fresh object numbers above every existing number, so creation can
  /// never collide with an existing object (P09-008).
  static func allocate(in graph: PDFGraph) throws -> Allocation {
    let base = graph.objects.keys.map(\.number).max() ?? 0
    let next = base + 3
    guard next <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for annotation objects")
    }
    return Allocation(
      annotation: PDFObjectID(base + 1), appearance: PDFObjectID(base + 2), next: next)
  }

  /// One fresh object number for annotations without a generated appearance.
  static func allocateOne(in graph: PDFGraph) throws -> PDFObjectID {
    let base = graph.objects.keys.map(\.number).max() ?? 0
    guard base + 1 <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for annotation objects")
    }
    return PDFObjectID(base + 1)
  }

  static func validatePage(_ pageID: PDFObjectID, in graph: PDFGraph) throws {
    let view = try PageTreeView(graph: graph)
    guard view.pages.contains(pageID) else {
      throw PDFError(.malformed, "Annotation target is not a page")
    }
  }

  static func validateQuads(_ quads: [Double]) throws {
    guard !quads.isEmpty, quads.count % 8 == 0, quads.allSatisfy(\.isFinite) else {
      throw PDFError(.malformed, "Annotation quadrilaterals are invalid")
    }
  }

  static func validateColor(_ color: [Double], label: String) throws {
    guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
      throw PDFError(.malformed, "\(label) must be three components in 0...1")
    }
  }

  static func validateOpacity(_ opacity: Double) throws {
    guard opacity.isFinite, opacity >= 0, opacity <= 1 else {
      throw PDFError(.malformed, "Annotation opacity must be in 0...1")
    }
  }

  static func validateBorderWidth(_ width: Double, maximum: Double = 24) throws {
    guard width.isFinite, width >= 0, width <= maximum else {
      throw PDFError(.malformed, "Annotation border width must be in 0...\(Int(maximum))")
    }
  }

  static func appendToAnnots(
    _ reference: PDFValue, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Annots")] {
    case .array(var items)?:
      items.append(reference)
      page[PDFName("Annots")] = .array(items)
    case .reference(let arrayID)?:
      guard case .array(var items)? = graph.objects[arrayID] else {
        throw PDFError(.malformed, "Annotation array is missing")
      }
      items.append(reference)
      graph.objects[arrayID] = .array(items)
    default:
      page[PDFName("Annots")] = .array([reference])
    }
    graph.objects[pageID] = .dictionary(page)
  }

  /// Keep the declared object count consistent with the added objects:
  /// /Size is the highest object number plus one.
  static func finish(_ graph: inout PDFGraph, allocation: Allocation) {
    graph.trailer[PDFName("Size")] = .integer(Int64(allocation.next))
  }

  static func finish(_ graph: inout PDFGraph, highest: Int) {
    graph.trailer[PDFName("Size")] = .integer(Int64(highest) + 1)
  }

  static func validateRect(_ rect: [Double]) throws {
    guard rect.count == 4, rect.allSatisfy(\.isFinite),
      rect[2] > rect[0], rect[3] > rect[1]
    else {
      throw PDFError(.malformed, "Annotation rectangle is invalid")
    }
  }

  /// Base annotation dictionary shared by every generated annotation type.
  static func annotationDictionary(
    subtype: PDFName, rect: [Double], color: [Double]?, opacity: Double?,
    contents: String?, author: String?, modified: String?, subject: String?,
    appearance: PDFObjectID
  ) -> [PDFName: PDFValue] {
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(subtype),
      PDFName("Rect"): .array(rect.map { .real($0) }),
      PDFName("F"): .integer(4),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(appearance)]),
    ]
    if let color { dictionary[PDFName("C")] = .array(color.map { .real($0) }) }
    if let opacity { dictionary[PDFName("CA")] = .real(opacity) }
    if let contents { dictionary[PDFName("Contents")] = .string(AnnotationText.encode(contents)) }
    if let author { dictionary[PDFName("T")] = .string(AnnotationText.encode(author)) }
    if let modified { dictionary[PDFName("M")] = .string(AnnotationText.encode(modified)) }
    if let subject { dictionary[PDFName("Subj")] = .string(AnnotationText.encode(subject)) }
    return dictionary
  }

  /// Generated appearance form in annotation-relative coordinates with an
  /// exact /Length, so no reader has to synthesize an appearance.
  static func formAppearance(
    rect: [Double], content: String, resources: [PDFName: PDFValue] = [:]
  ) -> PDFStream {
    let bytes = Data(content.utf8)
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Form")),
      PDFName("FormType"): .integer(1),
      PDFName("BBox"): .array([
        .integer(0), .integer(0), .real(rect[2] - rect[0]), .real(rect[3] - rect[1]),
      ]),
      PDFName("Length"): .integer(Int64(bytes.count)),
    ]
    if !resources.isEmpty { dictionary[PDFName("Resources")] = .dictionary(resources) }
    return PDFStream(dictionary: dictionary, bytes: bytes)
  }

  /// ExtGState resources with constant alpha and optional Multiply blending:
  /// text markup blends like Apple's writer, while shapes, notes, and lines
  /// keep their colors true.
  static func stateResources(opacity: Double, blendMultiply: Bool) -> [PDFName: PDFValue] {
    var state: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("ExtGState")),
      PDFName("ca"): .real(opacity),
      PDFName("CA"): .real(opacity),
    ]
    if blendMultiply { state[PDFName("BM")] = .name(PDFName("Multiply")) }
    return [PDFName("ExtGState"): .dictionary([PDFName("GS0"): .dictionary(state)])]
  }

  /// Axis-aligned union over every coordinate pair.
  static func rect(ofPoints values: [Double]) -> [Double] {
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    for index in stride(from: 0, to: values.count, by: 2) {
      minX = min(minX, values[index])
      maxX = max(maxX, values[index])
      minY = min(minY, values[index + 1])
      maxY = max(maxY, values[index + 1])
    }
    return [minX, minY, maxX, maxY]
  }

  static func rect(ofQuads quads: [Double]) -> [Double] { rect(ofPoints: quads) }

  /// Axis-aligned cluster bounds (`[x0, y0, x1, y1]`) become quadrilaterals
  /// in the order Apple's PDFKit and common viewers use: upper-left,
  /// upper-right, lower-left, lower-right.
  static func quadPoints(fromClusterBounds bounds: [[Double]]) -> [Double] {
    var quads: [Double] = []
    for bound in bounds where bound.count == 4 && bound.allSatisfy(\.isFinite) {
      quads.append(contentsOf: [
        bound[0], bound[3], bound[2], bound[3], bound[0], bound[1], bound[2], bound[1],
      ])
    }
    return quads
  }

  /// Canonical content-stream number without locale dependence.
  static func number(_ value: Double) -> String { ImageInventory.numberToken(value) }

  /// Four cubic curves approximating an ellipse centered at (cx, cy).
  static func ellipsePath(cx: Double, cy: Double, rx: Double, ry: Double) -> String {
    let kappa = 0.552_284_749_830_793_6
    let ox = rx * kappa
    let oy = ry * kappa
    func point(_ x: Double, _ y: Double) -> String {
      "\(number(x)) \(number(y))"
    }
    var path = "\(point(cx + rx, cy)) m\n"
    path += "\(point(cx + rx, cy + oy)) \(point(cx + ox, cy + ry)) \(point(cx, cy + ry)) c\n"
    path += "\(point(cx - ox, cy + ry)) \(point(cx - rx, cy + oy)) \(point(cx - rx, cy)) c\n"
    path += "\(point(cx - rx, cy - oy)) \(point(cx - ox, cy - ry)) \(point(cx, cy - ry)) c\n"
    path += "\(point(cx + ox, cy - ry)) \(point(cx + rx, cy - oy)) \(point(cx + rx, cy)) c\n"
    return path
  }

  // MARK: - Standard-14 font resources

  /// Reuse an existing standard Helvetica with WinAnsi encoding when the
  /// document already carries one, so repeated text annotations do not grow
  /// the object graph.
  static func helveticaFontID(in graph: PDFGraph) -> PDFObjectID? {
    for id in graph.objects.keys.sorted() {
      guard case .dictionary(let dictionary)? = graph.objects[id],
        dictionary[PDFName("Type")] == .name(PDFName("Font")),
        dictionary[PDFName("Subtype")] == .name(PDFName("Type1")),
        dictionary[PDFName("BaseFont")] == .name(PDFName("Helvetica"))
      else { continue }
      let encoding = dictionary[PDFName("Encoding")]
      if encoding == nil || encoding == .name(PDFName("WinAnsiEncoding")) { return id }
    }
    return nil
  }

  static func helveticaFontDictionary() -> [PDFName: PDFValue] {
    [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ]
  }

  /// PDF literal string with WinAnsi bytes, or nil when the text cannot be
  /// represented by that encoding (P22-005 profile limit).
  static func escapedLiteral(_ text: String) -> String? {
    guard let data = text.data(using: .windowsCP1252) else { return nil }
    var result = "("
    for byte in data {
      switch byte {
      case 0x28: result += "\\("
      case 0x29: result += "\\)"
      case 0x5C: result += "\\\\"
      case 0x0A: result += "\\n"
      case 0x0D: result += "\\r"
      case 0x09: result += "\\t"
      case 0x08: result += "\\b"
      case 0x0C: result += "\\f"
      default:
        if byte < 0x20 || byte > 0x7E {
          result += String(format: "\\%03o", byte)
        } else {
          result += String(UnicodeScalar(byte))
        }
      }
    }
    result += ")"
    return result
  }

  /// Default appearance string for free-text annotations (text editors use
  /// it; our generated appearance is the authoritative rendering).
  static func defaultAppearanceString(fontSize: Double, color: [Double]) -> String {
    "/Helvetica \(number(fontSize)) Tf \(number(color[0])) \(number(color[1])) "
      + "\(number(color[2])) rg"
  }

  /// Conservative Helvetica advance estimate for centering generated labels.
  static func approximateTextWidth(_ text: String, fontSize: Double) -> Double {
    Double(max(1, text.count)) * fontSize * 0.55
  }

  // MARK: - Annotation entry access (P22-011/P22-020)

  struct AnnotationEntry {
    let index: Int
    let objectID: PDFObjectID?
    let dictionary: [PDFName: PDFValue]
  }

  /// Resolve one annotation from a page's /Annots array, whether it is an
  /// indirect object or a direct dictionary.
  static func annotationEntry(
    in graph: PDFGraph, pageID: PDFObjectID, index: Int
  ) throws -> AnnotationEntry {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let items: [PDFValue]
    switch page[PDFName("Annots")] {
    case .array(let array)?:
      items = array
    case .reference(let arrayID)?:
      guard case .array(let array)? = graph.objects[arrayID] else {
        throw PDFError(.malformed, "Page has no annotation array")
      }
      items = array
    default:
      throw PDFError(.malformed, "Page has no annotation array")
    }
    guard index >= 0, index < items.count else {
      throw PDFError(.malformed, "Annotation index is outside the page")
    }
    switch items[index] {
    case .dictionary(let dictionary):
      return AnnotationEntry(index: index, objectID: nil, dictionary: dictionary)
    case .reference(let objectID):
      guard case .dictionary(let dictionary)? = graph.objects[objectID] else {
        throw PDFError(.malformed, "Annotation reference is missing")
      }
      return AnnotationEntry(index: index, objectID: objectID, dictionary: dictionary)
    default:
      throw PDFError(.malformed, "Annotation entry is not a dictionary")
    }
  }

  /// Write one annotation dictionary back, replacing an indirect object or
  /// the direct array element in place.
  static func setAnnotation(
    _ dictionary: [PDFName: PDFValue], entry: AnnotationEntry, pageID: PDFObjectID,
    in graph: inout PDFGraph
  ) throws {
    if let objectID = entry.objectID {
      graph.objects[objectID] = .dictionary(dictionary)
      return
    }
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Annots")] {
    case .array(var items)?:
      guard entry.index < items.count else {
        throw PDFError(.malformed, "Annotation index is outside the page")
      }
      items[entry.index] = .dictionary(dictionary)
      page[PDFName("Annots")] = .array(items)
      graph.objects[pageID] = .dictionary(page)
    case .reference(let arrayID)?:
      guard case .array(var items)? = graph.objects[arrayID], entry.index < items.count else {
        throw PDFError(.malformed, "Annotation index is outside the page")
      }
      items[entry.index] = .dictionary(dictionary)
      graph.objects[arrayID] = .array(items)
    default:
      throw PDFError(.malformed, "Page has no annotation array")
    }
  }

  /// Remove one annotation from the page's /Annots array. A direct array that
  /// becomes empty is dropped so deleting the last annotation restores the
  /// original page structure.
  static func removeAnnotation(pageID: PDFObjectID, index: Int, in graph: inout PDFGraph) throws {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Annots")] {
    case .array(var items)?:
      guard index >= 0, index < items.count else {
        throw PDFError(.malformed, "Annotation index is outside the page")
      }
      items.remove(at: index)
      page[PDFName("Annots")] = items.isEmpty ? nil : .array(items)
      graph.objects[pageID] = .dictionary(page)
    case .reference(let arrayID)?:
      guard case .array(var items)? = graph.objects[arrayID], index >= 0, index < items.count else {
        throw PDFError(.malformed, "Annotation index is outside the page")
      }
      items.remove(at: index)
      graph.objects[arrayID] = .array(items)
    default:
      throw PDFError(.malformed, "Page has no annotation array")
    }
  }

  /// Whether any object or trailer value still references `id`.
  static func isReferenced(_ id: PDFObjectID, in graph: PDFGraph) -> Bool {
    for value in graph.objects.values where references(value, id, depth: 0) { return true }
    for value in graph.trailer.values where references(value, id, depth: 0) { return true }
    return false
  }

  static func references(_ value: PDFValue, _ id: PDFObjectID, depth: Int) -> Bool {
    guard depth <= 64 else { return true }
    switch value {
    case .reference(let other):
      return other == id
    case .array(let values):
      return values.contains { references($0, id, depth: depth + 1) }
    case .dictionary(let dictionary):
      return dictionary.values.contains { references($0, id, depth: depth + 1) }
    case .stream(let stream):
      return references(.dictionary(stream.dictionary), id, depth: depth + 1)
    default:
      return false
    }
  }

  // MARK: - Geometry transforms (P22-011)

  static let pairKeys = ["QuadPoints", "L", "Vertices"]

  /// Translate /Rect and every paired point list by (dx, dy).
  static func translate(
    _ dictionary: inout [PDFName: PDFValue], dx: Double, dy: Double
  ) {
    if let rect = Annotation.numbers(dictionary[PDFName("Rect")], count: 4) {
      dictionary[PDFName("Rect")] = .array([
        .real(rect[0] + dx), .real(rect[1] + dy), .real(rect[2] + dx), .real(rect[3] + dy),
      ])
    }
    for key in pairKeys {
      guard case .array(let values)? = dictionary[PDFName(key)] else { continue }
      let numbers = values.compactMap(Annotation.number)
      guard numbers.count == values.count else { continue }
      dictionary[PDFName(key)] = .array(
        numbers.enumerated().map { index, value in
          .real(value + (index % 2 == 0 ? dx : dy))
        })
    }
    if case .array(let lists)? = dictionary[PDFName("InkList")] {
      dictionary[PDFName("InkList")] = .array(lists.map { list in
        guard case .array(let values) = list else { return list }
        let numbers = values.compactMap(Annotation.number)
        guard numbers.count == values.count else { return list }
        return .array(
          numbers.enumerated().map { index, value in
            .real(value + (index % 2 == 0 ? dx : dy))
          })
      })
    }
  }

  /// Map /Rect and every paired point list from one rectangle to another.
  static func rescale(
    _ dictionary: inout [PDFName: PDFValue], from old: [Double], to new: [Double]
  ) {
    let sx = (new[2] - new[0]) / (old[2] - old[0])
    let sy = (new[3] - new[1]) / (old[3] - old[1])
    func mapPairs(_ values: [PDFValue]) -> [PDFValue]? {
      let numbers = values.compactMap(Annotation.number)
      guard numbers.count == values.count else { return nil }
      var mapped: [PDFValue] = []
      mapped.reserveCapacity(numbers.count)
      for index in stride(from: 0, to: numbers.count, by: 2) {
        mapped.append(.real(new[0] + (numbers[index] - old[0]) * sx))
        mapped.append(.real(new[1] + (numbers[index + 1] - old[1]) * sy))
      }
      return mapped
    }
    dictionary[PDFName("Rect")] = .array(new.map { .real($0) })
    for key in pairKeys {
      guard case .array(let values)? = dictionary[PDFName(key)], let mapped = mapPairs(values)
      else { continue }
      dictionary[PDFName(key)] = .array(mapped)
    }
    if case .array(let lists)? = dictionary[PDFName("InkList")] {
      dictionary[PDFName("InkList")] = .array(lists.map { list in
        guard case .array(let values) = list, let mapped = mapPairs(values) else { return list }
        return .array(mapped)
      })
    }
  }

  static func borderWidth(of dictionary: [PDFName: PDFValue]) -> Double {
    if case .dictionary(let border)? = dictionary[PDFName("BS")],
      let width = Annotation.number(border[PDFName("W")])
    {
      return width
    }
    if case .array(let border)? = dictionary[PDFName("Border")], border.count == 3,
      let width = Annotation.number(border[2])
    {
      return width
    }
    return 1
  }
}
