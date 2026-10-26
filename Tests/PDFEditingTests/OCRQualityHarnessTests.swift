import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// OCR-08: metric arithmetic, separate error dimensions, reading-order and
/// overlay alignment, and the qualification matrix. Synthetic observations are
/// always method verification only; measured cells require a real recognizer.
@Suite("OCR quality harness")
struct OCRQualityHarnessTests {
  @Test func characterAndWordErrorRatesAreSeparate() {
    #expect(OCRQualityMetricsCalculator.characterErrorRate(
      groundTruth: "İstanbul güvenli", recognition: "İstanbul güvenli") == 0)
    // A diacritic difference is one grapheme-level character error, not two.
    let diacritic = OCRQualityMetricsCalculator.characterErrorRate(
      groundTruth: "İstanbul", recognition: "Istanbul")
    #expect(abs(diacritic - 1.0 / 8.0) < 1e-9)
    let insertion = OCRQualityMetricsCalculator.characterErrorRate(
      groundTruth: "abc", recognition: "abcd")
    #expect(abs(insertion - 1.0 / 3.0) < 1e-9)
    #expect(OCRQualityMetricsCalculator.wordErrorRate(
      groundTruth: "İstanbul güvenli ödeme", recognition: "İstanbul güvenli ödeme") == 0)
    let wordErrors = OCRQualityMetricsCalculator.wordErrorRate(
      groundTruth: "İstanbul güvenli ödeme", recognition: "Istanbul guvenli ödeme")
    // Two of three words differ; diacritics count per word, not per character.
    #expect(abs(wordErrors - 2.0 / 3.0) < 1e-9)
    let oneWordError = OCRQualityMetricsCalculator.wordErrorRate(
      groundTruth: "İstanbul güvenli ödeme", recognition: "İstanbul güvenli odeme")
    #expect(abs(oneWordError - 1.0 / 3.0) < 1e-9)
    #expect(OCRQualityMetricsCalculator.wordErrorRate(
      groundTruth: "", recognition: "") == 0)
  }

  @Test func readingOrderDetectsColumnAndTableDamage() {
    let columnTruth = ["Left one", "Left two", "Left three", "Right one", "Right two", "Right three"]
    #expect(OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: columnTruth, recognition: columnTruth) == 1)
    let rowOrder = ["Left one", "Right one", "Left two", "Right two", "Left three", "Right three"]
    let damaged = OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: columnTruth, recognition: rowOrder)
    #expect(damaged > 0 && damaged < 1)
    #expect(OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: ["A", "B"], recognition: ["B", "A"]) == 0.5)
    let tableTruth = ["A1", "A2", "A3", "A4"]
    #expect(OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: tableTruth, recognition: tableTruth) == 1)
    let columnMajor = ["A1", "A3", "A2", "A4"]
    let tableDamaged = OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: tableTruth, recognition: columnMajor)
    #expect(tableDamaged < 1 && tableDamaged > 0)
  }

  @Test func overlayAlignmentIsReportedIndependently() {
    let exact = OCRQualityMetricsCalculator.overlayAlignment(
      groundTruth: [[10, 10, 110, 30], [10, 40, 110, 60]],
      recognition: [[10, 10, 110, 30], [10, 40, 110, 60]])
    #expect(exact.matchedLines == 2)
    #expect(exact.coverage == 1)
    #expect(abs(exact.meanIOU - 1) < 1e-9)
    let shifted = OCRQualityMetricsCalculator.overlayAlignment(
      groundTruth: [[10, 10, 110, 30]],
      recognition: [[12, 12, 112, 32]])
    #expect(shifted.matchedLines == 1)
    #expect(shifted.meanIOU > 0.5 && shifted.meanIOU < 1)
    let missing = OCRQualityMetricsCalculator.overlayAlignment(
      groundTruth: [[10, 10, 110, 30], [10, 40, 110, 60]],
      recognition: [[10, 10, 110, 30]])
    #expect(missing.coverage == 0.5)
    let invalid: [Double] = [0, 0, 0, 0]
    let ignored = OCRQualityMetricsCalculator.overlayAlignment(
      groundTruth: [[10, 10, 110, 30], invalid],
      recognition: [[10, 10, 110, 30]])
    #expect(ignored.groundTruthLines == 1)
    // Text accuracy and overlay alignment remain separate values.
    let metrics = OCRQualityMetricsCalculator.compare(
      groundTruth: [OCRQualityLine(text: "Hello", rect: [10, 10, 110, 30])],
      observations: [OCRQualityLine(text: "Hello", rect: [400, 400, 500, 420])])
    #expect(metrics.characterErrorRate == 0)
    #expect(metrics.wordErrorRate == 0)
    #expect(metrics.readingOrderAgreement == 1)
    #expect(metrics.overlayAlignment.coverage == 0)
  }

  @Test func multicolumnFixtureOrderIsMeasuredNotAssume() throws {
    let parsed = try PDFParser.parse(PDFFixtures.twoColumnPages())
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    // Both columns share baselines, so the paragraph layout groups them into
    // one visual line. The fixture's text runs are the row-major reading
    // sequence; build the reference lines from those runs instead.
    let grouped = Dictionary(grouping: layout.clusters, by: \.runIndex)
    var rowMajor: [OCRQualityLine] = []
    for runIndex in grouped.keys.sorted() {
      guard let clusters = grouped[runIndex] else { continue }
      let text = clusters.map(\.text).joined()
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let glyphs = clusters.filter { !$0.isWhitespace }
      guard let first = glyphs.first else { continue }
      // Standard Type1 fonts carry a zero-width conservative bounds estimate
      // and per-glyph origins are not absolute advances, so width is estimated
      // from the font size (about half an em per non-space character). Overlay
      // alignment is reported as an indicative line-band overlap, not as a
      // precise glyph metric.
      let y0 = glyphs.map { $0.bounds.count == 4 ? $0.bounds[1] : $0.origin[1] }.min()
        ?? first.origin[1]
      let y1 = glyphs.map { $0.bounds.count == 4 ? $0.bounds[3] : $0.origin[1] + $0.fontSize }
        .max() ?? (first.origin[1] + first.fontSize)
      let x0 = glyphs.map { $0.bounds.count == 4 && $0.bounds[2] > $0.bounds[0]
        ? $0.bounds[0] : $0.origin[0] }.min() ?? first.origin[0]
      let width = Double(glyphs.count) * max(first.fontSize, 1) * 0.5
      rowMajor.append(
        OCRQualityLine(text: text, rect: [x0, y0, x0 + max(width, 1), y1]))
    }
    #expect(rowMajor.count == 6)
    #expect(rowMajor.map(\.text).prefix(2) == ["Left one", "Right one"])
    // The true reading order of a two-column page is column-major.
    let left = rowMajor.filter { $0.rect[0] < 300 }.sorted { $0.rect[1] > $1.rect[1] }
    let right = rowMajor.filter { $0.rect[0] >= 300 }.sorted { $0.rect[1] > $1.rect[1] }
    let columnMajor = left + right
    #expect(columnMajor.map(\.text) == [
      "Left one", "Left two", "Left three", "Right one", "Right two", "Right three",
    ])
    let rowScore = OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: columnMajor.map(\.text), recognition: rowMajor.map(\.text))
    let columnScore = OCRQualityMetricsCalculator.readingOrderAgreement(
      groundTruth: columnMajor.map(\.text), recognition: columnMajor.map(\.text))
    #expect(columnScore == 1)
    #expect(rowScore > 0 && rowScore < columnScore)
    // Text accuracy is compared in the recognition's own order; reading order
    // is a separate score against the true column order.
    let textMetrics = OCRQualityMetricsCalculator.compare(
      groundTruth: rowMajor, observations: rowMajor)
    #expect(textMetrics.characterErrorRate == 0)
    #expect(textMetrics.overlayAlignment.coverage == 1)
    let orderMetrics = OCRQualityMetricsCalculator.compare(
      groundTruth: columnMajor, observations: rowMajor)
    #expect(orderMetrics.readingOrderAgreement == rowScore)
    #expect(orderMetrics.overlayAlignment.coverage == 1)
  }

  @Test func syntheticObservationsAreMethodVerificationOnly() {
    let samples = [
      methodSample(id: "clean-en", layout: .cleanScan, language: .english),
      methodSample(id: "clean-tr", layout: .cleanScan, language: .turkish),
      methodSample(id: "column-en", layout: .multicolumn, language: .english),
      methodSample(id: "column-tr", layout: .multicolumn, language: .turkish),
    ]
    let report = OCRQualityQualification.evaluate(samples: samples)
    #expect(report.measuredSampleCount == 0)
    #expect(report.methodVerifiedSampleCount == samples.count)
    #expect(report.measuredCellCount == 0)
    #expect(report.methodVerifiedCellCount == 4)
    #expect(report.notMeasuredCellCount == 4)  // noisy-scan/table cells absent
    #expect(report.matrix.count == OCRQualityLayout.allCases.count
      * OCRQualityLanguage.allCases.count)
    let markdown = report.markdownTable()
    #expect(markdown.contains("method verification only"))
    #expect(markdown.contains("not measured"))
    #expect(!markdown.contains("| measured |"))
    #expect(report.limitations.localizedCaseInsensitiveContains("consented"))
    // The report round-trips as the stored qualification artifact.
    guard let data = try? JSONEncoder().encode(report),
      let decoded = try? JSONDecoder().decode(
        OCRQualityQualificationReport.self, from: data)
    else {
      Issue.record("The quality report must encode and decode")
      return
    }
    #expect(decoded == report)
  }

  @Test func realEngineSampleIsMeasuredAndLabelledIndicative() throws {
    let sample = OCRQualitySample(
      id: "live-clean-en", layout: .cleanScan, language: .english,
      inputProvenance: .syntheticFixture, engineProvenance: .visionRecognition,
      groundTruth: [
        OCRQualityLine(text: "Safe line", rect: [10, 10, 110, 30])
      ],
      observations: [
        OCRQualityLine(text: "Safe line", rect: [10, 10, 110, 30])
      ])
    let report = OCRQualityQualification.evaluate(samples: [sample])
    #expect(report.measuredSampleCount == 1)
    #expect(report.measuredCellCount == 1)
    let cell = report.matrix.first {
      $0.layout == .cleanScan && $0.language == .english
    }
    #expect(cell?.status == .measured)
    #expect(cell?.engineProvenance == .visionRecognition)
    #expect(cell?.inputProvenance == .syntheticFixture)
    let note = try #require(cell?.note)
    #expect(note == "Indicative: real engine, synthetic input; no consented corpus.")
    // Locale-independent folding: the host locale may be Turkish, where a
    // localized case-insensitive match treats dotted/dotless I differently.
    #expect(note.lowercased().contains("indicative"))
    #expect(note.lowercased().contains("consented"))
    // Every other cell still declares not measured.
    #expect(report.notMeasuredCellCount == 7)
  }

  @Test func corpusManifestDeclaresMissingConsentedCells() {
    let slots = OCRQACorpusManifest.declaredSlots()
    #expect(slots.count == 8)
    #expect(OCRQACorpusManifest.missingSlots().count == 4)
    let markdown = OCRQACorpusManifest.markdown()
    #expect(markdown.contains("syntheticFixture"))
    #expect(!markdown.contains("consentedPrivateDocument | yes"))
    #expect(OCRQACorpusManifest.limitations.localizedCaseInsensitiveContains("no owner-consented"))
  }

  private func methodSample(
    id: String, layout: OCRQualityLayout, language: OCRQualityLanguage
  ) -> OCRQualitySample {
    OCRQualitySample(
      id: id, layout: layout, language: language,
      inputProvenance: .syntheticFixture,
      engineProvenance: .syntheticObservations,
      groundTruth: [
        OCRQualityLine(text: "İstanbul güvenli", rect: [10, 10, 110, 30])
      ],
      observations: [
        OCRQualityLine(text: "İstanbul güvenli", rect: [10, 10, 110, 30])
      ])
  }
}
