import CoreGraphics
import Foundation
import PDFCore

/// PRE-08: advanced print imposition planning. This is an explicit layout
/// profile: it computes page order, paper boxes, clipping and scaling for
/// booklet/poster/N-up/single workflows before any output is drawn. The plan is
/// independently checkable; drawing/export lives in MacServices.
public enum PDFAdvancedPrintLayout: Sendable, Equatable {
  case single
  case nUp(rows: Int, columns: Int)
  case booklet
  case poster(rows: Int, columns: Int, overlap: Double)
}

public enum PDFPrintScaleMode: Sendable, Equatable {
  case fit
  case actual
  case custom(Double)
}

public enum PDFPrintDuplex: String, Sendable, Equatable {
  case simplex
  case longEdge
  case shortEdge
}

public struct PDFAdvancedPrintOptions: Sendable, Equatable {
  public var layout: PDFAdvancedPrintLayout
  public var scale: PDFPrintScaleMode
  /// Common output paper in points [width, height]; nil derives from content.
  public var paperSize: [Double]?
  /// Margin around the output page in points.
  public var margin: Double
  /// Space between placed pages in points.
  public var gutter: Double
  /// Draw annotation appearances (comments) into the printed pages.
  public var includeComments: Bool
  /// Preserve each source page's own paper size for single-page layouts.
  public var mixedPageSizes: Bool
  public var duplex: PDFPrintDuplex

  public init(
    layout: PDFAdvancedPrintLayout = .single, scale: PDFPrintScaleMode = .fit,
    paperSize: [Double]? = nil, margin: Double = 18, gutter: Double = 12,
    includeComments: Bool = false, mixedPageSizes: Bool = false,
    duplex: PDFPrintDuplex = .simplex
  ) {
    self.layout = layout
    self.scale = scale
    self.paperSize = paperSize
    self.margin = margin
    self.gutter = gutter
    self.includeComments = includeComments
    self.mixedPageSizes = mixedPageSizes
    self.duplex = duplex
  }
}

public struct PDFPrintPlacement: Sendable, Equatable {
  /// Zero-based index into the source page list.
  public let sourcePageIndex: Int
  /// Target rectangle in output page points [x, y, width, height].
  public let targetRect: [Double]
  /// Clip rectangle in output page points; nil means the page itself.
  public let clipRect: [Double]?
  public let scale: Double
  /// Source page box used for the placement [x, y, width, height].
  public let sourceBox: [Double]
  /// Optional human-readable label (for example "tile 2,1").
  public let label: String?
}

public struct PDFPrintSide: Sendable, Equatable {
  public let sideIndex: Int
  public let sheetIndex: Int
  public let isBack: Bool
  public let paperSize: [Double]
  public let placements: [PDFPrintPlacement]
  public var isBlank: Bool { placements.isEmpty }
}

public struct PDFPrintSheet: Sendable, Equatable {
  public let sheetIndex: Int
  public let front: PDFPrintSide
  public let back: PDFPrintSide?
}

public struct PDFAdvancedPrintPlan: Sendable, Equatable {
  public let options: PDFAdvancedPrintOptions
  public let sourcePageCount: Int
  public let sheets: [PDFPrintSheet]
  /// Flat print order; this is exactly the order the exporter must emit.
  public let sides: [PDFPrintSide]
  public let warnings: [String]

  public var outputPageCount: Int { sides.count }
  public var placementCount: Int { sides.reduce(0) { $0 + $1.placements.count } }

  public func report() -> String {
    var lines: [String] = []
    lines.append(
      "Advanced print plan — " + String(sourcePageCount) + " source page(s), "
        + String(sides.count) + " output page(s), " + String(sheets.count) + " sheet(s).")
    lines.append("Layout: " + Self.layoutDescription(options.layout)
      + "; scale: " + Self.scaleDescription(options.scale)
      + "; duplex: " + options.duplex.rawValue + ".")
    for side in sides {
      let placed = side.placements.map {
        String($0.sourcePageIndex + 1)
      }.joined(separator: ",")
      lines.append(
        "  Output " + String(side.sideIndex + 1) + " (sheet " + String(side.sheetIndex + 1)
          + (side.isBack ? " back" : " front") + "): ["
          + placed + "] on " + Self.format(side.paperSize))
    }
    if options.includeComments {
      lines.append("Comments: annotation appearances are drawn into the print output.")
    }
    lines.append("Appearance-oriented output; no PDF/X conformance or overprint simulation is claimed.")
    for warning in warnings { lines.append("  Warning: " + warning) }
    return lines.joined(separator: "\n")
  }

  static func layoutDescription(_ layout: PDFAdvancedPrintLayout) -> String {
    switch layout {
    case .single: return "single page"
    case .nUp(let rows, let columns): return "N-up " + String(rows) + "x" + String(columns)
    case .booklet: return "booklet (saddle stitch)"
    case .poster(let rows, let columns, let overlap):
      return "poster " + String(rows) + "x" + String(columns)
        + " overlap " + String(format: "%.1f", overlap) + "pt"
    }
  }

  static func scaleDescription(_ scale: PDFPrintScaleMode) -> String {
    switch scale {
    case .fit: return "fit"
    case .actual: return "actual size"
    case .custom(let factor): return "custom " + String(format: "%.3f", factor)
    }
  }

  static func format(_ rect: [Double]) -> String {
    rect.map { String(format: "%.1f", $0) }.joined(separator: "x")
  }
}

/// PRE-08: audit of the native print surface versus the custom layout engine.
public struct PDFNativePrintAudit: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public let feature: String
    public let nativeSupport: Bool
    public let note: String
  }

  public static let profile =
    "Owned layout/print pipeline: appearance-oriented pages (structure, forms and "
    + "annotation interactivity flatten as disclosed); no PDF/X or overprint simulation claim."

  public static func audit() -> [Item] {
    [
      Item(
        feature: "Page range", nativeSupport: true,
        note: "The system print panel selects pages from the paginated view."),
      Item(
        feature: "Copies / paper / orientation", nativeSupport: true,
        note: "Provided by the system print panel and NSPrintInfo."),
      Item(
        feature: "Uniform scale", nativeSupport: true,
        note: "The existing PDFPrintOptions scale factor is honoured before fitting."),
      Item(
        feature: "Booklet imposition", nativeSupport: false,
        note: "Owned engine: saddle-stitch order with padded blank positions."),
      Item(
        feature: "Poster/tiling", nativeSupport: false,
        note: "Owned engine: deterministic tiles with explicit overlap and clipping."),
      Item(
        feature: "N-up", nativeSupport: false,
        note: "Owned engine: explicit row-major grid, gutter and clipping."),
      Item(
        feature: "Comments/annotations printing", nativeSupport: false,
        note: "Owned option draws annotation appearances; native CGPDFPage printing does not."),
      Item(
        feature: "Mixed page sizes", nativeSupport: false,
        note: "Owned single-page mode preserves per-page paper; other layouts fit a common paper."),
      Item(
        feature: "Duplex ordering", nativeSupport: false,
        note: "Owned plan emits front/back sheet order; the printer's duplex setting must match."),
    ]
  }

  public static func report() -> String {
    var lines = ["Native print coverage audit"]
    for item in audit() {
      lines.append(
        "  " + (item.nativeSupport ? "native" : "custom") + ": " + item.feature
          + " — " + item.note)
    }
    lines.append("Profile: " + profile)
    return lines.joined(separator: "\n")
  }
}

public enum PDFAdvancedPrintPlanner {
  public static let maximumOutputPages = 512
  public static let maximumGrid = 8

  /// Plan output from source page boxes [x, y, width, height] in points.
  public static func plan(
    pageBoxes: [[Double]], options: PDFAdvancedPrintOptions
  ) throws -> PDFAdvancedPrintPlan {
    try validate(pageBoxes: pageBoxes, options: options)
    var warnings: [String] = []
    let sizes = pageBoxes.map { CGSize(width: $0[2], height: $0[3]) }
    let commonSize = sizes.reduce(CGSize.zero) {
      CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
    }
    var rawSides: [PDFPrintSide]
    switch options.layout {
    case .single:
      rawSides = singleSides(pageBoxes: pageBoxes, commonSize: commonSize, options: options,
        warnings: &warnings)
    case .nUp(let rows, let columns):
      rawSides = nUpSides(pageBoxes: pageBoxes, commonSize: commonSize, rows: rows,
        columns: columns, options: options, warnings: &warnings)
    case .booklet:
      rawSides = bookletSides(pageBoxes: pageBoxes, commonSize: commonSize, options: options,
        warnings: &warnings)
    case .poster(let rows, let columns, let overlap):
      rawSides = posterSides(pageBoxes: pageBoxes, rows: rows, columns: columns,
        overlap: overlap, options: options, warnings: &warnings)
    }
    let sheets: [PDFPrintSheet]
    let sides: [PDFPrintSide]
    if case .booklet = options.layout {
      if options.duplex == .simplex {
        warnings.append("Booklet output contains front and back sides; enable duplex when printing.")
      }
      let assembled = assembleSheets(rawSides, duplex: true, options: options)
      sheets = assembled.sheets
      sides = assembled.sides
    } else if options.duplex == .simplex {
      let assembled = assembleSheets(rawSides, duplex: false, options: options)
      sheets = assembled.sheets
      sides = assembled.sides
    } else {
      let assembled = assembleSheets(rawSides, duplex: true, options: options)
      sheets = assembled.sheets
      sides = assembled.sides
    }
    guard sides.count <= maximumOutputPages else {
      throw PDFError(
        .limitExceeded,
        "The print layout needs " + String(sides.count)
          + " output pages; the supported limit is " + String(maximumOutputPages))
    }
    // Report clipping when actual/custom scale exceeds the placement cell.
    var clipped = 0
    for side in sides {
      for placement in side.placements {
        if let clip = placement.clipRect,
          !Self.contains(clip, placement.targetRect)
        {
          clipped += 1
        }
      }
    }
    if clipped > 0 {
      warnings.append(
        " " + String(clipped) + " placement(s) exceed their print cell and are clipped.")
    }
    return PDFAdvancedPrintPlan(
      options: options, sourcePageCount: pageBoxes.count, sheets: sheets, sides: sides,
      warnings: warnings)
  }

  static func validate(pageBoxes: [[Double]], options: PDFAdvancedPrintOptions) throws {
    guard !pageBoxes.isEmpty, pageBoxes.count <= maximumOutputPages else {
      throw PDFError(.malformed, "The print page list is empty or too large")
    }
    for box in pageBoxes {
      guard box.count == 4, box.allSatisfy({ $0.isFinite }),
        box[2] > 0, box[3] > 0
      else {
        throw PDFError(.malformed, "A print page box is malformed")
      }
    }
    guard options.margin.isFinite, options.margin >= 0, options.margin <= 1_000,
      options.gutter.isFinite, options.gutter >= 0, options.gutter <= 1_000
    else {
      throw PDFError(.malformed, "The print margin or gutter is out of bounds")
    }
    if let paper = options.paperSize {
      guard paper.count == 2, paper.allSatisfy({ $0.isFinite }),
        paper[0] > 2 * options.margin, paper[1] > 2 * options.margin
      else {
        throw PDFError(.malformed, "The print paper size is smaller than its margins")
      }
    }
    switch options.scale {
    case .fit, .actual:
      break
    case .custom(let factor):
      guard factor.isFinite, factor >= 0.05, factor <= 20 else {
        throw PDFError(.malformed, "The custom print scale is out of the supported range")
      }
    }
    func grid(_ value: Int) throws {
      guard value >= 1, value <= maximumGrid else {
        throw PDFError(.malformed, "The print grid dimension is out of the supported range")
      }
    }
    switch options.layout {
    case .single, .booklet:
      break
    case .nUp(let rows, let columns):
      try grid(rows)
      try grid(columns)
    case .poster(let rows, let columns, let overlap):
      try grid(rows)
      try grid(columns)
      guard overlap.isFinite, overlap >= 0, overlap <= 1_000 else {
        throw PDFError(.malformed, "The poster overlap is out of bounds")
      }
    }
  }

  // MARK: Layouts

  static func singleSides(
    pageBoxes: [[Double]], commonSize: CGSize, options: PDFAdvancedPrintOptions,
    warnings: inout [String]
  ) -> [PDFPrintSide] {
    var sides: [PDFPrintSide] = []
    for (index, sourceBox) in pageBoxes.enumerated() {
      let paper: CGSize
      if let explicit = options.paperSize {
        paper = CGSize(width: explicit[0], height: explicit[1])
      } else if options.mixedPageSizes {
        paper = CGSize(width: sourceBox[2] + 2 * options.margin,
          height: sourceBox[3] + 2 * options.margin)
      } else {
        paper = CGSize(width: commonSize.width + 2 * options.margin,
          height: commonSize.height + 2 * options.margin)
      }
      let cell = CGRect(
        x: options.margin, y: options.margin,
        width: paper.width - 2 * options.margin, height: paper.height - 2 * options.margin)
      let placement = fittedPlacement(
        sourcePageIndex: index, sourceBox: sourceBox, cell: cell,
        scaleMode: options.scale, label: nil)
      sides.append(
        PDFPrintSide(
          sideIndex: index, sheetIndex: index, isBack: false,
          paperSize: [Double(paper.width), Double(paper.height)],
          placements: [placement]))
    }
    if !options.mixedPageSizes, Set(pageBoxes.map { Self.format($0) }).count > 1 {
      warnings.append("Mixed source page sizes are fitted to the largest common paper.")
    }
    return sides
  }

  static func nUpSides(
    pageBoxes: [[Double]], commonSize: CGSize, rows: Int, columns: Int,
    options: PDFAdvancedPrintOptions, warnings: inout [String]
  ) -> [PDFPrintSide] {
    let paper: CGSize
    if let explicit = options.paperSize {
      paper = CGSize(width: explicit[0], height: explicit[1])
    } else {
      paper = CGSize(
        width: Double(columns) * commonSize.width + Double(columns - 1) * options.gutter
          + 2 * options.margin,
        height: Double(rows) * commonSize.height + Double(rows - 1) * options.gutter
          + 2 * options.margin)
    }
    let cellWidth = (paper.width - 2 * options.margin - Double(columns - 1) * options.gutter)
      / Double(columns)
    let cellHeight = (paper.height - 2 * options.margin - Double(rows - 1) * options.gutter)
      / Double(rows)
    guard cellWidth > 0, cellHeight > 0 else { return [] }
    let perSheet = rows * columns
    let sheetCount = (pageBoxes.count + perSheet - 1) / perSheet
    var sides: [PDFPrintSide] = []
    for sheetIndex in 0..<sheetCount {
      var placements: [PDFPrintPlacement] = []
      for slot in 0..<perSheet {
        let sourceIndex = sheetIndex * perSheet + slot
        guard sourceIndex < pageBoxes.count else { continue }
        let row = slot / columns
        let column = slot % columns
        // Row 0 is the top row; output coordinates have the origin at bottom-left.
        let x = options.margin + Double(column) * (cellWidth + options.gutter)
        let y = paper.height - options.margin - Double(row + 1) * cellHeight
          - Double(row) * options.gutter
        let cell = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        placements.append(
          fittedPlacement(
            sourcePageIndex: sourceIndex, sourceBox: pageBoxes[sourceIndex], cell: cell,
            scaleMode: options.scale, label: nil))
      }
      let sideIndex = sides.count
      sides.append(
        PDFPrintSide(
          sideIndex: sideIndex, sheetIndex: sheetIndex, isBack: false,
          paperSize: [Double(paper.width), Double(paper.height)], placements: placements))
    }
    if !options.mixedPageSizes, Set(pageBoxes.map { Self.format($0) }).count > 1 {
      warnings.append("N-up fits mixed source page sizes into a common paper.")
    }
    return sides
  }

  static func bookletSides(
    pageBoxes: [[Double]], commonSize: CGSize, options: PDFAdvancedPrintOptions,
    warnings: inout [String]
  ) -> [PDFPrintSide] {
    let paper: CGSize
    if let explicit = options.paperSize {
      paper = CGSize(width: explicit[0], height: explicit[1])
    } else {
      paper = CGSize(
        width: 2 * commonSize.width + options.gutter + 2 * options.margin,
        height: commonSize.height + 2 * options.margin)
    }
    let cellWidth = (paper.width - 2 * options.margin - options.gutter) / 2
    let cellHeight = paper.height - 2 * options.margin
    guard cellWidth > 0, cellHeight > 0 else { return [] }
    let padded = Int(ceil(Double(pageBoxes.count) / 4.0)) * 4
    let sheetCount = padded / 4
    var sides: [PDFPrintSide] = []
    for sheetIndex in 0..<sheetCount {
      let frontLeft = padded - 2 * sheetIndex
      let frontRight = 1 + 2 * sheetIndex
      let backLeft = 2 + 2 * sheetIndex
      let backRight = padded - 1 - 2 * sheetIndex
      let front = bookletSide(
        paper: paper, pageBoxes: pageBoxes, cellWidth: cellWidth, cellHeight: cellHeight,
        margin: options.margin, gutter: options.gutter, scaleMode: options.scale,
        sheetIndex: sheetIndex, isBack: false, sideIndex: sides.count,
        leftPage: frontLeft, rightPage: frontRight)
      sides.append(front)
      let back = bookletSide(
        paper: paper, pageBoxes: pageBoxes, cellWidth: cellWidth, cellHeight: cellHeight,
        margin: options.margin, gutter: options.gutter, scaleMode: options.scale,
        sheetIndex: sheetIndex, isBack: true, sideIndex: sides.count,
        leftPage: backLeft, rightPage: backRight)
      sides.append(back)
    }
    if padded > pageBoxes.count {
      warnings.append(
        "Booklet pads " + String(padded - pageBoxes.count)
          + " blank position(s) to complete the last sheet.")
    }
    return sides
  }

  static func bookletSide(
    paper: CGSize, pageBoxes: [[Double]], cellWidth: Double, cellHeight: Double,
    margin: Double, gutter: Double, scaleMode: PDFPrintScaleMode, sheetIndex: Int,
    isBack: Bool, sideIndex: Int, leftPage: Int, rightPage: Int
  ) -> PDFPrintSide {
    var placements: [PDFPrintPlacement] = []
    let leftCell = CGRect(x: margin, y: margin, width: cellWidth, height: cellHeight)
    let rightCell = CGRect(
      x: margin + cellWidth + gutter, y: margin, width: cellWidth, height: cellHeight)
    if leftPage >= 1, leftPage <= pageBoxes.count {
      placements.append(
        fittedPlacement(
          sourcePageIndex: leftPage - 1, sourceBox: pageBoxes[leftPage - 1],
          cell: leftCell, scaleMode: scaleMode, label: nil))
    }
    if rightPage >= 1, rightPage <= pageBoxes.count {
      placements.append(
        fittedPlacement(
          sourcePageIndex: rightPage - 1, sourceBox: pageBoxes[rightPage - 1],
          cell: rightCell, scaleMode: scaleMode, label: nil))
    }
    return PDFPrintSide(
      sideIndex: sideIndex, sheetIndex: sheetIndex, isBack: isBack,
      paperSize: [Double(paper.width), Double(paper.height)], placements: placements)
  }

  static func posterSides(
    pageBoxes: [[Double]], rows: Int, columns: Int, overlap: Double,
    options: PDFAdvancedPrintOptions, warnings: inout [String]
  ) -> [PDFPrintSide] {
    var sides: [PDFPrintSide] = []
    for (pageIndex, sourceBox) in pageBoxes.enumerated() {
      let sourceWidth = sourceBox[2]
      let sourceHeight = sourceBox[3]
      let tileWidth = (sourceWidth + Double(columns - 1) * overlap) / Double(columns)
      let tileHeight = (sourceHeight + Double(rows - 1) * overlap) / Double(rows)
      let stepX = tileWidth - overlap
      let stepY = tileHeight - overlap
      for row in 0..<rows {
        for column in 0..<columns {
          let originX = Double(column) * stepX
          let originY = Double(rows - 1 - row) * stepY
          let scale: Double
          let paper: CGSize
          let cell: CGRect
          if let explicit = options.paperSize {
            paper = CGSize(width: explicit[0], height: explicit[1])
            cell = CGRect(
              x: options.margin, y: options.margin,
              width: paper.width - 2 * options.margin,
              height: paper.height - 2 * options.margin)
            switch options.scale {
            case .fit:
              scale = min(cell.width / tileWidth, cell.height / tileHeight)
            case .actual:
              scale = 1
            case .custom(let factor):
              scale = factor
            }
          } else {
            switch options.scale {
            case .actual, .fit:
              scale = 1
            case .custom(let factor):
              scale = factor
            }
            paper = CGSize(
              width: tileWidth * scale + 2 * options.margin,
              height: tileHeight * scale + 2 * options.margin)
            cell = CGRect(
              x: options.margin, y: options.margin,
              width: tileWidth * scale, height: tileHeight * scale)
          }
          let target = [
            options.margin - originX * scale,
            options.margin - originY * scale,
            sourceWidth * scale,
            sourceHeight * scale,
          ]
          let placement = PDFPrintPlacement(
            sourcePageIndex: pageIndex, targetRect: target,
            clipRect: [
              Double(cell.minX), Double(cell.minY), Double(cell.width), Double(cell.height),
            ],
            scale: scale, sourceBox: sourceBox,
            label: "tile " + String(row + 1) + "," + String(column + 1))
          sides.append(
            PDFPrintSide(
              sideIndex: sides.count, sheetIndex: sides.count, isBack: false,
              paperSize: [Double(paper.width), Double(paper.height)], placements: [placement]))
        }
      }
    }
    if overlap > 0 {
      warnings.append(
        "Poster tiles overlap by " + String(format: "%.1f", overlap)
          + "pt; trim the duplicated edges before assembly.")
    }
    warnings.append("Poster page order is row-major top-left to bottom-right.")
    return sides
  }

  // MARK: Assembly/helpers

  static func assembleSheets(
    _ rawSides: [PDFPrintSide], duplex: Bool, options: PDFAdvancedPrintOptions
  ) -> (sheets: [PDFPrintSheet], sides: [PDFPrintSide]) {
    var sides = rawSides
    var sheets: [PDFPrintSheet] = []
    if duplex {
      if sides.count.isMultiple(of: 2) == false {
        let lastPaper = sides.last?.paperSize ?? [612, 792]
        sides.append(
          PDFPrintSide(
            sideIndex: sides.count, sheetIndex: sides.count / 2, isBack: true,
            paperSize: lastPaper, placements: []))
      }
      var index = 0
      while index + 1 < sides.count {
        var front = sides[index]
        var back = sides[index + 1]
        if case .booklet = options.layout {
          // Keep the planned booklet sides; only the duplex orientation is
          // disclosed by the plan report (the printer flips the sheet).
        }
        front = PDFPrintSide(
          sideIndex: front.sideIndex, sheetIndex: index / 2, isBack: false,
          paperSize: front.paperSize, placements: front.placements)
        back = PDFPrintSide(
          sideIndex: back.sideIndex, sheetIndex: index / 2, isBack: true,
          paperSize: back.paperSize, placements: back.placements)
        sheets.append(PDFPrintSheet(sheetIndex: index / 2, front: front, back: back))
        index += 2
      }
    } else {
      for side in sides {
        sheets.append(
          PDFPrintSheet(
            sheetIndex: side.sideIndex, front: side, back: nil))
      }
    }
    return (sheets, sides)
  }

  static func fittedPlacement(
    sourcePageIndex: Int, sourceBox: [Double], cell: CGRect,
    scaleMode: PDFPrintScaleMode, label: String?
  ) -> PDFPrintPlacement {
    let scale: Double
    switch scaleMode {
    case .fit: scale = min(cell.width / sourceBox[2], cell.height / sourceBox[3])
    case .actual: scale = 1
    case .custom(let factor): scale = factor
    }
    let targetWidth = sourceBox[2] * scale
    let targetHeight = sourceBox[3] * scale
    let targetX = cell.minX + (cell.width - targetWidth) / 2
    let targetY = cell.minY + (cell.height - targetHeight) / 2
    return PDFPrintPlacement(
      sourcePageIndex: sourcePageIndex,
      targetRect: [Double(targetX), Double(targetY), targetWidth, targetHeight],
      clipRect: [Double(cell.minX), Double(cell.minY), Double(cell.width), Double(cell.height)],
      scale: scale, sourceBox: sourceBox, label: label)
  }

  static func contains(_ outer: [Double], _ inner: [Double]) -> Bool {
    guard outer.count == 4, inner.count == 4 else { return false }
    let tolerance = 0.01
    return inner[0] >= outer[0] - tolerance
      && inner[1] >= outer[1] - tolerance
      && inner[0] + inner[2] <= outer[0] + outer[2] + tolerance
      && inner[1] + inner[3] <= outer[1] + outer[3] + tolerance
  }

  static func format(_ box: [Double]) -> String {
    box.map { String(format: "%.3f", $0) }.joined(separator: ",")
  }
}
