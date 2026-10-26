import Foundation
import PDFCore

/// PRE-07: production-mark layout (crop marks, registration marks, color bar and
/// job slug). This file computes geometry and metadata only; MacServices draws
/// the marks. No PDF/X conformance or ink simulation is claimed.
public struct ProductionInk: Sendable, Equatable {
  public let name: String
  public let isProcess: Bool

  public init(name: String, isProcess: Bool = false) {
    self.name = name
    self.isProcess = isProcess
  }
}

public struct ProductionMarksOptions: Sendable, Equatable {
  public var margin: Double
  public var cropMarkLength: Double
  public var markGap: Double
  public var includeCropMarks: Bool
  public var includeRegistrationMarks: Bool
  public var includeColorBar: Bool
  public var includeJobSlug: Bool
  public var jobLabel: String?
  public var inks: [ProductionInk]

  public init(
    margin: Double = 24, cropMarkLength: Double = 12, markGap: Double = 3,
    includeCropMarks: Bool = true, includeRegistrationMarks: Bool = true,
    includeColorBar: Bool = true, includeJobSlug: Bool = true, jobLabel: String? = nil,
    inks: [ProductionInk] = []
  ) {
    self.margin = margin
    self.cropMarkLength = cropMarkLength
    self.markGap = markGap
    self.includeCropMarks = includeCropMarks
    self.includeRegistrationMarks = includeRegistrationMarks
    self.includeColorBar = includeColorBar
    self.includeJobSlug = includeJobSlug
    self.jobLabel = jobLabel
    self.inks = inks
  }
}

public struct ProductionMarksPageInput: Sendable, Equatable {
  public let mediaBox: [Double]
  public let trimBox: [Double]?
  public let bleedBox: [Double]?

  public init(mediaBox: [Double], trimBox: [Double]? = nil, bleedBox: [Double]? = nil) {
    self.mediaBox = mediaBox
    self.trimBox = trimBox
    self.bleedBox = bleedBox
  }
}

public enum ProductionMarkPrimitive: Sendable, Equatable {
  case line(x1: Double, y1: Double, x2: Double, y2: Double, width: Double)
  case rectangle(x: Double, y: Double, width: Double, height: Double)
  case circle(centerX: Double, centerY: Double, radius: Double)
  case text(String, x: Double, y: Double, size: Double)
}

public struct ProductionMarksPage: Sendable, Equatable {
  public let sourcePageIndex: Int
  public let outputBox: [Double]
  public let sourcePlacementRect: [Double]
  public let trimBox: [Double]
  public let bleedBox: [Double]
  public let marks: [ProductionMarkPrimitive]
  public let inkNames: [String]
  public let slugLines: [String]
  public let warnings: [String]
}

public struct ProductionMarksLayout: Sendable, Equatable {
  public let options: ProductionMarksOptions
  public let pages: [ProductionMarksPage]
  public let warnings: [String]

  public func report() -> String {
    var lines = [
      "Production marks — " + String(pages.count) + " page(s), "
        + String(pages.reduce(0) { $0 + $1.marks.count }) + " mark primitive(s)"
    ]
    for page in pages {
      lines.append(
        "  Page " + String(page.sourcePageIndex + 1) + ": output "
          + page.outputBox.map { String(format: "%.1f", $0) }.joined(separator: "x")
          + ", trim " + page.trimBox.map { String(format: "%.1f", $0) }.joined(separator: "x")
          + ", inks: " + (page.inkNames.isEmpty ? "none" : page.inkNames.joined(separator: ", ")))
      for warning in page.warnings { lines.append("    Warning: " + warning) }
    }
    lines.append(
      "Crop marks follow TrimBox (falling back to MediaBox); bleed/trim are not invented. "
        + "Marks are production aids, not a PDF/X or ink-simulation claim.")
    return lines.joined(separator: "\n")
  }
}

public enum ProductionMarksPlanner {
  public static let maximumPages = 256

  public static func plan(
    pageInputs: [ProductionMarksPageInput], options: ProductionMarksOptions
  ) throws -> ProductionMarksLayout {
    guard !pageInputs.isEmpty, pageInputs.count <= maximumPages else {
      throw PDFError(.malformed, "The production-marks page list is empty or too large")
    }
    guard options.margin.isFinite, options.margin >= 12, options.margin <= 288,
      options.cropMarkLength.isFinite, options.cropMarkLength > 0,
      options.cropMarkLength <= 72, options.markGap.isFinite, options.markGap >= 0,
      options.cropMarkLength + options.markGap <= options.margin
    else {
      throw PDFError(.malformed, "The production-marks margin or mark size is out of bounds")
    }
    var layoutWarnings: [String] = []
    var pages: [ProductionMarksPage] = []
    var sawMissingTrim = false
    for (index, input) in pageInputs.enumerated() {
      guard input.mediaBox.count == 4, input.mediaBox[2] > 0, input.mediaBox[3] > 0,
        input.mediaBox.allSatisfy({ $0.isFinite })
      else {
        throw PDFError(.malformed, "A production-marks media box is malformed")
      }
      let trim = validBox(input.trimBox) ?? input.mediaBox
      let bleed = validBox(input.bleedBox) ?? trim
      if validBox(input.trimBox) == nil {
        sawMissingTrim = true
      }
      if validBox(input.bleedBox) == nil && validBox(input.trimBox) != nil {
        // No invented bleed: record only that the bleed box is the trim box.
      }
      let outputWidth = input.mediaBox[2] + 2 * options.margin
      let outputHeight = input.mediaBox[3] + 2 * options.margin
      // Page user space -> output page space.
      func x(_ value: Double) -> Double { options.margin + value - input.mediaBox[0] }
      func y(_ value: Double) -> Double { options.margin + value - input.mediaBox[1] }
      var marks: [ProductionMarkPrimitive] = []
      var pageWarnings: [String] = []
      if options.includeCropMarks {
        let left = x(trim[0])
        let right = x(trim[0] + trim[2])
        let bottom = y(trim[1])
        let top = y(trim[1] + trim[3])
        let gap = options.markGap
        let length = options.cropMarkLength
        // Horizontal marks extend outward from each trim corner.
        marks.append(.line(x1: left - gap - length, y1: bottom, x2: left - gap, y2: bottom, width: 0.5))
        marks.append(.line(x1: right + gap, y1: bottom, x2: right + gap + length, y2: bottom, width: 0.5))
        marks.append(.line(x1: left - gap - length, y1: top, x2: left - gap, y2: top, width: 0.5))
        marks.append(.line(x1: right + gap, y1: top, x2: right + gap + length, y2: top, width: 0.5))
        // Vertical marks extend outward from each trim corner.
        marks.append(.line(x1: left, y1: bottom - gap - length, x2: left, y2: bottom - gap, width: 0.5))
        marks.append(.line(x1: right, y1: bottom - gap - length, x2: right, y2: bottom - gap, width: 0.5))
        marks.append(.line(x1: left, y1: top + gap, x2: left, y2: top + gap + length, width: 0.5))
        marks.append(.line(x1: right, y1: top + gap, x2: right, y2: top + gap + length, width: 0.5))
      }
      if options.includeRegistrationMarks {
        let midX = (x(trim[0]) + x(trim[0] + trim[2])) / 2
        let midY = (y(trim[1]) + y(trim[1] + trim[3])) / 2
        let radius = 3.0
        for center in [
          (x: midX, y: y(trim[1]) - options.markGap - 4),
          (x: midX, y: y(trim[1] + trim[3]) + options.markGap + 4),
          (x: x(trim[0]) - options.markGap - 4, y: midY),
          (x: x(trim[0] + trim[2]) + options.markGap + 4, y: midY),
        ] {
          marks.append(.circle(centerX: center.x, centerY: center.y, radius: radius))
          marks.append(
            .line(x1: center.x - radius, y1: center.y, x2: center.x + radius, y2: center.y,
              width: 0.4))
          marks.append(
            .line(x1: center.x, y1: center.y - radius, x2: center.x, y2: center.y + radius,
              width: 0.4))
        }
      }
      let inkNames = options.inks.map(\.name)
      if options.includeColorBar {
        if options.margin >= 20, !options.inks.isEmpty {
          let swatchWidth = max(12.0, (outputWidth - 2 * options.margin) / Double(options.inks.count))
          let swatchHeight = min(options.margin * 0.5, 12.0)
          for (inkIndex, ink) in options.inks.enumerated() {
            let rect = ProductionMarkPrimitive.rectangle(
              x: options.margin + Double(inkIndex) * swatchWidth,
              y: options.margin * 0.25, width: swatchWidth - 1, height: swatchHeight)
            marks.append(rect)
            marks.append(
              .text(
                ink.name, x: options.margin + Double(inkIndex) * swatchWidth,
                y: options.margin * 0.25 + swatchHeight + 1, size: 5.5))
          }
        } else if options.inks.isEmpty {
          pageWarnings.append("No inks were supplied; the production color bar is omitted.")
        } else {
          pageWarnings.append("The margin is too small for a production color bar.")
        }
      }
      var slugLines: [String] = []
      if options.includeJobSlug {
        slugLines.append(options.jobLabel ?? "sPDF production proof")
        slugLines.append("Page " + String(index + 1) + " of " + String(pageInputs.count))
        slugLines.append(
          "Trim " + format(trim) + " · Bleed " + format(bleed)
            + (validBox(input.trimBox) == nil ? " · TrimBox absent (MediaBox used)" : ""))
        slugLines.append(
          "Inks: " + (inkNames.isEmpty ? "none supplied" : inkNames.joined(separator: ", ")))
        slugLines.append("Appearance marks; no PDF/X conformance or ink simulation claim.")
        var slugY = outputHeight - options.margin * 0.25 - 6
        for line in slugLines {
          marks.append(.text(line, x: options.margin, y: slugY, size: 5.5))
          slugY -= 7
        }
      }
      pages.append(
        ProductionMarksPage(
          sourcePageIndex: index,
          outputBox: [0, 0, outputWidth, outputHeight],
          sourcePlacementRect: [
            options.margin - input.mediaBox[0], options.margin - input.mediaBox[1],
            input.mediaBox[2], input.mediaBox[3],
          ],
          trimBox: trim, bleedBox: bleed, marks: marks, inkNames: inkNames,
          slugLines: slugLines, warnings: pageWarnings))
    }
    if sawMissingTrim {
      layoutWarnings.append(
        "At least one page has no TrimBox; crop marks follow the MediaBox and this is disclosed.")
    }
    if options.inks.isEmpty {
      layoutWarnings.append("No production inks were supplied; spot/process bars are omitted.")
    }
    return ProductionMarksLayout(options: options, pages: pages, warnings: layoutWarnings)
  }

  static func validBox(_ box: [Double]?) -> [Double]? {
    guard let box, box.count == 4, box.allSatisfy({ $0.isFinite }), box[2] > 0, box[3] > 0
    else { return nil }
    return box
  }

  static func format(_ box: [Double]) -> String {
    box.map { String(format: "%.1f", $0) }.joined(separator: "x")
  }
}
