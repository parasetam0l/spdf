import Foundation
import PDFCore

/// OCR-05: bounded reader for our own generated searchable layer. The layer
/// writer emits only q/BT/ET/Q, 3 Tr, font size Tf, Tm and a single hex Tj per
/// line; any other operator means a foreign layer and reconstruction refuses
/// instead of guessing.
public enum ScannedTextLayerReader {
  public struct Line: Sendable, Equatable {
    public let text: String
    public let x: Double
    public let y: Double
    public let fontSize: Double

    public init(text: String, x: Double, y: Double, fontSize: Double) {
      self.text = text
      self.x = x
      self.y = y
      self.fontSize = fontSize
    }

    /// SearchableTextLine rectangle used when the layer is rebuilt. The layer
    /// font has a 1000-unit advance, so content width is glyphCount * fontSize.
    public var searchableRect: [Double] {
      let width = Double(text.utf16.count) * fontSize
      return [x, y, x + max(width, fontSize), y + fontSize]
    }
  }

  public static func lines(pageID: PDFObjectID, in graph: PDFGraph) throws -> [Line] {
    let streamIDs = OCRLayer.layerStreamIDs(in: graph, pageID: pageID)
    guard !streamIDs.isEmpty else {
      throw PDFError(.malformed, "This page has no generated searchable text layer")
    }
    var result: [Line] = []
    for streamID in streamIDs {
      guard case .stream(let stream)? = graph.objects[streamID] else {
        throw PDFError(.malformed, "The searchable text layer stream is missing")
      }
      let decoded = (try? PDFFilters.decoded(stream)) ?? stream.bytes
      result.append(contentsOf: try parse(decoded))
    }
    return result
  }

  public static func lineTexts(pageID: PDFObjectID, in graph: PDFGraph) throws -> [String] {
    try lines(pageID: pageID, in: graph).map(\.text)
  }

  enum Token: Equatable {
    case number(Double)
    case name(String)
    case hex([UInt8])
    case op(String)
  }

  static func parse(_ data: Data) throws -> [Line] {
    let bytes = [UInt8](data)
    var tokens: [Token] = []
    var index = 0
    func skipWhitespace() {
      while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C
          || byte == 0x00
        {
          index += 1
        } else {
          break
        }
      }
    }
    while true {
      skipWhitespace()
      guard index < bytes.count else { break }
      let byte = bytes[index]
      if byte == 0x3C { // <
        index += 1
        var hex: [UInt8] = []
        var digits = ""
        while index < bytes.count, bytes[index] != 0x3E { // >
          let character = Character(UnicodeScalar(bytes[index]))
          if character.isHexDigit {
            digits.append(character)
            if digits.count == 2 {
              if let value = UInt8(digits, radix: 16) { hex.append(value) }
              digits = ""
            }
          }
          index += 1
        }
        guard digits.isEmpty else {
          throw PDFError(.malformed, "The searchable text layer has a malformed hex string")
        }
        index += 1
        tokens.append(.hex(hex))
        continue
      }
      if byte == 0x2F { // /
        index += 1
        var nameBytes: [UInt8] = []
        while index < bytes.count,
          bytes[index] != 0x20, bytes[index] != 0x0A, bytes[index] != 0x0D,
          bytes[index] != 0x09
        {
          nameBytes.append(bytes[index])
          index += 1
        }
        tokens.append(.name(String(decoding: nameBytes, as: UTF8.self)))
        continue
      }
      if byte == 0x28 { // ( literal string; our writer never emits one
        throw PDFError(.unsupported, "The searchable text layer uses a literal string")
      }
      var wordBytes: [UInt8] = []
      while index < bytes.count,
        bytes[index] != 0x20, bytes[index] != 0x0A, bytes[index] != 0x0D,
        bytes[index] != 0x09, bytes[index] != 0x3C, bytes[index] != 0x3E
      {
        wordBytes.append(bytes[index])
        index += 1
      }
      let word = String(decoding: wordBytes, as: UTF8.self)
      guard !word.isEmpty else {
        index += 1
        continue
      }
      if let number = Double(word), !word.hasPrefix("/") {
        tokens.append(.number(number))
      } else if word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
        tokens.append(.op(word))
      } else {
        throw PDFError(.malformed, "The searchable text layer has an unsupported token")
      }
    }

    var lines: [Line] = []
    var fontSize = 12.0
    var textX: Double?
    var textY: Double?
    for tokenIndex in tokens.indices {
      guard case .op(let op) = tokens[tokenIndex] else { continue }
      switch op {
      case "q", "Q", "BT", "ET", "Tr":
        continue
      case "Tf":
        guard tokenIndex >= 2, case .number(let size) = tokens[tokenIndex - 1] else {
          throw PDFError(.malformed, "The searchable text layer lost its font size")
        }
        fontSize = size
      case "Tm":
        var numbers: [Double] = []
        var cursor = tokenIndex - 1
        while cursor >= 0, numbers.count < 6 {
          if case .number(let value) = tokens[cursor] { numbers.append(value) }
          cursor -= 1
        }
        guard numbers.count == 6 else {
          throw PDFError(.malformed, "The searchable text layer lost its text matrix")
        }
        numbers.reverse()
        textX = numbers[4]
        textY = numbers[5]
      case "Tj":
        guard tokenIndex >= 1, case .hex(let payload) = tokens[tokenIndex - 1],
          let x = textX, let y = textY
        else {
          throw PDFError(.malformed, "The searchable text layer has an unpositioned text draw")
        }
        let units = stride(from: 0, to: payload.count - payload.count % 2, by: 2).map {
          UInt16(payload[$0]) << 8 | UInt16(payload[$0 + 1])
        }
        let text = String(utf16CodeUnits: units, count: units.count)
        lines.append(Line(text: text, x: x, y: y, fontSize: fontSize))
        textX = nil
        textY = nil
      default:
        throw PDFError(.unsupported, "The searchable text layer uses an unsupported operator")
      }
    }
    return lines
  }

  public static func words(in line: String) -> [String] {
    line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  /// Replace one word token, preserving every whitespace separator.
  public static func replacingWord(
    in line: String, wordIndex: Int, with replacement: String
  ) -> String? {
    var output = ""
    var current = ""
    var index = 0
    var replaced = false
    func flush(separator: Character?) {
      guard !current.isEmpty else {
        if let separator { output.append(separator) }
        return
      }
      if index == wordIndex {
        output += replacement
        replaced = true
      } else {
        output += current
      }
      index += 1
      current = ""
      if let separator { output.append(separator) }
    }
    for character in line {
      if character.isWhitespace {
        flush(separator: character)
      } else {
        current.append(character)
      }
    }
    flush(separator: nil)
    guard replaced else { return nil }
    return output
  }
}

/// OCR-05: the visible replacement text run. The caller fits the size and
/// baseline to the erased word box; the command only validates.
public struct ScannedReplacementText: Sendable, Equatable {
  public var text: String
  public var x: Double
  public var baseline: Double
  public var fontSize: Double
  public var font: StandardTextFont
  public var color: [Double]

  public init(
    text: String, x: Double, baseline: Double, fontSize: Double,
    font: StandardTextFont = .helvetica, color: [Double] = [0, 0, 0]
  ) {
    self.text = text
    self.x = x
    self.baseline = baseline
    self.fontSize = fontSize
    self.font = font
    self.color = color
  }
}

/// OCR-05: map page-space rectangles onto the scan raster. Raster row 0 is the
/// top of the image (PDF image space top), so the vertical mapping flips.
public enum ScannedTextPixelMapping {
  public struct PixelRect: Sendable, Equatable {
    public let x0: Int
    public let y0: Int
    public let x1: Int
    public let y1: Int
  }

  public static func pixelRect(
    pageRect: [Double], imageWidth: Int, imageHeight: Int, placementMatrix: [Double]
  ) throws -> PixelRect {
    guard pageRect.count == 4, pageRect[2] > pageRect[0], pageRect[3] > pageRect[1],
      placementMatrix.count == 6,
      abs(placementMatrix[1]) < 1e-9, abs(placementMatrix[2]) < 1e-9,
      abs(placementMatrix[0] - placementMatrix[3]) < 1e-6,
      placementMatrix[0] > 0
    else {
      throw PDFError(
        .unsupported, "Word reconstruction needs an axis-aligned, uniformly scaled scan")
    }
    let scale = placementMatrix[0]
    let originX = placementMatrix[4]
    let originY = placementMatrix[5]
    let left = (pageRect[0] - originX) / scale
    let bottom = (pageRect[1] - originY) / scale
    let right = (pageRect[2] - originX) / scale
    let top = (pageRect[3] - originY) / scale
    guard left >= -1e-6, bottom >= -1e-6, right <= 1 + 1e-6, top <= 1 + 1e-6,
      right > left, top > bottom
    else {
      throw PDFError(.malformed, "The word box falls outside the scan image")
    }
    let x0 = max(0, min(imageWidth - 1, Int((left * Double(imageWidth)).rounded(.down))))
    let x1 = max(x0 + 1, min(imageWidth, Int((right * Double(imageWidth)).rounded(.up))))
    let y0 = max(0, min(imageHeight - 1, Int(((1 - top) * Double(imageHeight)).rounded(.down))))
    let y1 = max(y0 + 1, min(imageHeight, Int(((1 - bottom) * Double(imageHeight)).rounded(.up))))
    return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
  }
}

/// OCR-05: replace one recognized word so the visible scan content and the
/// selectable text change together. One atomic command:
/// 1. erases the original word pixels in the scan image by attaching a new
///    image instance whose word box already contains the sampled background;
/// 2. rebuilds the generated searchable layer without that word (no hidden
///    duplicate of the old or new text remains);
/// 3. adds a real, visible standard-font text run in the erased box, so the
///    replacement is selectable and editable through the normal text path.
public struct ReconstructScannedTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let ocrLineIndex: Int
  public let ocrWordIndex: Int
  public let originalWord: String
  public let wordRect: [Double]
  public let replacementImageWidth: Int
  public let replacementImageHeight: Int
  public let replacementRGB8: Data
  public let replacementText: ScannedReplacementText

  public init(
    pageID: PDFObjectID, placementIndex: Int, ocrLineIndex: Int, ocrWordIndex: Int,
    originalWord: String, wordRect: [Double], replacementImageWidth: Int,
    replacementImageHeight: Int, replacementRGB8: Data,
    replacementText: ScannedReplacementText
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.ocrLineIndex = ocrLineIndex
    self.ocrWordIndex = ocrWordIndex
    self.originalWord = originalWord
    self.wordRect = wordRect
    self.replacementImageWidth = replacementImageWidth
    self.replacementImageHeight = replacementImageHeight
    self.replacementRGB8 = replacementRGB8
    self.replacementText = replacementText
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Reconstruct Scanned Text" }

  public func validate(in graph: PDFGraph) throws {
    _ = try prepare(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let context = try prepare(in: graph)
    var graph = graph
    // 1. Erase the original word pixels; this also drops the stale layer.
    graph = try ApplyScanCleanupCommand(
      pageID: pageID, placementIndex: placementIndex,
      width: replacementImageWidth, height: replacementImageHeight,
      rgb8: replacementRGB8
    ).apply(to: graph)
    // 2. Rebuild the searchable layer without the reconstructed word.
    if !context.remainingLines.isEmpty {
      graph = try AddSearchableTextLayerCommand(
        pageID: pageID, lines: context.remainingLines, replacingExistingLayer: true
      ).apply(to: graph)
    }
    // 3. Add the visible, editable replacement text where the word was.
    let format = PageTextFormat(
      font: replacementText.font, size: replacementText.fontSize,
      color: replacementText.color)
    let segment = PageTextSegment(
      text: replacementText.text, x: replacementText.x, format: format)
    let line = PageTextLine(
      text: replacementText.text, x: replacementText.x,
      baseline: replacementText.baseline, segments: [segment])
    graph = try AddPageTextLinesCommand(
      pageID: pageID, lines: [line], box: context.textBox
    ).apply(to: graph)
    return graph
  }

  struct Prepared {
    let remainingLines: [SearchableTextLine]
    let textBox: PageTextBox
  }

  func prepare(in graph: PDFGraph) throws -> Prepared {
    guard try PDFPageTree.pageIDs(in: graph).contains(pageID) else {
      throw PDFError(.malformed, "The scan page is missing")
    }
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placements.count == 1, placementIndex == 0 else {
      throw PDFError(
        .unsupported,
        "Reconstruction needs one unambiguous scan image on the page")
    }
    let placement = placements[0]
    guard placement.depth == 0, placement.isDirectlyEditable,
      placement.hasSupportedClipping
    else {
      throw PDFError(
        .unsupported, "The scan is drawn inside a form or unsupported clip")
    }
    let mask = try ImageMaskState.describe(imageID: placement.imageID, in: graph)
    guard !mask.hasSMask, !mask.hasMask, !mask.isStencil, !mask.hasDecode else {
      throw PDFError(
        .unsupported, "The scan uses a mask or decode array; reconstruction would not preserve it")
    }
    guard case .stream(let image)? = graph.objects[placement.imageID],
      case .integer(let imageWidth)? = image.dictionary[PDFName("Width")],
      case .integer(let imageHeight)? = image.dictionary[PDFName("Height")]
    else {
      throw PDFError(.malformed, "The scan image dimensions are missing")
    }
    guard Int(imageWidth) == replacementImageWidth,
      Int(imageHeight) == replacementImageHeight,
      replacementImageWidth > 0, replacementImageHeight > 0,
      replacementRGB8.count == replacementImageWidth * replacementImageHeight * 3
    else {
      throw PDFError(
        .malformed, "The replacement raster must keep the scan image dimensions")
    }
    guard placement.bounds.count == 4,
      wordRect.count == 4, wordRect[2] > wordRect[0], wordRect[3] > wordRect[1],
      wordRect[0] >= placement.bounds[0] - 0.01,
      wordRect[1] >= placement.bounds[1] - 0.01,
      wordRect[2] <= placement.bounds[2] + 0.01,
      wordRect[3] <= placement.bounds[3] + 0.01
    else {
      throw PDFError(.malformed, "The word box falls outside the scan image")
    }
    try validateReplacementText(placement: placement, graph: graph)
    try validateErasedPixels(placement: placement)
    try validateNoUnsupportedPaint(placement: placement, graph: graph)
    let lines = try ScannedTextLayerReader.lines(pageID: pageID, in: graph)
    guard ocrLineIndex >= 0, ocrLineIndex < lines.count else {
      throw PDFError(.malformed, "The recognized OCR line no longer exists")
    }
    let words = ScannedTextLayerReader.words(in: lines[ocrLineIndex].text)
    guard ocrWordIndex >= 0, ocrWordIndex < words.count,
      words[ocrWordIndex] == originalWord
    else {
      throw PDFError(
        .malformed, "The recognized word no longer matches the searchable text layer")
    }
    var remaining: [SearchableTextLine] = []
    for (index, line) in lines.enumerated() {
      var text = line.text
      if index == ocrLineIndex {
        guard let edited = ScannedTextLayerReader.replacingWord(
          in: line.text, wordIndex: ocrWordIndex, with: "")
        else {
          throw PDFError(.malformed, "The recognized word could not be removed")
        }
        text = edited.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      } else {
        text = line.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      }
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
      remaining.append(
        SearchableTextLine(text: text, rect: line.searchableRect, confidence: nil))
    }
    return Prepared(remainingLines: remaining, textBox: textBox())
  }

  func validateReplacementText(placement: ImagePlacement, graph: PDFGraph) throws {
    let text = replacementText.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains("\n"), !text.contains("\r") else {
      throw PDFError(.malformed, "Enter one non-empty replacement line")
    }
    guard StandardTextFont.canEncode(text) else {
      throw PDFError(
        .unsupported,
        "The replacement text uses characters the standard fonts cannot encode")
    }
    let format = PageTextFormat(
      font: replacementText.font, size: replacementText.fontSize,
      color: replacementText.color)
    guard format.isValid else {
      throw PDFError(.malformed, "The replacement text style is not valid")
    }
    guard replacementText.x.isFinite, replacementText.baseline.isFinite,
      placement.bounds.count == 4,
      replacementText.x >= placement.bounds[0] - 0.01,
      replacementText.x <= placement.bounds[2],
      replacementText.baseline >= placement.bounds[1] - 0.01,
      replacementText.baseline <= placement.bounds[3]
    else {
      throw PDFError(.malformed, "The replacement text baseline falls outside the scan")
    }
    let box = textBox()
    guard box.isValid, box.allowsLineX(replacementText.x) else {
      throw PDFError(.malformed, "The replacement text does not fit its text box")
    }
    _ = graph
  }

  func textBox() -> PageTextBox {
    let width = Double(wordRect[2] - wordRect[0])
    let fontSize = replacementText.fontSize
    return PageTextBox(
      x: replacementText.x, firstBaseline: replacementText.baseline,
      width: max(24, min(2_000, width + 8)),
      lineSpacing: max(1, fontSize * 1.2), wraps: false)
  }

  /// The caller-supplied raster must already contain the sampled background in
  /// the padded word box; this proves the original glyph pixels are gone
  /// rather than merely painted over by the new text.
  func validateErasedPixels(placement: ImagePlacement) throws {
    let mapping = try ScannedTextPixelMapping.pixelRect(
      pageRect: wordRect, imageWidth: replacementImageWidth,
      imageHeight: replacementImageHeight, placementMatrix: placement.localMatrix)
    let padX = max(2, (mapping.x1 - mapping.x0) / 8)
    let padY = max(2, (mapping.y1 - mapping.y0) / 8)
    let x0 = max(0, mapping.x0 - padX)
    let y0 = max(0, mapping.y0 - padY)
    let x1 = min(replacementImageWidth, mapping.x1 + padX)
    let y1 = min(replacementImageHeight, mapping.y1 + padY)
    guard x1 - x0 > 2, y1 - y0 > 2 else {
      throw PDFError(.malformed, "The erased word region is too small")
    }
    var dark = 0
    var total = 0
    var samples: [(Double, Double, Double)] = []
    for y in y0..<y1 {
      for x in x0..<x1 {
        let offset = (y * replacementImageWidth + x) * 3
        let r = Double(replacementRGB8[offset])
        let g = Double(replacementRGB8[offset + 1])
        let b = Double(replacementRGB8[offset + 2])
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        total += 1
        if luminance < 160 { dark += 1 }
        samples.append((r, g, b))
      }
    }
    guard total > 0 else {
      throw PDFError(.malformed, "The erased word region has no pixels")
    }
    let count = Double(samples.count)
    let mean = (
      samples.reduce(0) { $0 + $1.0 } / count,
      samples.reduce(0) { $0 + $1.1 } / count,
      samples.reduce(0) { $0 + $1.2 } / count)
    let spread = samples.reduce(0.0) { partial, value in
      let dr = value.0 - mean.0, dg = value.1 - mean.1, db = value.2 - mean.2
      return partial + sqrt((dr * dr + dg * dg + db * db) / 3)
    } / count
    guard spread <= 24, Double(dark) / Double(total) <= 0.03 else {
      throw PDFError(
        .unsupported,
        "The original word pixels were not erased cleanly; reconstruction needs a flat background")
    }
  }

  func validateNoUnsupportedPaint(placement: ImagePlacement, graph: PDFGraph) throws {
    let content = try PageContent.load(pageID: pageID, in: graph)
    // The generated searchable layer is appended to the page contents but is
    // our own invisible text; only original content can overlap the scan.
    let layerIDs = Set(OCRLayer.layerStreamIDs(in: graph, pageID: pageID))
    let originalInstructions = try content.segments
      .filter { !layerIDs.contains($0.objectID) }
      .flatMap { try ContentParser.instructions(in: $0.decoded) }
    var path: [[Double]] = []
    for instruction in originalInstructions {
      switch instruction.operatorName {
      case "Tj", "TJ", "'", "\"":
        throw PDFError(
          .unsupported, "The page already paints text over the scan; reconstruction would overlap")
      case "BI":
        throw PDFError(.unsupported, "The page uses an inline image; reconstruction refuses")
      case "Do":
        if let name = instruction.operands.first, case .name(let resource) = name.value,
          resource == placement.resourceName
        {
          continue
        }
        throw PDFError(
          .unsupported, "The page draws another object over the scan; reconstruction refuses")
      case "m", "l":
        if let point = point(of: instruction.operands, at: 0) { path.append(point) }
      case "c", "v", "y":
        for index in 0..<instruction.operands.count {
          if let point = point(of: instruction.operands, at: index) { path.append(point) }
        }
      case "re":
        if let x = number(of: instruction.operands, at: 0),
          let y = number(of: instruction.operands, at: 1),
          let width = number(of: instruction.operands, at: 2),
          let height = number(of: instruction.operands, at: 3)
        {
          path.append([x, y])
          path.append([x + width, y])
          path.append([x + width, y + height])
          path.append([x, y + height])
        }
      case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
        if let bounds = boundingBox(path), intersects(bounds, wordRect) {
          throw PDFError(
            .unsupported, "Vector paint overlaps the word; reconstruction would damage it")
        }
        path.removeAll()
      default:
        continue
      }
    }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    if case .array(let annotations)? = page[PDFName("Annots")] {
      for value in annotations {
        let annotation: [PDFName: PDFValue]?
        switch value {
        case .dictionary(let dictionary): annotation = dictionary
        case .reference(let id):
          if case .dictionary(let dictionary)? = graph.objects[id] {
            annotation = dictionary
          } else {
            annotation = nil
          }
        default: annotation = nil
        }
        guard let dictionary = annotation,
          case .array(let rectValues)? = dictionary[PDFName("Rect")]
        else { continue }
        let rect = rectValues.compactMap { value -> Double? in
          switch value {
          case .integer(let int): return Double(int)
          case .real(let real): return real
          default: return nil
          }
        }
        if rect.count == 4, intersects(rect, wordRect) {
          throw PDFError(
            .unsupported,
            "An annotation overlaps the word; reconstruction would leave it inconsistent")
        }
      }
    }
  }

  func point(of operands: [ContentOperand], at index: Int) -> [Double]? {
    guard index + 1 < operands.count,
      let x = number(of: operands, at: index),
      let y = number(of: operands, at: index + 1)
    else { return nil }
    return [x, y]
  }

  func number(of operands: [ContentOperand], at index: Int) -> Double? {
    guard index < operands.count else { return nil }
    switch operands[index].value {
    case .integer(let int): return Double(int)
    case .real(let real): return real
    default: return nil
    }
  }

  func boundingBox(_ points: [[Double]]) -> [Double]? {
    guard let first = points.first else { return nil }
    var minX = first[0], minY = first[1], maxX = first[0], maxY = first[1]
    for point in points {
      minX = min(minX, point[0])
      minY = min(minY, point[1])
      maxX = max(maxX, point[0])
      maxY = max(maxY, point[1])
    }
    return [minX, minY, maxX, maxY]
  }

  func intersects(_ first: [Double], _ second: [Double]) -> Bool {
    guard first.count == 4, second.count == 4 else { return false }
    return first[0] < second[2] && first[2] > second[0]
      && first[1] < second[3] && first[3] > second[1]
  }
}
