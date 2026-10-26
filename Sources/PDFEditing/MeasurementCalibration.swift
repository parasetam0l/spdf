import Foundation
import PDFCore

// SPC-02: calibrated distance/perimeter/area measurement and supported
// geographic inspection. Declared profile: a calibration states exactly how
// many measured units one PDF page point represents. PDF /Measure ratio
// dictionaries with /R and /X are parsed for the supported syntaxes; geospatial
// support is the PDF 2.0 /Measure /GEO mapping with /GPTS (geographic points)
// and /LPTS (local page points), treated as a two-point similarity transform.
// No projection/datum conversion is performed and no accuracy is claimed when
// the evidence is missing.

public enum MeasurementUnit: String, Sendable, CaseIterable, Hashable {
  case point
  case inch
  case foot
  case yard
  case mile
  case millimeter
  case centimeter
  case meter
  case kilometer
  case nauticalMile

  public var metersPerUnit: Double {
    switch self {
    case .point: return 0.0254 / 72.0
    case .inch: return 0.0254
    case .foot: return 0.3048
    case .yard: return 0.9144
    case .mile: return 1_609.344
    case .millimeter: return 0.001
    case .centimeter: return 0.01
    case .meter: return 1
    case .kilometer: return 1_000
    case .nauticalMile: return 1_852
    }
  }

  public var symbol: String {
    switch self {
    case .point: return "pt"
    case .inch: return "in"
    case .foot: return "ft"
    case .yard: return "yd"
    case .mile: return "mi"
    case .millimeter: return "mm"
    case .centimeter: return "cm"
    case .meter: return "m"
    case .kilometer: return "km"
    case .nauticalMile: return "nmi"
    }
  }

  public var areaSymbol: String { symbol + "2" }

  public var title: String {
    switch self {
    case .point: return "Points"
    case .inch: return "Inches"
    case .foot: return "Feet"
    case .yard: return "Yards"
    case .mile: return "Miles"
    case .millimeter: return "Millimeters"
    case .centimeter: return "Centimeters"
    case .meter: return "Meters"
    case .kilometer: return "Kilometers"
    case .nauticalMile: return "Nautical miles"
    }
  }

  public static func fromPDFUnit(_ raw: String) -> MeasurementUnit? {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "pt", "point", "points": return .point
    case "in", "inch", "inches": return .inch
    case "ft", "foot", "feet": return .foot
    case "yd", "yard", "yards": return .yard
    case "mi", "mile", "miles": return .mile
    case "mm", "millimeter", "millimeters": return .millimeter
    case "cm", "centimeter", "centimeters": return .centimeter
    case "m", "meter", "meters": return .meter
    case "km", "kilometer", "kilometers": return .kilometer
    case "nmi", "nauticalmile", "nautical miles", "nm": return .nauticalMile
    default: return nil
    }
  }
}

public enum MeasurementScaleSource: String, Sendable, Equatable {
  case declared
  case pdfMeasureDictionary
  case geospatial
}

public struct MeasurementCalibration: Sendable, Equatable {
  public let unitsPerPoint: Double
  public let unit: MeasurementUnit
  public let source: MeasurementScaleSource
  public let displayPrecision: Int

  public init(
    unitsPerPoint: Double, unit: MeasurementUnit,
    source: MeasurementScaleSource = .declared, displayPrecision: Int = 2
  ) throws {
    guard unitsPerPoint.isFinite, unitsPerPoint > 0 else {
      throw PDFError(.malformed, "Calibration units per point must be a positive finite number")
    }
    guard (0...6).contains(displayPrecision) else {
      throw PDFError(.malformed, "Calibration precision must be in 0...6")
    }
    self.unitsPerPoint = unitsPerPoint
    self.unit = unit
    self.source = source
    self.displayPrecision = displayPrecision
  }

  public static let uncalibratedPoints: MeasurementCalibration = {
    try! MeasurementCalibration(unitsPerPoint: 1, unit: .point, source: .declared)
  }()

  public static func ratio(
    _ denominator: Double, unit: MeasurementUnit, displayPrecision: Int = 2
  ) throws -> MeasurementCalibration {
    guard denominator.isFinite, denominator > 0 else {
      throw PDFError(.malformed, "A 1:N scale needs a positive denominator")
    }
    let pointMeters = MeasurementUnit.point.metersPerUnit
    let units = denominator * pointMeters / unit.metersPerUnit
    return try MeasurementCalibration(
      unitsPerPoint: units, unit: unit, source: .declared,
      displayPrecision: displayPrecision)
  }

  public var description: String {
    String(format: "1 pt = %@ %@", format(unitsPerPoint), unit.symbol)
      + " (" + source.rawValue + ")"
  }

  public func format(_ value: Double) -> String {
    String(format: "%.\(displayPrecision)f", value)
  }
}

public enum MeasurementShape: Sendable, Equatable {
  case distance(from: [Double], to: [Double])
  case perimeter(points: [[Double]])
  case area(points: [[Double]])

  public var kind: MeasurementKind {
    switch self {
    case .distance: return .distance
    case .perimeter: return .perimeter
    case .area: return .area
    }
  }

  public var vertices: [[Double]] {
    switch self {
    case .distance(let from, let to): return [from, to]
    case .perimeter(let points), .area(let points): return points
    }
  }
}

public enum MeasurementKind: String, Sendable, CaseIterable, Hashable {
  case distance
  case perimeter
  case area

  public var title: String {
    switch self {
    case .distance: return "Distance"
    case .perimeter: return "Perimeter"
    case .area: return "Area"
    }
  }
}

public struct MeasurementResult: Sendable, Equatable {
  public let kind: MeasurementKind
  public let value: Double
  public let unit: MeasurementUnit
  public let calibration: MeasurementCalibration
  public let points: [[Double]]

  public init(
    kind: MeasurementKind, value: Double, unit: MeasurementUnit,
    calibration: MeasurementCalibration, points: [[Double]]
  ) {
    self.kind = kind
    self.value = value
    self.unit = unit
    self.calibration = calibration
    self.points = points
  }

  public var unitLabel: String {
    kind == .area ? unit.areaSymbol : unit.symbol
  }

  public var formatted: String {
    calibration.format(value) + " " + unitLabel
  }
}

public enum MeasurementCalculator {
  public static func measure(
    _ shape: MeasurementShape, calibration: MeasurementCalibration
  ) throws -> MeasurementResult {
    let points = shape.vertices
    guard !points.isEmpty, points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
    else {
      throw PDFError(.malformed, "Measurement points must be finite x,y pairs")
    }
    switch shape {
    case .distance(let from, let to):
      let dx = to[0] - from[0]
      let dy = to[1] - from[1]
      let pageDistance = (dx * dx + dy * dy).squareRoot()
      return MeasurementResult(
        kind: .distance, value: pageDistance * calibration.unitsPerPoint,
        unit: calibration.unit, calibration: calibration, points: points)
    case .perimeter(let points):
      guard points.count >= 2 else {
        throw PDFError(.malformed, "Perimeter needs at least two points")
      }
      var pagePerimeter = 0.0
      for index in 0..<(points.count - 1) {
        let dx = points[index + 1][0] - points[index][0]
        let dy = points[index + 1][1] - points[index][1]
        pagePerimeter += (dx * dx + dy * dy).squareRoot()
      }
      // A perimeter measurement is closed for a polygon-like path (3+ points).
      if points.count >= 3 {
        let dx = points[0][0] - points[points.count - 1][0]
        let dy = points[0][1] - points[points.count - 1][1]
        pagePerimeter += (dx * dx + dy * dy).squareRoot()
      }
      return MeasurementResult(
        kind: .perimeter, value: pagePerimeter * calibration.unitsPerPoint,
        unit: calibration.unit, calibration: calibration, points: points)
    case .area(let points):
      guard points.count >= 3 else {
        throw PDFError(.malformed, "Area needs at least three points")
      }
      var twiceArea = 0.0
      for index in 0..<points.count {
        let next = (index + 1) % points.count
        twiceArea += points[index][0] * points[next][1]
          - points[next][0] * points[index][1]
      }
      let pageArea = abs(twiceArea) / 2.0
      let scale = calibration.unitsPerPoint
      return MeasurementResult(
        kind: .area, value: pageArea * scale * scale,
        unit: calibration.unit, calibration: calibration, points: points)
    }
  }
}

public struct MeasurementAnchor: Sendable, Equatable {
  public let point: [Double]
  public let label: String

  public init(point: [Double], label: String) {
    self.point = point
    self.label = label
  }
}

public struct MeasurementSnapResult: Sendable, Equatable {
  public let point: [Double]
  public let anchor: MeasurementAnchor?
  public let didSnap: Bool

  public init(point: [Double], anchor: MeasurementAnchor?, didSnap: Bool) {
    self.point = point
    self.anchor = anchor
    self.didSnap = didSnap
  }
}

public enum MeasurementSnapping {
  public static func snap(
    _ point: [Double], to anchors: [MeasurementAnchor], tolerance: Double = 6
  ) -> MeasurementSnapResult {
    guard point.count == 2, tolerance.isFinite, tolerance >= 0 else {
      return MeasurementSnapResult(point: point, anchor: nil, didSnap: false)
    }
    var best: (anchor: MeasurementAnchor, distance: Double)?
    for anchor in anchors where anchor.point.count == 2 {
      let dx = anchor.point[0] - point[0]
      let dy = anchor.point[1] - point[1]
      let distance = (dx * dx + dy * dy).squareRoot()
      guard distance <= tolerance else { continue }
      if best == nil || distance < best!.distance {
        best = (anchor, distance)
      }
    }
    guard let best else {
      return MeasurementSnapResult(point: point, anchor: nil, didSnap: false)
    }
    return MeasurementSnapResult(point: best.anchor.point, anchor: best.anchor, didSnap: true)
  }

  public static func clamp(_ point: [Double], to box: [Double]) -> [Double] {
    guard point.count == 2, box.count == 4 else { return point }
    return [
      min(max(point[0], min(box[0], box[2])), max(box[0], box[2])),
      min(max(point[1], min(box[1], box[3])), max(box[1], box[3])),
    ]
  }
}

// MARK: - Geospatial metadata

public struct GeospatialCoordinate: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  public var formatted: String {
    String(format: "%.6f, %.6f", latitude, longitude)
  }
}

public struct GeospatialReference: Sendable, Equatable {
  public let geographicPoints: [[Double]]
  public let localPoints: [[Double]]
  public let boundaryNotes: [String]

  public init(geographicPoints: [[Double]], localPoints: [[Double]], boundaryNotes: [String]) {
    self.geographicPoints = geographicPoints
    self.localPoints = localPoints
    self.boundaryNotes = boundaryNotes
  }

  public static func from(measureDictionary: [PDFName: PDFValue]) -> GeospatialReference? {
    guard let geoValue = measureDictionary[PDFName("GEO")] else { return nil }
    let geo: [PDFName: PDFValue]
    if case .dictionary(let dictionary) = geoValue {
      geo = dictionary
    } else {
      return nil
    }
    guard case .array(let gptsValues)? = geo[PDFName("GPTS")],
      case .array(let lptsValues)? = geo[PDFName("LPTS")]
    else { return nil }
    let geographic = pairs(gptsValues)
    let local = pairs(lptsValues)
    guard geographic.count >= 2, geographic.count == local.count,
      geographic.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
    else { return nil }
    return GeospatialReference(
      geographicPoints: geographic, localPoints: local,
      boundaryNotes: [
        "Geographic points are treated as WGS84 latitude/longitude as authored.",
        "The page mapping is a two-point similarity transform from /LPTS to /GPTS; "
          + "no projection or datum conversion is applied.",
      ])
  }

  private static func pairs(_ values: [PDFValue]) -> [[Double]] {
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    guard numbers.count % 2 == 0 else { return [] }
    return stride(from: 0, to: numbers.count, by: 2).map { Array(numbers[$0..<($0 + 2)]) }
  }
}

public struct GeospatialInspection: Sendable, Equatable {
  public let pageIndex: Int
  public let reference: GeospatialReference
  public let sampleCoordinates: [GeospatialCoordinate]
  public let boundaryNotes: [String]

  public init(
    pageIndex: Int, reference: GeospatialReference,
    sampleCoordinates: [GeospatialCoordinate], boundaryNotes: [String]
  ) {
    self.pageIndex = pageIndex
    self.reference = reference
    self.sampleCoordinates = sampleCoordinates
    self.boundaryNotes = boundaryNotes
  }

  public func coordinate(forPagePoint point: [Double]) -> GeospatialCoordinate? {
    guard point.count == 2, reference.localPoints.count >= 2,
      reference.geographicPoints.count >= 2
    else { return nil }
    let localA = reference.localPoints[0]
    let localB = reference.localPoints[1]
    let geoA = reference.geographicPoints[0]
    let geoB = reference.geographicPoints[1]
    let localDX = localB[0] - localA[0]
    let localDY = localB[1] - localA[1]
    let geoDX = geoB[0] - geoA[0]
    let geoDY = geoB[1] - geoA[1]
    let localLengthSquared = localDX * localDX + localDY * localDY
    guard localLengthSquared > 0 else { return nil }
    let geoLength = (geoDX * geoDX + geoDY * geoDY).squareRoot()
    let localLength = localLengthSquared.squareRoot()
    let scale = geoLength / localLength
    let angle = atan2(geoDY, geoDX) - atan2(localDY, localDX)
    let cosAngle = cos(angle)
    let sinAngle = sin(angle)
    let sx = (point[0] - localA[0]) * scale
    let sy = (point[1] - localA[1]) * scale
    return GeospatialCoordinate(
      latitude: geoA[0] + sx * cosAngle - sy * sinAngle,
      longitude: geoA[1] + sx * sinAngle + sy * cosAngle)
  }

  public var report: String {
    var lines = [
      "Geospatial inspection - page \(pageIndex + 1)",
      "  Geographic points: \(reference.geographicPoints.count); local points: "
        + "\(reference.localPoints.count)",
      "  Supported profile: /Measure /GEO /GPTS + /LPTS, two-point similarity map.",
    ]
    for note in boundaryNotes { lines.append("  " + note) }
    for (index, coordinate) in sampleCoordinates.enumerated() {
      lines.append("  Sample \(index + 1): " + coordinate.formatted)
    }
    return lines.joined(separator: "\n")
  }
}

public enum GeospatialInspectionService {
  public static func inspect(
    pageID: PDFObjectID, pageIndex: Int, graph: PDFGraph
  ) -> GeospatialInspection? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    var dictionaries: [[PDFName: PDFValue]] = []
    func resolve(_ value: PDFValue) -> PDFValue {
      if case .reference(let id) = value, let object = graph.objects[id] { return object }
      return value
    }
    func collect(_ value: PDFValue?) {
      guard let value else { return }
      let resolved = resolve(value)
      switch resolved {
      case .dictionary(let dictionary):
        if dictionary[PDFName("GEO")] != nil {
          dictionaries.append(dictionary)
        }
        if let measure = dictionary[PDFName("Measure")] {
          if case .dictionary(let measureDictionary) = resolve(measure) {
            dictionaries.append(measureDictionary)
          }
        }
      case .array(let items):
        for item in items { collect(item) }
      default:
        break
      }
    }
    collect(page[PDFName("VP")])
    collect(page[PDFName("Measure")])
    for dictionary in dictionaries {
      if let reference = GeospatialReference.from(measureDictionary: dictionary) {
        return GeospatialInspection(
          pageIndex: pageIndex, reference: reference,
          sampleCoordinates: reference.localPoints.map {
            GeospatialCoordinate(latitude: $0[1], longitude: $0[0])
          }, boundaryNotes: reference.boundaryNotes)
      }
    }
    return nil
  }
}

// MARK: - Page calibration resolution

public struct MeasurementPageInfo: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let mediaBox: [Double]
  public let cropBox: [Double]
  public let userUnit: Double

  public init(
    pageID: PDFObjectID, pageIndex: Int, mediaBox: [Double], cropBox: [Double],
    userUnit: Double
  ) {
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.mediaBox = mediaBox
    self.cropBox = cropBox
    self.userUnit = userUnit
  }
}

public enum MeasurementPageGeometry {
  public static func info(
    pageID: PDFObjectID, pageIndex: Int, graph: PDFGraph
  ) -> MeasurementPageInfo? {
    var chain: [[PDFName: PDFValue]] = []
    var current: PDFObjectID? = pageID
    var depth = 0
    while let id = current, depth < 32 {
      guard case .dictionary(let page)? = graph.objects[id] else { break }
      chain.append(page)
      if case .reference(let parent)? = page[PDFName("Parent")] {
        current = parent
      } else {
        current = nil
      }
      depth += 1
    }
    guard !chain.isEmpty else { return nil }
    func inherited(_ key: String) -> PDFValue? {
      for page in chain {
        if let value = page[PDFName(key)] { return value }
      }
      return nil
    }
    let media = numbers(inherited("MediaBox")) ?? [0, 0, 612, 792]
    let crop = numbers(inherited("CropBox")) ?? media
    let userUnit: Double
    if let value = inherited("UserUnit"), let number = numbers(value)?.first,
      number.isFinite, number > 0
    {
      userUnit = number
    } else {
      userUnit = 1
    }
    guard media.count >= 4 else { return nil }
    return MeasurementPageInfo(
      pageID: pageID, pageIndex: pageIndex, mediaBox: Array(media.prefix(4)),
      cropBox: Array(crop.prefix(4)), userUnit: userUnit)
  }

  static func numbers(_ value: PDFValue?) -> [Double]? {
    guard let value else { return nil }
    let numbers: [Double]
    switch value {
    case .array(let values):
      numbers = values.compactMap { item in
        switch item {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
    case .integer(let number):
      numbers = [Double(number)]
    case .real(let number):
      numbers = [number]
    default:
      return nil
    }
    return numbers
  }
}

extension MeasurementCalibration {
  /// SPC-02: parse the supported /Measure /R + /X forms. Unsupported forms
  /// return nil (never a guessed calibration).
  public static func fromPDFMeasureDictionary(
    _ dictionary: [PDFName: PDFValue], userUnit: Double = 1
  ) -> MeasurementCalibration? {
    guard case .string(let ratioData)? = dictionary[PDFName("R")] else { return nil }
    let ratio = String(decoding: ratioData, as: UTF8.self)
    let unit: MeasurementUnit
    if case .string(let unitData)? = dictionary[PDFName("X")],
      let parsed = MeasurementUnit.fromPDFUnit(String(decoding: unitData, as: UTF8.self))
    {
      unit = parsed
    } else {
      unit = .point
    }
    let precision: Int
    if case .array(let values)? = dictionary[PDFName("D")],
      case .integer(let number)? = values.first,
      (0...6).contains(Int(number))
    {
      precision = Int(number)
    } else {
      precision = 2
    }
    guard let unitsPerPoint = unitsPerPoint(fromRatio: ratio, unit: unit) else {
      return nil
    }
    let factor = (userUnit.isFinite && userUnit > 0) ? userUnit : 1
    return try? MeasurementCalibration(
      unitsPerPoint: unitsPerPoint * factor, unit: unit,
      source: .pdfMeasureDictionary, displayPrecision: precision)
  }

  static func unitsPerPoint(fromRatio ratio: String, unit: MeasurementUnit) -> Double? {
    let trimmed = ratio.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let pointMeters = MeasurementUnit.point.metersPerUnit
    if trimmed.contains(":") {
      let parts = trimmed.split(separator: ":")
      guard parts.count == 2,
        let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
        let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)),
        numerator > 0, denominator > 0
      else { return nil }
      return (denominator / numerator) * pointMeters / unit.metersPerUnit
    }
    if trimmed.contains("=") {
      let parts = trimmed.components(separatedBy: "=")
      guard parts.count == 2,
        let left = parseLength(parts[0]), let right = parseLength(parts[1]),
        left.quantity > 0, right.quantity > 0
      else { return nil }
      let pageMeters = left.quantity * left.unit.metersPerUnit
      let realMeters = right.quantity * right.unit.metersPerUnit
      guard pageMeters > 0 else { return nil }
      return (realMeters / pageMeters) * pointMeters / unit.metersPerUnit
    }
    if let number = Double(trimmed), number > 0 {
      return number * pointMeters / unit.metersPerUnit
    }
    return nil
  }

  private static func parseLength(
    _ raw: String
  ) -> (quantity: Double, unit: MeasurementUnit)? {
    let tokens = raw.trimmingCharacters(in: .whitespaces).split(separator: " ")
    guard tokens.count >= 2, let quantity = Double(tokens[0]),
      let unit = MeasurementUnit.fromPDFUnit(tokens.dropFirst().joined(separator: " "))
    else { return nil }
    return (quantity, unit)
  }

  /// SPC-02: resolve calibration from the page's first supported /Measure
  /// dictionary under /VP or directly on the page. Returns nil when absent or
  /// unsupported; the caller must ask the user instead of assuming a scale.
  public static func resolve(
    pageID: PDFObjectID, graph: PDFGraph
  ) -> MeasurementCalibration? {
    guard let info = MeasurementPageGeometry.info(
      pageID: pageID, pageIndex: 0, graph: graph)
    else { return nil }
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    var dictionaries: [[PDFName: PDFValue]] = []
    func resolve(_ value: PDFValue) -> PDFValue {
      if case .reference(let id) = value, let object = graph.objects[id] { return object }
      return value
    }
    func collect(_ value: PDFValue?) {
      guard let value else { return }
      let resolved = resolve(value)
      switch resolved {
      case .dictionary(let dictionary):
        if dictionary[PDFName("R")] != nil || dictionary[PDFName("GEO")] != nil {
          dictionaries.append(dictionary)
        }
        if let measure = dictionary[PDFName("Measure")] {
          if case .dictionary(let measureDictionary) = resolve(measure) {
            dictionaries.append(measureDictionary)
          }
        }
      case .array(let items):
        for item in items { collect(item) }
      default:
        break
      }
    }
    collect(page[PDFName("VP")])
    collect(page[PDFName("Measure")])
    for dictionary in dictionaries {
      if let calibration = fromPDFMeasureDictionary(
        dictionary, userUnit: info.userUnit)
      {
        return calibration
      }
    }
    return nil
  }
}

// MARK: - Measurement annotations (round-trip)

public struct AddMeasurementAnnotationCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let shape: MeasurementShape
  public let calibration: MeasurementCalibration
  public let color: [Double]
  public let borderWidth: Double
  public let opacity: Double
  public let contents: String?
  public let author: String?
  public let modified: String?

  public init(
    pageID: PDFObjectID, shape: MeasurementShape, calibration: MeasurementCalibration,
    color: [Double] = [0.85, 0.1, 0.1], borderWidth: Double = 1, opacity: Double = 1,
    contents: String? = nil, author: String? = nil, modified: String? = nil
  ) {
    self.pageID = pageID
    self.shape = shape
    self.calibration = calibration
    self.color = color
    self.borderWidth = borderWidth
    self.opacity = opacity
    self.contents = contents
    self.author = author
    self.modified = modified
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add " + shape.kind.title + " Measurement" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateColor(color, label: "Measurement color")
    try AnnotationSupport.validateOpacity(opacity)
    try AnnotationSupport.validateBorderWidth(borderWidth)
    _ = try MeasurementCalculator.measure(shape, calibration: calibration)
    _ = try AnnotationSupport.allocate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let result = try MeasurementCalculator.measure(shape, calibration: calibration)
    let allocation = try AnnotationSupport.allocate(in: graph)
    let points = shape.vertices
    let flattened = points.flatMap { $0 }
    var rect = AnnotationSupport.rect(ofPoints: flattened)
    let minimum = max(1, borderWidth)
    if rect[2] - rect[0] < minimum { rect[2] = rect[0] + minimum }
    if rect[3] - rect[1] < minimum { rect[3] = rect[1] + minimum }
    let subtype: PDFName
    switch shape.kind {
    case .distance: subtype = PDFName("Line")
    case .perimeter: subtype = PDFName("PolyLine")
    case .area: subtype = PDFName("Polygon")
    }
    var dictionary = AnnotationSupport.annotationDictionary(
      subtype: subtype, rect: rect, color: color, opacity: opacity,
      contents: contents ?? result.formatted, author: author, modified: modified,
      subject: "Measurement", appearance: allocation.appearance)
    dictionary[PDFName("Border")] = .array([
      .integer(0), .integer(0), .real(borderWidth),
    ])
    dictionary[PDFName("Measure")] = .dictionary(Self.measureDictionary(
      result: result, kind: shape.kind))
    switch shape.kind {
    case .distance:
      dictionary[PDFName("L")] = .array(flattened.map { .real($0) })
    case .perimeter, .area:
      dictionary[PDFName("Vertices")] = .array(flattened.map { .real($0) })
    }
    graph.objects[allocation.annotation] = .dictionary(dictionary)
    graph.objects[allocation.appearance] = .stream(
      AnnotationSupport.formAppearance(
        rect: rect, content: Self.appearance(
          kind: shape.kind, points: points, rect: rect,
          color: color, borderWidth: borderWidth),
        resources: AnnotationSupport.stateResources(opacity: opacity, blendMultiply: false)))
    try AnnotationSupport.appendToAnnots(
      .reference(allocation.annotation), pageID: pageID, in: &graph)
    AnnotationSupport.finish(&graph, allocation: allocation)
    return graph
  }

  static func measureDictionary(
    result: MeasurementResult, kind: MeasurementKind
  ) -> [PDFName: PDFValue] {
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Measure")),
      PDFName("Subtype"): .name(PDFName("RL")),
      PDFName("R"): .string(Data(ratioDescription(kind: kind, calibration: result.calibration).utf8)),
      PDFName("X"): .string(Data(result.unit.symbol.utf8)),
      PDFName("D"): .array([.integer(Int64(result.calibration.displayPrecision))]),
      PDFName("sPDFUnitsPerPoint"): .real(result.calibration.unitsPerPoint),
      PDFName("sPDFUnit"): .name(PDFName(result.unit.rawValue)),
      PDFName("sPDFKind"): .name(PDFName(kind.rawValue)),
      PDFName("sPDFSource"): .name(PDFName(result.calibration.source.rawValue)),
    ]
    dictionary[PDFName("sPDFArea")] = .boolean(kind == .area)
    return dictionary
  }

  static func ratioDescription(
    kind: MeasurementKind, calibration: MeasurementCalibration
  ) -> String {
    let pointMeters = MeasurementUnit.point.metersPerUnit
    let relationship = calibration.unitsPerPoint * calibration.unit.metersPerUnit
      / pointMeters
    return String(format: "1:%g", relationship)
  }

  static func appearance(
    kind: MeasurementKind, points: [[Double]], rect: [Double], color: [Double],
    borderWidth: Double
  ) -> String {
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) RG\n"
    content += "\(AnnotationSupport.number(max(0.25, borderWidth))) w\n"
    func local(_ point: [Double]) -> (Double, Double) {
      (point[0] - rect[0], point[1] - rect[1])
    }
    if let first = points.first {
      let start = local(first)
      content += "\(AnnotationSupport.number(start.0)) "
      content += "\(AnnotationSupport.number(start.1)) m\n"
      for point in points.dropFirst() {
        let target = local(point)
        content += "\(AnnotationSupport.number(target.0)) "
        content += "\(AnnotationSupport.number(target.1)) l\n"
      }
      if kind == .area { content += "h\n" }
      content += "S\n"
    }
    content += "Q\n"
    return content
  }
}

public struct MeasurementInventoryReport: Sendable, Equatable {
  public let measurements: [MeasurementAnnotation]
  public let issues: [String]

  public init(measurements: [MeasurementAnnotation], issues: [String]) {
    self.measurements = measurements
    self.issues = issues
  }
}

public struct MeasurementAnnotation: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let objectID: PDFObjectID?
  public let index: Int
  public let kind: MeasurementKind
  public let points: [[Double]]
  public let calibration: MeasurementCalibration
  public let result: MeasurementResult
  public let contents: String?
  public let annotation: Annotation

  public init(
    pageID: PDFObjectID, objectID: PDFObjectID?, index: Int, kind: MeasurementKind,
    points: [[Double]], calibration: MeasurementCalibration, result: MeasurementResult,
    contents: String?, annotation: Annotation
  ) {
    self.pageID = pageID
    self.objectID = objectID
    self.index = index
    self.kind = kind
    self.points = points
    self.calibration = calibration
    self.result = result
    self.contents = contents
    self.annotation = annotation
  }
}

public enum MeasurementAnnotationInventory {
  /// SPC-02: read measurement annotations back from the document without
  /// replacing their raw dictionaries. Malformed entries are reported, not
  /// silently treated as measurements.
  public static func inventory(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> MeasurementInventoryReport {
    var measurements: [MeasurementAnnotation] = []
    var issues: [String] = []
    for pageID in pageIDs {
      let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
      for annotation in annotations {
        guard let measureValue = annotation.dictionary[PDFName("Measure")] else { continue }
        var measure = measureValue
        if case .reference(let id) = measureValue, let object = graph.objects[id] {
          measure = object
        }
        guard case .dictionary(let dictionary) = measure else {
          issues.append("Page \(pageID.number): /Measure is not a dictionary")
          continue
        }
        guard let subtype = annotation.subtype else { continue }
        let kind: MeasurementKind
        switch subtype {
        case PDFName("Line"): kind = .distance
        case PDFName("PolyLine"): kind = .perimeter
        case PDFName("Polygon"): kind = .area
        default:
          issues.append(
            "Page \(pageID.number): measurement subtype \(String(decoding: subtype.bytes, as: UTF8.self)) "
              + "is not supported")
          continue
        }
        guard let calibration = calibration(from: dictionary) else {
          issues.append("Page \(pageID.number): measurement calibration is unsupported")
          continue
        }
        let points: [[Double]]
        switch kind {
        case .distance:
          guard case .array(let values)? = annotation.dictionary[PDFName("L")],
            let numbers = numbers(values), numbers.count == 4
          else { continue }
          points = [Array(numbers[0..<2]), Array(numbers[2..<4])]
        case .perimeter, .area:
          guard case .array(let values)? = annotation.dictionary[PDFName("Vertices")],
            let numbers = numbers(values), numbers.count >= 4, numbers.count % 2 == 0
          else { continue }
          points = stride(from: 0, to: numbers.count, by: 2).map {
            Array(numbers[$0..<($0 + 2)])
          }
        }
        let shape: MeasurementShape
        switch kind {
        case .distance: shape = .distance(from: points[0], to: points[1])
        case .perimeter: shape = .perimeter(points: points)
        case .area: shape = .area(points: points)
        }
        guard let result = try? MeasurementCalculator.measure(shape, calibration: calibration)
        else {
          issues.append("Page \(pageID.number): measurement geometry is invalid")
          continue
        }
        measurements.append(
          MeasurementAnnotation(
            pageID: pageID, objectID: annotation.objectID, index: annotation.index,
            kind: kind, points: points, calibration: calibration, result: result,
            contents: annotation.contents, annotation: annotation))
      }
    }
    return MeasurementInventoryReport(measurements: measurements, issues: issues)
  }

  static func calibration(
    from dictionary: [PDFName: PDFValue]
  ) -> MeasurementCalibration? {
    if case .real(let unitsPerPoint)? = dictionary[PDFName("sPDFUnitsPerPoint")],
      unitsPerPoint.isFinite, unitsPerPoint > 0
    {
      let unit: MeasurementUnit
      if case .name(let unitName)? = dictionary[PDFName("sPDFUnit")],
        let parsed = MeasurementUnit(rawValue: String(decoding: unitName.bytes, as: UTF8.self))
      {
        unit = parsed
      } else if case .string(let unitData)? = dictionary[PDFName("X")],
        let parsed = MeasurementUnit.fromPDFUnit(String(decoding: unitData, as: UTF8.self))
      {
        unit = parsed
      } else {
        unit = .point
      }
      var precision = 2
      if case .array(let values)? = dictionary[PDFName("D")],
        case .integer(let number)? = values.first, (0...6).contains(Int(number))
      {
        precision = Int(number)
      }
      let source: MeasurementScaleSource
      if case .name(let sourceName)? = dictionary[PDFName("sPDFSource")],
        let parsed = MeasurementScaleSource(rawValue: String(decoding: sourceName.bytes, as: UTF8.self))
      {
        source = parsed
      } else {
        source = .pdfMeasureDictionary
      }
      return try? MeasurementCalibration(
        unitsPerPoint: unitsPerPoint, unit: unit, source: source,
        displayPrecision: precision)
    }
    return MeasurementCalibration.fromPDFMeasureDictionary(dictionary)
  }

  static func numbers(_ values: [PDFValue]) -> [Double]? {
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return numbers.count == values.count ? numbers : nil
  }
}
