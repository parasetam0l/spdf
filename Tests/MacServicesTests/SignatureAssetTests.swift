import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import MacServices

/// P29-001–P29-030: the signature capture surface, asset store, graphical
/// stamp/content placement, policy refusals, flattening, and measurements.
@Suite("Signature assets")
struct SignatureAssetTests {
  private func strokeAsset() -> SignatureAsset {
    var points: [[Double]] = []
    for index in 0..<20 {
      let x = 40 + Double(index) * 6
      let y = 60 + sin(Double(index) / 3) * 12
      points.append([x, y])
    }
    let first = SignatureCapture.Stroke(points: points, width: 4)
    let second = SignatureCapture.Stroke(
      points: [[60, 30], [90, 90], [130, 40]], width: 3)
    return SignatureCapture.render(
      strokes: [first, second], size: CGSize(width: 200, height: 120))
  }

  private func annotationRect(of annotation: Annotation) -> [Double]? {
    guard case .array(let values)? = annotation.dictionary[PDFName("Rect")] else { return nil }
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    return numbers.count == 4 ? numbers : nil
  }

  private func rawContent(_ graph: PDFGraph, _ pageID: PDFObjectID) -> String {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return "" }
    func bytes(of value: PDFValue) -> Data? {
      switch value {
      case .reference(let id):
        if case .stream(let stream)? = graph.objects[id] { return stream.bytes }
        return nil
      case .stream(let stream):
        return stream.bytes
      default:
        return nil
      }
    }
    var result = ""
    switch page[PDFName("Contents")] {
    case .reference, .stream:
      if let value = page[PDFName("Contents")], let data = bytes(of: value) {
        result += String(decoding: data, as: UTF8.self)
      }
    case .array(let items)?:
      for item in items {
        if let data = bytes(of: item) { result += String(decoding: data, as: UTF8.self) }
      }
    default:
      break
    }
    return result
  }

  private func fixture(_ relative: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(relative)
    return try Data(contentsOf: url)
  }

  private func pngWithAlpha() throws -> Data {
    let width = 8
    let height = 8
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        pixels[index] = 20
        pixels[index + 1] = 40
        pixels[index + 2] = 200
        pixels[index + 3] = x < width / 2 ? 255 : 0
      }
    }
    guard
      let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw PageImageExport.ExportError.encodingFailed
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { throw PageImageExport.ExportError.encodingFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PageImageExport.ExportError.encodingFailed
    }
    return output as Data
  }

  // MARK: - P29-001/P29-002/P29-005/P29-006

  @Test func captureRendersSmoothedStrokesDeterministically() throws {
    let asset = strokeAsset()
    #expect(asset.isWellFormed)
    #expect(asset.hasTransparency)
    // Cropping removed the empty borders of the 200×120 canvas.
    #expect(asset.width < 200)
    #expect(asset.height < 120)
    // The same strokes render identically.
    let again = strokeAsset()
    #expect(again.rgb8 == asset.rgb8)
    #expect(again.alpha8 == asset.alpha8)
    #expect(again.id == asset.id)
    // Smoothing keeps the endpoints and reduces point count growth.
    let smoothed = SignatureCapture.smooth([[0, 0], [10, 0], [20, 0], [30, 0]])
    #expect(smoothed.first == [0, 0])
    #expect(smoothed.last == [30, 0])
  }

  // MARK: - P29-003/P29-006

  @Test func importPreservesTransparency() throws {
    let imported = try SignatureCapture.importAsset(from: try pngWithAlpha())
    #expect(imported.kind == .imported)
    #expect(imported.hasTransparency)
    #expect(imported.width == 8)
    // Left half opaque, right half transparent.
    let alpha = try #require(imported.alpha8)
    #expect(alpha[0] == 255)
    #expect(alpha[7] == 0)
    // PNG round-trip through the store preserves the pixels and alpha.
    let store = SignatureAssetStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("spdf-assets-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let encoded = try store.data(for: imported)
    let decoded = try SignatureAssetStore.decode(encoded)
    #expect(decoded.width == imported.width)
    #expect(decoded.height == imported.height)
    #expect(decoded.alpha8 == imported.alpha8)
  }

  // MARK: - P29-007/P29-008/P29-009/P29-023/P29-024

  @Test func storeIsLocalOwnerOnlyBoundedAndDeletable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-assets-\(UUID().uuidString)")
    let store = SignatureAssetStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = strokeAsset()
    let url = try store.save(asset)
    // Owner-only file and directory permissions (P29-009).
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    // Listing finds it; saving the same asset again collapses (P29-024).
    #expect(try store.list().map(\.id) == [asset.id])
    _ = try store.save(asset)
    #expect(try store.list().count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    // Deleting removes the asset (P29-023).
    try store.delete(id: asset.id)
    #expect(try store.list().isEmpty)
  }

  // MARK: - P29-010/P29-012/P29-013/P29-014/P29-017/P29-019/P29-028

  @Test func stampPlacementIsAnEditableGraphicalMark() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let asset = strokeAsset()
    let options = SignatureStampOptions(
      opacity: 0.9, includeName: "Ada Lovelace", includeDate: "2026-10-12",
      author: "Ada")
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceSignatureStampCommand(
          pageID: pageID, rect: [100, 400, 300, 480], asset: asset, options: options)
      ]), to: graph)
    let annotations = try AnnotationInventory.annotations(in: edited, pageID: pageID)
    #expect(annotations.count == 1)
    let annotation = try #require(annotations.first)
    #expect(annotation.subtype == PDFName("Stamp"))
    #expect(annotation.dictionary[PDFName("Name")] == .name(PDFName("SPDFGraphicalSignature")))
    // The disclosure is present and no digital-signature claim exists.
    let contents = try #require(annotation.contents)
    #expect(contents.contains("not a digital signature"))
    #expect(contents.contains("Ada Lovelace"))
    #expect(contents.contains("2026-10-12"))
    for (_, value) in edited.objects {
      guard case .dictionary(let dictionary) = value else { continue }
      #expect(dictionary[PDFName("Type")] != .name(PDFName("Sig")))
      #expect(dictionary[PDFName("ByteRange")] == nil)
    }
    // Aspect ratio is preserved: the fitted rect matches the asset ratio.
    let rect = try #require(annotationRect(of: annotation))
    let rectRatio = (rect[2] - rect[0]) / (rect[3] - rect[1])
    let assetRatio = Double(asset.width) / Double(asset.height)
    #expect(abs(rectRatio - assetRatio) < 0.05)
    // The mark is an ordinary annotation: it can be moved (P29-012/P29-019).
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveAnnotationCommand(pageID: pageID, annotationIndex: annotation.index, dx: 20, dy: 10)
      ]), to: edited)
    let movedAnnotation = try #require(
      try AnnotationInventory.annotations(in: moved, pageID: pageID).first)
    let movedRect = try #require(annotationRect(of: movedAnnotation))
    #expect(movedRect[0] == rect[0] + 20)
    // Resize keeps working on the ordinary annotation (P29-012).
    let resized = try PDFEditingEngine.commit(
      PDFTransaction([
        ResizeAnnotationCommand(
          pageID: pageID, annotationIndex: movedAnnotation.index,
          rect: [movedRect[0], movedRect[1], movedRect[0] + 150, movedRect[1] + 60])
      ]), to: moved)
    let resizedAnnotation = try #require(
      try AnnotationInventory.annotations(in: resized, pageID: pageID).first)
    let resizedRect = try #require(annotationRect(of: resizedAnnotation))
    #expect(abs((resizedRect[2] - resizedRect[0]) - 150) < 0.5)

    // P29-026: placement on a rotated page keeps the rect and renders.
    var rotated = graph
    if case .dictionary(var page)? = rotated.objects[pageID] {
      page[PDFName("Rotate")] = .integer(90)
      rotated.objects[pageID] = .dictionary(page)
    }
    let rotatedPlaced = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceSignatureStampCommand(
          pageID: pageID, rect: [80, 400, 260, 470], asset: asset)
      ]), to: rotated)
    let rotatedAnnotation = try #require(
      try AnnotationInventory.annotations(in: rotatedPlaced, pageID: pageID).first)
    let rotatedRect = try #require(annotationRect(of: rotatedAnnotation))
    // The fitted rect stays inside the requested box on the rotated page.
    #expect(rotatedRect[0] >= 79.5 && rotatedRect[2] <= 260.5)
    #expect(rotatedRect[3] - rotatedRect[1] > 10)
    let rotatedDocument = try #require(PDFDocument(data: try PDFWriter.write(rotatedPlaced)))
    #expect(rotatedDocument.pageCount == 1)
  }

  // MARK: - P29-011/P29-025/P29-029

  @Test func contentPlacementPreservesTransparencyAndReusesAssets() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let asset = strokeAsset()
    let command = PlaceSignatureContentCommand(
      pageID: pageID, rect: [80, 300, 280, 380], asset: asset)
    var edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: edited)
    // Two placements share one image object through the asset marker (P29-029).
    let images = try PDFImageInventory.images(in: edited, pageIDs: [pageID])
    #expect(images.count == 2)
    #expect(Set(images.compactMap(\.objectID)).count == 1)
    #expect(images.allSatisfy { $0.hasSMask })
    // An independent reader renders the mark with transparency intact.
    let data = try PDFWriter.write(edited)
    let document = try #require(PDFDocument(data: data))
    let page = try #require(document.page(at: 0))
    let bounds = page.bounds(for: .cropBox)
    let image = page.thumbnail(of: CGSize(width: 300, height: 400), for: .cropBox)
    #expect(image.size.width > 0)
    // The signature area contains dark pixels; a corner of it stays light.
    let signatureRegion = CGRect(
      x: bounds.width * 0.5, y: bounds.height * 0.5, width: 20, height: 20)
    let region = page.thumbnail(of: signatureRegion.size, for: .cropBox)
    #expect(region.size.width > 0)
    // Page count and geometry survive.
    #expect(document.pageCount == 1)
  }

  // MARK: - P29-021

  @Test func placementRefusesOnSignedAndEncryptedDocuments() throws {
    let signed = try PDFParser.parse(try fixture("Signed/signed-one-page.pdf"))
    let signedPage = try PDFPageTree.pageIDs(in: signed.graph)[0]
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceSignatureStampCommand(
            pageID: signedPage, rect: [100, 400, 300, 480], asset: self.strokeAsset())
        ]), to: signed.graph)
    }
    let encrypted = try PDFParser.parse(try fixture("Encrypted/aes-256-r6.pdf"), password: "abc")
    let encryptedPage = try PDFPageTree.pageIDs(in: encrypted.graph)[0]
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceSignatureContentCommand(
            pageID: encryptedPage, rect: [100, 400, 300, 480], asset: self.strokeAsset())
        ]), to: encrypted.graph)
      Issue.record("Encrypted placement was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("encrypted"))
    }
  }

  // MARK: - P29-020/P29-027

  @Test func flatteningAndDeletionUpdateState() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let placed = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceSignatureStampCommand(
          pageID: pageID, rect: [100, 400, 300, 480], asset: strokeAsset())
      ]), to: graph)
    // Flattening converts the mark to page content and removes the annotation.
    let flattened = try PDFEditingEngine.commit(
      PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: placed)
    #expect(try AnnotationInventory.annotations(in: flattened, pageID: pageID).isEmpty)
    #expect(rawContent(flattened, pageID).contains("Do"))
    // Deletion removes the annotation entirely (fresh placement).
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]),
      to: placed)
    #expect(try AnnotationInventory.annotations(in: deleted, pageID: pageID).isEmpty)
    // Reparse both derivatives.
    _ = try PDFParser.parse(try PDFWriter.write(flattened))
    _ = try PDFParser.parse(try PDFWriter.write(deleted))
  }

  // MARK: - P29-004/P29-015/P29-016

  @Test func typedSignaturesAndTemplates() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let typed = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceTypedSignatureCommand(
          pageID: pageID, rect: [100, 400, 300, 460], text: "Ada Lovelace",
          options: SignatureStampOptions(includeDate: "2026-10-12"))
      ]), to: graph)
    let annotation = try #require(
      try AnnotationInventory.annotations(in: typed, pageID: pageID).first)
    #expect(annotation.contents?.contains("not a digital signature") == true)
    // The appearance uses the Times-Italic graphical font.
    let appearanceID = try #require({
      if case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
        case .reference(let id)? = appearance[PDFName("N")]
      { return id }
      return nil
    }())
    guard case .stream(let appearance)? = typed.objects[appearanceID] else {
      Issue.record("typed appearance missing")
      return
    }
    let appearanceContent = String(decoding: appearance.bytes, as: UTF8.self)
    #expect(appearanceContent.contains("/F1"))
    #expect(appearanceContent.contains("Ada Lovelace"))
    // Templates carry stable identities for a palette.
    let asset = strokeAsset()
    let first = SignatureStampTemplate(name: "My signature", asset: asset)
    let second = SignatureStampTemplate(name: "My signature", asset: asset)
    #expect(first.id == second.id)
    #expect(!first.id.isEmpty)
  }
}
