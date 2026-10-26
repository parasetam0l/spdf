import Foundation
import PDFCore

// PRE-06: separation and overprint preview, decision-first.
//
// Decision: public Apple rendering APIs (PDFKit and CoreGraphics) return one
// composite rendered page. They expose no public API for process/spot
// separation plates, per-plate ink coverage or overprint simulation results.
// Therefore this file implements an owned, explicitly declared approximation
// ("sPDF separation/overprint preview, declared area model v1") over parsed
// content. It is exact for process/spot plate mapping and axis-aligned
// rectangle fills with simple color operators; other paths use bounding-box
// estimates; text, image and shading ink is never estimated and is reported.
//
// Independent print-reference agreement is NOT claimed: no third-party
// separation/overprint reference renderer is available in this environment.
// The tests compare against independent hand-calculated synthetic references.

public enum PublicAppleSeparationSupport: Sendable, Equatable {
  case insufficient(reasons: [String])

  public var decision: String {
    switch self {
    case .insufficient:
      return "Public Apple APIs are insufficient for the required separation/overprint accuracy"
    }
  }

  public var reasons: [String] {
    switch self {
    case .insufficient(let reasons): return reasons
    }
  }

  public static let current: PublicAppleSeparationSupport = .insufficient(reasons: [
    "PDFKit renders a composite page image; it exposes no separation plates, ink names or per-plate coverage.",
    "CoreGraphics page drawing returns composite RGB/CMYK pixels; it exposes no overprint state or plate output.",
    "No public Apple API provides per-operator overprint simulation results, so an owned analyzer is required.",
  ])
}

public enum SeparationPlate: Sendable, Equatable, Hashable {
  case cyan
  case magenta
  case yellow
  case black
  case spot(String)

  public var displayName: String {
    switch self {
    case .cyan: return "Process Cyan"
    case .magenta: return "Process Magenta"
    case .yellow: return "Process Yellow"
    case .black: return "Process Black"
    case .spot(let name): return "Spot " + name
    }
  }

  public var id: String {
    switch self {
    case .cyan: return "process.cyan"
    case .magenta: return "process.magenta"
    case .yellow: return "process.yellow"
    case .black: return "process.black"
    case .spot(let name): return "spot." + name
    }
  }
}

public struct SeparationPlateCoverage: Sendable, Equatable {
  public let plate: SeparationPlate
  /// Page-fraction coverage: summed painted area x ink fraction / page area.
  /// Declared additive model; overlap double-counting is disclosed.
  public let coverage: Double
  public let operationCount: Int

  public init(plate: SeparationPlate, coverage: Double, operationCount: Int) {
    self.plate = plate
    self.coverage = coverage
    self.operationCount = operationCount
  }

  public var percent: Double { coverage * 100 }
}

public struct SeparationOperation: Sendable, Equatable, Identifiable {
  public let id: Int
  public let pageIndex: Int
  public let operatorName: String
  public let role: String
  public let areaFraction: Double
  public let isOverprint: Bool
  public let plateAmounts: [SeparationPlate: Double]
  public let overlapFraction: Double

  public init(
    id: Int, pageIndex: Int, operatorName: String, role: String,
    areaFraction: Double, isOverprint: Bool,
    plateAmounts: [SeparationPlate: Double], overlapFraction: Double
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.operatorName = operatorName
    self.role = role
    self.areaFraction = areaFraction
    self.isOverprint = isOverprint
    self.plateAmounts = plateAmounts
    self.overlapFraction = overlapFraction
  }
}

public struct SeparationOverprintFinding: Sendable, Equatable {
  public let pageIndex: Int
  public let detail: String
  public let overprintAreaFraction: Double

  public init(pageIndex: Int, detail: String, overprintAreaFraction: Double) {
    self.pageIndex = pageIndex
    self.detail = detail
    self.overprintAreaFraction = overprintAreaFraction
  }
}

public struct SeparationPagePreview: Sendable, Equatable, Identifiable {
  public var id: Int { pageIndex }
  public let pageIndex: Int
  public let pageArea: Double
  public let plates: [SeparationPlateCoverage]
  public let operations: [SeparationOperation]
  public let overprintOperations: Int
  public let knockoutOperations: Int
  public let imagePaintOperators: Int
  public let shadingPaintOperators: Int
  public let textPaintOperators: Int
  public let ignoredNotes: [String]
  public let overprintFindings: [SeparationOverprintFinding]

  public init(
    pageIndex: Int, pageArea: Double, plates: [SeparationPlateCoverage],
    operations: [SeparationOperation], overprintOperations: Int,
    knockoutOperations: Int, imagePaintOperators: Int, shadingPaintOperators: Int,
    textPaintOperators: Int, ignoredNotes: [String],
    overprintFindings: [SeparationOverprintFinding]
  ) {
    self.pageIndex = pageIndex
    self.pageArea = pageArea
    self.plates = plates
    self.operations = operations
    self.overprintOperations = overprintOperations
    self.knockoutOperations = knockoutOperations
    self.imagePaintOperators = imagePaintOperators
    self.shadingPaintOperators = shadingPaintOperators
    self.textPaintOperators = textPaintOperators
    self.ignoredNotes = ignoredNotes
    self.overprintFindings = overprintFindings
  }

  public func coverage(for plate: SeparationPlate) -> Double {
    plates.first(where: { $0.plate == plate })?.coverage ?? 0
  }
}

public struct SeparationPreviewReport: Sendable, Equatable {
  public let claimedProfile: String
  public let publicAPIDecision: PublicAppleSeparationSupport
  public let independentReferenceStatus: String
  public let claimedAccuracy: String
  public let pages: [SeparationPagePreview]

  public init(
    claimedProfile: String = "sPDF separation/overprint preview, declared area model v1",
    publicAPIDecision: PublicAppleSeparationSupport = .current,
    independentReferenceStatus: String = "unavailable in this environment; no third-party "
      + "separation/overprint reference renderer is installed. Hand-calculated synthetic "
      + "references are used in tests; third-party print-reference agreement is not claimed.",
    claimedAccuracy: String = "Exact process/spot plate mapping and axis-aligned rectangle "
      + "coverage for simple fill color operators. Non-rectangle paths use bounding-box "
      + "estimates, stroke ink uses a declared 2% area estimate, colors are converted through "
      + "the declared CoreGraphics profiles, and text/image/shading ink is not estimated.",
    pages: [SeparationPagePreview]
  ) {
    self.claimedProfile = claimedProfile
    self.publicAPIDecision = publicAPIDecision
    self.independentReferenceStatus = independentReferenceStatus
    self.claimedAccuracy = claimedAccuracy
    self.pages = pages
  }

  public var overprintOperationCount: Int { pages.reduce(0) { $0 + $1.overprintOperations } }
  public var knockoutOperationCount: Int { pages.reduce(0) { $0 + $1.knockoutOperations } }
  public var allPlates: [SeparationPlate] {
    var seen: Set<SeparationPlate> = []
    var result: [SeparationPlate] = []
    for page in pages {
      for plate in page.plates.map(\.plate) where seen.insert(plate).inserted {
        result.append(plate)
      }
    }
    return result.sorted { $0.displayName < $1.displayName }
  }

  public func report() -> String {
    var lines: [String] = [
      "Separation and overprint preview - " + claimedProfile,
      "Public API decision: " + publicAPIDecision.decision,
    ]
    for reason in publicAPIDecision.reasons { lines.append("  " + reason) }
    lines.append("Independent print reference: " + independentReferenceStatus)
    lines.append("Claimed accuracy: " + claimedAccuracy)
    for page in pages {
      lines.append("")
      lines.append("Page \(page.pageIndex + 1) (page area \(Int(page.pageArea))):")
      for plate in page.plates {
        lines.append(
          "  \(plate.plate.displayName): \(String(format: "%.3f", plate.percent))% coverage "
            + "(\(plate.operationCount) operation(s))")
      }
      if page.plates.isEmpty { lines.append("  No process/spot ink was found.") }
      lines.append(
        "  Overprint operations: \(page.overprintOperations); knockout operations: "
          + "\(page.knockoutOperations).")
      if !page.overprintFindings.isEmpty {
        for finding in page.overprintFindings {
          lines.append(
            "  Overprint: " + finding.detail + " ("
              + String(format: "%.3f", finding.overprintAreaFraction * 100)
              + "% of page area).")
        }
      }
      if page.imagePaintOperators > 0 {
        lines.append(
          "  \(page.imagePaintOperators) image paint operator(s): image ink is not separated.")
      }
      if page.shadingPaintOperators > 0 {
        lines.append(
          "  \(page.shadingPaintOperators) shading/pattern paint operator(s): ink is not separated.")
      }
      if page.textPaintOperators > 0 {
        lines.append(
          "  \(page.textPaintOperators) text paint operator(s): text ink is not estimated.")
      }
      for note in page.ignoredNotes { lines.append("  Note: " + note) }
    }
    lines.append("")
    lines.append(
      "This is an owned preview approximation, not proof of print accuracy; no public Apple "
        + "API supplies separation plates or overprint-accurate output.")
    return lines.joined(separator: "\n")
  }
}

// MARK: - Analyzer

public enum SeparationOverprintPreview {
  public static func analyze(
    graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) -> SeparationPreviewReport {
    var pages: [SeparationPagePreview] = []
    for (pageIndex, pageID) in pageIDs.enumerated() {
      pages.append(analyzePage(
        pageID: pageID, pageIndex: pageIndex, graph: graph, limits: limits))
    }
    return SeparationPreviewReport(pages: pages)
  }

  struct Ink {
    var cyan = 0.0
    var magenta = 0.0
    var yellow = 0.0
    var black = 0.0
    var spots: [String: Double] = [:]

    var isEmpty: Bool {
      cyan == 0 && magenta == 0 && yellow == 0 && black == 0 && spots.isEmpty
    }

    func scaled(by amount: Double) -> [SeparationPlate: Double] {
      var result: [SeparationPlate: Double] = [:]
      if cyan != 0 { result[.cyan] = cyan * amount }
      if magenta != 0 { result[.magenta] = magenta * amount }
      if yellow != 0 { result[.yellow] = yellow * amount }
      if black != 0 { result[.black] = black * amount }
      for (name, tint) in spots where tint != 0 {
        result[.spot(name)] = tint * amount
      }
      return result
    }

    static func cmyk(_ components: [Double]) -> Ink {
      Ink(
        cyan: components.count > 0 ? components[0] : 0,
        magenta: components.count > 1 ? components[1] : 0,
        yellow: components.count > 2 ? components[2] : 0,
        black: components.count > 3 ? components[3] : 0)
    }

    static func gray(_ value: Double) -> Ink {
      Ink(black: 1 - value)
    }

    static func rgb(_ components: [Double]) -> Ink {
      guard
        let cmyk = try? ColorManagedConversion.convertColor(
          components, from: .deviceRGB, to: .genericCMYK,
          options: ColorManagementOptions(blackPreservation: false))
      else { return Ink() }
      return .cmyk(cmyk)
    }

    static func lab(_ components: [Double]) -> Ink {
      let lab = [
        components.count > 0 ? components[0] : 0,
        components.count > 1 ? components[1] : 0,
        components.count > 2 ? components[2] : 0,
      ]
      guard
        let cmyk = try? ColorManagedConversion.convertColor(
          lab, from: .labD50, to: .genericCMYK,
          options: ColorManagementOptions(blackPreservation: false))
      else { return Ink() }
      return .cmyk(cmyk)
    }

    static func icc(_ components: [Double], profile: Data, count: Int) -> Ink {
      guard
        let cmyk = try? ColorManagedConversion.convertColor(
          components, from: .icc(name: "authored", data: profile, components: count),
          to: .genericCMYK,
          options: ColorManagementOptions(blackPreservation: false))
      else { return Ink() }
      return .cmyk(cmyk)
    }
  }

  struct State {
    var ctm: [Double] = [1, 0, 0, 1, 0, 0]
    var fillInk = Ink()
    var strokeInk = Ink()
    var fillOverprint = false
    var strokeOverprint = false
    var fillColorSpace: PDFValue?
    var strokeColorSpace: PDFValue?
  }

  static func analyzePage(
    pageID: PDFObjectID, pageIndex: Int, graph: PDFGraph, limits: PDFLimits
  ) -> SeparationPagePreview {
    let pageArea = max(1, pageGeometry(pageID: pageID, graph: graph))
    var notes: [String] = []
    guard let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits)
    else {
      return SeparationPagePreview(
        pageIndex: pageIndex, pageArea: pageArea, plates: [],
        operations: [], overprintOperations: 0, knockoutOperations: 0,
        imagePaintOperators: 0, shadingPaintOperators: 0, textPaintOperators: 0,
        ignoredNotes: ["The page content could not be parsed; no ink is reported."],
        overprintFindings: [])
    }
    let resources = pageResources(pageID: pageID, graph: graph)
    let externalStates = graphicsStates(in: resources, graph: graph)
    let colorSpaceResources = colorSpaceDictionary(in: resources)
    var state = State()
    var stack: [State] = []
    var pathRectangles: [[Double]] = []
    var pathBounds: [Double]?
    var operations: [SeparationOperation] = []
    var plateTotals: [SeparationPlate: Double] = [:]
    var plateCounts: [SeparationPlate: Int] = [:]
    var priorRectangles: [[Double]] = []
    var overprintOperations = 0
    var knockoutOperations = 0
    var imagePaints = 0
    var shadingPaints = 0
    var textPaints = 0
    var findings: [SeparationOverprintFinding] = []
    var operationID = 0

    func addPlates(_ amounts: [SeparationPlate: Double], areaFraction: Double) {
      for (plate, amount) in amounts {
        let coverage = amount * areaFraction
        guard coverage > 0 else { continue }
        plateTotals[plate, default: 0] += coverage
        plateCounts[plate, default: 0] += 1
      }
    }

    func paint(role: String, operatorName: String) {
      let fill = role == "fill" || role == "fill+stroke"
      let stroke = role == "stroke" || role == "fill+stroke"
      let rectangles = pathRectangles
      let area = paintedArea(
        rectangles: rectangles, bounds: pathBounds, pageArea: pageArea, fill: fill)
      let strokeArea =
        stroke
        ? paintedArea(
          rectangles: rectangles, bounds: pathBounds, pageArea: pageArea, fill: false)
        : 0
      let isOverprint = (fill && state.fillOverprint) || (stroke && state.strokeOverprint)
      var amounts: [SeparationPlate: Double] = [:]
      if fill {
        for (plate, amount) in state.fillInk.scaled(by: area) {
          amounts[plate, default: 0] += amount
        }
      }
      if stroke {
        for (plate, amount) in state.strokeInk.scaled(by: strokeArea) {
          amounts[plate, default: 0] += amount
        }
      }
      let coverage = amounts.values.reduce(0, +)
      if coverage > 0 || !rectangles.isEmpty {
        if isOverprint {
          overprintOperations += 1
        } else {
          knockoutOperations += 1
        }
      }
      for (plate, amount) in amounts { plateTotals[plate, default: 0] += amount }
      for plate in amounts.keys { plateCounts[plate, default: 0] += 1 }
      var overlapFraction = 0.0
      if isOverprint, !rectangles.isEmpty {
        for rectangle in rectangles {
          for prior in priorRectangles {
            overlapFraction += intersectionArea(rectangle, prior) / pageArea
          }
        }
        if overlapFraction > 0 {
          findings.append(
            SeparationOverprintFinding(
              pageIndex: pageIndex,
              detail: "Overprint paint overlaps earlier paint; plate ink is additive in this "
                + "declared preview.",
              overprintAreaFraction: min(1, overlapFraction)))
        }
      }
      operations.append(
        SeparationOperation(
          id: operationID, pageIndex: pageIndex, operatorName: operatorName, role: role,
          areaFraction: area, isOverprint: isOverprint,
          plateAmounts: amounts, overlapFraction: min(1, overlapFraction)))
      operationID += 1
      priorRectangles.append(contentsOf: rectangles)
      pathRectangles.removeAll()
      pathBounds = nil
    }

    for instruction in content.instructions {
      let op = instruction.operatorName
      let values = instruction.operands.map(\.value)
      switch op {
      case "q":
        stack.append(state)
      case "Q":
        if let restored = stack.popLast() { state = restored }
      case "cm":
        let matrix = numbers(values)
        if matrix.count == 6 {
          state.ctm = multiply(state.ctm, matrix)
        }
      case "m", "l":
        let operands = numbers(values)
        if operands.count >= 2 {
          let point = transform([operands[0], operands[1]], by: state.ctm)
          pathBounds = expand(pathBounds, with: point)
        }
      case "c":
        let operands = numbers(values)
        if operands.count >= 6 {
          for index in stride(from: 0, to: 6, by: 2) {
            let point = transform([operands[index], operands[index + 1]], by: state.ctm)
            pathBounds = expand(pathBounds, with: point)
          }
        }
      case "v", "y":
        let operands = numbers(values)
        if operands.count >= 4 {
          for index in stride(from: 0, to: 4, by: 2) {
            let point = transform([operands[index], operands[index + 1]], by: state.ctm)
            pathBounds = expand(pathBounds, with: point)
          }
        }
      case "re":
        let operands = numbers(values)
        if operands.count >= 4 {
          let rectangle = transformedRectangle(
            x: operands[0], y: operands[1], width: operands[2], height: operands[3],
            ctm: state.ctm)
          pathRectangles.append(rectangle)
          pathBounds = expand(pathBounds, with: [rectangle[0], rectangle[1]])
          pathBounds = expand(pathBounds, with: [rectangle[2], rectangle[3]])
        }
      case "h":
        break
      case "g":
        state.fillInk = ink(
          colorSpace: nil, components: numbers(values), resources: colorSpaceResources,
          graph: graph)
        state.fillColorSpace = nil
      case "G":
        state.strokeInk = ink(
          colorSpace: nil, components: numbers(values), resources: colorSpaceResources,
          graph: graph)
        state.strokeColorSpace = nil
      case "rg":
        state.fillInk = ink(
          colorSpace: nil, components: numbers(values), family: "DeviceRGB",
          resources: colorSpaceResources, graph: graph)
        state.fillColorSpace = nil
      case "RG":
        state.strokeInk = ink(
          colorSpace: nil, components: numbers(values), family: "DeviceRGB",
          resources: colorSpaceResources, graph: graph)
        state.strokeColorSpace = nil
      case "k":
        state.fillInk = .cmyk(numbers(values))
      case "K":
        state.strokeInk = .cmyk(numbers(values))
      case "cs":
        if case .name(let name)? = values.first {
          let value = colorSpaceValue(named: name, resources: colorSpaceResources, graph: graph)
          state.fillColorSpace = value
        }
      case "CS":
        if case .name(let name)? = values.first {
          let value = colorSpaceValue(named: name, resources: colorSpaceResources, graph: graph)
          state.strokeColorSpace = value
        }
      case "sc", "scn":
        state.fillInk = ink(
          colorSpace: state.fillColorSpace, components: numbers(values),
          resources: colorSpaceResources, graph: graph)
      case "SC", "SCN":
        state.strokeInk = ink(
          colorSpace: state.strokeColorSpace, components: numbers(values),
          resources: colorSpaceResources, graph: graph)
      case "f", "F", "f*":
        paint(role: "fill", operatorName: op)
      case "S", "s":
        paint(role: "stroke", operatorName: op)
      case "B", "B*", "b", "b*":
        paint(role: "fill+stroke", operatorName: op)
      case "W", "W*":
        notes.append("Clipping path (\(op)) is not intersected with painted coverage.")
      case "gs":
        if case .name(let name)? = values.first,
          let external = externalStates[bytesString(name)]
        {
          state.fillOverprint = external.fillOverprint
          state.strokeOverprint = external.strokeOverprint
        }
      case "Do":
        imagePaints += 1
      case "sh":
        shadingPaints += 1
      case "Tj", "TJ", "'", "\"":
        textPaints += 1
      default:
        break
      }
    }
    var plates: [SeparationPlateCoverage] = []
    for (plate, total) in plateTotals where total > 0 {
      plates.append(
        SeparationPlateCoverage(
          plate: plate, coverage: min(1, total), operationCount: plateCounts[plate] ?? 0))
    }
    plates.sort { $0.plate.displayName < $1.plate.displayName }
    if imagePaints > 0 {
      notes.append("Image paint operators are not separated by this preview.")
    }
    if shadingPaints > 0 {
      notes.append("Shading/pattern paint operators are not separated by this preview.")
    }
    if textPaints > 0 {
      notes.append("Text ink is not estimated; only explicit fill/stroke paths are measured.")
    }
    return SeparationPagePreview(
      pageIndex: pageIndex, pageArea: pageArea, plates: plates, operations: operations,
      overprintOperations: overprintOperations, knockoutOperations: knockoutOperations,
      imagePaintOperators: imagePaints, shadingPaintOperators: shadingPaints,
      textPaintOperators: textPaints, ignoredNotes: notes,
      overprintFindings: findings)
  }
}

// MARK: - Geometry, resource and color helpers

extension SeparationOverprintPreview {
  static func bytesString(_ name: PDFName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
  }

  static func numbers(_ values: [PDFValue]) -> [Double] {
    values.compactMap { value in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
  }

  static func resolve(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    guard let value else { return nil }
    if case .reference(let id) = value { return graph.objects[id] }
    return value
  }

  static func pageChain(_ pageID: PDFObjectID, in graph: PDFGraph) -> [[PDFName: PDFValue]] {
    var chain: [[PDFName: PDFValue]] = []
    var current: PDFObjectID? = pageID
    var depth = 0
    while let id = current, depth < 32 {
      guard case .dictionary(let page)? = graph.objects[id] else { break }
      chain.append(page)
      depth += 1
      if case .reference(let parent)? = page[PDFName("Parent")] {
        current = parent
      } else {
        current = nil
      }
    }
    return chain
  }

  static func pageResources(
    pageID: PDFObjectID, graph: PDFGraph
  ) -> [PDFName: PDFValue] {
    for page in pageChain(pageID, in: graph) {
      if let resources = resolve(page[PDFName("Resources")], in: graph) {
        if case .dictionary(let dictionary) = resources { return dictionary }
        if case .reference(let id) = resources,
          case .dictionary(let dictionary)? = graph.objects[id]
        {
          return dictionary
        }
      }
    }
    return [:]
  }

  static func pageGeometry(pageID: PDFObjectID, graph: PDFGraph) -> Double {
    var mediaBox: [Double] = [0, 0, 612, 792]
    for page in pageChain(pageID, in: graph) {
      if let value = resolve(page[PDFName("MediaBox")], in: graph),
        case .array(let array) = value
      {
        let box = numbers(array)
        if box.count >= 4 { mediaBox = box; break }
      }
    }
    return abs(mediaBox[2] - mediaBox[0]) * abs(mediaBox[3] - mediaBox[1])
  }

  static func graphicsStates(
    in resources: [PDFName: PDFValue], graph: PDFGraph
  ) -> [String: (fillOverprint: Bool, strokeOverprint: Bool)] {
    guard case .dictionary(let states)? = resolve(
      resources[PDFName("ExtGState")], in: graph)
    else { return [:] }
    var result: [String: (fillOverprint: Bool, strokeOverprint: Bool)] = [:]
    for (name, value) in states {
      guard case .dictionary(let state)? = resolve(value, in: graph) else { continue }
      var fill = false
      var stroke = false
      if case .boolean(let flag)? = resolve(state[PDFName("op")], in: graph) {
        fill = flag
      }
      if case .boolean(let flag)? = resolve(state[PDFName("OP")], in: graph) {
        stroke = flag
      }
      // OPM only changes how overprint applies when enabled; it is reported
      // via the operation flags and does not change the declared area model.
      result[bytesString(name)] = (fill, stroke)
    }
    return result
  }

  static func colorSpaceDictionary(
    in resources: [PDFName: PDFValue]
  ) -> [String: PDFValue] {
    guard case .dictionary(let spaces)? = resources[PDFName("ColorSpace")] else {
      return [:]
    }
    var result: [String: PDFValue] = [:]
    for (name, value) in spaces { result[bytesString(name)] = value }
    return result
  }

  static func colorSpaceValue(
    named name: PDFName, resources: [String: PDFValue], graph: PDFGraph
  ) -> PDFValue? {
    let key = bytesString(name)
    if let value = resources[key] { return resolve(value, in: graph) }
    let known: Set<String> = [
      "DeviceRGB", "DeviceGray", "DeviceCMYK", "Lab", "Pattern", "ICCBased",
    ]
    if known.contains(key) { return .name(name) }
    return nil
  }

  static func ink(
    colorSpace: PDFValue?, components: [Double],
    family: String? = nil, resources: [String: PDFValue], graph: PDFGraph
  ) -> Ink {
    if let colorSpace {
      switch colorSpace {
      case .name(let name):
        let familyName = bytesString(name)
        return inkFromFamily(familyName, components: components, graph: graph)
      case .array(let array):
        guard case .name(let familyName)? = array.first else { return Ink() }
        switch bytesString(familyName) {
        case "Separation":
          guard array.count > 1, case .name(let spotName) = array[1] else { return Ink() }
          return Ink(spots: [bytesString(spotName): components.first ?? 0])
        case "DeviceN":
          guard array.count > 1, case .array(let names) = array[1] else { return Ink() }
          var spots: [String: Double] = [:]
          for (index, value) in names.enumerated() {
            guard case .name(let spotName) = value, index < components.count else { continue }
            spots[bytesString(spotName)] = components[index]
          }
          return Ink(spots: spots)
        case "ICCBased":
          guard array.count > 1, case .reference(let profileID) = array[1],
            case .stream(let profile)? = graph.objects[profileID]
          else { return Ink() }
          guard case .integer(let count)? = profile.dictionary[PDFName("N")],
            let data = try? PDFFilters.decoded(profile, limits: PDFLimits())
          else { return Ink() }
          return Ink.icc(components, profile: data, count: Int(count))
        case "Lab":
          return Ink.lab(components)
        case "CalRGB", "CalGray":
          return inkFromFamily(bytesString(familyName), components: components, graph: graph)
        default:
          return Ink()
        }
      default:
        return Ink()
      }
    }
    if let family { return inkFromFamily(family, components: components, graph: graph) }
    switch components.count {
    case 1: return .gray(components[0])
    case 3: return .rgb(components)
    case 4: return .cmyk(components)
    default: return Ink()
    }
  }

  static func inkFromFamily(
    _ family: String, components: [Double], graph: PDFGraph
  ) -> Ink {
    switch family {
    case "DeviceGray", "CalGray": return .gray(components.first ?? 0)
    case "DeviceRGB", "CalRGB": return .rgb(components)
    case "DeviceCMYK": return .cmyk(components)
    case "Lab": return .lab(components)
    default: return Ink()
    }
  }

  static func multiply(_ first: [Double], _ second: [Double]) -> [Double] {
    guard first.count == 6, second.count == 6 else { return first }
    let a = first[0] * second[0] + first[1] * second[2]
    let b = first[0] * second[1] + first[1] * second[3]
    let c = first[2] * second[0] + first[3] * second[2]
    let d = first[2] * second[1] + first[3] * second[3]
    let e = first[4] * second[0] + first[5] * second[2] + second[4]
    let f = first[4] * second[1] + first[5] * second[3] + second[5]
    return [a, b, c, d, e, f]
  }

  static func transform(_ point: [Double], by matrix: [Double]) -> [Double] {
    guard point.count >= 2, matrix.count == 6 else { return point }
    return [
      matrix[0] * point[0] + matrix[2] * point[1] + matrix[4],
      matrix[1] * point[0] + matrix[3] * point[1] + matrix[5],
    ]
  }

  static func expand(_ bounds: [Double]?, with point: [Double]) -> [Double] {
    guard point.count >= 2 else { return bounds ?? [] }
    guard let bounds, bounds.count == 4 else { return [point[0], point[1], point[0], point[1]] }
    return [
      min(bounds[0], point[0]), min(bounds[1], point[1]),
      max(bounds[2], point[0]), max(bounds[3], point[1]),
    ]
  }

  static func transformedRectangle(
    x: Double, y: Double, width: Double, height: Double, ctm: [Double]
  ) -> [Double] {
    let corners = [
      transform([x, y], by: ctm), transform([x + width, y], by: ctm),
      transform([x + width, y + height], by: ctm), transform([x, y + height], by: ctm),
    ]
    let xs = corners.map { $0.first ?? 0 }
    let ys = corners.map { $0.count > 1 ? $0[1] : 0 }
    return [xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0]
  }

  static func intersectionArea(_ first: [Double], _ second: [Double]) -> Double {
    guard first.count == 4, second.count == 4 else { return 0 }
    let width = max(0, min(first[2], second[2]) - max(first[0], second[0]))
    let height = max(0, min(first[3], second[3]) - max(first[1], second[1]))
    return width * height
  }

  static func paintedArea(
    rectangles: [[Double]], bounds: [Double]?, pageArea: Double, fill: Bool
  ) -> Double {
    guard pageArea > 0 else { return 0 }
    if !rectangles.isEmpty {
      let area = rectangles.reduce(0) { total, rectangle in
        total + max(0, rectangle[2] - rectangle[0]) * max(0, rectangle[3] - rectangle[1])
      }
      return min(1, (fill ? area : area * 0.02) / pageArea)
    }
    guard let bounds, bounds.count == 4 else { return 0 }
    let area = max(0, bounds[2] - bounds[0]) * max(0, bounds[3] - bounds[1])
    return min(1, (fill ? area * 0.5 : area * 0.02) / pageArea)
  }
}
