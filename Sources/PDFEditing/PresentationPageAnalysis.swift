import Foundation
import PDFCore

/// EXP-03: one text element planned from the page's reconstructed paragraph
/// candidates. Bounds are unrotated page coordinates (points, bottom-left
/// origin); the presentation service converts them to slide coordinates.
public struct PresentationPlannedText: Sendable, Equatable {
  public let text: String
  public let bounds: [Double]
  public let fontSize: Double
  public let fontName: String
  public let bold: Bool
  public let italic: Bool
  public let colorHex: String
  public let alignment: PresentationTextAlignment
  /// Clockwise rotation in degrees for the slide (PDF counter-clockwise angle
  /// inverted). 0 for ordinary horizontal text.
  public let rotationDegrees: Double

  public init(
    text: String, bounds: [Double], fontSize: Double, fontName: String,
    bold: Bool, italic: Bool, colorHex: String,
    alignment: PresentationTextAlignment, rotationDegrees: Double
  ) {
    self.text = text
    self.bounds = bounds
    self.fontSize = fontSize
    self.fontName = fontName
    self.bold = bold
    self.italic = italic
    self.colorHex = colorHex
    self.alignment = alignment
    self.rotationDegrees = rotationDegrees
  }
}

/// EXP-03: one image placement planned for a picture element.
public struct PresentationPlannedImage: Sendable, Equatable {
  public let name: String
  public let bounds: [Double]
  public let encodedData: Data
  /// True when the stored bytes can be embedded as a picture directly (a
  /// standalone JPEG). Otherwise the presentation service renders the region.
  public let canUseOriginalBytes: Bool
  /// jpeg when the original bytes are used; png for a rendered region.
  public let fileExtension: String
  public let note: String

  public init(
    name: String, bounds: [Double], encodedData: Data, canUseOriginalBytes: Bool,
    fileExtension: String, note: String
  ) {
    self.name = name
    self.bounds = bounds
    self.encodedData = encodedData
    self.canUseOriginalBytes = canUseOriginalBytes
    self.fileExtension = fileExtension
    self.note = note
  }
}

public struct PresentationPlannedShape: Sendable, Equatable {
  public let kind: PresentationShapeKind
  public let bounds: [Double]
  public let fillColorHex: String?
  public let strokeColorHex: String?
  public let lineWidth: Double
  public let note: String

  public init(
    kind: PresentationShapeKind, bounds: [Double], fillColorHex: String?,
    strokeColorHex: String?, lineWidth: Double, note: String
  ) {
    self.kind = kind
    self.bounds = bounds
    self.fillColorHex = fillColorHex
    self.strokeColorHex = strokeColorHex
    self.lineWidth = lineWidth
    self.note = note
  }
}

public enum PresentationPlannedElement: Sendable, Equatable {
  case text(PresentationPlannedText)
  case image(PresentationPlannedImage)
  case shape(PresentationPlannedShape)
}

/// EXP-03: the reconstruction decision for one page. A page with any
/// content outside the reconstructible profile is exported as one labelled
/// raster fallback instead of silently dropping objects or approximating them.
public struct PresentationPagePlan: Sendable, Equatable {
  public let pageIndex: Int
  public let pageID: PDFObjectID
  /// Page size in points (CropBox width and height, unrotated).
  public let size: [Double]
  /// CropBox origin and size, used to map page coordinates to the slide.
  public let cropBox: [Double]
  public let elements: [PresentationPlannedElement]
  public let unsupportedReasons: [String]

  public init(
    pageIndex: Int, pageID: PDFObjectID, size: [Double], cropBox: [Double],
    elements: [PresentationPlannedElement], unsupportedReasons: [String]
  ) {
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.size = size
    self.cropBox = cropBox
    self.elements = elements
    self.unsupportedReasons = unsupportedReasons
  }

  public var requiresRasterFallback: Bool { !unsupportedReasons.isEmpty }
}

/// EXP-03: page analysis over the existing reconstruction inventories. Only
/// ordinary page content is analyzed: text runs with a supported transform,
/// image placements, and rectangle/line vector objects with solid paint.
/// Everything else is reported explicitly so the service can render a
/// labelled raster fallback.
public enum PresentationPageAnalyzer {
  public static let maximumReasons = 12
  public static let maximumTextElements = 2_000
  public static let maximumImageElements = 500
  public static let maximumShapeElements = 2_000

  /// Operators that do not by themselves prevent an editable reconstruction.
  static let supportedOperators: Set<String> = [
    "q", "Q", "cm", "w", "J", "j", "M", "d", "ri", "i",
    "g", "G", "rg", "RG", "k", "K", "cs", "CS", "sc", "scn", "SC", "SCN",
    "BT", "ET", "Tf", "Td", "TD", "Tm", "T*", "TL", "Tc", "Tw", "Tz", "Ts",
    "Tr", "Tj", "TJ", "'", "\"",
    "m", "l", "c", "v", "y", "re", "h",
    "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n",
    "W", "W*", "BMC", "BDC", "EMC", "MP", "DP", "BX", "EX", "Do",
  ]

  /// Operators that explicitly cannot be reconstructed and force a fallback.
  static let unsupportedOperators: [String: String] = [
    "sh": "Shading gradients are not reconstructed as editable shapes.",
    "gs": "Extended graphics state (transparency or rendering intent) is not reconstructed.",
    "BI": "Inline images are not reconstructed.",
    "ID": "Inline images are not reconstructed.",
    "EI": "Inline images are not reconstructed.",
  ]

  public static func analyze(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PresentationPagePlan {
    let cropBox = pageBox(of: pageID, in: graph) ?? [0, 0, 612, 792]
    let size = [max(1, cropBox[2] - cropBox[0]), max(1, cropBox[3] - cropBox[1])]
    var reasons: [String] = []

    if let rotation = pageRotation(of: pageID, in: graph), rotation % 360 != 0 {
      reasons.append("Page rotation is not reconstructed; the page is a raster fallback.")
    }
    if pageHasAnnotations(pageID: pageID, in: graph) {
      reasons.append("Page annotations are not reconstructed; the page is a raster fallback.")
    }

    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let images = try PDFImageInventory.images(in: graph, pageIDs: [pageID])
    let imageNames = Set(images.map(\.name))
    var textShowCount = 0
    var sawInlineImage = false
    for instruction in content.instructions {
      let name = instruction.operatorName
      if ["Tj", "TJ", "'", "\""].contains(name) { textShowCount += 1 }
      if name == "BI" { sawInlineImage = true }
      if let reason = unsupportedOperators[name] {
        if name != "ID", name != "EI" { reasons.append(reason) }
        continue
      }
      if name == "Do" {
        if let operand = instruction.operands.first,
          case .name(let resource) = operand.value
        {
          let resourceName = String(decoding: resource.bytes, as: UTF8.self)
          if !imageNames.contains(resourceName) {
            reasons.append(
              "The page draws a non-image XObject (\(resourceName)), for example a "
                + "reusable form, that is not reconstructed.")
          }
        } else {
          reasons.append("A page XObject could not be identified and is not reconstructed.")
        }
        continue
      }
      if !supportedOperators.contains(name) {
        reasons.append("The page uses a content operator that is not reconstructed: \(name).")
      }
    }
    if sawInlineImage {
      // The dedicated reasons above already mention inline images.
    }

    var elements: [PresentationPlannedElement] = []

    // Shapes: solid-painted rectangle and line vector objects.
    let refusals = try VectorObjectInventory.refusals(pageID: pageID, in: graph)
    for refusal in refusals.prefix(3) {
      // The vector profile also reports image and form XObjects as outside its
      // edit profile; images are reconstructed as pictures and non-image form
      // XObjects are detected by the content scan above, so only other paint
      // kinds force a fallback here.
      if refusal.reason.contains("Reusable form XObjects and images") { continue }
      reasons.append("Vector paint outside the reconstructible profile: \(refusal.reason)")
    }
    let selectable = try VectorObjectInventory.selectable(pageID: pageID, in: graph)
    var shapes: [PresentationPlannedElement] = []
    for object in selectable {
      let snapshot = object.style
      if snapshot.selfClipping || snapshot.inheritedClip
        || snapshot.inheritedTransparencyState || snapshot.patternFill
        || snapshot.patternStroke
      {
        reasons.append(
          "A vector object uses clipping, transparency or pattern paint and is not reconstructed.")
        continue
      }
      let operators: [String]
      do {
        let resolved = try VectorObjectSupport.resolve(object.id, in: graph)
        operators = resolved.pathInstructions.map(\.operatorName)
      } catch {
        reasons.append("A vector object's path could not be resolved for reconstruction.")
        continue
      }
      if !operators.isEmpty, operators.allSatisfy({ $0 == "re" }) {
        shapes.append(
          .shape(
            PresentationPlannedShape(
              kind: .rectangle, bounds: object.bounds,
              fillColorHex: object.paintKind.hasFill ? hex(object.style.fillColor) : nil,
              strokeColorHex: object.paintKind.hasStroke
                ? hex(object.style.strokeColor) : nil,
              lineWidth: object.style.lineWidth,
              note: "Rectangle reconstructed as an editable shape.")))
      } else if object.paintKind == .stroke,
        operators.allSatisfy({ ["m", "l", "h"].contains($0) }),
        operators.filter({ $0 == "m" || $0 == "l" }).count == 2,
        object.bounds.count == 4
      {
        shapes.append(
          .shape(
            PresentationPlannedShape(
              kind: .line, bounds: object.bounds, fillColorHex: nil,
              strokeColorHex: hex(object.style.strokeColor) ?? "000000",
              lineWidth: max(1, object.style.lineWidth),
              note: "Line reconstructed as an editable connector.")))
      } else {
        reasons.append(
          "A vector path is not a rectangle or line and is not reconstructed as a shape.")
      }
    }
    if shapes.count > maximumShapeElements {
      reasons.append("The page has more vector objects than the export reconstructs.")
      shapes = []
    }
    elements.append(contentsOf: shapes)

    // Images: standalone JPEGs keep their bytes; everything else is rendered.
    var plannedImages: [PresentationPlannedElement] = []
    for image in images {
      guard image.bounds.count == 4, image.bounds.allSatisfy(\.isFinite),
        image.bounds[2] > image.bounds[0], image.bounds[3] > image.bounds[1]
      else {
        reasons.append("An image placement has unusable bounds and is not reconstructed.")
        continue
      }
      let direct = image.isStandaloneJPEG
      let note: String
      if direct {
        note = "Original JPEG bytes embedded as an editable picture."
      } else if image.hasSMask || image.isImageMask || image.softMaskObjectID != nil
        || image.hasColorKeyMask || image.hasExplicitMask
      {
        note = "Rendered region: the image uses a mask or transform that cannot be "
          + "embedded directly; the appearance is preserved as a picture."
      } else {
        note = "Rendered region: the stored image codec or colour space cannot be "
          + "embedded directly; the appearance is preserved as a picture."
      }
      plannedImages.append(
        .image(
          PresentationPlannedImage(
            name: image.name, bounds: image.bounds, encodedData: image.encodedData,
            canUseOriginalBytes: direct, fileExtension: direct ? "jpeg" : "png",
            note: note)))
    }
    if plannedImages.count > maximumImageElements {
      reasons.append("The page has more images than the export reconstructs.")
      plannedImages = []
    }
    elements.append(contentsOf: plannedImages)

    // Text: paragraph candidates with a supported transform.
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    let candidates = try ParagraphReconstruction.candidates(
      pageID: pageID, in: graph, layout: layout, roles: [:])
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    var plannedTexts: [PresentationPlannedElement] = []
    for candidate in candidates {
      let trimmed = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let transform = transformProfile(
        candidate: candidate, runs: runs)
      guard let transform else {
        reasons.append(
          "A text run uses a skew, non-uniform scale or unsupported font transform and is "
            + "not reconstructed.")
        continue
      }
      let style = candidate.runStyles.first
      let baseFont = style?.baseFont ?? ""
      var bounds = candidate.bounds
      let lineCount = Double(max(1, candidate.lineIndices.count))
      if bounds.count == 4 {
        let fontSize = max(1, candidate.fontSize)
        var width = bounds[2] - bounds[0]
        var height = bounds[3] - bounds[1]
        if width < 1 {
          width = max(1, fontSize * 0.5 * Double(trimmed.count))
        }
        if height < fontSize * 0.5 {
          height = fontSize * 1.2 * lineCount
        }
        bounds = [bounds[0], bounds[1], bounds[0] + width, bounds[1] + height]
      } else {
        bounds = [0, 0, 0, 0]
      }
      plannedTexts.append(
        .text(
          PresentationPlannedText(
            text: trimmed, bounds: bounds,
            fontSize: max(1, style?.fontSize ?? candidate.fontSize),
            fontName: baseFont.isEmpty ? "Helvetica" : baseFont,
            bold: baseFont.lowercased().contains("bold")
              || baseFont.lowercased().contains("black")
              || baseFont.lowercased().contains("heavy"),
            italic: baseFont.lowercased().contains("italic")
              || baseFont.lowercased().contains("oblique"),
            colorHex: hex(style?.fillColor ?? [0, 0, 0]),
            alignment: alignment(candidate.alignment),
            rotationDegrees: transform.clockwiseDegrees)))
    }
    if plannedTexts.count > maximumTextElements {
      reasons.append("The page has more text lines than the export reconstructs.")
      plannedTexts = []
    }
    if textShowCount > 0, candidates.isEmpty, plannedTexts.isEmpty, reasons.isEmpty {
      // Text operators exist but no paragraph could be reconstructed; relying
      // on an empty editable slide would silently drop the text.
      reasons.append(
        "The page shows text but no paragraph could be reconstructed; the page is a "
          + "raster fallback.")
    }
    elements.append(contentsOf: plannedTexts)

    var uniqueReasons: [String] = []
    var seen = Set<String>()
    for reason in reasons where seen.insert(reason).inserted {
      uniqueReasons.append(reason)
    }
    if uniqueReasons.count > maximumReasons {
      uniqueReasons = Array(uniqueReasons.prefix(maximumReasons))
        + ["Additional unsupported content was omitted from this report."]
    }
    let plan = PresentationPagePlan(
      pageIndex: pageIndex, pageID: pageID, size: size, cropBox: cropBox,
      elements: uniqueReasons.isEmpty ? elements : [], unsupportedReasons: uniqueReasons)
    return plan
  }

  struct TransformProfile: Sendable {
    let clockwiseDegrees: Double
  }

  /// Only pure rotation with a positive uniform scale (and ordinary horizontal
  /// text) are reliably reconstructible as editable text boxes.
  static func transformProfile(
    candidate: TextParagraphCandidate, runs: [TextRun]
  ) -> TransformProfile? {
    guard let runIndex = candidate.runIndices.first,
      runIndex >= 0, runIndex < runs.count
    else {
      return TransformProfile(clockwiseDegrees: 0)
    }
    let run = runs[runIndex]
    let matrix = TextCanvasSupport.concatenate(run.ctm, run.matrix)
    guard matrix.count == 6, matrix.allSatisfy(\.isFinite) else { return nil }
    let scaleX = hypot(matrix[0], matrix[1])
    let scaleY = hypot(matrix[2], matrix[3])
    guard scaleX > 1e-6 else { return nil }
    let tolerance = max(1e-4, scaleX * 1e-3)
    guard abs(scaleX - scaleY) <= tolerance,
      abs(matrix[0] * matrix[2] + matrix[1] * matrix[3]) <= tolerance * scaleX,
      matrix[0] * matrix[3] - matrix[1] * matrix[2] > 0
    else {
      return nil
    }
    var degrees = atan2(matrix[1], matrix[0]) * 180 / .pi
    if degrees > 180 { degrees -= 360 }
    if degrees <= -180 { degrees += 360 }
    if abs(degrees) < 0.05 { degrees = 0 }
    return TransformProfile(clockwiseDegrees: -degrees)
  }

  static func alignment(_ alignment: TextParagraphCandidate.Alignment)
    -> PresentationTextAlignment
  {
    switch alignment {
    case .left: return .left
    case .center: return .center
    case .right: return .right
    case .justified: return .justified
    }
  }

  /// 1, 3 or 4 components in 0...1 to uppercase RRGGBB.
  static func hex(_ components: [Double]?) -> String {
    guard let components, !components.isEmpty else { return "000000" }
    let red = components.count >= 3 ? components[0] : components[0]
    let green = components.count >= 3 ? components[1] : components[0]
    let blue = components.count >= 3 ? components[2] : components[0]
    func channel(_ value: Double) -> Int {
      Int((max(0, min(value, 1)) * 255).rounded())
    }
    return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
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
        if numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] {
          return numbers
        }
      }
    }
    return nil
  }

  static func pageRotation(of pageID: PDFObjectID, in graph: PDFGraph) -> Int? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    if case .integer(let rotation)? = page[PDFName("Rotate")] { return Int(rotation) }
    return nil
  }

  static func pageHasAnnotations(pageID: PDFObjectID, in graph: PDFGraph) -> Bool {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return false }
    switch page[PDFName("Annots")] {
    case .array(let values)?: return !values.isEmpty
    case .reference(let id)?:
      if case .array(let values)? = graph.objects[id] { return !values.isEmpty }
      return true
    default: return false
    }
  }
}
