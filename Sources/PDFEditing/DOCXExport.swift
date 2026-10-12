import Foundation
import PDFCore

/// P35-002: the two DOCX export modes. `editable` reconstructs reliable
/// paragraphs, styles, lists, tables, and images as editable WordprocessingML;
/// `appearance` renders uncertain regions as labeled appearance elements.
public enum DOCXExportMode: String, Sendable, Equatable {
  case editable
  case appearance
}

/// P35-008/P35-009: one reconstructed paragraph for the document body.
public struct DOCXParagraphInput: Sendable, Equatable {
  public enum Style: Sendable, Equatable {
    case normal
    case heading(level: Int)
  }

  public let text: String
  public let style: Style

  public init(text: String, style: Style = .normal) {
    self.text = text
    self.style = style
  }
}

public struct DOCXExportOptions: Sendable, Equatable {
  public var mode: DOCXExportMode
  public var title: String?
  /// Page size in points; nil uses US Letter.
  public var pageWidth: Double?
  public var pageHeight: Double?
  public var maxParagraphs: Int

  public init(
    mode: DOCXExportMode = .editable, title: String? = nil, pageWidth: Double? = nil,
    pageHeight: Double? = nil, maxParagraphs: Int = 20_000
  ) {
    self.mode = mode
    self.title = title
    self.pageWidth = pageWidth
    self.pageHeight = pageHeight
    self.maxParagraphs = maxParagraphs
  }
}

/// P35-015: bytes for one image request (original bytes or a rendered image).
public struct DOCXImageResource: Sendable, Equatable {
  public let data: Data
  /// `png`, `jpg`, or `jp2`.
  public let fileExtension: String
  public let contentType: String

  public init(data: Data, fileExtension: String, contentType: String) {
    self.data = data
    self.fileExtension = fileExtension
    self.contentType = contentType
  }
}

public typealias DOCXImageResolver = @Sendable (DOCXImageRequest) -> DOCXImageResource?

/// P35-001/P35-003–P35-007/P35-015–P35-019/P35-023: a bounded, deterministic
/// OOXML package. References: ECMA-376 (WordprocessingML) and the PKWARE ZIP
/// APPNOTE; DEFLATE comes from the system Compression framework. Only the
/// parts listed here are ever emitted — no macros, no active content. External
/// relationships exist only for user-visible hyperlinks.
public enum DOCXExport {
  /// P35-028: the canonical fidelity statement every surface uses. DOCX export
  /// is a reconstruction: PDF→DOCX→PDF cannot reproduce the original layout,
  /// fonts, or objects, and the app never claims a perfect round trip.
  public static let fidelityDisclosure =
    "DOCX export reconstructs the document as editable content; it is not a perfect round trip and cannot reproduce the original layout, fonts, or objects. The PDF is not modified."

  public static let contentTypesPart = "[Content_Types].xml"
  public static let packageRelationshipsPart = "_rels/.rels"
  public static let documentPart = "word/document.xml"
  public static let documentRelationshipsPart = "word/_rels/document.xml.rels"
  public static let stylesPart = "word/styles.xml"
  public static let settingsPart = "word/settings.xml"
  public static let numberingPart = "word/numbering.xml"
  public static let headerPart = "word/header1.xml"
  public static let footerPart = "word/footer1.xml"

  public static let emittedParts = [
    contentTypesPart, packageRelationshipsPart, documentPart, documentRelationshipsPart,
    stylesPart, settingsPart, numberingPart,
  ]

  /// Bounds for media and relationships.
  public static let maxImages = 500
  public static let maxImageBytes = 16 * 1_024 * 1_024
  public static let maxMediaBytes = 64 * 1_024 * 1_024

  public static func package(
    paragraphs: [DOCXParagraphInput], options: DOCXExportOptions = .init(),
    zipLimits: ZIPArchiveWriter.Limits = .init()
  ) throws -> Data {
    guard paragraphs.count <= options.maxParagraphs else {
      throw PDFError(.limitExceeded, "The document exceeds the paragraph-count limit")
    }
    for paragraph in paragraphs where paragraph.text.utf8.count > 1_048_576 {
      throw PDFError(.limitExceeded, "A paragraph exceeds the text-size limit")
    }
    let reconstruction = DOCXReconstruction(
      blocks: paragraphs.map { paragraph in
        switch paragraph.style {
        case .normal:
          return DOCXBlock(kind: .paragraph, runs: [DOCXRunInput(text: paragraph.text)])
        case .heading(let level):
          return DOCXBlock(
            kind: .heading(level: level), runs: [DOCXRunInput(text: paragraph.text)])
        }
      },
      pageWidth: options.pageWidth ?? 612, pageHeight: options.pageHeight ?? 792,
      landscape: (options.pageWidth ?? 612) > (options.pageHeight ?? 792), limitations: [])
    return try package(reconstruction: reconstruction, options: options, zipLimits: zipLimits)
  }

  /// P35-008–P35-019: package a reconstructed document with inline runs,
  /// lists, tables, images, hyperlinks, headers/footers, and geometry.
  public static func package(
    reconstruction: DOCXReconstruction, options: DOCXExportOptions = .init(),
    imageResolver: DOCXImageResolver? = nil, zipLimits: ZIPArchiveWriter.Limits = .init()
  ) throws -> Data {
    guard reconstruction.blocks.count <= options.maxParagraphs else {
      throw PDFError(.limitExceeded, "The document exceeds the block-count limit")
    }

    // Resolve images and hyperlinks into media files and relationships.
    var media: [(name: String, resource: DOCXImageResource)] = []
    var imageRelationships: [String: String] = [:]  // key -> rId
    var totalMediaBytes = 0
    if let imageResolver {
      for block in reconstruction.blocks {
        guard case .image(let request) = block.kind else { continue }
        guard media.count < maxImages else {
          throw PDFError(.limitExceeded, "The document exceeds the image-count limit")
        }
        let key = "\(request.pageIndex)-\(request.name)-\(request.bounds)"
        if imageRelationships[key] != nil { continue }
        guard let resource = imageResolver(request) else { continue }
        guard resource.data.count <= maxImageBytes else {
          throw PDFError(.limitExceeded, "An image exceeds the per-image size limit")
        }
        guard totalMediaBytes + resource.data.count <= maxMediaBytes else {
          throw PDFError(.limitExceeded, "The document exceeds the media size limit")
        }
        totalMediaBytes += resource.data.count
        let name = String(format: "media/image%04d.%@", media.count + 1, resource.fileExtension)
        media.append((name, resource))
        imageRelationships[key] = "rIdImage\(media.count)"
      }
    }
    var hyperlinks: [String: String] = [:]  // URI -> rId
    for block in reconstruction.blocks {
      for run in allRuns(in: block) {
        guard let uri = run.hyperlinkURI, PDFHTMLEscape.safeURI(uri) != nil else { continue }
        if hyperlinks[uri] == nil {
          hyperlinks[uri] = "rIdLink\(hyperlinks.count + 1)"
        }
      }
    }

    let headerFooter = reconstruction.headerFooter
    let hasHeader = headerFooter.header != nil
    let hasFooter = headerFooter.footer != nil

    var zip = ZIPArchiveWriter(limits: zipLimits)
    try zip.add(
      name: contentTypesPart,
      data: contentTypes(hasHeader: hasHeader, hasFooter: hasFooter, media: media))
    try zip.add(name: packageRelationshipsPart, data: packageRelationships())
    try zip.add(
      name: documentPart,
      data: document(
        reconstruction: reconstruction, imageRelationships: imageRelationships,
        hyperlinks: hyperlinks, hasHeader: hasHeader, hasFooter: hasFooter))
    try zip.add(
      name: documentRelationshipsPart,
      data: documentRelationships(
        media: media, hyperlinks: hyperlinks, hasHeader: hasHeader, hasFooter: hasFooter))
    try zip.add(name: stylesPart, data: styles())
    try zip.add(name: settingsPart, data: settings())
    try zip.add(name: numberingPart, data: numbering())
    if let header = headerFooter.header {
      try zip.add(name: headerPart, data: headerFooterXML(kind: "hdr", runs: header))
    }
    if let footer = headerFooter.footer {
      try zip.add(name: footerPart, data: headerFooterXML(kind: "ftr", runs: footer))
    }
    for entry in media {
      try zip.add(name: "word/\(entry.name)", data: entry.resource.data)
    }
    return try zip.archive()
  }

  static func allRuns(in block: DOCXBlock) -> [DOCXRunInput] {
    switch block.kind {
    case .table(let rows): return rows.flatMap { $0.flatMap { $0 } }
    default: return block.runs
    }
  }

  // MARK: - Parts

  static func contentTypes(
    hasHeader: Bool = false, hasFooter: Bool = false,
    media: [(name: String, resource: DOCXImageResource)] = []
  ) -> Data {
    var defaults: [String: String] = [:]
    for entry in media { defaults[entry.resource.fileExtension] = entry.resource.contentType }
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>

      """
    for (ext, type) in defaults.sorted(by: { $0.key < $1.key }) {
      xml += "<Default Extension=\"\(ext)\" ContentType=\"\(type)\"/>\n"
    }
    xml += """
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
      <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
      <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
      """
    if hasHeader {
      xml += "<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>\n"
    }
    if hasFooter {
      xml += "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>\n"
    }
    xml += "</Types>\n"
    return Data(xml.utf8)
  }

  static func packageRelationships() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      </Relationships>
      """.utf8)
  }

  static func documentRelationships(
    media: [(name: String, resource: DOCXImageResource)] = [], hyperlinks: [String: String] = [:],
    hasHeader: Bool = false, hasFooter: Bool = false
  ) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>

      """
    if hasHeader {
      xml += "<Relationship Id=\"rIdHeader1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>\n"
    }
    if hasFooter {
      xml += "<Relationship Id=\"rIdFooter1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>\n"
    }
    for entry in media {
      xml +=
        "<Relationship Id=\"\(imageRelationshipID(for: entry.name, in: media))\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(entry.name)\"/>\n"
    }
    for (uri, id) in hyperlinks.sorted(by: { $0.value < $1.value }) {
      xml +=
        "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(DOCXXML.escape(uri))\" TargetMode=\"External\"/>\n"
    }
    xml += "</Relationships>\n"
    return Data(xml.utf8)
  }

  static func imageRelationshipID(
    for name: String, in media: [(name: String, resource: DOCXImageResource)]
  ) -> String {
    if let index = media.firstIndex(where: { $0.name == name }) {
      return "rIdImage\(index + 1)"
    }
    return "rIdImage1"
  }

  static func document(
    reconstruction: DOCXReconstruction, imageRelationships: [String: String],
    hyperlinks: [String: String], hasHeader: Bool, hasFooter: Bool
  ) -> Data {
    let width = Int((reconstruction.pageWidth * 20).rounded())
    let height = Int((reconstruction.pageHeight * 20).rounded())
    let orientation = reconstruction.landscape ? " w:orient=\"landscape\"" : ""
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
      <w:body>

      """
    var pictureIndex = 0
    var bookmarkID = 0
    for block in reconstruction.blocks {
      switch block.kind {
      case .image(let request):
        let key = "\(request.pageIndex)-\(request.name)-\(request.bounds)"
        if let relationship = imageRelationships[key] {
          pictureIndex += 1
          xml += imageXML(
            request: request, relationshipID: relationship, pictureIndex: pictureIndex)
        }
      case .table(let rows):
        xml += tableXML(rows: rows, spans: block.spans, hyperlinks: hyperlinks)
      default:
        var blockXML = self.blockXML(
          block, hyperlinks: hyperlinks, pageWidth: reconstruction.pageWidth,
          pageHeight: reconstruction.pageHeight, landscape: reconstruction.landscape)
        if let bookmark = block.bookmark {
          bookmarkID += 1
          blockXML =
            "<w:bookmarkStart w:id=\"\(bookmarkID)\" w:name=\"\(DOCXXML.escape(bookmark))\"/>"
            + blockXML
            + "<w:bookmarkEnd w:id=\"\(bookmarkID)\"/>\n"
        }
        xml += blockXML
      }
    }
    xml += "<w:sectPr>"
    if hasHeader {
      xml += "<w:headerReference w:type=\"default\" r:id=\"rIdHeader1\"/>"
    }
    if hasFooter {
      xml += "<w:footerReference w:type=\"default\" r:id=\"rIdFooter1\"/>"
    }
    if reconstruction.columns > 1 {
      xml += "<w:cols w:num=\"\(reconstruction.columns)\"/>"
    }
    xml += "<w:pgSz w:w=\"\(width)\" w:h=\"\(height)\"\(orientation)/>"
    xml += "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr>\n"
    xml += "</w:body>\n</w:document>\n"
    return Data(xml.utf8)
  }

  static func blockXML(
    _ block: DOCXBlock, hyperlinks: [String: String] = [:],
    pageWidth: Double = 612, pageHeight: Double = 792, landscape: Bool = false
  ) -> String {
    switch block.kind {
    case .pageBreak:
      return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>\n"
    case .sectionBreak(let columns):
      // A section break ends the previous page's section; Word implies the
      // page break at the section boundary.
      return "<w:p><w:pPr>\(sectionPropertiesXML(columns: columns, pageWidth: pageWidth, pageHeight: pageHeight, landscape: landscape))</w:pPr></w:p>\n"
    default:
      break
    }
    // WordprocessingML requires pPr children in schema order:
    // pStyle/numPr, bidi, spacing, ind, jc.
    var properties = ""
    switch block.kind {
    case .heading(let level):
      properties += "<w:pStyle w:val=\"Heading\(min(max(level, 1), 6))\"/>"
    case .listItem(let level, let ordered):
      properties +=
        "<w:numPr><w:ilvl w:val=\"\(max(0, min(level, 2)))\"/><w:numId w:val=\"\(ordered ? 2 : 1)\"/></w:numPr>"
    default:
      break
    }
    if block.rtl { properties += "<w:bidi/>" }
    if block.lineSpacing > 1 {
      properties +=
        "<w:spacing w:line=\"\(Int((block.lineSpacing * 20).rounded()))\" w:lineRule=\"exact\"/>"
    }
    if block.firstLineIndent > 1 {
      properties += "<w:ind w:firstLine=\"\(Int((block.firstLineIndent * 20).rounded()))\"/>"
    }
    switch block.alignment {
    case .center: properties += "<w:jc w:val=\"center\"/>"
    case .right: properties += "<w:jc w:val=\"right\"/>"
    case .justified: properties += "<w:jc w:val=\"both\"/>"
    case .left: break
    }
    var xml = "<w:p>"
    if !properties.isEmpty { xml += "<w:pPr>\(properties)</w:pPr>" }
    xml += runsXML(block.runs, hyperlinks: hyperlinks)
    xml += "</w:p>\n"
    return xml
  }

  /// P35-014: a section's geometry and column count.
  static func sectionPropertiesXML(
    columns: Int, pageWidth: Double, pageHeight: Double, landscape: Bool
  ) -> String {
    let width = Int((pageWidth * 20).rounded())
    let height = Int((pageHeight * 20).rounded())
    let orientation = landscape ? " w:orient=\"landscape\"" : ""
    var xml = "<w:sectPr>"
    if columns > 1 { xml += "<w:cols w:num=\"\(columns)\"/>" }
    xml += "<w:pgSz w:w=\"\(width)\" w:h=\"\(height)\"\(orientation)/>"
    xml += "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/>"
    xml += "</w:sectPr>"
    return xml
  }

  static func runsXML(_ runs: [DOCXRunInput], hyperlinks: [String: String]) -> String {
    var xml = ""
    var index = 0
    while index < runs.count {
      let run = runs[index]
      if let uri = run.hyperlinkURI, let id = hyperlinks[uri] {
        var group: [DOCXRunInput] = []
        while index < runs.count, runs[index].hyperlinkURI == uri {
          group.append(runs[index])
          index += 1
        }
        xml += "<w:hyperlink r:id=\"\(id)\">"
        for member in group { xml += runXML(member) }
        xml += "</w:hyperlink>"
        continue
      }
      if let anchor = run.anchor {
        var group: [DOCXRunInput] = []
        while index < runs.count, runs[index].anchor == anchor {
          group.append(runs[index])
          index += 1
        }
        xml += "<w:hyperlink w:anchor=\"\(DOCXXML.escape(anchor))\">"
        for member in group { xml += runXML(member) }
        xml += "</w:hyperlink>"
        continue
      }
      xml += runXML(run)
      index += 1
    }
    return xml
  }

  static func runXML(_ run: DOCXRunInput) -> String {
    // Schema order: rFonts, b, i, color, sz, rtl, lang.
    var properties = ""
    if let family = run.fontFamily {
      properties +=
        "<w:rFonts w:ascii=\"\(DOCXXML.escape(family))\" w:hAnsi=\"\(DOCXXML.escape(family))\"/>"
    }
    if run.bold { properties += "<w:b/>" }
    if run.italic { properties += "<w:i/>" }
    if let color = run.colorHex { properties += "<w:color w:val=\"\(color)\"/>" }
    if let size = run.sizePoints {
      properties += "<w:sz w:val=\"\(Int((size * 2).rounded()))\"/>"
    }
    if run.rtl { properties += "<w:rtl/>" }
    if let language = run.language {
      properties += "<w:lang w:val=\"\(DOCXXML.escape(language))\"/>"
    }
    let text = DOCXXML.escape(run.text)
    if let field = run.field {
      return
        "<w:fldSimple w:instr=\"\(DOCXXML.escape(field))\"><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:fldSimple>"
    }
    var xml = "<w:r>"
    if !properties.isEmpty { xml += "<w:rPr>\(properties)</w:rPr>" }
    let lines = text.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      if index > 0 { xml += "<w:br/>" }
      xml += "<w:t xml:space=\"preserve\">\(line)</w:t>"
    }
    xml += "</w:r>"
    return xml
  }

  static func imageXML(
    request: DOCXImageRequest, relationshipID: String, pictureIndex: Int
  ) -> String {
    let width = max(1, request.bounds[2] - request.bounds[0])
    let height = max(1, request.bounds[3] - request.bounds[1])
    let cx = Int((width * 12_700).rounded())
    let cy = Int((height * 12_700).rounded())
    let payload = """
      <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(pictureIndex)" name="Picture \(pictureIndex)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(pictureIndex)" name="Picture \(pictureIndex)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>
      """
    switch request.wrap {
    case .inline:
      return """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\(payload)</wp:inline></w:drawing></w:r></w:p>

        """
    case .squareBehind, .squareInFront:
      // P35-032: an anchored drawing with square wrapping. The position is
      // relative to the page (column and paragraph offsets approximated from
      // the placement bounds); draw order decides behind/in front.
      let behind = request.wrap == .squareBehind ? "1" : "0"
      let x = Int((request.bounds[0] * 12_700).rounded())
      let y = Int(((792 - request.bounds[3]) * 12_700).rounded())
      return """
        <w:p><w:r><w:drawing><wp:anchor distT="0" distB="0" distL="114300" distR="114300" simplePos="0" relativeHeight="\(pictureIndex)" behindDoc="\(behind)" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>\(x)</wp:posOffset></wp:positionH><wp:positionV relativeFrom="page"><wp:posOffset>\(y)</wp:posOffset></wp:positionV>\(payload)<wp:wrapSquare wrapText="bothSides"/></wp:anchor></w:drawing></w:r></w:p>

        """
    }
  }

  /// P35-031: emit merged cells with `w:gridSpan`/`w:vMerge` so spans survive
  /// into WordprocessingML.
  static func tableXML(
    rows: [[[DOCXRunInput]]], spans: [DOCXTableSpan] = [], hyperlinks: [String: String]
  ) -> String {
    var xml =
      "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
    for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
      xml += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
    }
    xml += "</w:tblBorders></w:tblPr>"
    for (rowIndex, row) in rows.enumerated() {
      xml += "<w:tr>"
      for (columnIndex, cell) in row.enumerated() {
        let starting = spans.first {
          $0.row == rowIndex && $0.column == columnIndex
        }
        let coveredVertically = spans.contains {
          $0.row < rowIndex && rowIndex < $0.row + $0.rowSpan
            && columnIndex >= $0.column && columnIndex < $0.column + $0.columnSpan
        }
        if coveredVertically {
          // A vertical continuation cell keeps the grid aligned.
          xml += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/><w:vMerge/></w:tcPr><w:p/></w:tc>"
          continue
        }
        let coveredHorizontally = spans.contains {
          $0.column < columnIndex && columnIndex < $0.column + $0.columnSpan
            && rowIndex >= $0.row && rowIndex < $0.row + $0.rowSpan
        }
        if coveredHorizontally { continue }
        var cellProperties = "<w:tcW w:w=\"0\" w:type=\"auto\"/>"
        if let starting {
          if starting.columnSpan > 1 {
            cellProperties += "<w:gridSpan w:val=\"\(starting.columnSpan)\"/>"
          }
          if starting.rowSpan > 1 {
            cellProperties += "<w:vMerge w:val=\"restart\"/>"
          }
        }
        xml += "<w:tc><w:tcPr>\(cellProperties)</w:tcPr><w:p>"
        xml += runsXML(cell, hyperlinks: hyperlinks)
        xml += "</w:p></w:tc>"
      }
      xml += "</w:tr>"
    }
    xml += "</w:tbl>\n<w:p/>\n"
    return xml
  }

  static func headerFooterXML(kind: String, runs: [DOCXRunInput]) -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:\(kind) xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p>\(runsXML(runs, hyperlinks: [:]))</w:p></w:\(kind)>
      """.utf8)
  }

  static func document(reconstruction: DOCXReconstruction) -> Data {
    document(
      reconstruction: reconstruction, imageRelationships: [:], hyperlinks: [:], hasHeader: false,
      hasFooter: false)
  }

  static func styles() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
      </w:styles>
      """.utf8)
  }

  static func numbering() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/></w:lvl></w:abstractNum>
      <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/></w:lvl></w:abstractNum>
      <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
      <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
      </w:numbering>
      """.utf8)
  }

  static func settings() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:zoom w:percent="100"/>
      <w:defaultTabStop w:val="720"/>
      </w:settings>
      """.utf8)
  }
}

/// P35-005: safe UTF-8 XML escaping with invalid characters removed, so part
/// generation is deterministic and never emits malformed XML.
public enum DOCXXML {
  public static func escape(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
      default:
        // XML 1.0 allows #x9 #xA #xD and #x20..#xD7FF/#xE000..#xFFFD.
        if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
          continue
        }
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
