import Foundation
import PDFCore

/// PRE-07: hairline checks. This scans page and nested form content, tracks the
/// graphics-state CTM and line width (including ExtGState /LW), and reports
/// strokes whose effective width is below the chosen press threshold. It is a
/// read-only review; it does not thicken or change any content.
public struct HairlineCheckFinding: Sendable, Equatable {
  public let pageIndex: Int
  public let contentPath: String
  public let instructionIndex: Int
  public let operatorName: String
  public let declaredLineWidth: Double
  public let effectiveWidth: Double
  public let isDeviceHairline: Bool
  public let detail: String
}

public struct HairlineCheckReport: Sendable, Equatable {
  public let threshold: Double
  public let checkedPageCount: Int
  public let findings: [HairlineCheckFinding]
  public let warnings: [String]

  public var count: Int { findings.count }
  public var deviceHairlineCount: Int { findings.filter(\.isDeviceHairline).count }

  public func report() -> String {
    var lines = [
      "Hairline review — " + String(findings.count) + " stroke(s) below "
        + String(format: "%.2f", threshold) + "pt effective width on "
        + String(checkedPageCount) + " page(s)"
    ]
    for finding in findings {
      lines.append(
        "  Page " + String(finding.pageIndex + 1) + " " + finding.contentPath
          + ": " + finding.operatorName + " width "
          + String(format: "%.3f", finding.declaredLineWidth) + "pt effective "
          + String(format: "%.3f", finding.effectiveWidth) + "pt"
          + (finding.isDeviceHairline ? " (device hairline)" : ""))
    }
    for warning in warnings { lines.append("  Warning: " + warning) }
    lines.append("Read-only check; no line width is modified by this report.")
    return lines.joined(separator: "\n")
  }
}

public enum HairlineChecker {
  public static let defaultThreshold = 0.25
  static let maximumFormDepth = 4

  public static func check(
    _ graph: PDFGraph, pageIDs: [PDFObjectID],
    threshold: Double = defaultThreshold, limits: PDFLimits = PDFLimits()
  ) throws -> HairlineCheckReport {
    guard threshold.isFinite, threshold > 0, threshold <= 100 else {
      throw PDFError(.malformed, "The hairline threshold is out of bounds")
    }
    var scanner = Scanner(graph: graph, threshold: threshold, limits: limits)
    for (pageIndex, pageID) in pageIDs.enumerated() {
      let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
      let resources = scanner.pageResources(pageID: pageID)
      try scanner.scan(
        bytes: content.bytes, resources: resources, pageIndex: pageIndex,
        path: "page", depth: 0,
        state: GraphicsState())
    }
    return HairlineCheckReport(
      threshold: threshold, checkedPageCount: pageIDs.count,
      findings: scanner.findings, warnings: scanner.warnings)
  }

  struct GraphicsState {
    var lineWidth: Double = 1
    var ctm: [Double] = [1, 0, 0, 1, 0, 0]
    var stack: [(lineWidth: Double, ctm: [Double])] = []
  }

  struct Scanner {
    let graph: PDFGraph
    let threshold: Double
    let limits: PDFLimits
    var findings: [HairlineCheckFinding] = []
    var warnings: [String] = []
    var visitedForms: Set<PDFObjectID> = []

    func pageResources(pageID: PDFObjectID) -> [PDFName: PDFValue] {
      guard case .dictionary(let page)? = graph.objects[pageID] else { return [:] }
      return resolveDictionary(page[PDFName("Resources")]) ?? [:]
    }

    mutating func scan(
      bytes: [UInt8], resources: [PDFName: PDFValue], pageIndex: Int, path: String,
      depth: Int, state: GraphicsState
    ) throws {
      guard depth <= maximumFormDepth else {
        warnings.append("Form nesting exceeds the supported depth at " + path)
        return
      }
      let instructions = try ContentParser.instructions(in: bytes, limits: limits)
      var state = state
      for (instructionIndex, instruction) in instructions.enumerated() {
        switch instruction.operatorName {
        case "q":
          state.stack.append((state.lineWidth, state.ctm))
        case "Q":
          if let previous = state.stack.popLast() {
            state.lineWidth = previous.lineWidth
            state.ctm = previous.ctm
          }
        case "w":
          if let value = number(instruction.operands.first?.value) {
            state.lineWidth = value
          }
        case "cm":
          let values = instruction.operands.compactMap { number($0.value) }
          if values.count == 6 {
            state.ctm = concatenated(values, state.ctm)
          }
        case "gs":
          if let name = nameString(instruction.operands.first?.value),
            let extGStates = resolveDictionary(resources[PDFName("ExtGState")]),
            let stateValue = extGStates[PDFName(name)],
            let extGState = resolveDictionary(stateValue),
            let lineWidth = number(extGState[PDFName("LW")])
          {
            state.lineWidth = lineWidth
          }
        case "S", "s", "B", "b", "B*", "b*":
          let effective = effectiveWidth(lineWidth: state.lineWidth, ctm: state.ctm)
          if state.lineWidth <= 0 || effective < threshold {
            findings.append(
              HairlineCheckFinding(
                pageIndex: pageIndex, contentPath: path,
                instructionIndex: instructionIndex, operatorName: instruction.operatorName,
                declaredLineWidth: state.lineWidth, effectiveWidth: effective,
                isDeviceHairline: state.lineWidth <= 0,
                detail: state.lineWidth <= 0
                  ? "Zero line width is a device hairline and may disappear on press."
                  : "Effective stroke width is below the review threshold."))
          }
        case "Do":
          guard let name = nameString(instruction.operands.first?.value),
            let xObjects = resolveDictionary(resources[PDFName("XObject")]),
            let value = xObjects[PDFName(name)]
          else { continue }
          guard let (stream, formID) = resolvedStream(value),
            stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form"))
          else { continue }
          if let formID {
            guard !visitedForms.contains(formID) else { continue }
            visitedForms.insert(formID)
          }
          let matrix = instructionMatrix(stream.dictionary[PDFName("Matrix")])
          var nested = state
          nested.ctm = concatenated(matrix, state.ctm)
          let formResources = resolveDictionary(stream.dictionary[PDFName("Resources")])
            ?? resources
          try scan(
            bytes: [UInt8](try PDFFilters.decoded(stream, limits: limits)),
            resources: formResources, pageIndex: pageIndex,
            path: path + " > form /" + name, depth: depth + 1, state: nested)
        default:
          continue
        }
      }
    }

    func resolveDictionary(_ value: PDFValue?) -> [PDFName: PDFValue]? {
      guard let value else { return nil }
      switch value {
      case .dictionary(let dictionary): return dictionary
      case .reference(let id):
        guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
        return dictionary
      default: return nil
      }
    }

    func resolvedStream(_ value: PDFValue) -> (PDFStream, PDFObjectID?)? {
      switch value {
      case .stream(let stream): return (stream, nil)
      case .reference(let id):
        guard case .stream(let stream)? = graph.objects[id] else { return nil }
        return (stream, id)
      default: return nil
      }
    }

    func instructionMatrix(_ value: PDFValue?) -> [Double] {
      guard case .array(let values)? = value else {
        return [1, 0, 0, 1, 0, 0]
      }
      let numbers = values.compactMap { number($0) }
      return numbers.count == 6 ? numbers : [1, 0, 0, 1, 0, 0]
    }

    func number(_ value: PDFValue?) -> Double? {
      switch value {
      case .integer(let number)?: return Double(number)
      case .real(let number)?: return number
      default: return nil
      }
    }

    func nameString(_ value: PDFValue?) -> String? {
      guard case .name(let name)? = value else { return nil }
      return String(decoding: name.bytes, as: UTF8.self)
    }

    /// PDF cm concatenates its matrix on top of the current CTM.
    func concatenated(_ matrix: [Double], _ ctm: [Double]) -> [Double] {
      guard matrix.count == 6, ctm.count == 6 else { return ctm }
      return [
        matrix[0] * ctm[0] + matrix[1] * ctm[2],
        matrix[0] * ctm[1] + matrix[1] * ctm[3],
        matrix[2] * ctm[0] + matrix[3] * ctm[2],
        matrix[2] * ctm[1] + matrix[3] * ctm[3],
        matrix[4] * ctm[0] + matrix[5] * ctm[2] + ctm[4],
        matrix[4] * ctm[1] + matrix[5] * ctm[3] + ctm[5],
      ]
    }

    func effectiveWidth(lineWidth: Double, ctm: [Double]) -> Double {
      let scaleX = (ctm[0] * ctm[0] + ctm[1] * ctm[1]).squareRoot()
      let scaleY = (ctm[2] * ctm[2] + ctm[3] * ctm[3]).squareRoot()
      return lineWidth * max(scaleX, scaleY)
    }
  }
}
