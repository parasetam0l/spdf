import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFFixtures
import Testing
import UniformTypeIdentifiers
@testable import MacServices

/// P34-003–P34-006/P34-026/P34-029: image export resolution, alpha, color,
/// orientation, deterministic names, batch cancellation, and buffer bounds.
@Suite("Page image export")
struct PageImageExportTests {
  private func image(from data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw PageImageExport.ExportError.cannotOpenDocument }
    return image
  }

  private func uti(of data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source)
    else { return nil }
    return type as String
  }

  @Test func pngExportMatchesResolutionAndAlphaPolicy() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let opaque = try PageImageExport.imageData(
      pageID: pageID, in: parsed.graph,
      options: PageImageExportOptions(format: .png, dpi: 72, includeAlpha: false))
    let opaqueImage = try image(from: opaque)
    #expect(opaqueImage.width == 612)
    #expect(opaqueImage.height == 792)
    #expect(opaqueImage.alphaInfo == .noneSkipLast)
    #expect(opaqueImage.colorSpace?.model == .rgb)
    #expect(uti(of: opaque) == UTType.png.identifier)

    let transparent = try PageImageExport.imageData(
      pageID: pageID, in: parsed.graph,
      options: PageImageExportOptions(format: .png, dpi: 144, includeAlpha: true))
    let transparentImage = try image(from: transparent)
    #expect(transparentImage.width == 1224)
    #expect(transparentImage.height == 1584)
    // ImageIO may return PNG alpha premultiplied or straight; both carry alpha.
    #expect(
      [CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(
        transparentImage.alphaInfo))
  }

  @Test func jpegQualityAndGrayscaleChoices() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let high = try PageImageExport.imageData(
      pageID: pageID, in: parsed.graph,
      options: PageImageExportOptions(format: .jpeg, dpi: 72, jpegQuality: 0.95))
    let low = try PageImageExport.imageData(
      pageID: pageID, in: parsed.graph,
      options: PageImageExportOptions(format: .jpeg, dpi: 72, jpegQuality: 0.2))
    #expect(uti(of: high) == UTType.jpeg.identifier)
    #expect(low.count < high.count)
    let gray = try PageImageExport.imageData(
      pageID: pageID, in: parsed.graph,
      options: PageImageExportOptions(format: .jpeg, dpi: 72, colorModel: .gray))
    let grayImage = try image(from: gray)
    #expect(grayImage.colorSpace?.model == .monochrome)
    #expect(grayImage.width == 612)
  }

  @Test func tiffExportOpensThroughImageIO() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let data = try PageImageExport.imageData(
      pageID: parsed.pageIDs[0], in: parsed.graph,
      options: PageImageExportOptions(format: .tiff, dpi: 72))
    #expect(uti(of: data) == UTType.tiff.identifier)
    let image = try image(from: data)
    #expect(image.width == 612)
    #expect(image.height == 792)
  }

  @Test func multiPageFilenamesAndRotation() async throws {
    let parsed = try PDFParser.parse(
      PDFWriter.write(PDFFixtures.graph(pages: 2, rotatedLastPage: true)))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-image-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let exported = try await PageImageExport.export(
      pages: parsed.pageIDs, in: parsed.graph, to: directory, baseName: "report",
      options: PageImageExportOptions(format: .png, dpi: 72))
    #expect(exported.count == 2)
    #expect(exported.map { $0.url.lastPathComponent } == ["report-0001.png", "report-0002.png"])
    #expect(exported[0].pixelWidth == 612 && exported[0].pixelHeight == 792)
    // The second page carries /Rotate 90: the rendered image is landscape.
    #expect(exported[1].pixelWidth == 842 && exported[1].pixelHeight == 595)
    for page in exported {
      #expect(FileManager.default.fileExists(atPath: page.url.path))
    }
  }

  @Test func batchExportReportsPerPageProgress() async throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-image-progress-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var calls: [(Int, Int)] = []
    _ = try await PageImageExport.export(
      pages: parsed.pageIDs, in: parsed.graph, to: directory, baseName: "page",
      options: PageImageExportOptions(format: .png, dpi: 72),
      progress: { done, total in calls.append((done, total)) })
    // P12-021: the producer calls back once per page with running totals —
    // the contract the progress center consumes.
    #expect(calls.map { $0.0 } == [1, 2, 3])
    #expect(calls.map { $0.1 } == [3, 3, 3])
  }

  @Test func batchCancellationAndBufferBounds() async throws {
    let parsed = try PDFParser.parse(PDFWriter.write(PDFFixtures.graph(pages: 8)))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-image-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    // P34-029 buffer bound: one page at 144 dpi needs about 7.8 MB, far below
    // any streaming threshold.
    let buffer = try PageImageExport.bufferBytes(
      pageID: parsed.pageIDs[0], in: parsed.graph,
      options: PageImageExportOptions(dpi: 144))
    print("[P34-029] per-page buffer: \(buffer / 1_024) KiB")
    #expect(buffer == 1224 * 1584 * 4)
    #expect(buffer < 64 * 1_024 * 1_024)

    // Cancellation: stop a large batch between pages and measure the latency.
    let task = Task {
      try await PageImageExport.export(
        pages: parsed.pageIDs, in: parsed.graph, to: directory, baseName: "batch",
        options: PageImageExportOptions(dpi: 200))
    }
    try await Task.sleep(for: .milliseconds(120))
    let cancelStart = ContinuousClock.now
    task.cancel()
    let result = await task.result
    let latency = ContinuousClock.now - cancelStart
    let latencyMilliseconds = latency.components.seconds * 1000
      + latency.components.attoseconds / 1_000_000_000_000_000
    let written = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    print("[P34-029] cancellation latency: \(latencyMilliseconds) ms, files: \(written)")
    switch result {
    case .success(let pages):
      // The batch may have finished before the cancellation arrived.
      #expect(pages.count == 8)
    case .failure(let error):
      #expect(error is CancellationError)
      #expect(written < 8)
    }
    #expect(latency < .seconds(2))

    // Peak buffer behavior: exporting pages sequentially must not accumulate
    // buffers; the resident footprint stays within a generous bound.
    let before = memoryFootprint()
    _ = try await PageImageExport.export(
      pages: parsed.pageIDs, in: parsed.graph, to: directory, baseName: "memory",
      options: PageImageExportOptions(dpi: 150))
    let after = memoryFootprint()
    let growth = after > before ? after - before : 0
    print("[P34-029] footprint growth: \(growth / 1_048_576) MiB")
    #expect(growth < 256 * 1_048_576)
  }

  private func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}

extension PageImageExportTests {
  /// P03-025: render snapshots carry renderer/OS metadata and reproduce
  /// byte-identically on one machine.
  @Test func renderSnapshotsAreReproducibleAndDescribed() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let first = try PageImageExport.snapshot(pageID: parsed.pageIDs[0], in: parsed.graph)
    let second = try PageImageExport.snapshot(pageID: parsed.pageIDs[0], in: parsed.graph)
    #expect(first.png == second.png)
    #expect(first.metadata["renderer"] == "CoreGraphics")
    #expect(!(first.metadata["os"] ?? "").isEmpty)
    #expect(first.metadata["pixels"] == "612x792")
    #expect(first.metadata["pageWidth"] == "612.00")
    // A rotated page snapshots at swapped pixel dimensions.
    let rotated = try PageImageExport.snapshot(pageID: parsed.pageIDs[2], in: parsed.graph)
    #expect(rotated.metadata["pixels"] == "792x612")
  }
}
