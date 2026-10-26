import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// IMG-06 evidence: export provenance, previewed reimport, preserved placement
/// geometry/masks, copy-on-write instance isolation and explicit refusals.
@Suite("External image edit round trip")
struct ExternalImageEditTests {
  @Test func classifiesOriginalSamplesAndReconstructionsHonestly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let target = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: parsed.graph)
    #expect(target.depth == 0)
    #expect(target.canReimport)
    #expect(target.mask == .none)
    #expect(target.pixelWidth == 2 && target.pixelHeight == 2)
    #expect(target.bounds == [80, 600, 200, 720])
    #expect(target.matrix == [120, 0, 0, 120, 80, 600])
    #expect(target.exportPlan.provenance == .originalStoredSamples)
    #expect(!target.exportPlan.requiresRendering)
    #expect(target.exportPlan.suggestedFileExtension == "png")
    let samples = try #require(target.exportPlan.losslessSamples)
    #expect(samples.width == 2 && samples.height == 2 && samples.components == .rgb)
    #expect(
      samples.samples == Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]))

    // A standalone JPEG stream is exported byte-for-byte as an original sample.
    var jpegGraph = parsed.graph
    guard case .stream(var imageStream)? = jpegGraph.objects[target.imageObjectID] else {
      Issue.record("image stream missing")
      return
    }
    let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
    imageStream.dictionary[PDFName("Filter")] = .name(PDFName("DCTDecode"))
    imageStream.dictionary[PDFName("Length")] = .integer(Int64(fakeJPEG.count))
    imageStream.bytes = fakeJPEG
    jpegGraph.objects[target.imageObjectID] = .stream(imageStream)
    let jpegTarget = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: jpegGraph)
    #expect(jpegTarget.exportPlan.provenance == .originalEncodedBytes)
    #expect(jpegTarget.exportPlan.originalBytes == fakeJPEG)
    #expect(jpegTarget.exportPlan.suggestedFileExtension == "jpg")
    #expect(!jpegTarget.exportPlan.requiresRendering)

    // A masked image cannot leave the document as original samples.
    let maskID = PDFObjectID(90)
    var maskedGraph = parsed.graph
    guard case .stream(var maskedStream)? = maskedGraph.objects[target.imageObjectID] else {
      Issue.record("image stream missing")
      return
    }
    maskedGraph.objects[maskID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: Data([255, 128, 64, 0])))
    maskedStream.dictionary[PDFName("SMask")] = .reference(maskID)
    maskedGraph.objects[target.imageObjectID] = .stream(maskedStream)
    let maskedTarget = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: maskedGraph)
    #expect(maskedTarget.exportPlan.provenance == .renderedReconstruction)
    #expect(maskedTarget.exportPlan.requiresRendering)
    #expect(!maskedTarget.exportPlan.notes.isEmpty)
    #expect(maskedTarget.canReimport)
  }

  @Test func reimportReplacesOnlyTheTargetInstanceAndPreservesGeometry() throws {
    let original = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = original.pageIDs[0]
    let secondPageID = original.pageIDs[1]
    let target = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: original.graph)
    let secondPlacement = try ImageInventory.placements(
      in: original.graph, pageID: pageID)[1]
    let secondPageObject = original.graph.objects[secondPageID]
    let originalSecondBytes = try imageBytes(secondPlacement.imageID, in: original.graph)
    let returnedRGB = Data([
      255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30,
    ])
    let returnedAlpha = Data([0, 64, 128, 255])
    let request = ExternalImageReplacementRequest(
      width: 2, height: 2, rgb8: returnedRGB, alpha8: returnedAlpha,
      sourceLabel: "edited.png")
    let plan = try ExternalImageEdit.planReplacement(
      target: target, returned: request, in: original.graph)
    #expect(plan.maskOutcome == .addedReturnedAlpha)
    #expect(!plan.aspectRatioChanged)
    #expect(plan.preservesPlacementGeometry)
    #expect(plan.commands.count == 1)
    #expect(plan.target.bounds == target.bounds)

    let replaced = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: original.graph)
    let placementsAfter = try ImageInventory.placements(in: replaced, pageID: pageID)
    #expect(placementsAfter.count == 2)
    // Size and orientation come from the placement matrix, which this profile
    // never rewrites.
    #expect(placementsAfter[0].matrix == target.matrix)
    #expect(placementsAfter[0].bounds == target.bounds)
    #expect(placementsAfter[1].matrix == secondPlacement.matrix)
    // The other draw of the same image resource is untouched.
    #expect(placementsAfter[1].imageID == secondPlacement.imageID)
    #expect(try imageBytes(secondPlacement.imageID, in: replaced) == originalSecondBytes)
    #expect(replaced.objects[secondPageID] == secondPageObject)
    // The target draw points at a fresh image object with the returned pixels
    // and an 8-bit alpha soft mask.
    #expect(placementsAfter[0].imageID != target.imageObjectID)
    guard case .stream(let newImage)? = replaced.objects[placementsAfter[0].imageID] else {
      Issue.record("replacement image missing")
      return
    }
    #expect(try PDFFilters.decoded(newImage) == returnedRGB)
    guard case .reference(let maskObjectID)? = newImage.dictionary[PDFName("SMask")],
      case .stream(let maskStream)? = replaced.objects[maskObjectID]
    else {
      Issue.record("replacement soft mask missing")
      return
    }
    #expect(try PDFFilters.decoded(maskStream) == returnedAlpha)

    // Save/reopen keeps the geometry and the replacement content.
    let reopened = try PDFParser.parse(PDFWriter.write(replaced))
    let reopenedPlacements = try ImageInventory.placements(
      in: reopened.graph, pageID: pageID)
    #expect(reopenedPlacements[0].bounds == target.bounds)
    #expect(reopenedPlacements[0].matrix == target.matrix)
    guard case .stream(let reopenedImage)? = reopened.graph.objects[
      reopenedPlacements[0].imageID]
    else {
      Issue.record("reopened replacement image missing")
      return
    }
    #expect(try PDFFilters.decoded(reopenedImage) == returnedRGB)
  }

  @Test func softMaskRoundTripRequiresAlphaOrExplicitDiscard() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    let blank = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceImageCommand(
          pageID: pageID, rect: [40, 40, 140, 120], width: 2, height: 2,
          rgb8: Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]),
          alpha8: Data([0, 85, 170, 255]))
      ]), to: parsed.graph)
    let target = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: blank)
    #expect(target.mask == .softMask)
    let returnedRGB = Data(repeating: 30, count: 12)
    let opaque = ExternalImageReplacementRequest(
      width: 2, height: 2, rgb8: returnedRGB)
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(target: target, returned: opaque, in: blank)
    }

    let discardOptions = ExternalImageReplacementOptions(
      allowReconstructedExport: true, discardExistingSoftMask: true)
    let discarded = try ExternalImageEdit.planReplacement(
      target: target, returned: opaque, options: discardOptions, in: blank)
    #expect(discarded.maskOutcome == .discardedOriginalMask)
    #expect(discarded.warnings.contains { $0.contains("soft mask is discarded") })
    let discardedGraph = try PDFEditingEngine.commit(
      PDFTransaction(discarded.commands), to: blank)
    let discardedImage = try #require(
      ImageInventory.placements(in: discardedGraph, pageID: pageID).first)
    guard case .stream(let image)? = discardedGraph.objects[discardedImage.imageID] else {
      Issue.record("discarded-mask image missing")
      return
    }
    #expect(image.dictionary[PDFName("SMask")] == nil)

    let alpha = Data([255, 128, 0, 64])
    let returned = ExternalImageReplacementRequest(
      width: 2, height: 2, rgb8: returnedRGB, alpha8: alpha)
    let plan = try ExternalImageEdit.planReplacement(
      target: target, returned: returned,
      options: ExternalImageReplacementOptions(allowReconstructedExport: true), in: blank)
    #expect(plan.maskOutcome == .replacedWithReturnedAlpha)
    let replaced = try PDFEditingEngine.commit(PDFTransaction(plan.commands), to: blank)
    let placement = try #require(
      ImageInventory.placements(in: replaced, pageID: pageID).first)
    guard case .stream(let image)? = replaced.objects[placement.imageID],
      case .reference(let maskID)? = image.dictionary[PDFName("SMask")],
      case .stream(let mask)? = replaced.objects[maskID]
    else {
      Issue.record("returned alpha did not become a soft mask")
      return
    }
    #expect(try PDFFilters.decoded(mask) == alpha)
  }

  @Test func reconstructionAndAspectRatioNeedExplicitChoices() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let target = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: parsed.graph)
    let maskID = PDFObjectID(91)
    var masked = parsed.graph
    guard case .stream(var stream)? = masked.objects[target.imageObjectID] else {
      Issue.record("image stream missing")
      return
    }
    masked.objects[maskID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: Data([255, 255, 255, 255])))
    stream.dictionary[PDFName("SMask")] = .reference(maskID)
    masked.objects[target.imageObjectID] = .stream(stream)
    let reconstructed = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: masked)
    #expect(reconstructed.exportPlan.provenance == .renderedReconstruction)
    let request = ExternalImageReplacementRequest(
      width: 2, height: 2, rgb8: Data(repeating: 220, count: 12),
      alpha8: Data([255, 255, 255, 255]))
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(
        target: reconstructed, returned: request, in: masked)
    }
    let accepted = try ExternalImageEdit.planReplacement(
      target: reconstructed, returned: request,
      options: ExternalImageReplacementOptions(allowReconstructedExport: true), in: masked)
    #expect(accepted.warnings.contains { $0.lowercased().contains("lossy") })

    // Aspect-ratio mismatch refuses by default and is a warned stretch when
    // explicitly allowed; the placement box never changes.
    let stretched = ExternalImageReplacementRequest(
      width: 4, height: 1, rgb8: Data(repeating: 5, count: 12))
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(
        target: target, returned: stretched, in: parsed.graph)
    }
    let stretchPlan = try ExternalImageEdit.planReplacement(
      target: target, returned: stretched,
      options: ExternalImageReplacementOptions(requireMatchingAspectRatio: false),
      in: parsed.graph)
    #expect(stretchPlan.aspectRatioChanged)
    #expect(stretchPlan.warnings.contains { $0.contains("stretched") })
    let committed = try PDFEditingEngine.commit(
      PDFTransaction(stretchPlan.commands), to: parsed.graph)
    let placement = try #require(
      ImageInventory.placements(in: committed, pageID: pageID).first)
    #expect(placement.bounds == target.bounds)
  }

  @Test func refusesNestedStencilAndColorKeyProfiles() throws {
    let nested = try nestedImageGraph()
    let nestedTarget = try ExternalImageEdit.target(
      pageID: nested.pageID, placementIndex: 0, in: nested.graph)
    #expect(nestedTarget.depth > 0)
    #expect(!nestedTarget.canReimport)
    #expect(nestedTarget.replacementRefusal?.contains("form XObject") == true)
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(
        target: nestedTarget,
        returned: ExternalImageReplacementRequest(
          width: 2, height: 2, rgb8: Data(repeating: 1, count: 12)),
        in: nested.graph)
    }

    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let base = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: parsed.graph)
    var stencil = parsed.graph
    guard case .stream(var stencilStream)? = stencil.objects[base.imageObjectID] else {
      Issue.record("image stream missing")
      return
    }
    stencilStream.dictionary[PDFName("ImageMask")] = .boolean(true)
    stencil.objects[base.imageObjectID] = .stream(stencilStream)
    let stencilTarget = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: stencil)
    #expect(stencilTarget.mask == .stencilMask)
    #expect(stencilTarget.replacementRefusal?.contains("stencil") == true)

    var colorKey = parsed.graph
    guard case .stream(var colorKeyStream)? = colorKey.objects[base.imageObjectID] else {
      Issue.record("image stream missing")
      return
    }
    colorKeyStream.dictionary[PDFName("Mask")] = .array([
      .integer(0), .integer(255), .integer(0), .integer(255), .integer(0), .integer(255),
    ])
    colorKey.objects[base.imageObjectID] = .stream(colorKeyStream)
    let colorKeyTarget = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: colorKey)
    #expect(colorKeyTarget.mask == .colorKeyMask)
    #expect(colorKeyTarget.replacementRefusal?.contains("color-key") == true)

    var explicitMask = parsed.graph
    guard case .stream(var explicitStream)? = explicitMask.objects[base.imageObjectID]
    else {
      Issue.record("image stream missing")
      return
    }
    explicitMask.objects[PDFObjectID(92)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("ImageMask"): .boolean(true),
          PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
        ], bytes: Data([0, 1])))
    explicitStream.dictionary[PDFName("Mask")] = .reference(PDFObjectID(92))
    explicitMask.objects[base.imageObjectID] = .stream(explicitStream)
    let explicitTarget = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: explicitMask)
    #expect(explicitTarget.mask == .explicitMask)
    #expect(explicitTarget.replacementRefusal?.contains("explicit mask") == true)
  }

  @Test func validatesReturnedRasterDimensions() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let target = try ExternalImageEdit.target(
      pageID: pageID, placementIndex: 0, in: parsed.graph)
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(
        target: target,
        returned: ExternalImageReplacementRequest(width: 2, height: 2, rgb8: Data([1])),
        in: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(
        target: target,
        returned: ExternalImageReplacementRequest(
          width: 2, height: 2, rgb8: Data(repeating: 0, count: 12),
          alpha8: Data([1, 2])),
        in: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try ExternalImageEdit.planReplacement(
        target: target,
        returned: ExternalImageReplacementRequest(width: 0, height: 2, rgb8: Data()),
        in: parsed.graph)
    }
  }

  // MARK: - Fixtures

  private func imageBytes(_ imageID: PDFObjectID, in graph: PDFGraph) throws -> Data {
    guard case .stream(let stream)? = graph.objects[imageID] else { return Data() }
    return stream.bytes
  }

  private func nestedImageGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let pageID = pageIDs[0]
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var xobjects)? = resources[PDFName("XObject")],
      case .reference(let imageID)? = xobjects[PDFName("Im1")]
    else {
      throw PDFError(.malformed, "image fixture resources missing")
    }
    let formID = PDFObjectID(50)
    let formResources: [PDFName: PDFValue] = [
      PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(imageID)])
    ]
    graph.objects[formID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary(formResources),
        ],
        bytes: Data("q 120 0 0 120 80 600 cm /Im1 Do Q\n".utf8)))
    xobjects[PDFName("Fm1")] = .reference(formID)
    resources[PDFName("XObject")] = .dictionary(xobjects)
    page[PDFName("Resources")] = .dictionary(resources)
    let formContent = Data("/Fm1 Do\n".utf8)
    switch page[PDFName("Contents")] {
    case .reference(let streamID)?:
      graph.objects[streamID] = .stream(
        PDFStream(
          dictionary: [PDFName("Length"): .integer(Int64(formContent.count))],
          bytes: formContent))
    default:
      throw PDFError(.malformed, "image fixture content missing")
    }
    graph.objects[pageID] = .dictionary(page)
    return (graph, pageID)
  }
}
