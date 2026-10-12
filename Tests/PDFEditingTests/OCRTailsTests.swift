import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P26-006/P26-015–P26-018/P26-021/P26-022/P26-027/P26-029 evidence.
@Suite("OCR tails")
struct OCRTailsTests {
  @Test func languageAndQualityChoicesValidate() throws {
    let supported = ["en-US", "de-DE", "fr-FR"]
    let choice = OCRLanguageChoice(languages: ["en-US", "de-DE"], quality: .accurate, minimumConfidence: 0.7)
    #expect(try choice.validated(supportedLanguages: supported) == choice)
    #expect(choice.effectiveLanguages == ["en-US", "de-DE"])
    // Empty means system default.
    #expect(try OCRLanguageChoice(languages: [], quality: .fast).validated(supportedLanguages: supported).languages.isEmpty)
    #expect(throws: PDFError.self) {
      _ = try OCRLanguageChoice(languages: ["xx-YY"]).validated(supportedLanguages: supported)
    }
    #expect(throws: PDFError.self) {
      _ = try OCRLanguageChoice(languages: ["en-US"], minimumConfidence: 2).validated(supportedLanguages: supported)
    }
  }

  @Test func uncertainRecognitionIsDistinguished() throws {
    #expect(OCRConfidence.classify(isGenerated: false, confidence: nil, threshold: 0.6) == .documentText)
    #expect(OCRConfidence.classify(isGenerated: false, confidence: 0.1, threshold: 0.6) == .documentText)
    #expect(OCRConfidence.classify(isGenerated: true, confidence: 0.9, threshold: 0.6) == .recognizedConfident)
    #expect(OCRConfidence.classify(isGenerated: true, confidence: 0.2, threshold: 0.6) == .recognizedUncertain)
    #expect(OCRConfidence.classify(isGenerated: true, confidence: nil, threshold: 0.6) == .recognizedUncertain)
    #expect(OCRConfidence.isUncertain(isGenerated: true, confidence: 0.2, threshold: 0.6))
    #expect(!OCRConfidence.isUncertain(isGenerated: true, confidence: 0.9, threshold: 0.6))
  }

  @Test func reviewCorrectionsStayAssociatedWithTheLayer() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let lines = [
      SearchableTextLine(text: "reciept", rect: [10, 10, 120, 30], confidence: 0.4),
      SearchableTextLine(text: "total", rect: [10, 40, 120, 60], confidence: 0.95),
    ]
    let layered = try PDFEditingEngine.commit(
      PDFTransaction([AddSearchableTextLayerCommand(pageID: pageID, lines: lines)]), to: parsed.graph)
    var store = OCRCorrectionStore()
    let correction = OCRCorrection(pageID: pageID, originalText: "reciept", correctedText: "receipt", rect: [10, 10, 120, 30])
    try store.propose(correction)
    #expect(store.isAssociated(correction, with: lines))
    #expect(!store.isAssociated(OCRCorrection(pageID: pageID, originalText: "missing", correctedText: "x", rect: [10, 10, 120, 30]), with: lines))
    let corrected = store.linesWithCorrections(lines, pageID: pageID)
    #expect(corrected[0].text == "receipt")
    #expect(corrected[0].rect == [10, 10, 120, 30])
    #expect(corrected[1].text == "total")
    // Committing the corrected layer keeps the association.
    let committed = try PDFEditingEngine.commit(
      PDFTransaction([AddSearchableTextLayerCommand(pageID: pageID, lines: corrected, replacingExistingLayer: true)]),
      to: layered)
    #expect(OCRLayer.hasGeneratedLayer(in: committed, pageID: pageID))
    let data = try PDFWriter.write(committed)
    #expect(data.range(of: Data("receipt".utf8)) == nil) // hex-encoded; check extraction instead
    #expect(try PDFParser.parse(data).graph == committed)
    #expect(throws: PDFError.self) {
      try store.propose(OCRCorrection(pageID: pageID, originalText: "x", correctedText: "   ", rect: [10, 10, 120, 30]))
    }
  }

  @Test func batchProgressCancellationAndResume() throws {
    var state = OCRBatchState(pages: [0, 1, 2, 3])
    var progress: [(Int, Int)] = []
    try OCRBatchRunner.run(state: &state, onProgress: { progress.append(($0, $1)) }) { _ in }
    #expect(state.isComplete)
    #expect(progress.map { "\($0.0)/\($0.1)" } == ["1/4", "2/4", "3/4", "4/4"])

    // Cancellation preserves page-level completion for a resume.
    var partial = OCRBatchState(pages: [0, 1, 2])
    var calls = 0
    do {
      try OCRBatchRunner.run(state: &partial) { _ in
        calls += 1
        if calls == 1 { throw CancellationError() }
      }
      Issue.record("Cancellation was swallowed")
    } catch is CancellationError {
      partial.markCancelled()
    }
    #expect(partial.completed.isEmpty)
    #expect(partial.remaining == [0, 1, 2])
    try OCRBatchRunner.run(state: &partial) { _ in }
    #expect(partial.isComplete)
  }

  @Test func deskewUsesMeasuredTransforms() throws {
    // A horizontal bar has ~0 skew; a diagonal bar measures away from 0.
    let width = 40
    let height = 20
    var flat = [UInt8](repeating: 255, count: width * height)
    for x in 5..<35 { flat[10 * width + x] = 0 }
    #expect(abs(ScanDeskew.estimateSkewAngle(pixels: flat, width: width, height: height)) < 1.0)
    var diagonal = [UInt8](repeating: 255, count: width * height)
    for x in 5..<35 {
      let y = 4 + (x - 5) / 4
      diagonal[y * width + x] = 0
    }
    let angle = ScanDeskew.estimateSkewAngle(pixels: diagonal, width: width, height: height)
    #expect(abs(angle) > 1.0)
    let matrix = ScanDeskew.transform(angleDegrees: angle)
    #expect(matrix.count == 6)
    // The straightening rotation is orthonormal.
    #expect(abs(matrix[0] * matrix[0] + matrix[1] * matrix[1] - 1) < 1e-9)
    let preview = ScanDeskew.preview(imageWidth: 612, imageHeight: 792, angleDegrees: 2)
    #expect(preview[2] > 612 && preview[3] < 820)
    #expect(ScanDeskew.estimateSkewAngle(pixels: [], width: 0, height: 0) == 0)
  }

  @Test func contrastCleanupPreviewsConsequences() throws {
    let options = try ContrastOptions(blackPoint: 100, whitePoint: 150)
    let before: [UInt8] = [0, 100, 125, 150, 255, 110]
    let after = ScanContrast.apply(pixels: before, options: options)
    #expect(after == [0, 0, 127, 255, 255, 51])
    let preview = ScanContrast.preview(before: before, after: after)
    #expect(preview.changedFraction > 0.5)
    #expect(preview.meanAbsoluteDelta > 10)
    #expect(preview.consequence.contains("lossy"))
    #expect(throws: PDFError.self) { _ = try ContrastOptions(blackPoint: 150, whitePoint: 100) }
  }

  @Test func reOCRRefusesDuplicatesAndResurrection() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let layered = try PDFEditingEngine.commit(
      PDFTransaction([AddSearchableTextLayerCommand(
        pageID: pageID, lines: [SearchableTextLine(text: "live", rect: [10, 10, 60, 30])])]),
      to: parsed.graph)
    #expect(throws: PDFError.self) {
      try OCRRedactionGuard.verifyNoDuplicate(pageID: pageID, in: layered)
    }
    try OCRRedactionGuard.verifyNoDuplicate(pageID: parsed.pageIDs[1], in: layered)
    #expect(throws: PDFError.self) {
      try OCRRedactionGuard.verifyNoResurrection(
        proposed: [SearchableTextLine(text: "SECRET-TOKEN-123 receipt", rect: [10, 10, 120, 30])],
        redactedStrings: ["SECRET-TOKEN-123"])
    }
    try OCRRedactionGuard.verifyNoResurrection(
      proposed: [SearchableTextLine(text: "harmless receipt", rect: [10, 10, 120, 30])],
      redactedStrings: ["SECRET-TOKEN-123"])
  }

  @Test func ocrSyntheticMeasurementRecordsMethodAndLimits() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let measurement = try OCRBenchmark.measure(baseGraph: parsed.graph, pageIDs: parsed.pageIDs, pages: 2, linesPerPage: 4)
    #expect(measurement.pageCount == 2)
    #expect(measurement.lineCount > 0)
    #expect(measurement.outputBytesDelta > 0)
    #expect(measurement.elapsedMilliseconds >= 0)
    #expect(measurement.method.contains("synthetic"))
    #expect(measurement.limits.contains("private corpus absent"))
  }
}
