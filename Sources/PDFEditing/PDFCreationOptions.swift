import Foundation
import PDFCore

// MARK: - PAG-08 creation options

/// Page size, orientation and margins for created PDFs. Shared by multi-image
/// import, text creation and clipboard creation so all creation routes speak
/// the same units (PDF points) and refuse impossible margins up front.
public struct PDFCreationPageOptions: Sendable, Equatable {
  public enum PageSize: String, Sendable, CaseIterable {
    case letter
    case a4
    case original

    public var title: String {
      switch self {
      case .letter: return "Letter"
      case .a4: return "A4"
      case .original: return "Original image size"
      }
    }

    var baseSize: [Double] {
      switch self {
      case .letter: return [612, 792]
      case .a4: return [595.276, 841.89]
      case .original: return [612, 792]
      }
    }
  }

  public enum Orientation: String, Sendable, CaseIterable {
    case automatic
    case portrait
    case landscape

    public var title: String {
      switch self {
      case .automatic: return "Automatic (follow image)"
      case .portrait: return "Portrait"
      case .landscape: return "Landscape"
      }
    }
  }

  public var pageSize: PageSize
  public var orientation: Orientation
  /// Uniform page margin in points; the image/text area is inset by this on
  /// every side.
  public var margins: Double
  /// Optional background color (RGB 0...1) painted behind image pages.
  public var background: [Double]?
  /// Text creation font size in points.
  public var textFontSize: Double

  public init(
    pageSize: PageSize = .letter, orientation: Orientation = .automatic,
    margins: Double = 36, background: [Double]? = nil, textFontSize: Double = 12
  ) {
    self.pageSize = pageSize
    self.orientation = orientation
    self.margins = margins
    self.background = background
    self.textFontSize = textFontSize
  }

  func validate() throws {
    guard margins.isFinite, margins >= 0, margins <= 1_000 else {
      throw PDFError(.malformed, "Page margins must be between 0 and 1000 points")
    }
    if let background {
      guard background.count == 3, background.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
      else {
        throw PDFError(.malformed, "The page background color is invalid")
      }
    }
    guard textFontSize.isFinite, (6...72).contains(textFontSize) else {
      throw PDFError(.malformed, "The font size must be between 6 and 72 points")
    }
  }

  func validateMargins(fit page: [Double]) throws {
    guard page.count == 2, page[0] > 0, page[1] > 0 else {
      throw PDFError(.malformed, "A created page has no size")
    }
    guard margins * 2 < min(page[0], page[1]) - 24 else {
      throw PDFError(.malformed, "The margins leave no room on the page")
    }
  }
}

/// The output of a creation route plus its page count for the UI.
public struct PDFCreationResult: Sendable, Equatable {
  public let data: Data
  public let pageCount: Int
  public let skippedInputs: [String]

  public init(data: Data, pageCount: Int, skippedInputs: [String] = []) {
    self.data = data
    self.pageCount = pageCount
    self.skippedInputs = skippedInputs
  }
}

/// PAG-08: multi-image creation with explicit page size, orientation and
/// margins. Each image gets its own page; images are centered and scaled to
/// fit inside the margins (never cropped or stretched).
public enum MultiImagePDFCreation {
  public static let maximumPageSide: Double = 14_400

  public static func make(
    sources: [ImagePDFCreation.Source], options: PDFCreationPageOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFCreationResult {
    try options.validate()
    guard !sources.isEmpty else {
      throw PDFError(.malformed, "Choose at least one image")
    }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ])
    ]
    var pageIDs: [PDFObjectID] = []
    var pageSizes: [[Double]] = []
    for (index, source) in sources.enumerated() {
      try validateSource(source, index: index)
      let page = pageSize(for: source, options: options)
      try options.validateMargins(fit: page)
      let pageID = PDFObjectID(3 + index * 2)
      let contentID = PDFObjectID(pageID.number + 1)
      pageIDs.append(pageID)
      pageSizes.append(page)
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .real(page[0]), .real(page[1]),
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      objects[contentID] = .stream(
        PDFStream(dictionary: [PDFName("Length"): .integer(0)], bytes: Data()))
    }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pageIDs.count)),
      PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
    ])
    var graph = PDFGraph(
      objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    for (index, source) in sources.enumerated() {
      let page = pageSizes[index]
      let rect = placementRect(for: source, page: page, margins: options.margins)
      graph = try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceImageCommand(
            pageID: pageIDs[index], rect: rect, width: source.width,
            height: source.height, rgb8: source.rgb8, alpha8: source.alpha8)
        ]), to: graph, limits: limits)
    }
    let data = try PDFWriter.write(graph, limits: limits)
    return PDFCreationResult(data: data, pageCount: sources.count)
  }

  static func validateSource(_ source: ImagePDFCreation.Source, index: Int) throws {
    guard source.width >= 1, source.height >= 1,
      source.width <= 20_000, source.height <= 20_000,
      source.rgb8.count == source.width * source.height * 3
    else {
      throw PDFError(.malformed, "Image \(index + 1) has invalid pixel dimensions or samples")
    }
    if let alpha = source.alpha8, alpha.count != source.width * source.height {
      throw PDFError(.malformed, "Image \(index + 1) has invalid transparency samples")
    }
  }

  static func pageSize(
    for source: ImagePDFCreation.Source, options: PDFCreationPageOptions
  ) -> [Double] {
    let natural: [Double]
    switch options.pageSize {
    case .letter, .a4:
      natural = options.pageSize.baseSize
    case .original:
      let width = max(1, Double(source.width))
      let height = max(1, Double(source.height))
      let scale = min(1, min(maximumPageSide / width, maximumPageSide / height))
      natural = [width * scale, height * scale]
    }
    switch options.orientation {
    case .automatic:
      // Letter/A4 follow the image's aspect; original size keeps its natural
      // pixel dimensions.
      if options.pageSize != .original, source.width > source.height {
        return [max(natural[0], natural[1]), min(natural[0], natural[1])]
      }
      return natural
    case .portrait:
      return [min(natural[0], natural[1]), max(natural[0], natural[1])]
    case .landscape:
      return [max(natural[0], natural[1]), min(natural[0], natural[1])]
    }
  }

  static func placementRect(
    for source: ImagePDFCreation.Source, page: [Double], margins: Double
  ) -> [Double] {
    let availableWidth = max(1, page[0] - margins * 2)
    let availableHeight = max(1, page[1] - margins * 2)
    let scale = min(
      availableWidth / Double(source.width),
      availableHeight / Double(source.height))
    let width = Double(source.width) * scale
    let height = Double(source.height) * scale
    let x = (page[0] - width) / 2
    let y = (page[1] - height) / 2
    return [x, y, x + width, y + height]
  }
}

/// PAG-08: text creation with explicit page size, orientation and margins.
/// Text is wrapped and paginated into ordinary editable page content; the
/// chosen orientation also applies to text pages.
public enum TextPDFCreationWithLayout {
  public static func make(
    text: String, options: PDFCreationPageOptions, limits: PDFLimits = PDFLimits()
  ) throws -> PDFCreationResult {
    try options.validate()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The text is empty")
    }
    let base: [Double]
    switch options.pageSize {
    case .letter: base = [612, 792]
    case .a4: base = [595.276, 841.89]
    case .original:
      throw PDFError(
        .unsupported,
        "Text creation uses Letter or A4; original size only applies to image pages")
    }
    var page: [Double]
    switch options.orientation {
    case .portrait: page = [min(base[0], base[1]), max(base[0], base[1])]
    case .landscape: page = [max(base[0], base[1]), min(base[0], base[1])]
    case .automatic: page = base
    }
    try options.validateMargins(fit: page)
    let width = page[0] - options.margins * 2
    let height = page[1] - options.margins * 2
    // Conservative estimate below the writer's half-em fallback so the added
    // text command never re-wraps a line into more lines than were reserved.
    let charactersPerLine = max(8, Int(width / (options.textFontSize * 0.58)))
    let lineHeight = options.textFontSize * 1.32
    let linesPerPage = max(1, Int(height / lineHeight))
    let lines = TextPDFCreation.wrappedLines(text, charactersPerLine: charactersPerLine)
    let pages = stride(from: 0, to: max(lines.count, 1), by: linesPerPage).map { start in
      Array(lines[start..<min(lines.count, start + linesPerPage)])
    }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ])
    ]
    var pageIDs: [PDFObjectID] = []
    for (index, _) in pages.enumerated() {
      let pageID = PDFObjectID(3 + index * 2)
      let contentID = PDFObjectID(pageID.number + 1)
      pageIDs.append(pageID)
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .real(page[0]), .real(page[1]),
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      objects[contentID] = .stream(
        PDFStream(dictionary: [PDFName("Length"): .integer(0)], bytes: Data()))
    }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pageIDs.count)),
      PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
    ])
    var graph = PDFGraph(
      objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    for (index, pageLines) in pages.enumerated() {
      if let background = options.background {
        graph = try PDFEditingEngine.commit(
          PDFTransaction([
            AddVectorShapeCommand(
              pageID: pageIDs[index],
              shape: .rectangle([0, 0, page[0], page[1]]),
              style: AddedShapeStyle(
                strokeColor: nil, fillColor: background, lineWidth: 0),
              toFront: false)
          ]), to: graph, limits: limits)
      }
      graph = try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextObjectCommand(
            pageID: pageIDs[index],
            rect: [
              options.margins, options.margins,
              page[0] - options.margins, page[1] - options.margins,
            ],
            text: pageLines.joined(separator: "\n"),
            style: AddedTextStyle(
              size: options.textFontSize, alignment: .left, lineSpacing: 1.32),
            clips: false)
        ]), to: graph, limits: limits)
    }
    let data = try PDFWriter.write(graph, limits: limits)
    return PDFCreationResult(data: data, pageCount: pages.count)
  }
}

/// PAG-08: clipboard creation. The App reads the pasteboard and passes text or
/// decoded image samples; the core stays deterministic and renderer-free.
public enum ClipboardPDFCreation {
  public enum Content: Sendable, Equatable {
    case text(String)
    case images([ImagePDFCreation.Source])
    case empty
  }

  public static func make(
    _ content: Content, options: PDFCreationPageOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFCreationResult {
    try options.validate()
    switch content {
    case .empty:
      throw PDFError(.malformed, "The clipboard does not contain text or a supported image")
    case .text(let text):
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PDFError(.malformed, "The clipboard text is empty")
      }
      return try TextPDFCreationWithLayout.make(
        text: text, options: options, limits: limits)
    case .images(let sources):
      return try MultiImagePDFCreation.make(
        sources: sources, options: options, limits: limits)
    }
  }
}
