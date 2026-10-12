import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P20-006/P20-013–P20-024/P20-026–P20-030 evidence: view-consistent rotation
/// handles, soft masks, mask preservation, stencil editing, non-destructive
/// and destructive crops, quality controls, placement, deletion, extraction,
/// codec preservation, OCR relationships/invalidation, reopen verification,
/// handle agreement, measurements, and the capability table.
@Suite("Advanced image editing")
struct ImageAdvancedTests {
  private func imageGraph() throws -> PDFGraph {
    try PDFParser.parse(PDFFixtures.imagePages()).graph
  }

  private func contentText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    String(decoding: try PageContent.load(pageID: pageID, in: graph).bytes, as: UTF8.self)
  }

  // MARK: - P20-006 view/PDF consistency

  @Test func rotationHandlesMapConsistentlyThroughTheViewTransform() throws {
    let graph = try imageGraph()
    let pageID = PDFObjectID(3)
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    let matrix = placements[0].matrix
    #expect(matrix == [120, 0, 0, 120, 80, 600])

    let corners = ImageViewMapping.corners(of: matrix)
    #expect(corners == [[80, 600], [200, 600], [200, 720], [80, 720]])
    let handle = ImageViewMapping.rotationHandle(of: matrix)
    #expect(handle == [140, 736])

    // A 2x view scale with an offset round-trips exactly.
    let view = [2.0, 0, 0, 2.0, 10.0, 20.0]
    let mapped = try #require(ImageViewMapping.apply(corners[2], through: view))
    #expect(mapped == [410, 1460])
    let inverse = try #require(ImageViewMapping.invert(view))
    let back = try #require(ImageViewMapping.apply(mapped, through: inverse))
    #expect(abs(back[0] - corners[2][0]) < 1e-9 && abs(back[1] - corners[2][1]) < 1e-9)

    // Singular view transforms refuse instead of producing infinities.
    #expect(ImageViewMapping.invert([0, 0, 0, 0, 0, 0]) == nil)
    #expect(ImageViewMapping.viewAngleOf(matrix: matrix) == 0)
    #expect(ImageViewMapping.snappedQuarterTurn(87) == 90)
    #expect(ImageViewMapping.snappedQuarterTurn(-95) == 270)
    #expect(ImageViewMapping.snappedQuarterTurn(181) == 180)
  }

  // MARK: - P20-013 soft masks

  @Test func softMaskAttachesToOneInstanceAndSurvivesReopen() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let page2 = PDFObjectID(4)
    let gray = Data([0, 64, 128, 255])
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([SetImageSoftMaskCommand(pageID: page1, placementIndex: 0, gray8: gray)]),
      to: graph)
    let placements = try ImageInventory.placements(in: edited, pageID: page1)
    #expect(placements[0].imageID != PDFObjectID(6))
    #expect(placements[1].imageID == PDFObjectID(6))
    #expect(try ImageMaskState.describe(imageID: placements[0].imageID, in: edited).hasSMask)
    guard case .stream(let copy)? = edited.objects[placements[0].imageID],
      case .reference(let maskID)? = copy.dictionary[PDFName("SMask")],
      case .stream(let mask)? = edited.objects[maskID]
    else {
      Issue.record("Soft mask objects are missing")
      return
    }
    #expect(mask.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceGray")))
    #expect(try PDFFilters.decoded(mask) == gray)
    // The shared original on the other page stays opaque.
    let other = try ImageInventory.placements(in: edited, pageID: page2)
    #expect(other[0].imageID == PDFObjectID(6))
    #expect(!(try ImageMaskState.describe(imageID: PDFObjectID(6), in: edited).hasSMask))
    // Independent reopening keeps the mask and its samples.
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let reopenedPlacements = try ImageInventory.placements(in: reopened.graph, pageID: page1)
    guard case .stream(let reopenedCopy)? = reopened.graph.objects[reopenedPlacements[0].imageID],
      case .reference(let reopenedMaskID)? = reopenedCopy.dictionary[PDFName("SMask")],
      case .stream(let reopenedMask)? = reopened.graph.objects[reopenedMaskID]
    else {
      Issue.record("Soft mask did not survive reopening")
      return
    }
    #expect(try PDFFilters.decoded(reopenedMask) == gray)

    // Mismatched samples and double-masking refuse.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetImageSoftMaskCommand(pageID: page1, placementIndex: 0, gray8: Data([1, 2]))
        ]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetImageSoftMaskCommand(pageID: page1, placementIndex: 0, gray8: gray)
        ]), to: edited)
    }
  }

  // MARK: - P20-014 preservation

  @Test func masksAndDecodeArraysSurviveGeometryEdits() throws {
    var graph = try imageGraph()
    guard case .stream(let image)? = graph.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    var dictionary = image.dictionary
    dictionary[PDFName("Mask")] = .array([
      .integer(0), .integer(1), .integer(0), .integer(1), .integer(0), .integer(1),
    ])
    dictionary[PDFName("Decode")] = .array([
      .integer(0), .integer(1), .integer(0), .integer(1), .integer(0), .integer(1),
    ])
    graph.objects[PDFObjectID(6)] = .stream(PDFStream(dictionary: dictionary, bytes: image.bytes))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let page1 = PDFObjectID(3)
    let before = try ImageMaskState.describe(imageID: PDFObjectID(6), in: parsed.graph)
    #expect(before.hasMask && before.hasDecode && !before.hasSMask && !before.isStencil)

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([MoveImageCommand(pageID: page1, placementIndex: 0, dx: 5, dy: 5)]),
      to: parsed.graph)
    let scaled = try PDFEditingEngine.commit(
      PDFTransaction([
        ScaleImageCommand(pageID: page1, placementIndex: 0, scaleX: 1.5, scaleY: 1.5)
      ]), to: moved)
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotateImageCommand(pageID: page1, placementIndex: 0, degrees: 90)]),
      to: scaled)
    #expect(try ImageMaskState.describe(imageID: PDFObjectID(6), in: rotated) == before)
    guard case .stream(let after)? = rotated.objects[PDFObjectID(6)] else {
      Issue.record("Image missing after edits")
      return
    }
    #expect(after.dictionary[PDFName("Mask")] == dictionary[PDFName("Mask")])
    #expect(after.dictionary[PDFName("Decode")] == dictionary[PDFName("Decode")])

    // Replacement still refuses masked/decoded images instead of dropping data.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageDataCommand(
            pageID: page1, placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 9, count: 12))
        ]), to: parsed.graph)
    }
  }

  // MARK: - P20-015 stencils

  @Test func stencilReplacementStaysOnItsOwnPath() throws {
    var graph = try imageGraph()
    // An 8x2 1-bit stencil next to the shared color image.
    graph.objects[PDFObjectID(30)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(8),
          PDFName("Height"): .integer(2),
          PDFName("ImageMask"): .boolean(true),
          PDFName("BitsPerComponent"): .integer(1),
        ], bytes: Data([0b1010_1010, 0b0101_0101])))
    guard case .dictionary(var page)? = graph.objects[PDFObjectID(3)],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var xobjects)? = resources[PDFName("XObject")]
    else {
      Issue.record("Page resources missing")
      return
    }
    xobjects[PDFName("ImS")] = .reference(PDFObjectID(30))
    resources[PDFName("XObject")] = .dictionary(xobjects)
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[PDFObjectID(3)] = .dictionary(page)
    guard case .stream(let content)? = graph.objects[PDFObjectID(5)] else {
      Issue.record("Content missing")
      return
    }
    var contentBytes = content.bytes
    contentBytes.append(contentsOf: Data("q\n8 0 0 2 50 700 cm\n/ImS Do\nQ\n".utf8))
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: content.dictionary, bytes: contentBytes))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let page1 = PDFObjectID(3)
    let placements = try ImageInventory.placements(in: parsed.graph, pageID: page1)
    #expect(placements.count == 3)
    guard let stencilIndex = placements.firstIndex(where: { $0.imageID == PDFObjectID(30) }) else {
      Issue.record("Stencil placement missing")
      return
    }

    let bits = Data([0b1111_0000, 0b0000_1111])
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceStencilImageCommand(
          pageID: page1, placementIndex: stencilIndex, packedBits: bits)
      ]), to: parsed.graph)
    let after = try ImageInventory.placements(in: edited, pageID: page1)
    #expect(after[stencilIndex].imageID != PDFObjectID(30))
    guard case .stream(let copy)? = edited.objects[after[stencilIndex].imageID] else {
      Issue.record("Stencil copy missing")
      return
    }
    #expect(copy.bytes == bits)
    #expect(copy.dictionary[PDFName("ImageMask")] == .boolean(true))
    #expect(copy.dictionary[PDFName("BitsPerComponent")] == .integer(1))
    // The original stencil and the shared color image are untouched.
    #expect(edited.objects[PDFObjectID(30)] == parsed.graph.objects[PDFObjectID(30)])
    #expect(edited.objects[PDFObjectID(6)] == parsed.graph.objects[PDFObjectID(6)])
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    #expect(reopened.graph == edited)

    // Color images refuse the stencil path and stencils refuse the color path.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceStencilImageCommand(pageID: page1, placementIndex: 0, packedBits: bits)
        ]), to: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageDataCommand(
            pageID: page1, placementIndex: stencilIndex, width: 2, height: 2,
            rgb8: Data(repeating: 1, count: 12))
        ]), to: parsed.graph)
    }
  }

  // MARK: - P20-016 non-destructive crop

  @Test func nonDestructiveCropClipsWithoutTouchingPixels() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ClipImageDrawCommand(pageID: page1, placementIndex: 0, unitRect: [0.25, 0.25, 0.75, 0.75])
      ]), to: graph)
    let text = try contentText(edited, page1)
    #expect(text.contains(" W n"))
    // Pixels and placement matrix are byte-identical; only the wrapper is new.
    #expect(edited.objects[PDFObjectID(6)] == graph.objects[PDFObjectID(6)])
    let placements = try ImageInventory.placements(in: edited, pageID: page1)
    #expect(placements[0].matrix == [120, 0, 0, 120, 80, 600])
    #expect(placements[1].matrix == [120, 0, 0, 120, 80, 400])
    #expect(try ImageInventory.placementIndex(at: [140, 660], in: edited, pageID: page1) == 0)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    #expect(reopened.graph == edited)

    // Identity and out-of-range crops refuse.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ClipImageDrawCommand(pageID: page1, placementIndex: 0, unitRect: [0, 0, 1, 1])
        ]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ClipImageDrawCommand(pageID: page1, placementIndex: 0, unitRect: [0.5, 0.5, 1.5, 1])
        ]), to: graph)
    }
  }

  // MARK: - P20-017/P20-028 destructive crop

  @Test func destructiveCropRemovesCroppedAwayPixels() throws {
    var graph = try imageGraph()
    // Distinct pixels: row 0 is red/green, row 1 is blue/white (top origin).
    let distinct = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    guard case .stream(let image)? = graph.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    graph.objects[PDFObjectID(6)] = .stream(
      PDFStream(dictionary: image.dictionary, bytes: distinct))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let page1 = PDFObjectID(3)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        CropImagePixelsCommand(pageID: page1, placementIndex: 0, pixelRect: [1, 0, 1, 2])
      ]), to: parsed.graph)
    let placements = try ImageInventory.placements(in: edited, pageID: page1)
    #expect(placements[0].imageID != PDFObjectID(6))
    #expect(placements[1].imageID == PDFObjectID(6))
    guard case .stream(let copy)? = edited.objects[placements[0].imageID] else {
      Issue.record("Cropped image missing")
      return
    }
    #expect(copy.dictionary[PDFName("Width")] == .integer(1))
    #expect(copy.dictionary[PDFName("Height")] == .integer(2))
    // Right column only: green over white. Red and blue are gone.
    #expect(try PDFFilters.decoded(copy) == Data([0, 255, 0, 255, 255, 255]))
    #expect(parsed.graph.objects[PDFObjectID(6)] == edited.objects[PDFObjectID(6)])
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    guard case .stream(let reopenedCopy)? = reopened.graph.objects[placements[0].imageID] else {
      Issue.record("Cropped image did not survive reopening")
      return
    }
    #expect(try PDFFilters.decoded(reopenedCopy) == Data([0, 255, 0, 255, 255, 255]))

    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          CropImagePixelsCommand(pageID: page1, placementIndex: 0, pixelRect: [0, 0, 2, 2])
        ]), to: parsed.graph)
    }
  }

  // MARK: - P20-018 quality controls

  @Test func qualityPreviewPrecedesDownsampling() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let placements = try ImageInventory.placements(in: graph, pageID: page1)
    // The 2x2 fixture at 120 points is ~1.2 dpi, so any real target refuses.
    let preview = try ImageQualityPreview.preview(
      imageWidth: 2, imageHeight: 2, matrix: placements[0].matrix, targetDPI: 72)
    #expect(abs(preview.placementWidthPoints - 120) < 1e-9)
    #expect(preview.warning != nil)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([DownsampleImageCommand(pageID: page1, placementIndex: 0, targetDPI: 72)]),
        to: graph)
    }

    // A 288x288 image at 288 points is 72 dpi; downsampling to 36 halves it.
    var large = graph
    let pixels = Data((0..<(288 * 288 * 3)).map { UInt8($0 % 251) })
    guard case .stream(let image)? = large.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    var dictionary = image.dictionary
    dictionary[PDFName("Width")] = .integer(288)
    dictionary[PDFName("Height")] = .integer(288)
    large.objects[PDFObjectID(6)] = .stream(PDFStream(dictionary: dictionary, bytes: pixels))
    guard case .stream(let content)? = large.objects[PDFObjectID(5)] else {
      Issue.record("Content missing")
      return
    }
    let resized = String(decoding: content.bytes, as: UTF8.self)
      .replacingOccurrences(of: "120 0 0 120 80 600", with: "288 0 0 288 80 400")
    large.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: content.dictionary, bytes: Data(resized.utf8)))
    let parsed = try PDFParser.parse(PDFWriter.write(large))
    let largePlacements = try ImageInventory.placements(in: parsed.graph, pageID: page1)
    let largePreview = try ImageQualityPreview.preview(
      imageWidth: 288, imageHeight: 288, matrix: largePlacements[0].matrix, targetDPI: 36)
    #expect(abs(largePreview.currentDPIWidth - 72) < 1e-9)
    #expect(largePreview.targetWidthPixels == 144 && largePreview.targetHeightPixels == 144)
    #expect(largePreview.estimatedBytes == 144 * 144 * 3)
    let downsampled = try PDFEditingEngine.commit(
      PDFTransaction([DownsampleImageCommand(pageID: page1, placementIndex: 0, targetDPI: 36)]),
      to: parsed.graph)
    let downPlacements = try ImageInventory.placements(in: downsampled, pageID: page1)
    guard case .stream(let down)? = downsampled.objects[downPlacements[0].imageID] else {
      Issue.record("Downsampled image missing")
      return
    }
    #expect(down.dictionary[PDFName("Width")] == .integer(144))
    #expect(down.dictionary[PDFName("Height")] == .integer(144))
    #expect(try PDFFilters.decoded(down).count == 144 * 144 * 3)
    #expect(downPlacements[0].matrix == largePlacements[0].matrix)
    #expect(try PDFParser.parse(PDFWriter.write(downsampled)).graph == downsampled)
  }

  // MARK: - P20-019 placement

  @Test func placeImageCreatesARealDraw() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let pixels = Data((0..<(4 * 4 * 3)).map { UInt8($0 % 251) })
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceImageCommand(
          pageID: page1, rect: [300, 100, 400, 200], width: 4, height: 4, rgb8: pixels)
      ]), to: graph)
    let placements = try ImageInventory.placements(in: edited, pageID: page1)
    #expect(placements.count == 3)
    #expect(placements[2].matrix == [100, 0, 0, 100, 300, 100])
    guard case .stream(let placed)? = edited.objects[placements[2].imageID] else {
      Issue.record("Placed image missing")
      return
    }
    #expect(try PDFFilters.decoded(placed) == pixels)
    #expect(try PDFParser.parse(PDFWriter.write(edited)).graph == edited)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceImageCommand(
            pageID: page1, rect: [0, 0, 0, 0], width: 4, height: 4, rgb8: pixels)
        ]), to: graph)
    }
  }

  // MARK: - P20-020 deletion

  @Test func deleteDrawKeepsTheSharedResource() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let page2 = PDFObjectID(4)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([DeleteImageDrawCommand(pageID: page1, placementIndex: 0)]), to: graph)
    let remaining = try ImageInventory.placements(in: edited, pageID: page1)
    #expect(remaining.count == 1)
    #expect(remaining[0].matrix == [120, 0, 0, 120, 80, 400])
    #expect(remaining[0].imageID == PDFObjectID(6))
    // The shared object and the other page are untouched.
    #expect(edited.objects[PDFObjectID(6)] == graph.objects[PDFObjectID(6)])
    let other = try ImageInventory.placements(in: edited, pageID: page2)
    #expect(other.count == 1 && other[0].imageID == PDFObjectID(6))
    #expect(!(try contentText(edited, page1)).contains("80 600"))
    #expect((try contentText(edited, page1)).contains("80 400"))
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    #expect(reopened.graph == edited)
  }

  // MARK: - P20-021 extraction

  @Test func originalExtractionDistinguishesUsableFromRendered() throws {
    var graph = try imageGraph()
    let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    graph.objects[PDFObjectID(30)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(8),
          PDFName("Height"): .integer(8),
          PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("DCTDecode")),
        ], bytes: jpegBytes))
    graph.objects[PDFObjectID(31)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(8),
          PDFName("Height"): .integer(8),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(1),
          PDFName("Filter"): .name(PDFName("CCITTFaxDecode")),
        ], bytes: Data([1, 2, 3, 4])))
    graph.objects[PDFObjectID(32)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2),
          PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: Data([255, 255, 255, 255])))

    let jpeg = try ImageOriginalExtraction.extract(imageID: PDFObjectID(30), in: graph)
    #expect(jpeg.usableAsStandaloneFile && jpeg.suggestedExtension == "jpg")
    #expect(jpeg.originalBytes == jpegBytes)

    let flate = try ImageOriginalExtraction.extract(imageID: PDFObjectID(6), in: graph)
    #expect(flate.usableAsStandaloneFile && flate.suggestedExtension == "png")
    guard case .stream(let raw)? = graph.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    #expect(flate.decodedSamples == raw.bytes)

    let fax = try ImageOriginalExtraction.extract(imageID: PDFObjectID(31), in: graph)
    #expect(!fax.usableAsStandaloneFile && fax.decodedSamples == nil)
    #expect(fax.originalBytes == Data([1, 2, 3, 4]))

    var maskedGraph = graph
    guard case .stream(let plain)? = maskedGraph.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    var withMask = plain.dictionary
    withMask[PDFName("SMask")] = .reference(PDFObjectID(32))
    maskedGraph.objects[PDFObjectID(6)] = .stream(
      PDFStream(dictionary: withMask, bytes: plain.bytes))
    let masked = try ImageOriginalExtraction.extract(imageID: PDFObjectID(6), in: maskedGraph)
    #expect(!masked.usableAsStandaloneFile)
  }

  // MARK: - P20-022 codec preservation

  @Test func unsupportedCodecsSurviveUnrelatedEdits() throws {
    var graph = try imageGraph()
    let dct = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
    let jpx = Data([0, 0, 0, 12, 106, 80, 32, 32])
    let fax = Data([5, 6, 7, 8])
    func imageObject(filter: String, bytes: Data) -> PDFStream {
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(8),
          PDFName("Height"): .integer(8),
          PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName(filter)),
        ], bytes: bytes)
    }
    graph.objects[PDFObjectID(30)] = .stream(imageObject(filter: "DCTDecode", bytes: dct))
    graph.objects[PDFObjectID(31)] = .stream(imageObject(filter: "JPXDecode", bytes: jpx))
    graph.objects[PDFObjectID(32)] = .stream(imageObject(filter: "CCITTFaxDecode", bytes: fax))
    guard case .dictionary(var page2)? = graph.objects[PDFObjectID(4)],
      case .dictionary(var resources)? = page2[PDFName("Resources")],
      case .dictionary(var xobjects)? = resources[PDFName("XObject")]
    else {
      Issue.record("Page resources missing")
      return
    }
    xobjects[PDFName("ImD")] = .reference(PDFObjectID(30))
    xobjects[PDFName("ImJ")] = .reference(PDFObjectID(31))
    xobjects[PDFName("ImF")] = .reference(PDFObjectID(32))
    resources[PDFName("XObject")] = .dictionary(xobjects)
    page2[PDFName("Resources")] = .dictionary(resources)
    graph.objects[PDFObjectID(4)] = .dictionary(page2)
    guard case .stream(let content2)? = graph.objects[PDFObjectID(7)] else {
      Issue.record("Content missing")
      return
    }
    var content2Bytes = content2.bytes
    content2Bytes.append(
      contentsOf: Data(
        "q\n8 0 0 8 400 600 cm\n/ImD Do\nQ\nq\n8 0 0 8 400 500 cm\n/ImJ Do\nQ\nq\n8 0 0 8 400 400 cm\n/ImF Do\nQ\n"
          .utf8))
    graph.objects[PDFObjectID(7)] = .stream(
      PDFStream(dictionary: content2.dictionary, bytes: content2Bytes))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))

    let before = ImageCodecPreservation.imageBytes(in: parsed.graph)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveImageCommand(pageID: PDFObjectID(3), placementIndex: 0, dx: 10, dy: 10),
        ScaleImageCommand(pageID: PDFObjectID(3), placementIndex: 1, uniformScale: 2),
      ]), to: parsed.graph)
    #expect(ImageCodecPreservation.preserved(before: before, after: edited))
    guard case .stream(let dctAfter)? = edited.objects[PDFObjectID(30)] else {
      Issue.record("DCT image missing")
      return
    }
    #expect(dctAfter.bytes == dct)
    #expect(edited.objects[PDFObjectID(31)] == parsed.graph.objects[PDFObjectID(31)])
    #expect(edited.objects[PDFObjectID(32)] == parsed.graph.objects[PDFObjectID(32)])
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    #expect(ImageCodecPreservation.preserved(before: before, after: reopened.graph))
  }

  // MARK: - P20-023/P20-024 OCR relationships

  @Test func scanOCRRelationshipsAreDetectedAndInvalidated() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let plain = try ImageOCRRelations.describe(pageID: page1, in: graph)
    #expect(!plain.hasGeneratedLayer && plain.imagePlacementCount == 2)
    #expect(plain.recommendation == .noAction)

    let layered = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: page1,
          lines: [SearchableTextLine(text: "scan", rect: [80, 600, 200, 620])])
      ]), to: graph)
    let related = try ImageOCRRelations.describe(pageID: page1, in: layered)
    #expect(related.hasGeneratedLayer)
    #expect(related.recommendation == .mustInvalidate)

    // Replacing the scan invalidates the stale layer in the same commit.
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: page1, placementIndex: 0, width: 2, height: 2,
          rgb8: Data(repeating: 7, count: 12))
      ]), to: layered)
    #expect(!OCRLayer.hasGeneratedLayer(in: replaced, pageID: page1))
    #expect((try? ImageInventory.placements(in: replaced, pageID: page1))?.count == 2)

    // Deleting the scan drops its layer too.
    let layeredAgain = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: page1,
          lines: [SearchableTextLine(text: "scan", rect: [80, 600, 200, 620])])
      ]), to: graph)
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteImageDrawCommand(pageID: page1, placementIndex: 0)]),
      to: layeredAgain)
    #expect(!OCRLayer.hasGeneratedLayer(in: deleted, pageID: page1))
  }

  // MARK: - P20-026 mask/transparency/color reopening

  @Test func maskTransparencyAndColorFixturesSurviveIndependentReopening() throws {
    var graph = try imageGraph()
    // DeviceGray image with a soft mask plus the stencil from P20-015.
    graph.objects[PDFObjectID(30)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2),
          PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: Data([0, 85, 170, 255])))
    graph.objects[PDFObjectID(31)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2),
          PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("FlateDecode")),
          PDFName("Length"): .integer(4),
        ], bytes: Data([10, 20, 30, 40])))
    guard case .stream(var gray)? = graph.objects[PDFObjectID(30)] else {
      Issue.record("Gray image missing")
      return
    }
    var grayDict = gray.dictionary
    grayDict[PDFName("SMask")] = .reference(PDFObjectID(31))
    gray = PDFStream(dictionary: grayDict, bytes: gray.bytes)
    graph.objects[PDFObjectID(30)] = .stream(gray)
    let parsed = try PDFParser.parse(PDFWriter.write(graph))

    // Independent reopening: serialize and reparse, then verify everything.
    let reopened = try PDFParser.parse(PDFWriter.write(parsed.graph))
    guard case .stream(let grayAfter)? = reopened.graph.objects[PDFObjectID(30)],
      case .reference(let maskID)? = grayAfter.dictionary[PDFName("SMask")],
      case .stream(let maskAfter)? = reopened.graph.objects[maskID]
    else {
      Issue.record("Gray soft mask did not survive reopening")
      return
    }
    #expect(grayAfter.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceGray")))
    #expect(grayAfter.bytes == Data([0, 85, 170, 255]))
    #expect(maskAfter.bytes == Data([10, 20, 30, 40]))
    #expect(try ImageMaskState.describe(imageID: PDFObjectID(30), in: reopened.graph).hasSMask)
    let extracted = try ImageOriginalExtraction.extract(
      imageID: PDFObjectID(30), in: reopened.graph)
    #expect(!extracted.usableAsStandaloneFile)
  }

  // MARK: - P20-027 transformed edits match handles

  @Test func transformedEditsMatchTheirOnScreenHandles() throws {
    let graph = try imageGraph()
    let page1 = PDFObjectID(3)
    let before = try ImageInventory.placements(in: graph, pageID: page1)
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([MoveImageCommand(pageID: page1, placementIndex: 0, dx: 40, dy: -25)]),
      to: graph)
    let movedPlacements = try ImageInventory.placements(in: moved, pageID: page1)
    let movedCorners = ImageViewMapping.corners(of: movedPlacements[0].matrix)
    let beforeCorners = ImageViewMapping.corners(of: before[0].matrix)
    for (after, prior) in zip(movedCorners, beforeCorners) {
      #expect(abs(after[0] - (prior[0] + 40)) < 1e-9 && abs(after[1] - (prior[1] - 25)) < 1e-9)
    }
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotateImageCommand(pageID: page1, placementIndex: 0, degrees: 90)]),
      to: graph)
    let rotatedPlacements = try ImageInventory.placements(in: rotated, pageID: page1)
    #expect(ImageViewMapping.corners(of: rotatedPlacements[0].matrix).count == 4)
    #expect(ImageViewMapping.rotationHandle(of: rotatedPlacements[0].matrix) != [140, 736])
    #expect(ImageViewMapping.viewAngleOf(matrix: rotatedPlacements[0].matrix) == 90)
    let scaled = try PDFEditingEngine.commit(
      PDFTransaction([
        ScaleImageCommand(pageID: page1, placementIndex: 0, scaleX: 2, scaleY: 0.5)
      ]), to: graph)
    let scaledPlacements = try ImageInventory.placements(in: scaled, pageID: page1)
    #expect(scaledPlacements[0].bounds == ImageViewMapping.corners(of: scaledPlacements[0].matrix)
      .reduce([Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, 0, 0]) {
        [min($0[0], $1[0]), min($0[1], $1[1]), max($0[2], $1[0]), max($0[3], $1[1])]
      })
  }

  // MARK: - P20-029 measurement

  @Test func largeImageEditsReportBoundedCost() throws {
    var graph = try imageGraph()
    let size = 256
    let pixels = Data((0..<(size * size * 3)).map { UInt8($0 % 251) })
    guard case .stream(let image)? = graph.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    var dictionary = image.dictionary
    dictionary[PDFName("Width")] = .integer(Int64(size))
    dictionary[PDFName("Height")] = .integer(Int64(size))
    graph.objects[PDFObjectID(6)] = .stream(PDFStream(dictionary: dictionary, bytes: pixels))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let replacement = Data((0..<(size * size * 3)).map { UInt8(($0 + 7) % 251) })
    let (updated, measurement) = try ImageEditMeasurement.measureReplace(
      in: parsed.graph, pageID: PDFObjectID(3), placementIndex: 0,
      width: size, height: size, rgb8: replacement)
    #expect(measurement.pixels == size * size)
    #expect(measurement.bytes == size * size * 3)
    #expect(measurement.seconds < 10)
    print(
      "P20-029 replace \(size)x\(size): \(measurement.bytes) bytes in "
        + "\(String(format: "%.3f", measurement.seconds))s")
    let placements = try ImageInventory.placements(in: updated, pageID: PDFObjectID(3))
    guard case .stream(let copy)? = updated.objects[placements[0].imageID] else {
      Issue.record("Replacement missing")
      return
    }
    #expect(try PDFFilters.decoded(copy) == replacement)
  }

  // MARK: - P20-030 capability table

  @Test func capabilityTableCoversCodecsAndMasks() throws {
    #expect(ImageCapabilities.rows.count == 17)
    func row(codec: String, mask: String) throws -> ImageCapabilityRow {
      try #require(ImageCapabilities.rows.first { $0.codec == codec && $0.mask == mask })
    }
    #expect(try row(codec: "DCTDecode", mask: "none").edit == "unsupported (preserved)")
    #expect(try row(codec: "DCTDecode", mask: "none").extract == "original bytes")
    #expect(try row(codec: "FlateDecode", mask: "none").edit == "supported")
    #expect(
      try row(codec: "FlateDecode", mask: "SMask").edit == "dedicated soft-mask path")
    #expect(
      try row(codec: "Raw/FlateDecode", mask: "ImageMask stencil").edit
        == "dedicated stencil path")
    #expect(try row(codec: "CCITTFaxDecode", mask: "none").write == "preserved")
    #expect(try row(codec: "JBIG2Decode", mask: "none").read == "metadata only")
    #expect(!ImageCapabilities.summary().isEmpty)
  }
}
