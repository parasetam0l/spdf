import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import Testing

private func policyGraph() throws -> PDFGraph {
  let graph = PDFGraph(
    objects: [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("OCProperties"): .reference(PDFObjectID(10)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([:]),
        PDFName("Contents"): .reference(PDFObjectID(4)),
      ]),
      PDFObjectID(4): .stream(PDFStream(bytes: Data("20 20 100 100 re f\n".utf8))),
      PDFObjectID(10): .dictionary([
        PDFName("OCGs"): .array([.reference(PDFObjectID(11)), .reference(PDFObjectID(12))]),
        PDFName("D"): .dictionary([
          PDFName("Name"): .string(Data("Layers".utf8)),
          PDFName("OFF"): .array([.reference(PDFObjectID(12))]),
        ]),
      ]),
      PDFObjectID(11): .dictionary([
        PDFName("Type"): .name(PDFName("OCG")),
        PDFName("Name"): .string(Data("Draft".utf8)),
      ]),
      PDFObjectID(12): .dictionary([
        PDFName("Type"): .name(PDFName("OCG")),
        PDFName("Name"): .string(Data("Review".utf8)),
      ]),
    ],
    trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  return try PDFParser.parse(try PDFWriter.write(graph)).graph
}

private func plainGraph() throws -> PDFGraph {
  let graph = PDFGraph(
    objects: [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([:]),
        PDFName("Contents"): .reference(PDFObjectID(4)),
      ]),
      PDFObjectID(4): .stream(PDFStream(bytes: Data("20 20 100 100 re f\n".utf8))),
    ],
    trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  return try PDFParser.parse(try PDFWriter.write(graph)).graph
}

private func policyPixel(in image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
  let width = image.width
  let height = image.height
  var data = [UInt8](repeating: 0, count: width * 4 * height)
  data.withUnsafeMutableBytes { buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  let offset = ((height - 1 - y) * width + x) * 4
  return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}

@Suite("Render policy tails")
struct RenderPolicyTests {
  // MARK: - P11-018 optional-content visibility

  @Test func optionalContentDefaultsResolveWithoutFiltering() throws {
    let policy = OptionalContentDisplayPolicy.resolve(in: try policyGraph())
    #expect(policy.groups.count == 2)
    #expect(policy.groups[0] == OptionalContentDisplayGroup(name: "Draft", visibleByDefault: true))
    #expect(
      policy.groups[1] == OptionalContentDisplayGroup(name: "Review", visibleByDefault: false))
    // Neither public renderer applies ON/OFF filtering; the policy says so
    // explicitly instead of claiming hidden layers.
    #expect(policy.appliesFiltering == false)
    #expect(!policy.reason.isEmpty)

    let plain = OptionalContentDisplayPolicy.resolve(in: try plainGraph())
    #expect(plain.isEmpty)
    #expect(plain.appliesFiltering == false)
  }

  // MARK: - P11-021 display versus export/print color

  @Test func displayBackgroundsAreDistinctFromExportChoices() async throws {
    let graph = try plainGraph()
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let white = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 0.5,
        background: .white))
    let transparent = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 0.5,
        background: .transparent))
    // Display: the two backgrounds are distinct cache entries with
    // different pixels — white composites opaquely, transparent leaves
    // the background clear.
    let stats = await service.cacheStatistics()
    #expect(stats.entries == 2)
    let centerWhite = policyPixel(in: white.image.image, x: white.pixelWidth / 2, y: white.pixelHeight / 2)
    #expect(centerWhite.0 == 255 && centerWhite.1 == 255 && centerWhite.2 == 255 && centerWhite.3 == 255)
    let centerClear = policyPixel(
      in: transparent.image.image, x: transparent.pixelWidth / 2, y: transparent.pixelHeight / 2)
    #expect(centerClear.3 == 0)

    // Export/print: explicit caller choices, separate from the display
    // bitmaps. RGB and gray exports of the same region both succeed and
    // differ, proving the choice is honored rather than assumed.
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let rgb = try PageImageExport.regionImageData(
      pageID: pageID, in: graph, region: [0, 0, 612, 792],
      options: PageImageExportOptions(format: .png, dpi: 36, colorModel: .rgb))
    let gray = try PageImageExport.regionImageData(
      pageID: pageID, in: graph, region: [0, 0, 612, 792],
      options: PageImageExportOptions(format: .png, dpi: 36, colorModel: .gray))
    #expect(!rgb.isEmpty && !gray.isEmpty)
    #expect(rgb != gray)
  }

  // MARK: - P11-028 rapid interaction freshness

  @Test func rapidScrollZoomEditNeverServesStaleContent() async throws {
    let slow: PageBitmapRenderer = { _, _, _, _, _, _ in
      try await Task.sleep(nanoseconds: 5_000_000)
      let context = CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      return PageBitmap(image: context.makeImage()!)
    }
    let graph = try plainGraph()
    let service = PageRenderService(renderer: slow)
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    // A burst of scroll/zoom-equivalent requests at several scales.
    await withTaskGroup(of: Void.self) { group in
      for scale in [0.5, 1.0, 2.0, 0.75, 1.5, 3.0] {
        group.addTask {
          _ = try? await service.render(
            PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: scale))
        }
      }
      // An edit lands mid-burst: the revision advances and in-flight
      // renders for the old revision are cancelled.
      try? await Task.sleep(nanoseconds: 2_000_000)
      try? await service.setSnapshot(documentID: id, revision: 2, graph: graph, changedPages: [0])
    }
    // Nothing from the old revision is served as new: the same request
    // under the new revision is a miss, and the old anchor is refused.
    let fresh = try await service.render(
      PageRenderRequest(documentID: id, revision: 2, pageIndex: 0, scale: 1.0))
    #expect(fresh.cacheHit == false)
    #expect(fresh.request.revision == 2)
    let staleAnchor = PageOverlayAnchor(
      documentID: id, revision: 1, pageIndex: 0, contentRect: [20, 20, 120, 120])
    do {
      _ = try await service.displayRect(for: staleAnchor)
      #expect(Bool(false), "a superseded overlay anchor must be refused")
    } catch let error as PageRenderError {
      #expect(error == .staleRevision(expected: 1, current: 2))
    }
    let currentAnchor = PageOverlayAnchor(
      documentID: id, revision: 2, pageIndex: 0, contentRect: [20, 20, 120, 120])
    let rect = try await service.displayRect(for: currentAnchor)
    #expect(rect.width == 100 && rect.height == 100)
  }
}
