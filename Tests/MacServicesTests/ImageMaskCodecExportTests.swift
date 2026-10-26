import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import Testing

@testable import MacServices

/// IMG-03 evidence: CMYK JPEG/JPX bytes export byte-identically with their
/// color space noted, 8-bit samples with a soft mask export as an
/// alpha-preserving PNG, and color-key/stencil/CMYK sample images are only
/// offered as an explicitly rendered conversion.
@Suite("Image mask, codec and color export")
struct ImageMaskCodecExportTests {
  private func fixture() -> PDFGraph {
    let cmykJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
    let cmykJPX = Data([0, 0, 0, 12, 106, 80, 32, 32, 0x0D, 0x0A, 0x87, 0x0A])
    let rgbPixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    let alphaPixels = Data([0, 64, 128, 255])
    let renderableContent = """
      q 60 0 0 60 200 620 cm /ImAlpha Do Q
      q 60 0 0 60 280 620 cm /ImKey Do Q
      q 60 0 0 60 360 620 cm /ImStencil Do Q
      q 60 0 0 60 440 620 cm /ImCMYKR Do Q

      """
    let originalContent = """
      q 60 0 0 60 40 620 cm /ImCM Do Q
      q 60 0 0 60 120 620 cm /ImJP Do Q

      """
    func image(
      _ dictionary: [PDFName: PDFValue], _ bytes: Data
    ) -> PDFStream {
      var value: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("BitsPerComponent"): .integer(8),
      ]
      for (key, entry) in dictionary { value[key] = entry }
      return PDFStream(dictionary: value, bytes: bytes)
    }
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([
              PDFName("ImAlpha"): .reference(PDFObjectID(22)),
              PDFName("ImKey"): .reference(PDFObjectID(24)),
              PDFName("ImStencil"): .reference(PDFObjectID(25)),
              PDFName("ImCMYKR"): .reference(PDFObjectID(26)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([
              PDFName("ImCM"): .reference(PDFObjectID(20)),
              PDFName("ImJP"): .reference(PDFObjectID(21)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(renderableContent.utf8))),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(originalContent.utf8))),
        PDFObjectID(20): .stream(
          image(
            [
              PDFName("Width"): .integer(8), PDFName("Height"): .integer(8),
              PDFName("ColorSpace"): .name(PDFName("DeviceCMYK")),
              PDFName("Filter"): .name(PDFName("DCTDecode")),
            ], cmykJPEG)),
        PDFObjectID(21): .stream(
          image(
            [
              PDFName("Width"): .integer(8), PDFName("Height"): .integer(8),
              PDFName("ColorSpace"): .name(PDFName("DeviceCMYK")),
              PDFName("Filter"): .name(PDFName("JPXDecode")),
            ], cmykJPX)),
        PDFObjectID(22): .stream(
          image(
            [
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("SMask"): .reference(PDFObjectID(23)),
            ], rgbPixels)),
        PDFObjectID(23): .stream(
          image(
            [
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
            ], alphaPixels)),
        PDFObjectID(24): .stream(
          image(
            [
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("Mask"): .array([
                .integer(0), .integer(255), .integer(0),
              ]),
            ], rgbPixels)),
        PDFObjectID(25): .stream(
          image(
            [
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ImageMask"): .boolean(true),
              PDFName("BitsPerComponent"): .integer(1),
            ], Data([0xF0, 0xF0]))),
        PDFObjectID(26): .stream(
          image(
            [
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceCMYK")),
            ], Data(repeating: 64, count: 16))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func export(_ graph: PDFGraph) async throws -> [PDFExportedImage] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-IMG03-\(UUID().uuidString)")
    return try await PDFImageExport.export(
      pageIDs: pageIDs, in: graph, to: directory, baseName: "doc")
  }

  @Test func cmykAndCodecBytesExportAsOriginalWithColorNotes() async throws {
    let graph = fixture()
    let exported = try await export(graph)
    let cmykJPEG = try #require(exported.first { $0.name == "ImCM" })
    #expect(cmykJPEG.provenance == .original)
    #expect(cmykJPEG.url.pathExtension == "jpg")
    #expect(cmykJPEG.preservationNote.contains("DeviceCMYK"))
    let cmykJPX = try #require(exported.first { $0.name == "ImJP" })
    #expect(cmykJPX.provenance == .original)
    #expect(cmykJPX.url.pathExtension == "jp2")
    #expect(cmykJPX.preservationNote.contains("JPEG 2000"))
  }

  @Test func softMaskedSamplesExportAlphaPreservingPNG() async throws {
    let graph = fixture()
    let exported = try await export(graph)
    let alpha = try #require(exported.first { $0.name == "ImAlpha" })
    #expect(alpha.provenance == .original)
    #expect(alpha.url.pathExtension == "png")
    #expect(alpha.pixelWidth == 2 && alpha.pixelHeight == 2)
    #expect(alpha.preservationNote.contains("soft mask"))
    guard let source = CGImageSourceCreateWithURL(alpha.url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      Issue.record("Alpha-preserving PNG did not reopen")
      return
    }
    #expect(image.width == 2 && image.height == 2)
    #expect(image.alphaInfo == .last || image.alphaInfo == .premultipliedLast)
    var rgba = [UInt8](repeating: 0, count: 2 * 2 * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
      return true
    }
    guard drawn else {
      Issue.record("Alpha-preserving PNG could not be sampled")
      return
    }
    let alphaValues = Set(stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
    #expect(alphaValues == [0, 64, 128, 255])
  }

  @Test func colorKeyStencilAndCMYKRenderExplicitly() async throws {
    let graph = fixture()
    let exported = try await export(graph)
    let key = try #require(exported.first { $0.name == "ImKey" })
    #expect(key.provenance == .reconstructed)
    #expect(key.preservationNote.contains("color-key"))
    let stencil = try #require(exported.first { $0.name == "ImStencil" })
    #expect(stencil.provenance == .reconstructed)
    #expect(stencil.preservationNote.contains("Stencil"))
    let cmyk = try #require(exported.first { $0.name == "ImCMYKR" })
    #expect(cmyk.provenance == .reconstructed)
    #expect(cmyk.preservationNote.contains("DeviceCMYK"))
  }
}
