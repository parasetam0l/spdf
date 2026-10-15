import Foundation

/// A new document starts with an empty page, without fixture content or metadata.
public enum BlankPageFormat: String, CaseIterable, Sendable {
  case a4
  case letter

  public var title: String { self == .a4 ? "A4" : "US Letter" }
  public var size: (width: Double, height: Double) {
    self == .a4 ? (595.276, 841.89) : (612, 792)
  }
}

public enum BlankPDF {
  public static func data(format: BlankPageFormat = .a4, landscape: Bool = false) throws -> Data {
    let size = format.size
    let width = landscape ? size.height : size.width
    let height = landscape ? size.width : size.height
    let catalog = PDFObjectID(1), pages = PDFObjectID(2), page = PDFObjectID(3)
    let graph = PDFGraph(objects: [
      catalog: .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")), PDFName("Pages"): .reference(pages),
      ]),
      pages: .dictionary([
        PDFName("Type"): .name(PDFName("Pages")), PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(page)]),
      ]),
      page: .dictionary([
        PDFName("Type"): .name(PDFName("Page")), PDFName("Parent"): .reference(pages),
        PDFName("MediaBox"): .array([.integer(0), .integer(0), .real(width), .real(height)]),
        PDFName("Resources"): .dictionary([:]),
      ]),
    ], trailer: [PDFName("Root"): .reference(catalog)])
    return try PDFWriter.write(graph)
  }
}
