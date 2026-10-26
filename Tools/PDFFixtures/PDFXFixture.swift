import Foundation
import PDFCore

/// PRE-03/PRE-04 harness fixtures: a representative one-page print job with an
/// embedded TrueType subset, CMYK and gray paint, a CMYK image and a note
/// annotation; plus minimal refusal fixtures for unembedded fonts, RGB content
/// and transparency.
public enum PDFXFixture {
  public static func printJobPages() throws -> Data {
    let parsed = try PDFParser.parse(try PDFFixtures.fontEmbeddedPages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    let content = """
      0.15 0.85 0.10 0.05 k 36 36 540 60 re f
      0.55 g 36 700 200 20 re f
      0 0 0 1 K 2 w 36 120 m 576 120 l S
      BT /F1 24 Tf 42 650 Td (Print job) Tj ET
      q 200 0 0 150 100 400 cm /Im1 Do Q

      """
    var contentID: PDFObjectID?
    if case .reference(let id)? = contentReference(pageID: pageID, in: graph) {
      contentID = id
    } else {
      contentID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    }
    guard let contentID else { throw PDFError(.malformed, "fixture content object missing") }
    graph.objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
    let image = Data([0, 0, 0, 0, 255, 0, 255, 0, 0, 255, 255, 0, 40, 40, 40, 40])
    let imageID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[imageID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
          PDFName("ColorSpace"): .name(PDFName("DeviceCMYK")),
          PDFName("BitsPerComponent"): .integer(8),
        ], bytes: image))
    let appearanceID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[appearanceID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(20), .integer(20)]),
        ],
        bytes: Data("q 1 0 0 1 0 0 cm 0 0 20 20 re f Q\n".utf8)))
    let annotationID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[annotationID] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Text")),
      PDFName("Rect"): .array([.integer(40), .integer(40), .integer(60), .integer(60)]),
      PDFName("Contents"): .string(Data("Print note for the provider".utf8)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(appearanceID)]),
    ])
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "fixture page missing")
    }
    guard case .dictionary(var resources)? = page[PDFName("Resources")] else {
      throw PDFError(.malformed, "fixture resources missing")
    }
    resources[PDFName("XObject")] = .dictionary([PDFName("Im1"): .reference(imageID)])
    page[PDFName("Resources")] = .dictionary(resources)
    page[PDFName("CropBox")] = .array([.integer(18), .integer(18), .integer(594), .integer(774)])
    page[PDFName("BleedBox")] = .array([.integer(9), .integer(9), .integer(603), .integer(783)])
    page[PDFName("Annots")] = .array([.reference(annotationID)])
    page[PDFName("Contents")] = .reference(contentID)
    graph.objects[pageID] = .dictionary(page)
    return try PDFWriter.write(graph)
  }

  /// Standard-14 text: fonts are not embedded.
  public static func unembeddedFontPages() throws -> Data {
    try PDFFixtures.textWidthsPages()
  }

  /// RGB image content (x1a refusal; x4 permitted).
  public static func rgbContentPages() throws -> Data {
    try PDFFixtures.imagePages()
  }

  /// Transparency through an ExtGState with ca < 1 (x1a refusal; x4 permitted).
  public static func transparencyPages() throws -> Data {
    let parsed = try PDFParser.parse(try printJobPages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    let transparencyID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[transparencyID] = .dictionary([
      PDFName("Type"): .name(PDFName("ExtGState")),
      PDFName("ca"): .real(0.5),
      PDFName("CA"): .real(0.5),
    ])
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .dictionary(var resources)? = page[PDFName("Resources")]
    else { throw PDFError(.malformed, "fixture resources missing") }
    resources[PDFName("ExtGState")] = .dictionary([PDFName("GS0"): .reference(transparencyID)])
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
    return try PDFWriter.write(graph)
  }

  static func contentReference(pageID: PDFObjectID, in graph: PDFGraph) -> PDFValue? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    return page[PDFName("Contents")]
  }
}

