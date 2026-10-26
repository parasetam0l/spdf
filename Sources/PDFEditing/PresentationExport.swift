import Foundation
import PDFCore

/// EXP-03: one run inside an editable slide text box.
public struct PresentationTextRun: Sendable, Equatable {
  public let text: String
  public let fontName: String
  public let fontSize: Double
  public let bold: Bool
  public let italic: Bool
  /// Uppercase RRGGBB.
  public let colorHex: String

  public init(
    text: String, fontName: String = "Helvetica", fontSize: Double = 12,
    bold: Bool = false, italic: Bool = false, colorHex: String = "000000"
  ) {
    self.text = text
    self.fontName = fontName
    self.fontSize = max(1, min(fontSize, 4_000))
    self.bold = bold
    self.italic = italic
    self.colorHex = colorHex
  }
}

public enum PresentationTextAlignment: String, Sendable, Equatable {
  case left
  case center
  case right
  case justified

  var pptxValue: String {
    switch self {
    case .left: return "l"
    case .center: return "ctr"
    case .right: return "r"
    case .justified: return "just"
    }
  }
}

/// EXP-03: a text box in slide points. Bounds use the presentation coordinate
/// system (origin at the top-left of the slide).
public struct PresentationTextElement: Sendable, Equatable {
  public let runs: [PresentationTextRun]
  public let bounds: [Double]
  public let alignment: PresentationTextAlignment
  /// Clockwise degrees in the slide; 0 for ordinary horizontal text.
  public let rotationDegrees: Double

  public init(
    runs: [PresentationTextRun], bounds: [Double],
    alignment: PresentationTextAlignment = .left, rotationDegrees: Double = 0
  ) {
    self.runs = runs
    self.bounds = bounds
    self.alignment = alignment
    self.rotationDegrees = rotationDegrees
  }

  public var text: String { runs.map(\.text).joined() }
}

public struct PresentationImageElement: Sendable, Equatable {
  public enum Provenance: String, Sendable, Equatable, Codable {
    /// The original encoded image bytes were used.
    case originalEncoded
    /// A rendered region was used because the original bytes were not
    /// independently usable (masks, transforms, unsupported codec).
    case renderedRegion
    /// The whole page was rendered because it could not be reconstructed as
    /// editable content.
    case fullPageFallback
  }

  public let name: String
  public let bounds: [Double]
  public let data: Data
  /// png or jpeg.
  public let fileExtension: String
  public let provenance: Provenance
  public let note: String

  public init(
    name: String, bounds: [Double], data: Data, fileExtension: String,
    provenance: Provenance, note: String
  ) {
    self.name = name
    self.bounds = bounds
    self.data = data
    self.fileExtension = fileExtension
    self.provenance = provenance
    self.note = note
  }
}

public enum PresentationShapeKind: String, Sendable, Equatable {
  case rectangle
  case line
}

public struct PresentationShapeElement: Sendable, Equatable {
  public let kind: PresentationShapeKind
  public let bounds: [Double]
  public let fillColorHex: String?
  public let strokeColorHex: String?
  public let lineWidth: Double
  public let note: String

  public init(
    kind: PresentationShapeKind, bounds: [Double], fillColorHex: String? = nil,
    strokeColorHex: String? = nil, lineWidth: Double = 1, note: String = ""
  ) {
    self.kind = kind
    self.bounds = bounds
    self.fillColorHex = fillColorHex
    self.strokeColorHex = strokeColorHex
    self.lineWidth = max(0, min(lineWidth, 100))
    self.note = note
  }
}

public enum PresentationSlideElement: Sendable, Equatable {
  case text(PresentationTextElement)
  case image(PresentationImageElement)
  case shape(PresentationShapeElement)

  var isRasterFallback: Bool {
    guard case .image(let image) = self else { return false }
    return image.provenance == .fullPageFallback
  }
}

public struct PresentationSlide: Sendable, Equatable {
  public let pageIndex: Int
  /// Slide size in points.
  public let size: [Double]
  public let elements: [PresentationSlideElement]
  /// When set, a clearly visible label is added to the slide saying that the
  /// page is a raster fallback.
  public let fallbackLabel: String?
  public let notes: [String]

  public init(
    pageIndex: Int, size: [Double], elements: [PresentationSlideElement],
    fallbackLabel: String? = nil, notes: [String] = []
  ) {
    self.pageIndex = pageIndex
    self.size = size
    self.elements = elements
    self.fallbackLabel = fallbackLabel
    self.notes = notes
  }

  public var hasRasterFallback: Bool {
    elements.contains(where: \.isRasterFallback)
  }

  public var editableTextCount: Int {
    elements.reduce(0) { count, element in
      if case .text = element { return count + 1 }
      return count
    }
  }

  public var editableImageCount: Int {
    elements.reduce(0) { count, element in
      guard case .image(let image) = element, image.provenance != .fullPageFallback
      else { return count }
      return count + 1
    }
  }

  public var editableShapeCount: Int {
    elements.reduce(0) { count, element in
      if case .shape = element { return count + 1 }
      return count
    }
  }
}

/// EXP-03: the truthful editability report that accompanies a PowerPoint
/// export. It reports what was reconstructed as editable objects and where a
/// labelled raster fallback was used; it never claims layout fidelity.
public struct PresentationEditabilityReport: Sendable, Equatable, Codable {
  public struct SlideEntry: Sendable, Equatable, Codable {
    public let slideNumber: Int
    public let pageNumber: Int
    public let editableTextCount: Int
    public let editableImageCount: Int
    public let editableShapeCount: Int
    public let rasterFallback: Bool
    public let notes: [String]
  }

  public static let truthfulnessStatement =
    "This report states what the exporter reconstructed as editable PowerPoint "
    + "objects. Reliably recovered text, images and shapes become editable text "
    + "boxes, pictures and shapes; pages that cannot be reconstructed are exported "
    + "as a clearly labelled raster image that is not editable. Layout, line "
    + "breaks and font substitution may differ in a presentation application. "
    + "The package was structurally validated as an OPC/PPTX file; it was not "
    + "opened in PowerPoint by the exporter."

  public let title: String
  public let slides: [SlideEntry]

  public init(title: String, slides: [SlideEntry]) {
    self.title = title
    self.slides = slides
  }

  init(title: String, exportSlides: [PresentationSlide]) {
    self.title = title
    self.slides = exportSlides.enumerated().map { index, slide in
      var notes = slide.notes
      if slide.hasRasterFallback {
        notes.append(
          "Raster fallback: this page is a labelled image and is not editable.")
      }
      if slide.fallbackLabel != nil {
        notes.append("The slide carries a visible raster-fallback label.")
      }
      return SlideEntry(
        slideNumber: index + 1, pageNumber: slide.pageIndex + 1,
        editableTextCount: slide.editableTextCount,
        editableImageCount: slide.editableImageCount,
        editableShapeCount: slide.editableShapeCount,
        rasterFallback: slide.hasRasterFallback, notes: notes)
    }
  }

  public var rasterFallbackSlideCount: Int {
    slides.filter(\.rasterFallback).count
  }

  /// True when every raster-fallback slide carries an explanatory note, so
  /// the report never hides that the slide is not editable.
  public var hasTruthfulFallbackNotes: Bool {
    slides.filter(\.rasterFallback).allSatisfy { !$0.notes.isEmpty }
  }

  public var editableElementCount: Int {
    slides.reduce(0) {
      $0 + $1.editableTextCount + $1.editableImageCount + $1.editableShapeCount
    }
  }

  public func markdown() -> String {
    var lines = [
      "# PowerPoint export editability report", "",
      PresentationEditabilityReport.truthfulnessStatement, "",
      "Title: \(title)",
      "Slides: \(slides.count); fully editable: \(slides.count - rasterFallbackSlideCount); "
        + "raster fallback: \(rasterFallbackSlideCount).",
      "",
      "| Slide | Page | Editable text | Editable images | Editable shapes | Raster fallback |",
      "| --- | --- | --- | --- | --- | --- |",
    ]
    for slide in slides {
      lines.append(
        "| \(slide.slideNumber) | \(slide.pageNumber) | \(slide.editableTextCount) | "
        + "\(slide.editableImageCount) | \(slide.editableShapeCount) | "
        + "\(slide.rasterFallback ? "yes (labelled, not editable)" : "no") |")
    }
    let notes = slides.flatMap(\.notes)
    if !notes.isEmpty {
      lines.append("")
      lines.append("Notes:")
      for note in notes { lines.append("- \(note)") }
    }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}

public struct PresentationExportDocument: Sendable, Equatable {
  public let slides: [PresentationSlide]
  public let report: PresentationEditabilityReport

  public init(slides: [PresentationSlide], title: String = "Reconstructed presentation") {
    self.slides = slides
    self.report = PresentationEditabilityReport(title: title, exportSlides: slides)
  }
}

/// EXP-03: a deterministic, bounded PowerPoint (PresentationML) package. The
/// writer reconstructs only declared slide objects (text boxes, pictures,
/// shapes) and never embeds macros or active content. References: ECMA-376
/// Part 1 (PresentationML) and the OPC package/relationship rules.
public enum PPTXExport {
  public static let contentTypesPart = "[Content_Types].xml"
  public static let packageRelationshipsPart = "_rels/.rels"
  public static let presentationPart = "ppt/presentation.xml"
  public static let presentationRelationshipsPart = "ppt/_rels/presentation.xml.rels"
  public static let slideMasterPart = "ppt/slideMasters/slideMaster1.xml"
  public static let slideMasterRelationshipsPart =
    "ppt/slideMasters/_rels/slideMaster1.xml.rels"
  public static let slideLayoutPart = "ppt/slideLayouts/slideLayout1.xml"
  public static let slideLayoutRelationshipsPart =
    "ppt/slideLayouts/_rels/slideLayout1.xml.rels"
  public static let themePart = "ppt/theme/theme1.xml"

  public static func slidePart(index: Int) -> String { "ppt/slides/slide\(index).xml" }

  public static func slideRelationshipsPart(index: Int) -> String {
    "ppt/slides/_rels/slide\(index).xml.rels"
  }

  public static func mediaPart(index: Int, fileExtension: String) -> String {
    String(format: "ppt/media/image%04d.%@", index, normalizedExtension(fileExtension))
  }

  public static let maxSlides = 512
  public static let maxElementsPerSlide = 500
  public static let maxImageBytes = 16 * 1_024 * 1_024
  public static let maxMediaBytes = 64 * 1_024 * 1_024
  public static let maxTextCharacters = 32_767
  /// PowerPoint allows slide dimensions up to 56 inches (4032 points).
  public static let maximumSlidePoints = 4_032.0
  public static let emuPerPoint = 12_700.0

  public static func package(
    document: PresentationExportDocument, zipLimits: ZIPArchiveWriter.Limits = .init()
  ) throws -> Data {
    guard document.slides.count <= maxSlides else {
      throw PDFError(.limitExceeded, "The export exceeds the slide limit")
    }
    let slideSize = presentationSize(document.slides)
    var media: [(path: String, data: Data)] = []
    var slideImageRelationships: [[(id: String, target: String)]] = []
    var totalMediaBytes = 0
    for slide in document.slides {
      guard slide.elements.count <= maxElementsPerSlide else {
        throw PDFError(.limitExceeded, "A slide exceeds the element limit")
      }
      var relationships: [(id: String, target: String)] = []
      for element in slide.elements {
        guard case .image(let image) = element else { continue }
        guard image.data.count <= maxImageBytes else {
          throw PDFError(.limitExceeded, "An image exceeds the per-image size limit")
        }
        guard totalMediaBytes + image.data.count <= maxMediaBytes else {
          throw PDFError(.limitExceeded, "The export exceeds the media size limit")
        }
        totalMediaBytes += image.data.count
        let path = mediaPart(
          index: media.count + 1, fileExtension: image.fileExtension)
        media.append((path: path, data: image.data))
        let target = "media/" + (path as NSString).lastPathComponent
        relationships.append(("rIdImage\(relationships.count + 1)", target))
      }
      slideImageRelationships.append(relationships)
    }

    var zip = ZIPArchiveWriter(limits: zipLimits)
    try zip.add(
      name: contentTypesPart,
      data: contentTypes(slideCount: document.slides.count, media: media))
    try zip.add(name: packageRelationshipsPart, data: packageRelationships())
    try zip.add(
      name: presentationPart, data: presentation(slideCount: document.slides.count, size: slideSize))
    try zip.add(
      name: presentationRelationshipsPart,
      data: presentationRelationships(slideCount: document.slides.count))
    try zip.add(name: slideMasterPart, data: slideMaster())
    try zip.add(
      name: slideMasterRelationshipsPart, data: slideMasterRelationships())
    try zip.add(name: slideLayoutPart, data: slideLayout())
    try zip.add(
      name: slideLayoutRelationshipsPart, data: slideLayoutRelationships())
    try zip.add(name: themePart, data: theme())
    for (index, slide) in document.slides.enumerated() {
      let relationships = slideImageRelationships[index]
      try zip.add(
        name: slidePart(index: index + 1),
        data: slideXML(
          slide: slide, size: slideSize, imageRelationships: relationships))
      try zip.add(
        name: slideRelationshipsPart(index: index + 1),
        data: slideRelationships(imageRelationships: relationships))
    }
    if document.slides.isEmpty {
      // A presentation needs at least one slide part; an empty document exports
      // one empty slide rather than a dangling relationship.
      let slide = PresentationSlide(pageIndex: 0, size: slideSize, elements: [])
      try zip.add(
        name: slidePart(index: 1),
        data: slideXML(slide: slide, size: slideSize, imageRelationships: []))
      try zip.add(
        name: slideRelationshipsPart(index: 1),
        data: slideRelationships(imageRelationships: []))
    }
    for entry in media {
      try zip.add(name: entry.path, data: entry.data)
    }
    return try zip.archive()
  }

  static func presentationSize(_ slides: [PresentationSlide]) -> [Double] {
    guard let first = slides.first, first.size.count == 2,
      first.size[0].isFinite, first.size[1].isFinite
    else {
      return [720, 540]
    }
    return [
      min(max(first.size[0], 1), maximumSlidePoints),
      min(max(first.size[1], 1), maximumSlidePoints),
    ]
  }

  static func normalizedExtension(_ fileExtension: String) -> String {
    let lower = fileExtension.lowercased()
    switch lower {
    case "jpg", "jpeg": return "jpeg"
    case "png": return "png"
    default: return "png"
    }
  }

  // MARK: - Package parts

  static func contentTypes(
    slideCount: Int, media: [(path: String, data: Data)]
  ) -> Data {
    var extensions = Set<String>()
    for entry in media {
      extensions.insert((entry.path as NSString).pathExtension)
    }
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Default Extension="png" ContentType="image/png"/>
      <Default Extension="jpeg" ContentType="image/jpeg"/>
      <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
      <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
      <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
      <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>

      """
    _ = extensions
    for index in 1...max(slideCount, 1) {
      xml += "<Override PartName=\"/ppt/slides/slide\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>\n"
    }
    xml += "</Types>\n"
    return Data(xml.utf8)
  }

  static func packageRelationships() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
      </Relationships>

      """.utf8)
  }

  static func presentation(slideCount: Int, size: [Double]) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster1"/></p:sldMasterIdLst>
      <p:sldIdLst>

      """
    for index in 1...max(slideCount, 1) {
      xml += "<p:sldId id=\"\(255 + index)\" r:id=\"rIdSlide\(index)\"/>\n"
    }
    xml += """
      </p:sldIdLst>
      <p:sldSz cx="\(emu(size[0]))" cy="\(emu(size[1]))"/>
      <p:notesSz cx="6858000" cy="9144000"/>
      </p:presentation>

      """
    return Data(xml.utf8)
  }

  static func presentationRelationships(slideCount: Int) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rIdMaster1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>

      """
    for index in 1...max(slideCount, 1) {
      xml += "<Relationship Id=\"rIdSlide\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(index).xml\"/>\n"
    }
    xml += "</Relationships>\n"
    return Data(xml.utf8)
  }

  static func slideMaster() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:cSld>
      <p:spTree>
      <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
      <p:grpSpPr/>
      </p:spTree>
      </p:cSld>
      <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
      <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rIdLayout1"/></p:sldLayoutIdLst>
      </p:sldMaster>

      """.utf8)
  }

  static func slideMasterRelationships() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rIdLayout1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
      <Relationship Id="rIdTheme1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
      </Relationships>

      """.utf8)
  }

  static func slideLayout() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
      <p:cSld name="Blank">
      <p:spTree>
      <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
      <p:grpSpPr/>
      </p:spTree>
      </p:cSld>
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
      </p:sldLayout>

      """.utf8)
  }

  static func slideLayoutRelationships() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rIdMaster1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
      </Relationships>

      """.utf8)
  }

  static func theme() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
      <a:themeElements>
      <a:clrScheme name="Office">
      <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
      <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
      <a:dk2><a:srgbClr val="44546A"/></a:dk2>
      <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
      <a:accent1><a:srgbClr val="4472C4"/></a:accent1>
      <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
      <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
      <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
      <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
      <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
      <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
      <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
      </a:clrScheme>
      <a:fontScheme name="Office">
      <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
      <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
      </a:fontScheme>
      <a:fmtScheme name="Office">
      <a:fillStyleLst>
      <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      </a:fillStyleLst>
      <a:lnStyleLst>
      <a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
      <a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
      <a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
      </a:lnStyleLst>
      <a:effectStyleLst>
      <a:effectStyle><a:effectLst/></a:effectStyle>
      <a:effectStyle><a:effectLst/></a:effectStyle>
      <a:effectStyle><a:effectLst/></a:effectStyle>
      </a:effectStyleLst>
      <a:bgFillStyleLst>
      <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      </a:bgFillStyleLst>
      </a:fmtScheme>
      </a:themeElements>
      </a:theme>

      """.utf8)
  }

  // MARK: - Slides

  static func slideXML(
    slide: PresentationSlide, size: [Double],
    imageRelationships: [(id: String, target: String)]
  ) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:cSld>
      <p:spTree>
      <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
      <p:grpSpPr/>

      """
    var identifier = 2
    var imageIndex = 0
    for element in slide.elements {
      switch element {
      case .text(let text):
        xml += textShapeXML(text, id: identifier, size: size)
        identifier += 1
      case .image(let image):
        let relationship = imageRelationships[imageIndex]
        xml += pictureXML(image, id: identifier, size: size, relationshipID: relationship.id)
        identifier += 1
        imageIndex += 1
      case .shape(let shape):
        xml += shapeXML(shape, id: identifier, size: size)
        identifier += 1
      }
    }
    if let label = slide.fallbackLabel, !label.isEmpty {
      let labelElement = PresentationTextElement(
        runs: [
          PresentationTextRun(
            text: label, fontName: "Helvetica", fontSize: 11, bold: true,
            colorHex: "B00020")
        ],
        bounds: [18, max(0, size[1] - 44), max(18, size[0] - 18), max(8, size[1] - 18)],
        alignment: .left)
      xml += textShapeXML(labelElement, id: identifier, size: size)
      identifier += 1
    }
    xml += """
      </p:spTree>
      </p:cSld>
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
      </p:sld>

      """
    return Data(xml.utf8)
  }

  static func slideRelationships(imageRelationships: [(id: String, target: String)]) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rIdLayout1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>

      """
    for relationship in imageRelationships {
      xml += "<Relationship Id=\"\(relationship.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(relationship.target)\"/>\n"
    }
    xml += "</Relationships>\n"
    return Data(xml.utf8)
  }

  static func textShapeXML(
    _ text: PresentationTextElement, id: Int, size: [Double]
  ) -> String {
    let frame = sanitizedFrame(text.bounds, size: size)
    let name = "Text \(id - 1)"
    var xml = """
      <p:sp>
      <p:nvSpPr><p:cNvPr id="\(id)" name="\(DOCXXML.escape(name))"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm\(rotationAttribute(text.rotationDegrees))><a:off x="\(emu(frame[0]))" y="\(emu(frame[1]))"/><a:ext cx="\(emu(frame[2]))" cy="\(emu(frame[3]))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
      <p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0"><a:noAutofit/></a:bodyPr><a:lstStyle/>

      """
    let paragraphs = textParagraphs(text.runs)
    for paragraph in paragraphs {
      xml += "<a:p><a:pPr algn=\"\(text.alignment.pptxValue)\"/>"
      if paragraph.isEmpty {
        xml += "<a:endParaRPr lang=\"en-US\"/>"
      } else {
        for run in paragraph {
          xml += runXML(run)
        }
      }
      xml += "</a:p>\n"
    }
    xml += """
      </p:txBody>
      </p:sp>

      """
    return xml
  }

  struct StyledSegment: Sendable {
    let text: String
    let run: PresentationTextRun
  }

  static func textParagraphs(_ runs: [PresentationTextRun]) -> [[StyledSegment]] {
    var paragraphs: [[StyledSegment]] = []
    var current: [StyledSegment] = []
    for run in runs {
      let bounded = String(run.text.prefix(maxTextCharacters))
      let parts = bounded.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, part) in parts.enumerated() {
        if index > 0 {
          paragraphs.append(current)
          current = []
        }
        if !part.isEmpty {
          current.append(StyledSegment(text: String(part), run: run))
        }
      }
    }
    paragraphs.append(current)
    return paragraphs
  }

  static func runXML(_ segment: StyledSegment) -> String {
    let run = segment.run
    let size = Int((run.fontSize * 100).rounded())
    let bold = run.bold ? " b=\"1\"" : ""
    let italic = run.italic ? " i=\"1\"" : ""
    return "<a:r><a:rPr lang=\"en-US\" sz=\"\(max(100, min(size, 400_000)))\"\(bold)\(italic) dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(colorHex(run.colorHex))\"/></a:solidFill><a:latin typeface=\"\(DOCXXML.escape(run.fontName))\"/></a:rPr><a:t>\(DOCXXML.escape(segment.text))</a:t></a:r>"
  }

  static func pictureXML(
    _ image: PresentationImageElement, id: Int, size: [Double], relationshipID: String
  ) -> String {
    let frame = sanitizedFrame(image.bounds, size: size)
    let extensionName = normalizedExtension(image.fileExtension)
    let description = image.note.isEmpty
      ? (image.provenance == .fullPageFallback
        ? "Raster fallback: page content that could not be reconstructed as editable."
        : "Image reconstructed from the page.")
      : image.note
    return """
      <p:pic>
      <p:nvPicPr><p:cNvPr id="\(id)" name="\(DOCXXML.escape(image.name))" descr="\(DOCXXML.escape(description))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
      <p:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
      <p:spPr><a:xfrm><a:off x="\(emu(frame[0]))" y="\(emu(frame[1]))"/><a:ext cx="\(emu(frame[2]))" cy="\(emu(frame[3]))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
      </p:pic>

      """
  }

  static func shapeXML(
    _ shape: PresentationShapeElement, id: Int, size: [Double]
  ) -> String {
    let frame = sanitizedFrame(shape.bounds, size: size)
    let name = shape.kind == .rectangle ? "Shape \(id - 1)" : "Line \(id - 1)"
    var paint = ""
    if let fill = shape.fillColorHex {
      paint += "<a:solidFill><a:srgbClr val=\"\(colorHex(fill))\"/></a:solidFill>"
    } else {
      paint += "<a:noFill/>"
    }
    var line = ""
    if let stroke = shape.strokeColorHex {
      line = "<a:ln w=\"\(Int(max(1, shape.lineWidth * PPTPoint.emuPerPoint)))\"><a:solidFill><a:srgbClr val=\"\(colorHex(stroke))\"/></a:solidFill></a:ln>"
    }
    if shape.kind == .line {
      return """
        <p:cxnSp>
        <p:nvCxnSpPr><p:cNvPr id="\(id)" name="\(DOCXXML.escape(name))"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>
        <p:spPr><a:xfrm><a:off x="\(emu(frame[0]))" y="\(emu(frame[1]))"/><a:ext cx="\(emu(max(1, frame[2])))" cy="\(emu(max(1, frame[3])))"/></a:xfrm><a:prstGeom prst="line"><a:avLst/></a:prstGeom>\(line.isEmpty ? "<a:ln w=\"\(Int(max(1, shape.lineWidth * PPTPoint.emuPerPoint)))\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill></a:ln>" : line)</p:spPr>
        </p:cxnSp>

        """
    }
    return """
      <p:sp>
      <p:nvSpPr><p:cNvPr id="\(id)" name="\(DOCXXML.escape(name))"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="\(emu(frame[0]))" y="\(emu(frame[1]))"/><a:ext cx="\(emu(frame[2]))" cy="\(emu(frame[3]))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\(paint)\(line)</p:spPr>
      </p:sp>

      """
  }

  enum PPTPoint {
    static let emuPerPoint = PPTXExport.emuPerPoint
  }

  static func sanitizedFrame(_ bounds: [Double], size: [Double]) -> [Double] {
    guard bounds.count == 4, bounds.allSatisfy(\.isFinite) else {
      return [0, 0, max(1, size[0]), max(1, size[1])]
    }
    let x = max(0, min(bounds[0], size[0] - 1))
    let y = max(0, min(bounds[1], size[1] - 1))
    let width = max(1, min(bounds[2] - bounds[0], size[0] - x))
    let height = max(1, min(bounds[3] - bounds[1], size[1] - y))
    return [x, y, width, height]
  }

  static func emu(_ points: Double) -> Int {
    Int((points * emuPerPoint).rounded())
  }

  static func rotationAttribute(_ degrees: Double) -> String {
    guard abs(degrees) > 0.01, degrees.isFinite else { return "" }
    var value = Int((degrees * 60_000).rounded())
    while value <= -21_600_000 { value += 21_600_000 }
    while value > 21_600_000 { value -= 21_600_000 }
    return " rot=\"\(value)\""
  }

  static func colorHex(_ value: String) -> String {
    let cleaned = value.uppercased().filter { $0.isHexDigit }
    guard cleaned.count >= 6 else { return "000000" }
    return String(cleaned.prefix(6))
  }
}
