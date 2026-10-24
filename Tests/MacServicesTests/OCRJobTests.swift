import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFFixtures
import PDFKit
import Testing

/// P26-002/P26-003/P26-004/P26-005/P26-007/P26-008/P26-009/P26-018/P26-028
/// evidence: the OCR job, page-coordinate transforms, rasterization bounds,
/// reading order, progress, and cancellation.
@Suite("OCR job")
struct OCRJobTests {
  @Test func transformMapsRotationsAndCrops() {
    let crop: [Double] = [100, 100, 500, 700]
    let none = OCRPageTransform(imageWidth: 400, imageHeight: 600, cropBox: crop, rotation: 0)
    #expect(
      approximatelyEqual(
        none.pageRect(forNormalizedBox: CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)),
        [200, 250, 300, 550]))
    let ninety = OCRPageTransform(imageWidth: 600, imageHeight: 400, cropBox: crop, rotation: 90)
    #expect(
      approximatelyEqual(
        ninety.pageRect(forNormalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3)),
        [300, 160, 420, 280]))
    let oneEighty = OCRPageTransform(
      imageWidth: 400, imageHeight: 600, cropBox: crop, rotation: 180)
    #expect(
      approximatelyEqual(
        oneEighty.pageRect(forNormalizedBox: CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)),
        [300, 250, 400, 550]))
    let twoSeventy = OCRPageTransform(
      imageWidth: 600, imageHeight: 400, cropBox: crop, rotation: 270)
    #expect(
      approximatelyEqual(
        twoSeventy.pageRect(forNormalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3)),
        [180, 520, 300, 640]))
  }

  @Test func displayRectsMapBackThroughRotationAndCrop() {
    let crop: [Double] = [100, 100, 500, 700]
    let cases: [(rotation: Int, displayWidth: Double, displayHeight: Double)] = [
      (0, 400, 600), (90, 600, 400), (180, 400, 600), (270, 600, 400),
    ]
    for entry in cases {
      let transform = OCRPageTransform(
        imageWidth: entry.displayWidth, imageHeight: entry.displayHeight, cropBox: crop,
        rotation: entry.rotation)
      let display: [Double] = [60, 80, 180, 200]
      let normalized = CGRect(
        x: display[0] / entry.displayWidth, y: display[1] / entry.displayHeight,
        width: (display[2] - display[0]) / entry.displayWidth,
        height: (display[3] - display[1]) / entry.displayHeight)
      #expect(
        approximatelyEqual(
          transform.pageRect(forDisplayRect: display),
          transform.pageRect(forNormalizedBox: normalized)),
        "rotation \(entry.rotation)")
    }
    let ninety = OCRPageTransform(
      imageWidth: 600, imageHeight: 400, cropBox: crop, rotation: 90)
    #expect(
      approximatelyEqual(
        ninety.pageRect(forDisplayRect: [60, 80, 180, 200]), [300, 160, 420, 280]))
  }

  /// P26-005/P27-003: pin the display↔page convention to PDFKit's actual
  /// rendering. Line 1 of the rotated fixture page sits at unrotated page
  /// x 42–378, y 710–734. Under the supported /Rotate 90 mapping
  /// `display = (y_page, cropWidth − x_page)` its pixels land in the memory
  /// band x 1972–2039, y 117–1050; the transposed (mirrored) convention
  /// would put them at y 650–1583.
  @Test func rasterizedPixelsAgreeWithTransformConvention() throws {
    let document = try #require(PDFDocument(data: PDFFixtures.threePages()))
    let page = try #require(document.page(at: 2))
    let raster = try #require(OCRPageRasterizer.rasterize(page: page))
    let image = raster.image
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(
      CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let scale = 2200.0 / 792.0
    func darkCount(x: Range<Int>, y: Range<Int>) -> Int {
      var count = 0
      for row in y {
        for column in x {
          let index = (row * width + column) * 4
          if bytes[index] < 100 && bytes[index + 1] < 100 && bytes[index + 2] < 100 {
            count += 1
          }
        }
      }
      return count
    }
    let xBand = Int(710 * scale)..<Int(734 * scale)
    let corrected = Int(Double(height) - 570 * scale)..<Int(Double(height) - 234 * scale)
    let mirrored = Int(Double(height) - 378 * scale)..<Int(Double(height) - 42 * scale)
    #expect(darkCount(x: xBand, y: corrected) > 200)
    #expect(darkCount(x: xBand, y: mirrored) < darkCount(x: xBand, y: corrected))
  }

  @Test func selectionBoundsOnRotatedPagesMatchContentSpace() throws {
    // P27-003 evidence: PDFKit selection bounds are reported in unrotated page
    // space (the space page content instructions live in), so redaction
    // regions taken from a selection need no rotation mapping. This test
    // pins that environment behavior.
    let document = try #require(PDFDocument(data: PDFFixtures.threePages()))
    let page = try #require(document.page(at: 2))
    #expect(page.rotation == 90)
    let unrotated = try #require(
      page.selection(for: CGRect(x: 42, y: 705, width: 300, height: 30)))
    #expect(unrotated.string?.contains("page 3") == true)
    // The rotated-space location of the same text selects nothing.
    let rotated = page.selection(for: CGRect(x: 705, y: 40, width: 30, height: 300))
    #expect(rotated?.string?.contains("page 3") != true)
  }

  @Test func rasterizerBoundsResolutionAndOrientation() throws {
    let document = try #require(PDFDocument(data: PDFFixtures.threePages()))
    let page1 = try #require(document.page(at: 0))
    let raster1 = try #require(OCRPageRasterizer.rasterize(page: page1))
    #expect(raster1.image.width == 1700 && raster1.image.height == 2200)
    #expect(raster1.transform.rotation == 0)
    let page3 = try #require(document.page(at: 2))
    #expect(page3.rotation == 90)
    let raster3 = try #require(OCRPageRasterizer.rasterize(page: page3))
    #expect(raster3.image.width == 2200 && raster3.image.height == 1700)
    #expect(raster3.transform.rotation == 90)
    // Mixed sizes: the A4 page scales to the same long-side bound.
    let page2 = try #require(document.page(at: 1))
    let raster2 = try #require(OCRPageRasterizer.rasterize(page: page2))
    #expect(raster2.image.width == 1555 && raster2.image.height == 2200)
  }

  @Test func jobMapsAndOrdersObservationsWithAStubRecognizer() throws {
    struct Stub: TextRecognizing {
      let observations: [OCRObservation]
      func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
        -> [OCRObservation]
      {
        observations
      }
    }
    let document = try #require(PDFDocument(data: PDFFixtures.imagePages()))
    let stub = Stub(observations: [
      OCRObservation(
        text: "bottom", confidence: 0.7,
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
      OCRObservation(
        text: "top right", confidence: 0.9,
        boundingBox: CGRect(x: 0.5, y: 0.8, width: 0.3, height: 0.05)),
      OCRObservation(
        text: "top left", confidence: 0.8,
        boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)),
      OCRObservation(
        text: "   ", confidence: 0.5,
        boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.05)),
    ])
    var progress: [(Int, Int)] = []
    let results = try OCRJob.run(
      document: document, pageIndexes: [0], languages: ["en-US"], recognizer: stub,
      onProgress: { progress.append(($0, $1)) })
    #expect(results.count == 1)
    #expect(results[0].lines.map(\.text) == ["top left", "top right", "bottom"])
    #expect(progress.count == 1 && progress[0] == (1, 1))
    let topLeft = try #require(results[0].lines.first)
    #expect(abs(topLeft.rect[0] - 61.2) < 0.01 && abs(topLeft.rect[2] - 244.8) < 0.01)
    #expect(abs(topLeft.rect[1] - 633.6) < 0.01 && abs(topLeft.rect[3] - 673.2) < 0.01)
    #expect(topLeft.confidence == 0.8)
  }

  @Test func requestedLanguagesAndLevelReachTheRecognizer() throws {
    final class Recorder: @unchecked Sendable {
      var languages: [[String]] = []
      var levels: [OCRRecognitionLevel] = []
    }
    struct Stub: TextRecognizing {
      let recorder: Recorder
      func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
        -> [OCRObservation]
      {
        recorder.languages.append(languages)
        recorder.levels.append(level)
        return []
      }
    }
    let document = try #require(PDFDocument(data: PDFFixtures.imagePages()))
    let recorder = Recorder()
    _ = try OCRJob.run(
      document: document, pageIndexes: [0], languages: ["tr-TR", "en-US"], level: .fast,
      recognizer: Stub(recorder: recorder))
    #expect(recorder.languages == [["tr-TR", "en-US"]])
    #expect(recorder.levels == [.fast])
  }

  @Test func jobCancellationLeavesNoResults() async throws {
    struct Stub: TextRecognizing {
      func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
        -> [OCRObservation]
      {
        try Task.checkCancellation()
        return []
      }
    }
    let document = try #require(PDFDocument(data: PDFFixtures.imagePages()))
    let task = Task { () -> [OCRPageResult] in
      try OCRJob.run(document: document, pageIndexes: [0, 1], languages: [], recognizer: Stub())
    }
    task.cancel()
    let result = await task.result
    switch result {
    case .success(let results):
      #expect(results.isEmpty)
    case .failure(let error):
      #expect(error is CancellationError)
    }
  }

  @Test func visionLanguagesAndTolerantRecognition() throws {
    // P26-002: the language list is queried, not assumed.
    let languages = try VisionTextRecognizer.supportedLanguages()
    #expect(languages.contains("en-US"))

    // Recognition may be unavailable in restricted environments; when it
    // works it must return observations, and when it does not it must throw
    // an explicit unsupported error instead of failing silently.
    let context = try #require(
      CGContext(
        data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 1600,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
    let image = try #require(context.makeImage())
    do {
      let observations = try VisionTextRecognizer().recognize(
        image: image, languages: ["en-US"], level: .fast)
      #expect(observations.allSatisfy { !$0.text.isEmpty })
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func cancellationAfterFirstPageStopsBeforeTheNextRecognition() async throws {
    final class Probe: TextRecognizing, @unchecked Sendable {
      private let lock = NSLock()
      private var recognitions = 0
      private var completions: [Int] = []

      func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
        -> [OCRObservation]
      {
        lock.withLock { recognitions += 1 }
        return [
          OCRObservation(
            text: "Recognized fixture", confidence: 1,
            boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1))
        ]
      }

      func recordProgress(_ completed: Int) {
        lock.withLock { completions.append(completed) }
      }

      var snapshot: (recognitions: Int, completions: [Int]) {
        lock.withLock { (recognitions, completions) }
      }
    }

    let fixture = try PDFFixtures.threePages()
    let probe = Probe()
    let job = Task {
      let document = try #require(PDFDocument(data: fixture))
      return try OCRJob.run(
        document: document, pageIndexes: [0, 1, 2], languages: [], recognizer: probe,
        onProgress: { completed, _ in
          probe.recordProgress(completed)
          if completed == 1 {
            // Cancel after real work starts, without a scheduler/sleep race.
            withUnsafeCurrentTask { $0?.cancel() }
          }
        })
    }
    switch await job.result {
    case .success:
      Issue.record("Canceled OCR returned partial results instead of CancellationError")
    case .failure(let error):
      #expect(error is CancellationError)
    }
    let observed = probe.snapshot
    #expect(observed.recognitions == 1)
    #expect(observed.completions == [1])
  }

  private func approximatelyEqual(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 0.01)
    -> Bool
  {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < tolerance }
  }

  @Test @MainActor func snapshotRecognitionLeavesTheUIExecutor() async throws {
    struct Probe: TextRecognizing {
      func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
        -> [OCRObservation]
      {
        #expect(!Thread.isMainThread)
        return [OCRObservation(
          text: "Background snapshot", confidence: 1,
          boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1))]
      }
    }
    let result = try await OCRJob.run(
      data: PDFFixtures.onePage(), pageIndexes: [0], languages: [], recognizer: Probe())
    #expect(result.count == 1)
    #expect(result[0].lines.first?.text == "Background snapshot")
  }

  @Test func cancellationDuringTheLastRecognitionCannotReturnResults() async throws {
    struct Probe: TextRecognizing {
      func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws
        -> [OCRObservation]
      {
        withUnsafeCurrentTask { $0?.cancel() }
        return [OCRObservation(
          text: "Canceled result", confidence: 1,
          boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1))]
      }
    }
    let bytes = try PDFFixtures.onePage()
    let job = Task {
      try await OCRJob.run(data: bytes, pageIndexes: [0], languages: [], recognizer: Probe())
    }
    switch await job.result {
    case .success: Issue.record("Last-page cancellation returned an applicable result")
    case .failure(let error): #expect(error is CancellationError)
    }
  }
}
