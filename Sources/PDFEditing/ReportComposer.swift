import CoreGraphics
import CoreText
import Foundation
import PDFCore

// MARK: - Report page geometry

/// Page format used by the printable review and comparison reports.
public enum ReportPageFormat: String, Sendable, Equatable, CaseIterable {
  case letter
  case a4

  public var title: String {
    switch self {
    case .letter: return "Letter"
    case .a4: return "A4"
    }
  }

  /// Page size in PDF points.
  public var size: [Double] {
    switch self {
    case .letter: return [612, 792]
    case .a4: return [595.276, 841.89]
    }
  }
}

/// One raster page image supplied by the caller (the App renders pages; the
/// core report composer stays deterministic and independent of a renderer).
public struct ReportRasterImage: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let rgb8: Data
  public let alpha8: Data?

  public init(width: Int, height: Int, rgb8: Data, alpha8: Data? = nil) {
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.alpha8 = alpha8
  }

  var isValid: Bool {
    width >= 1 && height >= 1 && width <= 20_000 && height <= 20_000
      && rgb8.count == width * height * 3
      && (alpha8 == nil || alpha8?.count == width * height)
  }
}

/// Converts page-content rectangles into a display-space geometry so a report
/// can place comment anchors and change regions on a rendered page image. The
/// mapping matches a renderer that honors the crop box and page rotation.
public enum ReportPageGeometry {
  public static func displaySize(displayBox: [Double], rotation: Int) -> [Double] {
    guard displayBox.count == 4 else { return [612, 792] }
    let width = max(1, abs(displayBox[2] - displayBox[0]))
    let height = max(1, abs(displayBox[3] - displayBox[1]))
    let normalized = ((rotation % 360) + 360) % 360
    if normalized == 90 || normalized == 270 { return [height, width] }
    return [width, height]
  }

  /// Page content space to display space (origin bottom-left of the displayed
  /// page, rotation and crop box applied).
  public static func displayPoint(
    _ point: [Double], displayBox: [Double], rotation: Int
  ) -> [Double] {
    guard point.count == 2, displayBox.count == 4 else { return point }
    let x = point[0]
    let y = point[1]
    let x0 = displayBox[0]
    let y0 = displayBox[1]
    let x1 = displayBox[2]
    let y1 = displayBox[3]
    let normalized = ((rotation % 360) + 360) % 360
    switch normalized {
    case 90:
      return [y - y0, x1 - x]
    case 180:
      return [x1 - x, y1 - y]
    case 270:
      return [y1 - y, x - x0]
    default:
      return [x - x0, y - y0]
    }
  }

  public static func displayRect(
    forContentRect rect: [Double], displayBox: [Double], rotation: Int
  ) -> [Double] {
    guard rect.count == 4, displayBox.count == 4 else { return rect }
    let corners = [
      displayPoint([rect[0], rect[1]], displayBox: displayBox, rotation: rotation),
      displayPoint([rect[2], rect[1]], displayBox: displayBox, rotation: rotation),
      displayPoint([rect[2], rect[3]], displayBox: displayBox, rotation: rotation),
      displayPoint([rect[0], rect[3]], displayBox: displayBox, rotation: rotation),
    ]
    let xs = corners.map { $0[0] }
    let ys = corners.map { $0[1] }
    return [xs.min() ?? rect[0], ys.min() ?? rect[1], xs.max() ?? rect[2], ys.max() ?? rect[3]]
  }

  /// Maps a page-content rectangle into a placed page image rectangle.
  public static func imageRect(
    forContentRect rect: [Double], displayBox: [Double], rotation: Int,
    imageRect: [Double]
  ) -> [Double] {
    let display = displayRect(forContentRect: rect, displayBox: displayBox, rotation: rotation)
    let size = displaySize(displayBox: displayBox, rotation: rotation)
    let width = max(size[0], 1e-9)
    let height = max(size[1], 1e-9)
    let u0 = min(max(display[0] / width, 0), 1)
    let v0 = min(max(display[1] / height, 0), 1)
    let u1 = min(max(display[2] / width, 0), 1)
    let v1 = min(max(display[3] / height, 0), 1)
    let x0 = imageRect[0] + u0 * (imageRect[2] - imageRect[0])
    let x1 = imageRect[0] + u1 * (imageRect[2] - imageRect[0])
    let y0 = imageRect[1] + v0 * (imageRect[3] - imageRect[1])
    let y1 = imageRect[1] + v1 * (imageRect[3] - imageRect[1])
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]
  }
}

// MARK: - Report text policy

/// Printable report body text uses the standard-14 WinAnsi profile (no font
/// embedding, no additional license surface). Characters outside that profile
/// are shown as "?" and the exact original UTF-8 is written as a hex appendix
/// in the same report so nothing is lost.
enum ReportText {
  static func normalized(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\t", with: "    ")
  }

  /// Display text that the standard-14 WinAnsi writer can encode.
  static func display(_ text: String) -> String {
    let normalized = normalized(text)
    var result = ""
    result.reserveCapacity(normalized.utf8.count)
    for scalar in normalized.unicodeScalars {
      if scalar == "\n" {
        result.append("\n")
        continue
      }
      if scalar.value < 0x20 || scalar.value == 0x7F {
        result.append(" ")
        continue
      }
      let candidate = String(scalar)
      if candidate.data(using: .windowsCP1252) != nil {
        result.append(candidate)
      } else {
        result.append("?")
      }
    }
    return result
  }

  static func exactHexIfNeeded(_ text: String) -> String? {
    let normalized = normalized(text)
    let display = display(normalized)
    guard display != normalized else { return nil }
    return normalized.utf8.map { String(format: "%02X", $0) }.joined()
  }

  static func isPrintable(_ text: String) -> Bool {
    display(text) == normalized(text)
  }

  static func measureWidth(_ text: String, size: Double, bold: Bool) -> Double {
    guard !text.isEmpty else { return 0 }
    let fontName = bold ? "Helvetica-Bold" : "Helvetica"
    let font = CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
    let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    let attributes: [NSAttributedString.Key: Any] = [fontKey: font]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    // AddTextObjectCommand falls back to half an em per character when the
    // standard-14 font has no explicit widths. Wrapping must satisfy both
    // metrics so the command never re-wraps a report line into more lines than
    // the layout reserved space for.
    let fallbackEstimate = Double(text.count) * size * 0.5
    return max(Double(advance), fallbackEstimate)
  }

  static func wrap(_ text: String, width: Double, size: Double, bold: Bool) -> [String] {
    let limit = max(width - 2.5, size * 4)
    var result: [String] = []
    for paragraph in normalized(text).components(separatedBy: "\n") {
      if paragraph.isEmpty {
        result.append("")
        continue
      }
      var current = ""
      for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
        let fragment = String(word)
        let candidate = current.isEmpty ? fragment : current + " " + fragment
        if measureWidth(candidate, size: size, bold: bold) <= limit {
          current = candidate
          continue
        }
        if !current.isEmpty {
          result.append(current)
          current = ""
        }
        if measureWidth(fragment, size: size, bold: bold) <= limit {
          current = fragment
          continue
        }
        // A single long token is split on character boundaries.
        var piece = ""
        for character in fragment {
          let candidatePiece = piece + String(character)
          if measureWidth(candidatePiece, size: size, bold: bold) <= limit {
            piece = candidatePiece
          } else {
            if !piece.isEmpty { result.append(piece) }
            piece = String(character)
          }
        }
        current = piece
      }
      if !current.isEmpty { result.append(current) }
    }
    return result
  }

  static func clipped(_ text: String, maximum: Int) -> (text: String, clipped: Bool) {
    guard text.count > maximum else { return (text, false) }
    return (String(text.prefix(maximum)) + " ... [truncated]", true)
  }
}

// MARK: - Report composer

/// Deterministic printable-report document builder. The App renders page
/// images; this composer lays out text, page images, comment anchors and
/// change regions and writes one ordinary PDF through the owned writer.
struct ReportComposer {
  enum Typography {
    static let titleSize: Double = 20
    static let headingSize: Double = 13.5
    static let subheadingSize: Double = 11
    static let bodySize: Double = 9.5
    static let smallSize: Double = 8
    static let tinySize: Double = 6.5
    static let lineFactor: Double = 1.32
  }

  struct Anchor {
    let label: String
    /// Page-content space rectangle on the source page.
    let contentRect: [Double]
  }

  let format: ReportPageFormat
  let margins: Double
  let pageSize: [Double]
  let contentWidth: Double
  var graph: PDFGraph
  var pageIDs: [PDFObjectID] = []
  var cursorY: Double = 0
  var currentPageID: PDFObjectID?
  let title: String?
  let subject: String?

  init(format: ReportPageFormat, title: String?, subject: String?, margins: Double = 36) {
    self.format = format
    self.title = title
    self.subject = subject
    self.margins = margins
    self.pageSize = format.size
    self.contentWidth = max(72, format.size[0] - margins * 2)
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(0),
        PDFName("Kids"): .array([]),
      ]),
    ]
    objects.reserveCapacity(64)
    self.graph = PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  var pageCount: Int { pageIDs.count }

  // MARK: Pages

  mutating func startPage() {
    let next = (graph.objects.keys.map(\.number).max() ?? 2) + 1
    let pageID = PDFObjectID(next)
    let contentID = PDFObjectID(next + 1)
    graph.objects[pageID] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .real(0), .real(0), .real(pageSize[0]), .real(pageSize[1]),
      ]),
      PDFName("Contents"): .reference(contentID),
    ])
    graph.objects[contentID] = .stream(
      PDFStream(dictionary: [PDFName("Length"): .integer(0)], bytes: Data()))
    pageIDs.append(pageID)
    currentPageID = pageID
    cursorY = pageSize[1] - margins
    if case .dictionary(var pages)? = graph.objects[PDFObjectID(2)] {
      pages[PDFName("Kids")] = .array(pageIDs.map(PDFValue.reference))
      pages[PDFName("Count")] = .integer(Int64(pageIDs.count))
      graph.objects[PDFObjectID(2)] = .dictionary(pages)
    }
  }

  mutating func ensureSpace(_ height: Double) {
    if currentPageID == nil {
      startPage()
      return
    }
    if cursorY - height < margins {
      startPage()
    }
  }

  mutating func spacer(_ height: Double) {
    guard height > 0 else { return }
    if currentPageID == nil { startPage() }
    cursorY = max(margins, cursorY - height)
  }

  // MARK: Text

  mutating func titleBlock(_ text: String, subtitles: [String]) throws {
    ensureSpace(Typography.titleSize * Typography.lineFactor + 8)
    try paragraphLines(
      ReportText.wrap(text, width: contentWidth, size: Typography.titleSize, bold: true),
      size: Typography.titleSize, bold: true, indent: 0, color: [0, 0, 0], spacingAfter: 4)
    for subtitle in subtitles {
      try paragraph(
        subtitle, size: Typography.subheadingSize, bold: false, indent: 0,
        color: [0.22, 0.22, 0.24], spacingAfter: 1)
    }
    spacer(6)
  }

  mutating func heading(_ text: String) throws {
    ensureSpace(Typography.headingSize * Typography.lineFactor + 34)
    try paragraph(
      text, size: Typography.headingSize, bold: true, indent: 0,
      color: [0.05, 0.05, 0.08], spacingAfter: 3)
  }

  mutating func subheading(_ text: String) throws {
    ensureSpace(Typography.subheadingSize * Typography.lineFactor + 18)
    try paragraph(
      text, size: Typography.subheadingSize, bold: true, indent: 0,
      color: [0.10, 0.10, 0.14], spacingAfter: 2)
  }

  mutating func paragraph(
    _ text: String, size: Double = Typography.bodySize, bold: Bool = false,
    indent: Double = 0, color: [Double] = [0, 0, 0], spacingAfter: Double = 2
  ) throws {
    let lines = ReportText.wrap(
      ReportText.display(text), width: contentWidth - indent, size: size, bold: bold)
    try paragraphLines(
      lines, size: size, bold: bold, indent: indent, color: color,
      spacingAfter: spacingAfter)
  }

  mutating func paragraphLines(
    _ lines: [String], size: Double = Typography.bodySize, bold: Bool = false,
    indent: Double = 0, color: [Double] = [0, 0, 0], spacingAfter: Double = 2
  ) throws {
    let safeLines = lines.map(ReportText.display)
    guard !safeLines.isEmpty else { return }
    var remaining = safeLines
    let lineHeight = (size * Typography.lineFactor).rounded(.up)
    while !remaining.isEmpty {
      if currentPageID == nil { startPage() }
      let available = max(1, Int(((cursorY - margins) / lineHeight).rounded(.down)))
      let count = min(remaining.count, available)
      let chunk = Array(remaining.prefix(count))
      let height = Double(count) * lineHeight + 3
      ensureSpace(height)
      let pageID = currentPageID ?? pageIDs.last!
      let rect = [
        margins + indent, cursorY - height, pageSize[0] - margins, cursorY - 1,
      ]
      let style = AddedTextStyle(
        family: .helvetica, bold: bold, italic: false, size: size, color: color,
        alignment: .left, lineSpacing: Typography.lineFactor)
      let command = AddTextObjectCommand(
        pageID: pageID, rect: rect, text: chunk.joined(separator: "\n"),
        style: style, toFront: true, clips: false)
      graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      cursorY -= height
      remaining.removeFirst(count)
    }
    spacer(spacingAfter)
  }

  // MARK: Rules

  mutating func divider() throws {
    ensureSpace(12)
    let pageID = currentPageID ?? pageIDs.last!
    let rect = [margins, cursorY - 6, pageSize[0] - margins, cursorY - 6]
    let style = AddedShapeStyle(
      strokeColor: [0.72, 0.72, 0.75], fillColor: nil, lineWidth: 0.7)
    let command = AddVectorShapeCommand(
      pageID: pageID, shape: .line(from: [rect[0], rect[1]], to: [rect[2], rect[3]]),
      style: style, toFront: true)
    graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    spacer(10)
  }

  // MARK: Images and page context

  /// Place one raster image fitted to the report content width and a height
  /// budget. Returns the page-space rectangle it occupies in the report.
  @discardableResult
  mutating func image(
    _ raster: ReportRasterImage, maxWidth: Double? = nil, maxHeight: Double? = nil
  ) throws -> [Double] {
    guard raster.isValid else {
      throw PDFError(.malformed, "A report page image has invalid dimensions or samples")
    }
    let width = min(maxWidth ?? contentWidth, contentWidth)
    guard width > 1 else { throw PDFError(.malformed, "The report image has no room") }
    let budget = maxHeight ?? max(48, pageSize[1] - margins * 2 - 72)
    var drawWidth = width
    var drawHeight = drawWidth * Double(raster.height) / Double(raster.width)
    if drawHeight > budget {
      drawHeight = budget
      drawWidth = drawHeight * Double(raster.width) / Double(raster.height)
    }
    ensureSpace(drawHeight + 12)
    let pageID = currentPageID ?? pageIDs.last!
    let x = margins + (contentWidth - drawWidth) / 2
    let rect = [x, cursorY - drawHeight, x + drawWidth, cursorY]
    let command = PlaceImageCommand(
      pageID: pageID, rect: rect, width: raster.width, height: raster.height,
      rgb8: raster.rgb8, alpha8: raster.alpha8)
    graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    cursorY -= drawHeight + 6
    return rect
  }

  /// Place two raster images side by side (comparison page context). Each
  /// image is fitted into half of the content width; the taller image sets the
  /// row height. Missing images leave their half empty.
  @discardableResult
  mutating func sideBySideImages(
    left: ReportRasterImage?, right: ReportRasterImage?, maxHeight: Double = 280
  ) throws -> (left: [Double]?, right: [Double]?) {
    for raster in [left, right] {
      if let raster, !raster.isValid {
        throw PDFError(.malformed, "A comparison page image has invalid dimensions or samples")
      }
    }
    let gap: Double = 12
    let halfWidth = (contentWidth - gap) / 2
    func fitted(_ raster: ReportRasterImage?) -> (width: Double, height: Double)? {
      guard let raster else { return nil }
      var width = halfWidth
      var height = width * Double(raster.height) / Double(raster.width)
      if height > maxHeight {
        height = maxHeight
        width = height * Double(raster.width) / Double(raster.height)
      }
      return (max(1, width), max(1, height))
    }
    let leftFit = fitted(left)
    let rightFit = fitted(right)
    let rowHeight = max(leftFit?.height ?? 0, rightFit?.height ?? 0)
    guard rowHeight > 0 else { return (nil, nil) }
    ensureSpace(rowHeight + 14)
    let pageID = currentPageID ?? pageIDs.last!
    let rowBottom = cursorY - rowHeight
    var leftRect: [Double]?
    var rightRect: [Double]?
    if let fit = leftFit, let raster = left {
      let rect = [margins, rowBottom, margins + fit.width, rowBottom + fit.height]
      let command = PlaceImageCommand(
        pageID: pageID, rect: rect, width: raster.width, height: raster.height,
        rgb8: raster.rgb8, alpha8: raster.alpha8)
      graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      leftRect = rect
    }
    if let fit = rightFit, let raster = right {
      let x = margins + halfWidth + gap
      let rect = [x, rowBottom, x + fit.width, rowBottom + fit.height]
      let command = PlaceImageCommand(
        pageID: pageID, rect: rect, width: raster.width, height: raster.height,
        rgb8: raster.rgb8, alpha8: raster.alpha8)
      graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      rightRect = rect
    }
    cursorY = rowBottom - 8
    return (leftRect, rightRect)
  }

  /// One page-context section: a rendered page image (or a schematic page
  /// outline), numbered comment anchors, and a legend. The caller supplies
  /// anchors in page-content space; the section maps them through the page's
  /// display box and rotation.
  mutating func pageContext(
    heading headingText: String, displayBox: [Double], rotation: Int,
    raster: ReportRasterImage?, anchors: [Anchor], legend: [String]
  ) throws {
    try heading(headingText)
    let display = ReportPageGeometry.displaySize(
      displayBox: displayBox, rotation: rotation)
    let aspect = display[1] / max(display[0], 1e-9)
    let budget = max(90, min(300, pageSize[1] - margins * 2 - 96))
    var imageRect: [Double]
    if let raster, raster.isValid {
      imageRect = try image(raster, maxWidth: contentWidth, maxHeight: budget)
    } else {
      var height = min(budget, contentWidth * aspect)
      var width = height / max(aspect, 1e-9)
      if width > contentWidth {
        width = contentWidth
        height = width * aspect
      }
      ensureSpace(height + 14)
      let pageID = currentPageID ?? pageIDs.last!
      let x = margins + (contentWidth - width) / 2
      let rect = [x, cursorY - height, x + width, cursorY]
      let fill = AddedShapeStyle(
        strokeColor: [0.55, 0.55, 0.58], fillColor: [0.975, 0.975, 0.98], lineWidth: 0.8)
      let command = AddVectorShapeCommand(
        pageID: pageID, shape: .rectangle(rect), style: fill, toFront: true)
      graph = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      cursorY -= height + 6
      imageRect = rect
    }
    try drawAnchors(anchors: anchors, displayBox: displayBox, rotation: rotation, imageRect: imageRect)
    if !legend.isEmpty {
      for line in legend {
        try paragraph(
          line, size: Typography.smallSize, indent: 12, color: [0.12, 0.12, 0.14],
          spacingAfter: 0.5)
      }
    }
    spacer(8)
  }

  mutating func drawAnchors(
    anchors: [Anchor], displayBox: [Double], rotation: Int, imageRect: [Double]
  ) throws {
    guard !anchors.isEmpty, currentPageID != nil else { return }
    let pageID = currentPageID!
    for anchor in anchors.prefix(200) {
      guard anchor.contentRect.count == 4 else { continue }
      var rect = ReportPageGeometry.imageRect(
        forContentRect: anchor.contentRect, displayBox: displayBox, rotation: rotation,
        imageRect: imageRect)
      let minimum: Double = 4
      if rect[2] - rect[0] < minimum {
        let mid = (rect[0] + rect[2]) / 2
        rect[0] = mid - minimum / 2
        rect[2] = mid + minimum / 2
      }
      if rect[3] - rect[1] < minimum {
        let mid = (rect[1] + rect[3]) / 2
        rect[1] = mid - minimum / 2
        rect[3] = mid + minimum / 2
      }
      let style = AddedShapeStyle(
        strokeColor: [0.86, 0.15, 0.12], fillColor: nil, lineWidth: 1.1)
      let shape = AddVectorShapeCommand(
        pageID: pageID, shape: .rectangle(rect), style: style, toFront: true)
      graph = try PDFEditingEngine.commit(PDFTransaction([shape]), to: graph)
      let labelText = ReportText.display(anchor.label)
      let labelWidth = max(10, ReportText.measureWidth(
        labelText, size: Typography.tinySize + 1, bold: true) + 4)
      let labelHeight = Typography.tinySize * 1.5 + 3
      var labelX = min(max(rect[0], imageRect[0]), imageRect[2] - labelWidth)
      var labelY = rect[3] + 1
      if labelY + labelHeight > imageRect[3] {
        labelY = max(imageRect[1], rect[3] - labelHeight - 1)
      }
      if labelX < imageRect[0] { labelX = imageRect[0] }
      let background = AddVectorShapeCommand(
        pageID: pageID,
        shape: .rectangle([labelX, labelY, labelX + labelWidth, labelY + labelHeight]),
        style: AddedShapeStyle(
          strokeColor: [0.86, 0.15, 0.12], fillColor: [1, 1, 1], lineWidth: 0.5),
        toFront: true)
      graph = try PDFEditingEngine.commit(PDFTransaction([background]), to: graph)
      let label = AddTextObjectCommand(
        pageID: pageID,
        rect: [labelX + 1, labelY + 1, labelX + labelWidth - 1, labelY + labelHeight - 1],
        text: labelText,
        style: AddedTextStyle(
          family: .helvetica, bold: true, size: Typography.tinySize + 1,
          color: [0.7, 0.1, 0.08], alignment: .left, lineSpacing: 1.0),
        toFront: true, clips: true)
      graph = try PDFEditingEngine.commit(PDFTransaction([label]), to: graph)
    }
  }

  // MARK: Finish

  mutating func finish(limits: PDFLimits = PDFLimits()) throws -> Data {
    if pageIDs.isEmpty { startPage() }
    let next = (graph.objects.keys.map(\.number).max() ?? 2) + 1
    let infoID = PDFObjectID(next)
    var info: [PDFName: PDFValue] = [
      PDFName("Creator"): .string(Data("sPDF Editor".utf8)),
      PDFName("Producer"): .string(Data("sPDF Editor".utf8)),
    ]
    if let title, !title.isEmpty {
      info[PDFName("Title")] = .string(Data(title.utf8))
    }
    if let subject, !subject.isEmpty {
      info[PDFName("Subject")] = .string(Data(subject.utf8))
    }
    graph.objects[infoID] = .dictionary(info)
    graph.trailer[PDFName("Info")] = .reference(infoID)
    let data = try PDFWriter.write(graph, limits: limits)
    let reparsed = try PDFParser.parse(data, limits: limits)
    guard reparsed.pageIDs.count == pageIDs.count else {
      throw PDFError(.malformed, "The generated report did not verify its page count")
    }
    return data
  }
}
