import Foundation
import PDFCore

/// P26-006: explicit language and recognition-quality choices.
/// Languages are BCP-47 tags validated against the recognizer's supported
/// list; quality selects the recognition level and rasterization target.
public enum OCRQualityLevel: String, Sendable, Equatable, CaseIterable {
  case fast
  case accurate
}

public struct OCRLanguageChoice: Sendable, Equatable {
  public let languages: [String]
  public let quality: OCRQualityLevel
  /// Minimum confidence (0...1) below which recognition is uncertain (P26-015).
  public let minimumConfidence: Double

  public init(languages: [String], quality: OCRQualityLevel = .accurate, minimumConfidence: Double = 0.6) {
    self.languages = languages
    self.quality = quality
    self.minimumConfidence = minimumConfidence
  }

  /// Validate against the recognizer's supported languages. Empty means
  /// "system default" and is valid; unknown tags and out-of-range
  /// confidences refuse explicitly.
  public func validated(supportedLanguages: [String]) throws -> OCRLanguageChoice {
    guard minimumConfidence >= 0, minimumConfidence <= 1, minimumConfidence.isFinite else {
      throw PDFError(.malformed, "OCR confidence threshold must be within 0...1")
    }
    for language in languages {
      guard supportedLanguages.contains(language) else {
        throw PDFError(.unsupported, "OCR language \(language) is not supported on this system")
      }
    }
    return self
  }

  public var effectiveLanguages: [String] { languages }
}

/// P26-015: provenance of a text run — definitive document text versus
/// recognized text, with uncertain recognition flagged by confidence.
public enum OCRTextProvenance: String, Sendable, Equatable {
  case documentText
  case recognizedConfident
  case recognizedUncertain
}

public enum OCRConfidence {
  /// Classify one observation. Non-generated content is always definitive.
  public static func classify(isGenerated: Bool, confidence: Double?, threshold: Double) -> OCRTextProvenance {
    guard isGenerated else { return .documentText }
    guard let confidence else { return .recognizedUncertain }
    return confidence >= threshold ? .recognizedConfident : .recognizedUncertain
  }

  public static func isUncertain(isGenerated: Bool, confidence: Double?, threshold: Double) -> Bool {
    classify(isGenerated: isGenerated, confidence: confidence, threshold: threshold) == .recognizedUncertain
  }
}

/// P26-016/P26-017: a user correction to a committed OCR text layer.
/// Corrections are associated with the committed layer by page plus the
/// original line text and rect, so they survive save/reopen.
public struct OCRCorrection: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let originalText: String
  public let correctedText: String
  public let rect: [Double]

  public init(pageID: PDFObjectID, originalText: String, correctedText: String, rect: [Double]) {
    self.pageID = pageID
    self.originalText = originalText
    self.correctedText = correctedText
    self.rect = rect
  }
}

public struct OCRCorrectionStore: Sendable, Equatable {
  public private(set) var corrections: [OCRCorrection] = []

  public init() {}

  public mutating func propose(_ correction: OCRCorrection) throws {
    guard !correction.correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "OCR corrections need non-empty replacement text")
    }
    guard correction.correctedText.unicodeScalars.allSatisfy({ $0.value < 0x10000 }) else {
      throw PDFError(.unsupported, "OCR corrections beyond the BMP are not supported yet")
    }
    guard correction.rect.count == 4, correction.rect[2] > correction.rect[0],
      correction.rect[3] > correction.rect[1]
    else {
      throw PDFError(.malformed, "OCR correction geometry is invalid")
    }
    // One correction per original line; re-proposing replaces it.
    corrections.removeAll {
      $0.pageID == correction.pageID && $0.originalText == correction.originalText
        && $0.rect == correction.rect
    }
    corrections.append(correction)
  }

  public func corrections(for pageID: PDFObjectID) -> [OCRCorrection] {
    corrections.filter { $0.pageID == pageID }
  }

  /// Lines with corrections applied. Rects and order are preserved; only
  /// the text changes. Uncorrected lines pass through untouched.
  public func linesWithCorrections(_ lines: [SearchableTextLine], pageID: PDFObjectID) -> [SearchableTextLine] {
    let scoped = corrections(for: pageID)
    guard !scoped.isEmpty else { return lines }
    return lines.map { line in
      if let correction = scoped.first(where: { $0.originalText == line.text && $0.rect == line.rect }) {
        return SearchableTextLine(text: correction.correctedText, rect: line.rect, confidence: line.confidence)
      }
      return line
    }
  }

  /// P26-017: a correction is associated exactly when its page, original
  /// text, and rect match a committed layer line.
  public func isAssociated(_ correction: OCRCorrection, with lines: [SearchableTextLine]) -> Bool {
    lines.contains { $0.text == correction.originalText && $0.rect == correction.rect }
  }
}

/// P26-018: resumable page-level batch state. Pages complete atomically;
/// cancellation or termination keeps `completed` so a later run resumes
/// with `remaining`.
public struct OCRBatchState: Sendable, Equatable {
  public let pages: [Int]
  public private(set) var completed: Set<Int> = []
  public private(set) var cancelled: Bool = false

  public init(pages: [Int]) {
    self.pages = pages
  }

  public var remaining: [Int] { pages.filter { !completed.contains($0) } }
  public var isComplete: Bool { remaining.isEmpty }
  public var progress: (done: Int, total: Int) { (completed.count, pages.count) }

  public mutating func markCompleted(_ page: Int) {
    completed.insert(page)
  }

  public mutating func markCancelled() { cancelled = true }
}

public enum OCRBatchRunner {
  /// Run `work` over the state's remaining pages in order, reporting
  /// `(done, total)` after each page. Cancellation throws and preserves
  /// the completed set for a later resume.
  public static func run(
    state: inout OCRBatchState,
    onProgress: ((Int, Int) -> Void)? = nil,
    work: (Int) throws -> Void
  ) throws {
    for page in state.remaining {
      try Task.checkCancellation()
      try work(page)
      state.markCompleted(page)
      onProgress?(state.progress.done, state.progress.total)
    }
  }
}

/// P26-021: explicit deskew cleanup using a measured image transform.
/// The estimator fits a skew angle to dark pixels with linear regression;
/// the transform is the measured rotation that straightens the page.
public enum ScanDeskew {
  /// Estimate the skew angle in degrees from a grayscale buffer (0 = white).
  /// Returns 0 when there are too few dark pixels to measure.
  public static func estimateSkewAngle(pixels: [UInt8], width: Int, height: Int) -> Double {
    guard width > 0, height > 0, pixels.count == width * height else { return 0 }
    var count = 0
    var sumX = 0.0
    var sumY = 0.0
    var sumXX = 0.0
    var sumXY = 0.0
    for y in 0..<height {
      for x in 0..<width {
        if pixels[y * width + x] < 128 {
          let dx = Double(x)
          let dy = Double(y)
          count += 1
          sumX += dx
          sumY += dy
          sumXX += dx * dx
          sumXY += dx * dy
        }
      }
    }
    guard count >= 8 else { return 0 }
    let denominator = Double(count) * sumXX - sumX * sumX
    guard abs(denominator) > 1e-9 else { return 0 }
    let slope = (Double(count) * sumXY - sumX * sumY) / denominator
    return atan(slope) * 180 / Double.pi
  }

  /// The straightening rotation matrix `[a b c d e f]` for an angle.
  public static func transform(angleDegrees: Double) -> [Double] {
    let radians = -angleDegrees * Double.pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    return [cosine, sine, -sine, cosine, 0, 0]
  }

  /// Previewed consequence: the axis-aligned bounds of an image after the
  /// straightening rotation.
  public static func preview(imageWidth: Double, imageHeight: Double, angleDegrees: Double) -> [Double] {
    let matrix = transform(angleDegrees: angleDegrees)
    let (a, b, c, d) = (matrix[0], matrix[1], matrix[2], matrix[3])
    let xs = [0.0, a * imageWidth, c * imageHeight, a * imageWidth + c * imageHeight]
    let ys = [0.0, b * imageWidth, d * imageHeight, b * imageWidth + d * imageHeight]
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
  }
}

/// P26-022: explicit contrast/background cleanup with previewed
/// consequences. Levels stretch linearly; the preview reports how much of
/// the image changes so the lossy consequence is visible before applying.
public struct ContrastOptions: Sendable, Equatable {
  public let blackPoint: UInt8
  public let whitePoint: UInt8

  public init(blackPoint: UInt8, whitePoint: UInt8) throws {
    guard blackPoint < whitePoint else {
      throw PDFError(.malformed, "Contrast cleanup needs blackPoint < whitePoint")
    }
    self.blackPoint = blackPoint
    self.whitePoint = whitePoint
  }
}

public struct ContrastPreview: Sendable, Equatable {
  public let changedFraction: Double
  public let meanAbsoluteDelta: Double
  public var consequence: String {
    "contrast \(String(format: "%.0f%%", changedFraction * 100)) of pixels change (mean Δ \(String(format: "%.1f", meanAbsoluteDelta))); this is a lossy cleanup"
  }
}

public enum ScanContrast {
  public static func apply(pixels: [UInt8], options: ContrastOptions) -> [UInt8] {
    let black = Int(options.blackPoint)
    let white = Int(options.whitePoint)
    let span = max(white - black, 1)
    return pixels.map { value in
      let clamped = min(max(Int(value), black), white)
      return UInt8((clamped - black) * 255 / span)
    }
  }

  public static func preview(before: [UInt8], after: [UInt8]) -> ContrastPreview {
    guard before.count == after.count, !before.isEmpty else {
      return ContrastPreview(changedFraction: 0, meanAbsoluteDelta: 0)
    }
    var changed = 0
    var total = 0
    for (lhs, rhs) in zip(before, after) {
      let delta = abs(Int(lhs) - Int(rhs))
      total += delta
      if delta > 0 { changed += 1 }
    }
    return ContrastPreview(
      changedFraction: Double(changed) / Double(before.count),
      meanAbsoluteDelta: Double(total) / Double(before.count))
  }
}

/// P26-027: re-OCR must neither duplicate a live layer nor resurrect text
/// that redaction removed.
public enum OCRRedactionGuard {
  public static func verifyNoDuplicate(pageID: PDFObjectID, in graph: PDFGraph) throws {
    guard !OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID) else {
      throw PDFError(.unsupported, "Re-OCR would duplicate the live searchable layer; replace it explicitly")
    }
  }

  /// Refuse proposed lines whose text contains a redacted secret.
  public static func verifyNoResurrection(proposed: [SearchableTextLine], redactedStrings: [String]) throws {
    for line in proposed {
      for secret in redactedStrings where !secret.isEmpty {
        if line.text.contains(secret) {
          throw PDFError(.unsupported, "Re-OCR would resurrect redacted text")
        }
      }
    }
  }
}

/// P26-029: synthetic measurement when the private corpus is absent.
/// Records method and limits alongside the numbers.
public struct OCRMeasurement: Sendable, Equatable {
  public let pageCount: Int
  public let lineCount: Int
  public let elapsedMilliseconds: Double
  public let outputBytesDelta: Int
  public let method: String
  public let limits: String
}

public enum OCRBenchmark {
  public static func measure(
    baseGraph: PDFGraph, pageIDs: [PDFObjectID], pages: Int = 4, linesPerPage: Int = 8
  ) throws -> OCRMeasurement {
    let started = Date()
    var totalDelta = 0
    var totalLines = 0
    var graph = baseGraph
    for index in 0..<pages {
      let pageID = pageIDs[index % pageIDs.count]
      // Use a fresh image-only page per iteration when possible; otherwise
      // replace the layer so deltas stay comparable.
      let lines = (0..<linesPerPage).map { line in
        let bottom = Double(30 + line * 20)
        let top = Double(48 + line * 20)
        let rect: [Double] = [10, bottom, 300, top]
        return SearchableTextLine(
          text: "benchmark line \(index)-\(line)", rect: rect,
          confidence: 0.9)
      }
      let before = (try? PDFWriter.serialize(graph))?.count ?? 0
      if OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID) {
        graph = try PDFEditingEngine.commit(
          PDFTransaction([AddSearchableTextLayerCommand(pageID: pageID, lines: lines, replacingExistingLayer: true)]),
          to: graph)
      } else {
        // Image pages have no text; a second page may already carry a
        // layer from an earlier iteration.
        if OCRLayer.pageShowsText(pageID, in: graph) {
          continue
        }
        graph = try PDFEditingEngine.commit(
          PDFTransaction([AddSearchableTextLayerCommand(pageID: pageID, lines: lines)]),
          to: graph)
      }
      let after = (try? PDFWriter.serialize(graph))?.count ?? before
      totalDelta += after - before
      totalLines += lines.count
    }
    let elapsed = Date().timeIntervalSince(started) * 1000
    return OCRMeasurement(
      pageCount: pages, lineCount: totalLines, elapsedMilliseconds: elapsed,
      outputBytesDelta: totalDelta,
      method: "synthetic fixture graph with generated OCR layers (no Vision recognition)",
      limits: "private corpus absent; recognition quality not measured here")
  }
}
