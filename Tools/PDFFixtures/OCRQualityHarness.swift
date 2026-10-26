import Foundation

/// OCR-08: language and layout quality qualification. Metrics are reported
/// separately (character error, word error, reading order, overlay alignment)
/// and synthetic observation sets are never labelled as measured recognition
/// quality. This module is pure measurement logic; recognition stays with the
/// existing OCR engine and is never substituted here.
public enum OCRQualityLayout: String, CaseIterable, Codable, Sendable {
  case cleanScan
  case noisyScan
  case multicolumn
  case table

  public var title: String {
    switch self {
    case .cleanScan: return "clean scan"
    case .noisyScan: return "noisy scan"
    case .multicolumn: return "multicolumn"
    case .table: return "table"
    }
  }
}

public enum OCRQualityLanguage: String, CaseIterable, Codable, Sendable {
  case english
  case turkish

  public var title: String { rawValue.capitalized }
  /// BCP-47 tags used for recognition requests.
  public var recognitionLanguages: [String] {
    switch self {
    case .english: return ["en-US"]
    case .turkish: return ["tr-TR"]
    }
  }
}

/// OCR-08: where the page content came from. Synthetic fixtures are allowed for
/// method verification and for exercising a real recognizer, but never as a
/// claim about an owner's real-world scanned material.
public enum OCRQualityInputProvenance: String, Codable, Sendable {
  case syntheticFixture
  case consentedPrivateDocument
}

/// OCR-08: who produced the observations. Only a real recognizer can measure
/// recognition quality.
public enum OCRQualityEngineProvenance: String, Codable, Sendable {
  case visionRecognition
  case syntheticObservations
}

public enum OCRQualityMeasurementStatus: String, Codable, Sendable {
  /// Real recognizer observations; only this status counts as measured quality.
  case measured
  /// Metric arithmetic verified against a synthetic observation set.
  case methodVerifiedOnly
  case notMeasured

  public var title: String {
    switch self {
    case .measured: return "measured"
    case .methodVerifiedOnly: return "method verification only"
    case .notMeasured: return "not measured"
    }
  }
}

/// One reference or recognized line with its page-space box.
public struct OCRQualityLine: Sendable, Equatable, Codable {
  public let text: String
  /// Page-space [x0, y0, x1, y1]; empty when no box is available.
  public let rect: [Double]

  public init(text: String, rect: [Double] = []) {
    self.text = text
    self.rect = rect
  }
}

public struct OCRQualitySample: Sendable, Equatable {
  public let id: String
  public let layout: OCRQualityLayout
  public let language: OCRQualityLanguage
  public let inputProvenance: OCRQualityInputProvenance
  public let engineProvenance: OCRQualityEngineProvenance
  public let groundTruth: [OCRQualityLine]
  /// Observations in the engine's reported reading order.
  public let observations: [OCRQualityLine]
  public let note: String

  public init(
    id: String, layout: OCRQualityLayout, language: OCRQualityLanguage,
    inputProvenance: OCRQualityInputProvenance,
    engineProvenance: OCRQualityEngineProvenance,
    groundTruth: [OCRQualityLine], observations: [OCRQualityLine],
    note: String = ""
  ) {
    self.id = id
    self.layout = layout
    self.language = language
    self.inputProvenance = inputProvenance
    self.engineProvenance = engineProvenance
    self.groundTruth = groundTruth
    self.observations = observations
    self.note = note
  }
}

public struct OCRQualityOverlayAlignment: Sendable, Equatable, Codable {
  public let matchedLines: Int
  public let groundTruthLines: Int
  /// Mean intersection-over-union over matched lines (0...1).
  public let meanIOU: Double
  /// Matched reference lines divided by all reference lines (0...1).
  public let coverage: Double

  public init(
    matchedLines: Int, groundTruthLines: Int, meanIOU: Double, coverage: Double
  ) {
    self.matchedLines = matchedLines
    self.groundTruthLines = groundTruthLines
    self.meanIOU = meanIOU
    self.coverage = coverage
  }
}

/// OCR-08: the separately-reported quality dimensions.
public struct OCRQualityMetrics: Sendable, Equatable, Codable {
  /// Character error rate over canonical, whitespace-normalized text (0...1+).
  public let characterErrorRate: Double
  /// Word error rate over whitespace tokens (0...1+).
  public let wordErrorRate: Double
  /// Longest common subsequence of line text sequences divided by reference
  /// line count (0...1). Detects column/table reading-order damage.
  public let readingOrderAgreement: Double
  /// Reference lines present in the recognition divided by reference lines.
  public let lineCoverage: Double
  public let overlayAlignment: OCRQualityOverlayAlignment

  public init(
    characterErrorRate: Double, wordErrorRate: Double, readingOrderAgreement: Double,
    lineCoverage: Double, overlayAlignment: OCRQualityOverlayAlignment
  ) {
    self.characterErrorRate = characterErrorRate
    self.wordErrorRate = wordErrorRate
    self.readingOrderAgreement = readingOrderAgreement
    self.lineCoverage = lineCoverage
    self.overlayAlignment = overlayAlignment
  }
}

public struct OCRQualitySampleResult: Sendable, Equatable, Codable {
  public let sampleID: String
  public let layout: OCRQualityLayout
  public let language: OCRQualityLanguage
  public let inputProvenance: OCRQualityInputProvenance
  public let engineProvenance: OCRQualityEngineProvenance
  public let status: OCRQualityMeasurementStatus
  public let metrics: OCRQualityMetrics?
  public let note: String
}

public struct OCRQualityMatrixCell: Sendable, Equatable, Codable {
  public let layout: OCRQualityLayout
  public let language: OCRQualityLanguage
  public let status: OCRQualityMeasurementStatus
  public let engineProvenance: OCRQualityEngineProvenance?
  public let inputProvenance: OCRQualityInputProvenance?
  public let note: String
}

/// OCR-08: the qualification report. Every required layout x language cell is
/// present; measured cells are never upgraded from synthetic observations.
public struct OCRQualityQualificationReport: Sendable, Equatable, Codable {
  public static let reportVersion = 1
  public let reportVersion: Int
  public let method: String
  public let limitations: String
  public let samples: [OCRQualitySampleResult]
  public let matrix: [OCRQualityMatrixCell]

  public init(
    method: String, limitations: String, samples: [OCRQualitySampleResult],
    matrix: [OCRQualityMatrixCell]
  ) {
    self.reportVersion = Self.reportVersion
    self.method = method
    self.limitations = limitations
    self.samples = samples
    self.matrix = matrix
  }

  public var measuredSampleCount: Int {
    samples.filter { $0.status == .measured }.count
  }
  public var methodVerifiedSampleCount: Int {
    samples.filter { $0.status == .methodVerifiedOnly }.count
  }
  public var measuredCellCount: Int {
    matrix.filter { $0.status == .measured }.count
  }
  public var methodVerifiedCellCount: Int {
    matrix.filter { $0.status == .methodVerifiedOnly }.count
  }
  public var notMeasuredCellCount: Int {
    matrix.filter { $0.status == .notMeasured }.count
  }

  public func markdownTable() -> String {
    var lines = [
      "| Layout | Language | Status | Engine | Input | Note |",
      "| --- | --- | --- | --- | --- | --- |",
    ]
    for cell in matrix {
      let engine = cell.engineProvenance?.rawValue ?? "—"
      let input = cell.inputProvenance?.rawValue ?? "—"
      lines.append(
        "| \(cell.layout.title) | \(cell.language.title) | \(cell.status.title) | "
        + "\(engine) | \(input) | \(cell.note) |")
    }
    return lines.joined(separator: "\n")
  }
}

/// OCR-08: deterministic metric arithmetic. Turkish and other combining text is
/// compared as extended grapheme clusters, so diacritics are not split into
/// separate characters.
public enum OCRQualityMetricsCalculator {
  public static func normalizedText(_ text: String) -> String {
    let composed = text.precomposedStringWithCanonicalMapping
    return composed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  public static func characters(_ text: String) -> [Character] {
    Array(normalizedText(text))
  }

  public static func words(_ text: String) -> [String] {
    normalizedText(text).split(separator: " ").map(String.init)
  }

  /// Levenshtein distance divided by reference length (0 when both empty).
  public static func characterErrorRate(groundTruth: String, recognition: String) -> Double {
    let reference = characters(groundTruth)
    let hypothesis = characters(recognition)
    return editRate(reference, hypothesis)
  }

  public static func wordErrorRate(groundTruth: String, recognition: String) -> Double {
    editRate(words(groundTruth), words(recognition))
  }

  public static func editRate<T: Equatable>(_ reference: [T], _ hypothesis: [T]) -> Double {
    guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
    let distance = editDistance(reference, hypothesis)
    return Double(distance) / Double(reference.count)
  }

  public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let substitution = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(
          previous[j] + 1, current[j - 1] + 1, previous[j - 1] + substitution)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  /// Longest common subsequence of line texts, divided by reference line count.
  public static func readingOrderAgreement(
    groundTruth: [String], recognition: [String]
  ) -> Double {
    let reference = groundTruth.map(normalizedText).filter { !$0.isEmpty }
    let hypothesis = recognition.map(normalizedText).filter { !$0.isEmpty }
    guard !reference.isEmpty else { return 0 }
    let common = longestCommonSubsequenceLength(reference, hypothesis)
    return Double(common) / Double(reference.count)
  }

  static func longestCommonSubsequenceLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    if a.isEmpty || b.isEmpty { return 0 }
    var previous = [Int](repeating: 0, count: b.count + 1)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = 0
      for j in 1...b.count {
        current[j] = a[i - 1] == b[j - 1]
          ? previous[j - 1] + 1
          : max(previous[j], current[j - 1])
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  /// Overlay alignment is reported independently of text accuracy: every
  /// reference box is greedily paired with the best-overlapping unused
  /// observation box. Invalid or empty boxes are ignored, never counted as
  /// aligned.
  public static func overlayAlignment(
    groundTruth: [[Double]], recognition: [[Double]]
  ) -> OCRQualityOverlayAlignment {
    let reference = groundTruth.filter(validBox)
    let observed = recognition.filter(validBox)
    guard !reference.isEmpty else {
      return OCRQualityOverlayAlignment(
        matchedLines: 0, groundTruthLines: 0, meanIOU: 0, coverage: 0)
    }
    var candidates: [(iou: Double, reference: Int, observation: Int)] = []
    for (referenceIndex, referenceBox) in reference.enumerated() {
      for (observationIndex, observationBox) in observed.enumerated() {
        let iou = intersectionOverUnion(referenceBox, observationBox)
        if iou > 0 {
          candidates.append((iou, referenceIndex, observationIndex))
        }
      }
    }
    candidates.sort { $0.iou > $1.iou }
    var usedReference = Set<Int>()
    var usedObservation = Set<Int>()
    var matchedIOU: [Double] = []
    for candidate in candidates {
      guard !usedReference.contains(candidate.reference),
        !usedObservation.contains(candidate.observation)
      else { continue }
      usedReference.insert(candidate.reference)
      usedObservation.insert(candidate.observation)
      matchedIOU.append(candidate.iou)
    }
    let mean = matchedIOU.isEmpty
      ? 0 : matchedIOU.reduce(0, +) / Double(matchedIOU.count)
    return OCRQualityOverlayAlignment(
      matchedLines: matchedIOU.count, groundTruthLines: reference.count,
      meanIOU: mean, coverage: Double(matchedIOU.count) / Double(reference.count))
  }

  public static func intersectionOverUnion(_ a: [Double], _ b: [Double]) -> Double {
    guard validBox(a), validBox(b) else { return 0 }
    let x0 = max(a[0], b[0])
    let y0 = max(a[1], b[1])
    let x1 = min(a[2], b[2])
    let y1 = min(a[3], b[3])
    guard x1 > x0, y1 > y0 else { return 0 }
    let intersection = (x1 - x0) * (y1 - y0)
    let areaA = (a[2] - a[0]) * (a[3] - a[1])
    let areaB = (b[2] - b[0]) * (b[3] - b[1])
    let union = areaA + areaB - intersection
    guard union > 0 else { return 0 }
    return intersection / union
  }

  public static func validBox(_ rect: [Double]) -> Bool {
    rect.count == 4 && rect.allSatisfy(\.isFinite)
      && rect[2] > rect[0] && rect[3] > rect[1]
  }

  public static func compare(
    groundTruth: [OCRQualityLine], observations: [OCRQualityLine]
  ) -> OCRQualityMetrics {
    let groundTruthText = groundTruth.map(\.text).joined(separator: "\n")
    let observationText = observations.map(\.text).joined(separator: "\n")
    let referenceLines = groundTruth.map(\.text)
    let recognizedLines = observations.map(\.text)
    let lineCoverage = Double(
      longestCommonSubsequenceLength(
        referenceLines.map(normalizedText), recognizedLines.map(normalizedText)))
      / Double(max(1, referenceLines.count))
    return OCRQualityMetrics(
      characterErrorRate: characterErrorRate(
        groundTruth: groundTruthText, recognition: observationText),
      wordErrorRate: wordErrorRate(
        groundTruth: groundTruthText, recognition: observationText),
      readingOrderAgreement: readingOrderAgreement(
        groundTruth: referenceLines, recognition: recognizedLines),
      lineCoverage: min(1, lineCoverage),
      overlayAlignment: overlayAlignment(
        groundTruth: groundTruth.map(\.rect), recognition: observations.map(\.rect)))
  }
}

/// OCR-08: declared corpus slots. Only a consented private document can fill a
/// real-world cell; this repository currently has no owner-consented scan
/// corpus, so those cells are declared and explicitly not measured.
public struct OCRQACorpusSlot: Sendable, Equatable, Codable {
  public enum Source: String, Codable, Sendable {
    case syntheticFixture
    case consentedPrivateDocument
  }

  public let layout: OCRQualityLayout
  public let language: OCRQualityLanguage
  public let source: Source
  public let available: Bool
  public let note: String
}

public enum OCRQACorpusManifest {
  public static let limitations =
    "No owner-consented scan corpus is present in this workspace. Synthetic fixtures and a real recognizer can demonstrate the harness and produce indicative numbers, but they are not a claim about real-world scanned material. Recognition quality is only marked measured when a real recognizer produced the observations; synthetic observation sets are method verification only."

  public static let method =
    "Ground-truth lines are compared with recognizer observations using separate metrics: grapheme-level character error rate, word error rate, longest-common-subsequence reading order, and greedy best-overlap line IoU/coverage. Diagnostic-only; no thresholds or pass/fail claims."

  /// Every required layout x language cell, with its current source status.
  public static func declaredSlots() -> [OCRQACorpusSlot] {
    OCRQualityLayout.allCases.flatMap { layout in
      OCRQualityLanguage.allCases.map { language in
        OCRQACorpusSlot(
          layout: layout, language: language, source: .syntheticFixture,
          available: layout == .cleanScan || layout == .multicolumn,
          note: layout == .cleanScan || layout == .multicolumn
            ? "Synthetic fixture can be rendered and recognized by the real engine."
            : "Synthetic layout fixture for metric method verification only; no consented real-world sample.")
      }
    }
  }

  public static func missingSlots(
    _ slots: [OCRQACorpusSlot] = declaredSlots()
  ) -> [OCRQACorpusSlot] {
    let required = Set(
      OCRQualityLayout.allCases.flatMap { layout in
        OCRQualityLanguage.allCases.map { "\(layout.rawValue)|\($0.rawValue)" }
      })
    let covered = Set(
      slots.filter(\.available).map { "\($0.layout.rawValue)|\($0.language.rawValue)" })
    guard required != covered else { return [] }
    return slots.filter {
      !covered.contains("\($0.layout.rawValue)|\($0.language.rawValue)")
    }
  }

  public static func markdown() -> String {
    var lines = [
      "| Layout | Language | Source | Available | Note |",
      "| --- | --- | --- | --- | --- |",
    ]
    for slot in declaredSlots() {
      lines.append(
        "| \(slot.layout.title) | \(slot.language.title) | \(slot.source.rawValue) | "
        + "\(slot.available ? "yes" : "no") | \(slot.note) |")
    }
    return lines.joined(separator: "\n")
  }
}

/// OCR-08: evaluate samples into the qualification report and matrix.
public enum OCRQualityQualification {
  public static func evaluate(samples: [OCRQualitySample]) -> OCRQualityQualificationReport {
    let results = samples.map { sample -> OCRQualitySampleResult in
      let status: OCRQualityMeasurementStatus = sample.engineProvenance
        == .syntheticObservations ? .methodVerifiedOnly : .measured
      let note: String
      switch sample.inputProvenance {
      case .syntheticFixture:
        note = status == .measured
          ? "Real recognizer on a synthetic fixture; indicative, not a real-scan claim."
          : "Synthetic observation set; metric arithmetic only."
      case .consentedPrivateDocument:
        note = ""
      }
      return OCRQualitySampleResult(
        sampleID: sample.id, layout: sample.layout, language: sample.language,
        inputProvenance: sample.inputProvenance,
        engineProvenance: sample.engineProvenance,
        status: status,
        metrics: OCRQualityMetricsCalculator.compare(
          groundTruth: sample.groundTruth, observations: sample.observations),
        note: sample.note.isEmpty ? note : sample.note)
    }
    let matrix = OCRQualityLayout.allCases.flatMap { layout in
      OCRQualityLanguage.allCases.map { language -> OCRQualityMatrixCell in
        let scoped = results.filter { $0.layout == layout && $0.language == language }
        if let measured = scoped.first(where: { $0.status == .measured }) {
          return OCRQualityMatrixCell(
            layout: layout, language: language, status: .measured,
            engineProvenance: measured.engineProvenance,
            inputProvenance: measured.inputProvenance,
            note: measured.inputProvenance == .syntheticFixture
              ? "Indicative: real engine, synthetic input; no consented corpus."
              : "Measured on a consented document.")
        }
        if !scoped.isEmpty {
          return OCRQualityMatrixCell(
            layout: layout, language: language, status: .methodVerifiedOnly,
            engineProvenance: scoped[0].engineProvenance,
            inputProvenance: scoped[0].inputProvenance,
            note: "Metric arithmetic verified; recognition quality not measured.")
        }
        return OCRQualityMatrixCell(
          layout: layout, language: language, status: .notMeasured,
          engineProvenance: nil, inputProvenance: nil,
          note: "No consented sample and no live measurement for this cell.")
      }
    }
    return OCRQualityQualificationReport(
      method: OCRQACorpusManifest.method,
      limitations: OCRQACorpusManifest.limitations,
      samples: results, matrix: matrix)
  }
}
