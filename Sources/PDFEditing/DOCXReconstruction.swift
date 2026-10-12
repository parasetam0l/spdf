import Foundation
import PDFCore

/// P35-008–P35-013: reconstruction of a PDF's pages into DOCX blocks. Mapping
/// is read-only (the source graph is never modified) and records the
/// limitations of what was reconstructed.
public struct DOCXRunInput: Sendable, Equatable {
  public let text: String
  public let bold: Bool
  public let italic: Bool
  /// RGB hex (for example `FF0000`) when the run is not black.
  public let colorHex: String?
  /// Font size in points when it differs from the document default.
  public let sizePoints: Double?
  /// P35-017: an external hyperlink URI (safe schemes only).
  public let hyperlinkURI: String?
  /// P35-017: an internal anchor (for example `page-2`).
  public let anchor: String?
  /// P35-019: the resolved font family to request (substituted when missing).
  public let fontFamily: String?
  /// P35-018: a simple field instruction such as `PAGE`.
  public let field: String?
  /// P35-020: the run's script direction is right-to-left.
  public let rtl: Bool
  /// P35-020: the document language from the catalog, when present.
  public let language: String?

  public init(
    text: String, bold: Bool = false, italic: Bool = false, colorHex: String? = nil,
    sizePoints: Double? = nil, hyperlinkURI: String? = nil, anchor: String? = nil,
    fontFamily: String? = nil, field: String? = nil, rtl: Bool = false, language: String? = nil
  ) {
    self.text = text
    self.bold = bold
    self.italic = italic
    self.colorHex = colorHex
    self.sizePoints = sizePoints
    self.hyperlinkURI = hyperlinkURI
    self.anchor = anchor
    self.fontFamily = fontFamily
    self.field = field
    self.rtl = rtl
    self.language = language
  }
}

/// P35-015: one image to place, resolved to bytes at packaging time.
public struct DOCXImageRequest: Sendable, Equatable {
  public let pageIndex: Int
  public let name: String
  /// Placement bounds in page points [x0, y0, x1, y1].
  public let bounds: [Double]
  /// P35-021: true when the request is an uncertain region that exports as a
  /// rendered appearance image rather than an existing image placement.
  public let isAppearance: Bool
  /// P35-032: how the image interacts with surrounding text.
  public let wrap: DOCXImageWrap

  public init(
    pageIndex: Int, name: String, bounds: [Double], isAppearance: Bool = false,
    wrap: DOCXImageWrap = .inline
  ) {
    self.pageIndex = pageIndex
    self.name = name
    self.bounds = bounds
    self.isAppearance = isAppearance
    self.wrap = wrap
  }
}

/// P35-032: floating placement mapping. Text-wrapping modes are inferred from
/// overlap and draw order; true word-processor wrap geometry is not known.
public enum DOCXImageWrap: String, Sendable, Equatable {
  case inline
  case squareBehind
  case squareInFront
}

/// P35-018: repeated header/footer content.
public struct DOCXHeaderFooter: Sendable, Equatable {
  public let header: [DOCXRunInput]?
  public let footer: [DOCXRunInput]?

  public init(header: [DOCXRunInput]? = nil, footer: [DOCXRunInput]? = nil) {
    self.header = header
    self.footer = footer
  }
}

/// P35-031: a merged cell's span inside a reconstructed table.
public struct DOCXTableSpan: Sendable, Equatable {
  public let row: Int
  public let column: Int
  public let rowSpan: Int
  public let columnSpan: Int

  public init(row: Int, column: Int, rowSpan: Int, columnSpan: Int) {
    self.row = row
    self.column = column
    self.rowSpan = rowSpan
    self.columnSpan = columnSpan
  }
}

public struct DOCXBlock: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case paragraph
    case heading(level: Int)
    case listItem(level: Int, ordered: Bool)
    /// A deliberate page break between PDF pages.
    case pageBreak
    /// P35-015: an inline image.
    case image(DOCXImageRequest)
    /// P35-016: a simple table with editable cell text.
    case table(rows: [[[DOCXRunInput]]])
    /// P35-014: a section boundary carrying the page's column count.
    case sectionBreak(columns: Int)
  }

  public let kind: Kind
  public let runs: [DOCXRunInput]
  public let alignment: TextParagraphCandidate.Alignment
  public let firstLineIndent: Double
  public let lineSpacing: Double
  /// P35-017: a bookmark placed around this block (for example `page-2`).
  public let bookmark: String?
  /// P35-020: the paragraph's dominant script direction is right-to-left.
  public let rtl: Bool
  /// P35-031: merged-cell spans for a table block (empty otherwise).
  public let spans: [DOCXTableSpan]
  /// P35-022: the source analysis confidence (1.0 for structural elements).
  public let confidence: Double

  public init(
    kind: Kind, runs: [DOCXRunInput],
    alignment: TextParagraphCandidate.Alignment = .left, firstLineIndent: Double = 0,
    lineSpacing: Double = 0, bookmark: String? = nil, rtl: Bool = false,
    confidence: Double = 1, spans: [DOCXTableSpan] = []
  ) {
    self.kind = kind
    self.runs = runs
    self.alignment = alignment
    self.firstLineIndent = firstLineIndent
    self.lineSpacing = lineSpacing
    self.bookmark = bookmark
    self.rtl = rtl
    self.confidence = confidence
    self.spans = spans
  }

  public var text: String { runs.map(\.text).joined() }
}

public struct DOCXReconstruction: Sendable, Equatable {
  public let blocks: [DOCXBlock]
  public let pageWidth: Double
  public let pageHeight: Double
  public let landscape: Bool
  /// Human-readable notes about what the reconstruction could not represent.
  public let limitations: [String]
  /// P35-018: repeated header/footer content (already excluded from blocks).
  public let headerFooter: DOCXHeaderFooter
  /// P35-014: the final section's column count.
  public let columns: Int

  public init(
    blocks: [DOCXBlock], pageWidth: Double, pageHeight: Double, landscape: Bool,
    limitations: [String], headerFooter: DOCXHeaderFooter = DOCXHeaderFooter(),
    columns: Int = 1
  ) {
    self.columns = columns
    self.blocks = blocks
    self.pageWidth = pageWidth
    self.pageHeight = pageHeight
    self.landscape = landscape
    self.limitations = limitations
    self.headerFooter = headerFooter
  }
}

public enum DOCXReconstructionBuilder {
  public struct Limits: Sendable {
    public var maxPages: Int
    public var maxBlocks: Int

    public init(maxPages: Int = 512, maxBlocks: Int = 20_000) {
      self.maxPages = maxPages
      self.maxBlocks = maxBlocks
    }
  }

  struct PageAnalysis {
    let pageID: PDFObjectID
    let pageIndex: Int
    let pageWidth: Double
    let pageHeight: Double
    let layout: PageTextLayout
    let candidates: [TextParagraphCandidate]
    let perLine: [TextParagraphCandidate]
    let tableGrid: TableGrid
    let links: [PDFLinkTarget]
    let images: [PDFImageResource]
    let textByRun: [Int: String]
    let runBounds: [Int: [Double]]
    let bodySize: Double
  }

  /// P35-008–P35-019: map the pages into blocks, runs, tables, images,
  /// hyperlinks, headers/footers, geometry, and deliberate page breaks.
  public static func reconstruct(
    pageIDs: [PDFObjectID], in graph: PDFGraph, limits: Limits = Limits(),
    mode: DOCXExportMode = .editable
  ) throws -> DOCXReconstruction {
    var pages: [PageAnalysis] = []
    let allLinks = PDFLinkInventory.links(in: graph, pageIDs: Array(pageIDs))
    let rolesByPage = ParagraphReconstruction.structureRolesByPage(
      in: graph, pageIDs: Array(pageIDs))
    var geometry: (width: Double, height: Double)?
    var sawDifferentGeometry = false
    let pageList = Array(pageIDs.prefix(limits.maxPages))
    for (pageIndex, pageID) in pageList.enumerated() {
      try Task.checkCancellation()
      if let box = pageBox(of: pageID, in: graph) {
        let width = box[2] - box[0]
        let height = box[3] - box[1]
        if let geometry {
          if abs(geometry.width - width) > 1 || abs(geometry.height - height) > 1 {
            sawDifferentGeometry = true
          }
        } else {
          geometry = (width, height)
        }
      }
      let box = pageBox(of: pageID, in: graph)
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      let candidates = try ParagraphReconstruction.candidates(
        pageID: pageID, in: graph, roles: rolesByPage[pageID] ?? [:])
      let perLine = ParagraphListReconstruction.itemCandidates(from: candidates)
      pages.append(
        PageAnalysis(
          pageID: pageID, pageIndex: pageIndex,
          pageWidth: box.map { $0[2] - $0[0] } ?? 612,
          pageHeight: box.map { $0[3] - $0[1] } ?? 792, layout: layout, candidates: candidates,
          perLine: perLine,
          tableGrid: TableCellReconstruction.grid(
            from: candidates.filter {
              ParagraphListReconstruction.marker(in: $0.text) == nil
            }),
          links: allLinks.filter { $0.pageIndex == pageIndex },
          images: try PDFImageInventory.images(in: graph, pageIDs: [pageID]),
          textByRun: textByRun(of: layout), runBounds: runBounds(of: layout),
          bodySize: ParagraphReconstruction.bodyFontSize(of: layout)))
    }

    // P35-018: repeated band text becomes header/footer content.
    let bandResult = detectHeadersFooters(pages: pages)
    var headerFooter = DOCXHeaderFooter(
      header: bandResult.header, footer: bandResult.footer)
    var limitations: [String] = []
    // P35-020: the catalog language applies to every run when present.
    let language = catalogLanguage(in: graph)
    // P35-014: per-page column counts; uniform documents keep page breaks and
    // one final section, mixed documents get a section boundary per page.
    let columnCounts = pages.map { columnCount(of: $0) }
    let uniformColumns = Set(columnCounts).count <= 1
    let splitByPage = pages.map { columnSplits(of: $0) }

    var blocks: [DOCXBlock] = []
    var substitutedFonts = false
    var appearanceCount = 0
    for (pageOffset, page) in pages.enumerated() {
      try Task.checkCancellation()
      if pageOffset > 0 {
        if uniformColumns {
          blocks.append(DOCXBlock(kind: .pageBreak, runs: []))
        } else {
          blocks.append(
            DOCXBlock(kind: .sectionBreak(columns: columnCounts[pageOffset - 1]), runs: []))
        }
      }
      let skippedRuns = bandResult.excludedRunIndices[page.pageIndex] ?? []
      var tableRuns: Set<Int> = []
      var tableBounds: [Double]?
      var entries: [(column: Int, top: Double, x: Double, block: DOCXBlock)] = []
      let splits = splitByPage[pageOffset]
      func columnIndex(for bounds: [Double]) -> Int {
        // A block belongs to the column its left edge starts in (a wide
        // heading or image stays in the leftmost column it touches).
        splits.filter { bounds[0] >= $0 }.count
      }

      // P35-031: ruled or tagged tables (with merged cells) come from the
      // extraction layer; geometry grids are handled below.
      if !(page.tableGrid.cells.count >= 2 && page.tableGrid.columnCount >= 2),
        let extracted = (try? TableExtraction.tables(
          pageIDs: [page.pageID], in: graph,
          profile: TableDetectionProfile(mode: .automatic)))?.first
      {
        var rows: [[[DOCXRunInput]]] = []
        for row in 0..<extracted.rowCount {
          var cells: [[DOCXRunInput]] = []
          for column in 0..<extracted.columnCount {
            if let cell = extracted.cell(row: row, column: column) {
              cells.append([DOCXRunInput(text: cell.text)])
            } else {
              cells.append([])
            }
          }
          rows.append(cells)
        }
        let spans = extracted.cells.compactMap { cell -> DOCXTableSpan? in
          guard cell.rowSpan > 1 || cell.columnSpan > 1 else { return nil }
          return DOCXTableSpan(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
            columnSpan: cell.columnSpan)
        }
        entries.append(
          (columnIndex(for: extracted.bounds), extracted.bounds[3], extracted.bounds[0],
            DOCXBlock(
              kind: .table(rows: rows), runs: [], confidence: extracted.confidence,
              spans: spans)))
        tableBounds = extracted.bounds
      }

      // P35-016: a detected grid with two or more columns becomes one table
      // block; a single column stays ordinary text (a narrow list or note).
      if page.tableGrid.cells.count >= 2, page.tableGrid.columnCount >= 2 {
        var rows: [[[DOCXRunInput]]] = []
        for row in 0..<page.tableGrid.rowCount {
          var cells: [[DOCXRunInput]] = []
          for column in 0..<page.tableGrid.columnCount {
            if let cell = page.tableGrid.cell(row: row, column: column) {
              tableRuns.formUnion(cell.runIndices)
              let runs = runInputs(
                for: cell, textByRun: page.textByRun, links: page.links,
                runBounds: page.runBounds, pageIndex: page.pageIndex, language: language)
              cells.append(runs)
            } else {
              cells.append([DOCXRunInput(text: "")])
            }
          }
          rows.append(cells)
        }
        let top = page.tableGrid.cells.map { $0.bounds[3] }.max() ?? 0
        let left = page.tableGrid.cells.map { $0.bounds[0] }.min() ?? 0
        let bounds = unionBounds(page.tableGrid.cells.map(\.bounds))
        let tableConfidence = page.tableGrid.cells.map(\.confidence).min() ?? 1
        // P35-031: infer merged-cell spans from the grid geometry (how many
        // row/column centers a cell's bounds cover).
        let columnCenters = TableExtraction.centers(
          count: page.tableGrid.columnCount, indices: page.tableGrid.columnIndices,
          bounds: page.tableGrid.cells.map { ($0.bounds[0], $0.bounds[2]) })
        let rowCenters = TableExtraction.centers(
          count: page.tableGrid.rowCount, indices: page.tableGrid.rowIndices,
          bounds: page.tableGrid.cells.map { ($0.bounds[1], $0.bounds[3]) })
        var spans: [DOCXTableSpan] = []
        for (offset, cell) in page.tableGrid.cells.enumerated() {
          let row = page.tableGrid.rowIndices[offset]
          let column = page.tableGrid.columnIndices[offset]
          let columnSpan = max(
            1, min(page.tableGrid.columnCount - column, columnCenters.filter {
              $0 >= cell.bounds[0] - 1 && $0 <= cell.bounds[2] + 1
            }.count))
          let rowSpan = max(
            1, min(page.tableGrid.rowCount - row, rowCenters.filter {
              $0 >= cell.bounds[1] - 1 && $0 <= cell.bounds[3] + 1
            }.count))
          if rowSpan > 1 || columnSpan > 1 {
            spans.append(
              DOCXTableSpan(row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan))
          }
        }
        entries.append(
          (columnIndex(for: bounds), top, left,
            DOCXBlock(
              kind: .table(rows: rows), runs: [], confidence: tableConfidence, spans: spans)))
      }

      let lists = ParagraphListReconstruction.lists(from: page.candidates)
      var listByRun: [Int: (level: Int, ordered: Bool, text: String)] = [:]
      for list in lists {
        for item in list.items {
          let info = (level: 0, ordered: list.style.kind == .ordered, text: item.text)
          for run in item.candidate.runIndices { listByRun[run] = info }
        }
      }

      for candidate in page.perLine {
        guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          continue
        }
        if candidate.runIndices.contains(where: tableRuns.contains) { continue }
        if candidate.runIndices.contains(where: skippedRuns.contains) { continue }
        if let tableBounds {
          let center = [
            (candidate.bounds[0] + candidate.bounds[2]) / 2,
            (candidate.bounds[1] + candidate.bounds[3]) / 2,
          ]
          if center[0] >= tableBounds[0] - 1 && center[0] <= tableBounds[2] + 1,
            center[1] >= tableBounds[1] - 1 && center[1] <= tableBounds[3] + 1
          {
            continue
          }
        }
        // P35-021: in appearance mode, uncertain regions export as a labeled
        // rendered image instead of guessed text.
        if mode == .appearance, candidate.confidence < appearanceConfidenceThreshold {
          let snippet = candidate.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
          let request = DOCXImageRequest(
            pageIndex: page.pageIndex, name: "appearance", bounds: candidate.bounds,
            isAppearance: true)
          entries.append(
            (columnIndex(for: candidate.bounds), candidate.bounds[3], candidate.bounds[0],
              DOCXBlock(kind: .image(request), runs: [], confidence: candidate.confidence)))
          let label = "Appearance: " + String(snippet.prefix(80))
          entries.append(
            (columnIndex(for: candidate.bounds), candidate.bounds[3],
              candidate.bounds[0] + 0.01,
              DOCXBlock(
                kind: .paragraph,
                runs: [DOCXRunInput(text: label, italic: true, language: language)],
                alignment: candidate.alignment, rtl: isRTLMajority(snippet),
                confidence: candidate.confidence)))
          appearanceCount += 1
          continue
        }
        let runs = runInputs(
          for: candidate, textByRun: page.textByRun, links: page.links,
          runBounds: page.runBounds, pageIndex: page.pageIndex, language: language)
        if runs.contains(where: { $0.fontFamily != nil }) { substitutedFonts = true }
        let block: DOCXBlock
        if let info = candidate.runIndices.compactMap({ listByRun[$0] }).first {
          block = DOCXBlock(
            kind: .listItem(level: info.level, ordered: info.ordered),
            runs: [
              DOCXRunInput(
                text: info.text, bold: runs.first?.bold ?? false,
                rtl: containsRTL(info.text), language: language)
            ],
            alignment: candidate.alignment, rtl: isRTLMajority(candidate.text),
            confidence: candidate.confidence)
        } else {
          let kind: DOCXBlock.Kind
          if let role = candidate.structureRole, role.hasPrefix("H"), role != "H",
            let level = Int(role.dropFirst())
          {
            kind = .heading(level: level)
          } else if candidate.kind == .heading {
            kind = .heading(level: headingLevel(for: candidate, bodySize: page.bodySize))
          } else {
            kind = .paragraph
          }
          block = DOCXBlock(
            kind: kind, runs: runs, alignment: candidate.alignment,
            firstLineIndent: candidate.firstLineIndent, lineSpacing: candidate.lineSpacing,
            rtl: isRTLMajority(candidate.text), confidence: candidate.confidence)
        }
        entries.append(
          (columnIndex(for: candidate.bounds), candidate.bounds[3], candidate.bounds[0], block))
      }

      // P35-015/P35-032: images interleave with the text by their top edge;
      // images overlapping text become anchored drawings, with draw order
      // deciding whether they sit behind or in front of the text.
      let trace = try? ContentInterpreter.trace(pageID: page.pageID, in: graph)
      for image in page.images {
        guard image.bounds.count == 4 else { continue }
        var wrap: DOCXImageWrap = .inline
        if let trace {
          let imageDrawIndex = trace.draws.first {
            $0.kind == .image && $0.resourceName == image.name
          }?.instructionIndex
          let overlappingText = trace.draws.filter { draw in
            draw.kind == .text && overlaps(draw.bounds, image.bounds)
          }
          if let imageDrawIndex, let firstText = overlappingText.first {
            wrap = imageDrawIndex < firstText.instructionIndex ? .squareBehind : .squareInFront
          } else if !overlappingText.isEmpty {
            wrap = .squareInFront
          }
        }
        let request = DOCXImageRequest(
          pageIndex: page.pageIndex, name: image.name, bounds: image.bounds, wrap: wrap)
        entries.append(
          (columnIndex(for: image.bounds), image.bounds[3], image.bounds[0],
            DOCXBlock(kind: .image(request), runs: [])))
      }

      // P35-014: two-column pages read column by column (left, then right).
      entries.sort { left, right in
        if left.column != right.column { return left.column < right.column }
        return left.top == right.top ? left.x < right.x : left.top > right.top
      }
      // P35-017: the first block of each page carries its bookmark.
      for (entryIndex, entry) in entries.enumerated() {
        var block = entry.block
        if entryIndex == 0 {
          block = DOCXBlock(
            kind: block.kind, runs: block.runs, alignment: block.alignment,
            firstLineIndent: block.firstLineIndent, lineSpacing: block.lineSpacing,
            bookmark: "page-\(page.pageIndex + 1)", rtl: block.rtl,
            confidence: block.confidence, spans: block.spans)
        }
        blocks.append(block)
        if blocks.count >= limits.maxBlocks {
          throw PDFError(.limitExceeded, "The reconstruction exceeds the block limit")
        }
      }
    }

    let resolved = geometry ?? (612, 792)
    if sawDifferentGeometry {
      limitations.append(
        "Pages with different sizes or orientations map to the first page's section.")
    }
    if pages.contains(where: { $0.tableGrid.cells.count >= 2 && $0.tableGrid.columnCount >= 2 }) {
      limitations.append(
        "Detected table grids map as simple tables; merged cells and spans are not reconstructed.")
    }
    if pages.contains(where: { !$0.images.isEmpty }) {
      limitations.append(
        "Images are placed inline in reading order; wrapping and layering are not reconstructed.")
    }
    if substitutedFonts {
      limitations.append(
        "Fonts without a standard family map to a documented substitution.")
    }
    if appearanceCount > 0 {
      limitations.append(
        "\(appearanceCount) uncertain region\(appearanceCount == 1 ? "" : "s") exported as labeled appearance images.")
    }
    if columnCounts.contains(where: { $0 > 1 }) {
      limitations.append(
        "Detected columns map to Word sections with that column count; exact column breaks and balancing are not reconstructed.")
    }
    if !uniformColumns {
      limitations.append(
        "Column counts differ between pages; each page maps to its own section.")
    }
    limitations.append(
      "Bold and italic come from font names; underline, strikethrough, and tracking are not reconstructed.")
    if headerFooter.header == nil, headerFooter.footer == nil {
      // Nothing repeated: no header/footer parts are emitted.
    }
    return DOCXReconstruction(
      blocks: blocks, pageWidth: resolved.width, pageHeight: resolved.height,
      landscape: resolved.width > resolved.height, limitations: limitations,
      headerFooter: headerFooter, columns: columnCounts.last ?? 1)
  }

  // MARK: - Helpers

  /// P35-021: candidates below this confidence export as appearance images in
  /// appearance mode (the same gate the paragraph profile uses).
  public static let appearanceConfidenceThreshold = 0.6

  struct BandDetection {
    let header: [DOCXRunInput]?
    let footer: [DOCXRunInput]?
    /// Page index -> excluded run indices (run indices are per page).
    let excludedRunIndices: [Int: Set<Int>]
  }

  /// P35-018: text that repeats in the top or bottom band on two or more pages
  /// becomes header/footer content; a single number maps to a PAGE field.
  static func detectHeadersFooters(pages: [PageAnalysis]) -> BandDetection {
    struct Key: Hashable {
      let band: String
      let x: Int
      let text: String
    }
    var occurrences: [Key: [(pageIndex: Int, candidate: TextParagraphCandidate)]] = [:]
    for page in pages {
      let height = page.pageHeight
      let topBand = height * 0.92
      let bottomBand = height * 0.08
      for candidate in page.perLine {
        let centerY = (candidate.bounds[1] + candidate.bounds[3]) / 2
        let band: String
        if centerY > topBand {
          band = "top"
        } else if centerY < bottomBand {
          band = "bottom"
        } else {
          continue
        }
        let key = Key(
          band: band, x: Int((candidate.bounds[0] / 4).rounded()),
          text: normalizedBandText(candidate.text))
        occurrences[key, default: []].append((page.pageIndex, candidate))
      }
    }
    let repeated = occurrences.filter { $0.value.count >= 2 }
    guard !repeated.isEmpty else {
      return BandDetection(header: nil, footer: nil, excludedRunIndices: [:])
    }
    func groups(_ band: String) -> [(key: Key, value: [(pageIndex: Int, candidate: TextParagraphCandidate)])] {
      repeated.filter { $0.key.band == band }.sorted { left, right in
        left.value.count == right.value.count
          ? left.key.text < right.key.text : left.value.count > right.value.count
      }
    }
    var excluded: [Int: Set<Int>] = [:]
    func runs(
      for occurrence: (pageIndex: Int, candidate: TextParagraphCandidate),
      pages: [PageAnalysis]
    ) -> [DOCXRunInput] {
      for page in pages where page.pageIndex == occurrence.pageIndex {
        var runs = runInputs(
          for: occurrence.candidate, textByRun: page.textByRun, links: [], runBounds: [:],
          pageIndex: page.pageIndex)
        // A single number becomes a PAGE field.
        if let base = runs.first {
          runs = pageNumberRuns(text: occurrence.candidate.text, base: base)
        }
        return runs
      }
      return []
    }
    var header: [DOCXRunInput]?
    var footer: [DOCXRunInput]?
    if let top = groups("top").first {
      header = runs(for: top.value[0], pages: pages)
      for occurrence in top.value {
        excluded[occurrence.pageIndex, default: []].formUnion(occurrence.candidate.runIndices)
      }
    }
    if let bottom = groups("bottom").first {
      footer = runs(for: bottom.value[0], pages: pages)
      for occurrence in bottom.value {
        excluded[occurrence.pageIndex, default: []].formUnion(occurrence.candidate.runIndices)
      }
    }
    return BandDetection(header: header, footer: footer, excludedRunIndices: excluded)
  }

  /// P35-014/P35-033: conservative column splits for a page. Candidate starts
  /// are grouped into columns separated by gutters wider than 24 pt; every
  /// group needs at least two lines and the groups must overlap vertically.
  /// Returns the split x positions (empty for a single column).
  static func columnSplits(of page: PageAnalysis) -> [Double] {
    let candidates = page.perLine.filter {
      !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.kind != .tableCell
    }
    func lineCount(_ candidates: [TextParagraphCandidate]) -> Int {
      candidates.reduce(0) { total, candidate in
        total + max(candidate.text.components(separatedBy: "\n").count, 1)
      }
    }
    guard lineCount(candidates) >= 4 else { return [] }
    let sorted = candidates.sorted { $0.bounds[0] < $1.bounds[0] }
    // Greedy grouping by gutters: start a new column when the gap between the
    // previous group's right edge and the next candidate's left edge exceeds
    // 24 pt. Groups are reconsidered below against the vertical-overlap rule.
    var groups: [[TextParagraphCandidate]] = []
    var groupBounds: [[Double]] = []
    for candidate in sorted {
      if let last = groupBounds.last, candidate.bounds[0] - last[2] <= 24 {
        groups[groups.count - 1].append(candidate)
        groupBounds[groups.count - 1] = unionBounds([last, candidate.bounds])
      } else {
        groups.append([candidate])
        groupBounds.append(candidate.bounds)
      }
    }
    guard groups.count >= 2 else { return [] }
    // Every group needs at least two lines, and the groups must overlap
    // vertically (side-by-side flow).
    guard groups.allSatisfy({ lineCount($0) >= 2 }) else { return [] }
    let top = groupBounds.map { $0[3] }.min() ?? 0
    let bottom = groupBounds.map { $0[1] }.max() ?? 0
    guard top - bottom > 8 else { return [] }
    var splits: [Double] = []
    for index in 1..<groupBounds.count {
      splits.append((groupBounds[index - 1][2] + groupBounds[index][0]) / 2)
    }
    return splits
  }

  static func columnCount(of page: PageAnalysis) -> Int {
    columnSplits(of: page).count + 1
  }

  static func unionBounds(_ bounds: [[Double]]) -> [Double] {
    guard var result = bounds.first else { return [0, 0, 0, 0] }
    for box in bounds.dropFirst() {
      result = [
        min(result[0], box[0]), min(result[1], box[1]), max(result[2], box[2]),
        max(result[3], box[3]),
      ]
    }
    return result
  }

  /// P35-020: the catalog's declared language, when present.
  static func catalogLanguage(in graph: PDFGraph) -> String? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .string(let data)? = catalog[PDFName("Lang")]
    else { return nil }
    let text = AnnotationText.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 35 else { return nil }
    return text
  }

  /// P35-020: right-to-left Unicode ranges (Hebrew, Arabic, Syriac, Thaana,
  /// N'Ko, Samaritan, Mandaic, and the RTL presentation forms).
  static func isRTLScalar(_ value: UInt32) -> Bool {
    switch value {
    case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F,
      0x0780...0x07BF, 0x07C0...0x07FF, 0x0800...0x083F, 0x0840...0x085F,
      0x0860...0x086F, 0x0870...0x089F, 0x08A0...0x08FF, 0xFB1D...0xFB4F,
      0xFB50...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
      return true
    default:
      return false
    }
  }

  static func containsRTL(_ text: String) -> Bool {
    text.unicodeScalars.contains { isRTLScalar($0.value) }
  }

  static func isRTLMajority(_ text: String) -> Bool {
    let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
    guard !scalars.isEmpty else { return false }
    let rtl = scalars.filter { isRTLScalar($0.value) }.count
    return rtl * 2 >= scalars.count
  }

  /// P35-018: band keys normalize a single number to `#` so `Page 1` and
  /// `Page 2` group as one repeated footer.
  static func normalizedBandText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.range(of: "^\\D*(\\d+)\\D*$", options: .regularExpression) != nil else {
      return trimmed
    }
    var result = ""
    var inDigits = false
    for character in trimmed {
      if character.isNumber {
        if !inDigits { result += "#" }
        inDigits = true
      } else {
        result.append(character)
        inDigits = false
      }
    }
    return result
  }

  /// P35-018: map a single-number text to prefix + PAGE field + suffix runs.
  static func pageNumberRuns(text: String, base: DOCXRunInput) -> [DOCXRunInput] {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.range(of: "^\\D*(\\d+)\\D*$", options: .regularExpression) != nil else {
      return [base]
    }
    let digits = String(trimmed).filter(\.isNumber)
    let prefix = String(trimmed.prefix(while: { !$0.isNumber }))
    let suffix = String(String(trimmed).reversed().prefix(while: { !$0.isNumber }).reversed())
    var runs: [DOCXRunInput] = []
    if !prefix.isEmpty {
      runs.append(
        DOCXRunInput(
          text: prefix, sizePoints: base.sizePoints, fontFamily: base.fontFamily))
    }
    runs.append(
      DOCXRunInput(
        text: digits, sizePoints: base.sizePoints, fontFamily: base.fontFamily, field: "PAGE"))
    if !suffix.isEmpty {
      runs.append(
        DOCXRunInput(
          text: suffix, sizePoints: base.sizePoints, fontFamily: base.fontFamily))
    }
    return runs
  }

  static func pageBox(of pageID: PDFObjectID, in graph: PDFGraph) -> [Double]? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    for key in ["CropBox", "MediaBox"] {
      if case .array(let values)? = page[PDFName(key)], values.count == 4 {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
    }
    return nil
  }

  static func headingLevel(for candidate: TextParagraphCandidate, bodySize: Double) -> Int {
    let ratio = candidate.fontSize / max(bodySize, 1)
    if ratio >= 1.8 { return 1 }
    if ratio >= 1.5 { return 2 }
    return 3
  }

  /// Text per run in reading order, from the page layout. Clusters on a new
  /// line are separated by a newline so cell and paragraph text keeps its
  /// line structure.
  static func textByRun(of layout: PageTextLayout) -> [Int: String] {
    var result: [Int: String] = [:]
    var lastCenter: [Int: Double] = [:]
    for cluster in layout.clusters where !cluster.text.isEmpty {
      let center = (cluster.bounds[1] + cluster.bounds[3]) / 2
      let height = max(cluster.bounds[3] - cluster.bounds[1], 1)
      if let previous = lastCenter[cluster.runIndex], abs(previous - center) > height * 0.5 {
        result[cluster.runIndex, default: ""] += "\n"
      }
      result[cluster.runIndex, default: ""] += cluster.text
      lastCenter[cluster.runIndex] = center
    }
    return result
  }

  /// Axis-aligned bounds per run, from the page layout clusters.
  static func runBounds(of layout: PageTextLayout) -> [Int: [Double]] {
    var result: [Int: [Double]] = [:]
    for cluster in layout.clusters {
      var bounds = result[cluster.runIndex] ?? [
        cluster.bounds[0], cluster.bounds[1], cluster.bounds[2], cluster.bounds[3],
      ]
      bounds[0] = min(bounds[0], cluster.bounds[0])
      bounds[1] = min(bounds[1], cluster.bounds[1])
      bounds[2] = max(bounds[2], cluster.bounds[2])
      bounds[3] = max(bounds[3], cluster.bounds[3])
      result[cluster.runIndex] = bounds
    }
    return result
  }

  /// P35-019: a standard family or a documented substitution.
  static func fontFamily(for baseFont: String) -> (family: String, substituted: Bool) {
    let common = [
      "Helvetica", "Arial", "Times", "Courier", "Menlo", "Georgia", "Verdana", "Tahoma",
      "Calibri", "Cambria",
    ]
    if let match = common.first(where: { baseFont.localizedCaseInsensitiveContains($0) }) {
      return (match, false)
    }
    return (FontFallback.family(for: baseFont), true)
  }

  static func runInputs(
    for candidate: TextParagraphCandidate, textByRun: [Int: String],
    links: [PDFLinkTarget], runBounds: [Int: [Double]], pageIndex: Int,
    language: String? = nil
  ) -> [DOCXRunInput] {
    // Per-run text, in candidate run order.
    let texts: [String] = candidate.runIndices.enumerated().map { offset, run in
      if offset < candidate.runStyles.count {
        return textByRun[run] ?? (candidate.runIndices.count == 1 ? candidate.text : "")
      }
      return ""
    }
    // Per-run bounds (P35-034): real cluster bounds when the font has
    // metrics; otherwise a proportional split *per line* so a link on one
    // line never bleeds into another.
    let weights = texts.map { Double(max($0.count, 1)) }
    let candidateWidth = max(candidate.bounds[2] - candidate.bounds[0], 1)
    let lineCount = max(candidate.lineIndices.count, 1)
    let lineHeight = (candidate.bounds[3] - candidate.bounds[1]) / Double(lineCount)
    var runBoundsList: [[Double]] = []
    for (offset, run) in candidate.runIndices.enumerated() {
      if let bounds = runBounds[run], bounds.count == 4, bounds[2] - bounds[0] > 0.5 {
        runBoundsList.append(bounds)
        continue
      }
      // Distribute within the run's own line when the layout knows it.
      let lineIndex = offset < candidate.lineIndices.count
        ? candidate.lineIndices[offset] : candidate.lineIndices.last ?? 0
      let position = candidate.lineIndices.firstIndex(of: lineIndex) ?? 0
      let lineTop = candidate.bounds[3] - Double(position) * lineHeight
      let width = candidateWidth * weights[offset]
        / max(weights.reduce(0, +), 1)
      // The horizontal start follows the preceding runs of the same line.
      var cursor = candidate.bounds[0]
      for earlier in 0..<offset {
        let earlierLine = earlier < candidate.lineIndices.count
          ? candidate.lineIndices[earlier] : lineIndex
        if earlierLine == lineIndex {
          cursor += candidateWidth * weights[earlier] / max(weights.reduce(0, +), 1)
        }
      }
      runBoundsList.append([
        cursor, lineTop - lineHeight, cursor + width, lineTop,
      ])
    }

    var runs: [DOCXRunInput] = []
    for (offset, run) in candidate.runIndices.enumerated() {
      guard offset < candidate.runStyles.count else { continue }
      let style = candidate.runStyles[offset]
      let base = style.baseFont.isEmpty ? style.fontResource : style.baseFont
      let bold = base.localizedCaseInsensitiveContains("bold")
      let italic =
        base.localizedCaseInsensitiveContains("italic")
        || base.localizedCaseInsensitiveContains("oblique")
      let color = style.fillColor
      let colorHex: String?
      if color.count == 3, !(color[0] > 0.95 && color[1] > 0.95 && color[2] > 0.95) {
        colorHex = String(
          format: "%02X%02X%02X", Int((color[0] * 255).rounded()),
          Int((color[1] * 255).rounded()), Int((color[2] * 255).rounded()))
      } else {
        colorHex = nil
      }
      let text = texts[offset]
      guard !text.isEmpty else { continue }
      let family = fontFamily(for: base)
      // P35-017: attach the link whose rectangle overlaps this run.
      var hyperlinkURI: String?
      var anchor: String?
      let bounds = runBoundsList[offset]
      for link in links where intersects(bounds, link.rect) {
        if let uri = link.uri, PDFHTMLEscape.safeURI(uri) != nil {
          hyperlinkURI = uri
          break
        }
        if let destination = link.destinationPageIndex {
          anchor = "page-\(destination + 1)"
          break
        }
      }
      runs.append(
        DOCXRunInput(
          text: text, bold: bold, italic: italic, colorHex: colorHex,
          sizePoints: abs(style.fontSize - 12) > 0.1 ? style.fontSize : nil,
          hyperlinkURI: hyperlinkURI, anchor: anchor,
          fontFamily: family.substituted ? family.family : nil,
          rtl: containsRTL(text), language: language))
    }
    if runs.isEmpty {
      runs.append(DOCXRunInput(text: candidate.text))
    }
    return runs
  }

  static func overlaps(_ left: [Double], _ right: [Double]) -> Bool {
    let width = min(left[2], right[2]) - max(left[0], right[0])
    let height = min(left[3], right[3]) - max(left[1], right[1])
    return width > 1 && height > 1
  }

  static func intersects(_ left: [Double], _ right: [Double]) -> Bool {
    let width = min(left[2], right[2]) - max(left[0], right[0])
    let height = min(left[3], right[3]) - max(left[1], right[1])
    return width > 0.5 && height > 0.5
  }
}
