import AppKit
import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// OCR-08: optional live qualification run. This is NOT part of the normal
/// suite: it is enabled only with SPDF_OCR_QUALITY_LIVE=1 so recognition
/// quality is measured when the host's Vision stack is available, never
/// substituted by a synthetic recognizer. Observations always come from the
/// real Vision recognizer; the input pages are deterministic synthetic
/// fixtures, which the report labels as indicative rather than as a
/// real-world/consented-scan claim.
///
/// Artifacts: set SPDF_OCR_QUALITY_OUTPUT to a directory to write
/// ocr-quality-report.json, ocr-quality-matrix.md and
/// ocr-quality-environment.json.
@Suite("OCR quality live qualification")
struct OCRQualityLiveTests {
  @Test func measuresRealRecognitionOnSyntheticLayouts() throws {
    guard ProcessInfo.processInfo.environment["SPDF_OCR_QUALITY_LIVE"] == "1" else {
      return
    }
    let supportedLanguages = (try? VisionTextRecognizer.supportedLanguages()) ?? []
    var samples: [OCRQualitySample] = []
    samples.append(
      try recognisedSample(
        data: try PDFFixtures.textEditPages(), id: "clean-en", layout: .cleanScan,
        language: .english, columnOrder: false))
    samples.append(
      try recognisedSample(
        data: try PDFFixtures.twoColumnPages(), id: "multicolumn-en",
        layout: .multicolumn, language: .english, columnOrder: true))
    samples.append(
      try noisyRecognisedSample(
        data: try PDFFixtures.textEditPages(), id: "noisy-en"))
    if supportedLanguages.contains("tr-TR") {
      // The standard-14 PDF fonts cannot encode Turkish; render a synthetic
      // clean page directly so the real recognizer still measures its own
      // Turkish recognition rather than a substituted recognizer.
      samples.append(
        try drawnSample(
          id: "clean-tr", layout: .cleanScan, language: .turkish,
          lines: [
            "İstanbul güvenli ödeme şubesi",
            "Güneşli günler, güzel günler",
            "Türkçe metin doğru okunmalı",
          ]))
    }

    let report = OCRQualityQualification.evaluate(samples: samples)
    #expect(report.measuredSampleCount == samples.count)
    #expect(report.methodVerifiedSampleCount == 0)
    #expect(report.samples.allSatisfy { $0.engineProvenance == .visionRecognition })
    for sample in report.samples {
      let metrics = try #require(sample.metrics)
      #expect(metrics.characterErrorRate.isFinite && metrics.characterErrorRate >= 0)
      #expect(metrics.wordErrorRate.isFinite && metrics.wordErrorRate >= 0)
      #expect(metrics.readingOrderAgreement >= 0 && metrics.readingOrderAgreement <= 1)
      #expect(metrics.lineCoverage >= 0 && metrics.lineCoverage <= 1)
      #expect(metrics.overlayAlignment.coverage >= 0
        && metrics.overlayAlignment.coverage <= 1)
      #expect(sample.inputProvenance == .syntheticFixture)
    }
    // Measured does not mean representative: the report must say so.
    #expect(report.limitations.localizedCaseInsensitiveContains("not a claim"))
    #expect(report.measuredCellCount >= samples.count)
    #expect(report.matrix.count == 8)

    try writeArtifacts(report: report, supportedLanguages: supportedLanguages)
  }

  // MARK: - Samples

  private func recognisedSample(
    data: Data, id: String, layout: OCRQualityLayout,
    language: OCRQualityLanguage, columnOrder: Bool
  ) throws -> OCRQualitySample {
    let groundTruth = try groundTruth(from: data, columnOrder: columnOrder)
    let document = try #require(PDFDocument(data: data))
    #expect(document.pageCount > 0)
    let results = try OCRJob.run(
      document: document, pageIndexes: [0],
      languages: language.recognitionLanguages, level: .fast)
    let lines = results.first?.lines ?? []
    let observations = lines.map { OCRQualityLine(text: $0.text, rect: $0.rect) }
    return OCRQualitySample(
      id: id, layout: layout, language: language,
      inputProvenance: .syntheticFixture,
      engineProvenance: .visionRecognition,
      groundTruth: groundTruth, observations: observations,
      note: "Real Vision recognition, Fast level, on a deterministic synthetic fixture page.")
  }

  private func noisyRecognisedSample(
    data: Data, id: String
  ) throws -> OCRQualitySample {
    let groundTruth = try groundTruth(from: data, columnOrder: false)
    let document = try #require(PDFDocument(data: data))
    let page = try #require(document.page(at: 0))
    let raster = try #require(OCRPageRasterizer.rasterize(page: page))
    let noisy = try addDeterministicNoise(to: raster.image)
    let recognizer = VisionTextRecognizer()
    let outcome = try recognizer.recognizeWithFallback(
      image: noisy, languages: OCRQualityLanguage.english.recognitionLanguages,
      level: .fast)
    let observations = outcome.observations.map { observation in
      OCRQualityLine(
        text: observation.text,
        rect: raster.transform.pageRect(forNormalizedBox: observation.boundingBox))
    }
    return OCRQualitySample(
      id: id, layout: .noisyScan, language: .english,
      inputProvenance: .syntheticFixture,
      engineProvenance: .visionRecognition,
      groundTruth: groundTruth, observations: observations,
      note: "Real Vision recognition on a rendered page with deterministic synthetic speckle; Fast level.")
  }

  /// Render known Turkish lines into a synthetic clean page and let the real
  /// Vision recognizer read them. Ground-truth boxes come from the same
  /// drawing layout, so text accuracy and overlay alignment are independent.
  private func drawnSample(
    id: String, layout: OCRQualityLayout, language: OCRQualityLanguage,
    lines: [String]
  ) throws -> OCRQualitySample {
    let width = 1_680
    let height = 2_200
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw PDFError(.unsupported, "The synthetic page context is unavailable")
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 44),
      .foregroundColor: NSColor.black,
    ]
    var groundTruth: [OCRQualityLine] = []
    var top = Double(height) - 220
    for line in lines {
      let attributed = NSAttributedString(string: line, attributes: attributes)
      let size = attributed.size()
      attributed.draw(at: NSPoint(x: 150, y: top - size.height))
      groundTruth.append(
        OCRQualityLine(
          text: line,
          rect: [150, top - size.height, 150 + size.width, top]))
      top -= size.height + 70
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else {
      throw PDFError(.unsupported, "The synthetic page image is unavailable")
    }
    let recognizer = VisionTextRecognizer()
    let outcome = try recognizer.recognizeWithFallback(
      image: image, languages: language.recognitionLanguages, level: .fast)
    let transform = OCRPageTransform(
      imageWidth: Double(width), imageHeight: Double(height),
      cropBox: [0, 0, Double(width), Double(height)], rotation: 0)
    let observations = outcome.observations.map {
      OCRQualityLine(
        text: $0.text, rect: transform.pageRect(forNormalizedBox: $0.boundingBox))
    }
    return OCRQualitySample(
      id: id, layout: layout, language: language,
      inputProvenance: .syntheticFixture,
      engineProvenance: .visionRecognition,
      groundTruth: groundTruth, observations: observations,
      note: "Real Vision recognition on a synthetic rendered page; Fast level.")
  }

  // MARK: - Ground truth

  private func groundTruth(from data: Data, columnOrder: Bool) throws -> [OCRQualityLine] {
    let parsed = try PDFParser.parse(data)
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    // Build reference lines from the fixture's text runs: the page layout can
    // group two-column lines that share a baseline into one visual line.
    let grouped = Dictionary(grouping: layout.clusters, by: \.runIndex)
    var lines: [OCRQualityLine] = []
    for runIndex in grouped.keys.sorted() {
      guard let clusters = grouped[runIndex] else { continue }
      let text = clusters.map(\.text).joined()
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let glyphs = clusters.filter { !$0.isWhitespace }
      guard let first = glyphs.first else { continue }
      let y0 = glyphs.map { $0.bounds.count == 4 ? $0.bounds[1] : $0.origin[1] }.min()
        ?? first.origin[1]
      let y1 = glyphs.map { $0.bounds.count == 4 ? $0.bounds[3] : $0.origin[1] + $0.fontSize }
        .max() ?? (first.origin[1] + first.fontSize)
      let x0 = glyphs.map { $0.bounds.count == 4 && $0.bounds[2] > $0.bounds[0]
        ? $0.bounds[0] : $0.origin[0] }.min() ?? first.origin[0]
      let width = Double(glyphs.count) * max(first.fontSize, 1) * 0.5
      lines.append(OCRQualityLine(text: text, rect: [x0, y0, x0 + max(width, 1), y1]))
    }
    if columnOrder {
      let midpoint = 306.0
      let left = lines.filter { ($0.rect.first ?? 0) < midpoint }
        .sorted { ($0.rect.dropFirst().first ?? 0) > ($1.rect.dropFirst().first ?? 0) }
      let right = lines.filter { ($0.rect.first ?? 0) >= midpoint }
        .sorted { ($0.rect.dropFirst().first ?? 0) > ($1.rect.dropFirst().first ?? 0) }
      return left + right
    }
    return lines
  }

  // MARK: - Deterministic noise

  private func addDeterministicNoise(to image: CGImage) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw PDFError(.unsupported, "The qualification noise context is unavailable")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var state: UInt64 = 0x5EDF_0A75
    func next() -> UInt64 {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return state >> 33
    }
    context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.7))
    let count = max(400, width * height / 40_000)
    for _ in 0..<count {
      let x = Int(next() % UInt64(max(1, width)))
      let y = Int(next() % UInt64(max(1, height)))
      let size = 1 + Int(next() % 2)
      context.fill(CGRect(x: x, y: y, width: size, height: size))
    }
    guard let noisy = context.makeImage() else {
      throw PDFError(.unsupported, "The qualification noise image is unavailable")
    }
    return noisy
  }

  // MARK: - Artifacts

  private func writeArtifacts(
    report: OCRQualityQualificationReport, supportedLanguages: [String]
  ) throws {
    guard let path = ProcessInfo.processInfo.environment["SPDF_OCR_QUALITY_OUTPUT"],
      !path.isEmpty
    else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(
      to: directory.appendingPathComponent("ocr-quality-report.json"))
    try report.markdownTable().write(
      to: directory.appendingPathComponent("ocr-quality-matrix.md"),
      atomically: true, encoding: .utf8)
    let environment = [
      "supportedRecognitionLanguages": supportedLanguages,
      "measuredAt": ISO8601DateFormatter().string(from: Date()),
      "engine": "VisionTextRecognizer (real recognition)",
      "input": "deterministic synthetic fixture pages",
      "gatedBy": "SPDF_OCR_QUALITY_LIVE=1",
    ] as [String: Any]
    if let data = try? JSONSerialization.data(
      withJSONObject: environment, options: [.prettyPrinted, .sortedKeys])
    {
      try data.write(
        to: directory.appendingPathComponent("ocr-quality-environment.json"))
    }
  }
}
