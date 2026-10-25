import Foundation
import PDFCore

/// OCR-04: attach a cleaned raster as a fresh image instance. The source image
/// stream is never rewritten, so Undo and extraction can recover the original
/// scan; only the targeted page draw switches to the new instance. Unlike the
/// general image-replace command this profile accepts any decodable source
/// codec (gray scans, JPEG) because the caller supplies the full RGB raster.
public struct ApplyScanCleanupCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let width: Int
  public let height: Int
  public let rgb8: Data

  public init(
    pageID: PDFObjectID, placementIndex: Int, width: Int, height: Int, rgb8: Data
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.width = width
    self.height = height
    self.rgb8 = rgb8
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Clean Up Scan" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolve(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let placement = try resolve(in: graph).placement
    var graph = graph
    let limits = PDFLimits()
    let bytes = try PDFFilters.encodeFlate(rgb8, limits: limits)
    let dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("Width"): .integer(Int64(width)),
      PDFName("Height"): .integer(Int64(height)),
      PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
      PDFName("BitsPerComponent"): .integer(8),
      PDFName("Filter"): .name(PDFName("FlateDecode")),
    ]
    try ImageInstanceEditing.attachCopy(
      in: &graph, pageID: pageID, placement: placement, dictionary: dictionary,
      bytes: bytes)
    // Pixel content changed, so a generated text layer no longer matches the
    // scan; callers that reconstruct text re-add a corrected layer afterwards.
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &graph)
    return graph
  }

  struct Resolved {
    let placement: ImagePlacement
  }

  func resolve(in graph: PDFGraph) throws -> Resolved {
    guard try PDFPageTree.pageIDs(in: graph).contains(pageID) else {
      throw PDFError(.malformed, "The scan page is missing")
    }
    guard width > 0, height > 0, width <= 20_000, height <= 20_000,
      rgb8.count == width * height * 3
    else {
      throw PDFError(.malformed, "The cleaned scan raster does not match its dimensions")
    }
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "The scanned image draw is missing")
    }
    let placement = placements[placementIndex]
    guard placement.depth == 0, placement.isDirectlyEditable,
      placement.hasSupportedClipping
    else {
      throw PDFError(
        .unsupported,
        "The scan is drawn inside a form or unsupported clip; cleanup cannot replace it safely")
    }
    let mask = try ImageMaskState.describe(imageID: placement.imageID, in: graph)
    guard !mask.hasSMask, !mask.hasMask, !mask.isStencil, !mask.hasDecode else {
      throw PDFError(
        .unsupported, "The scan uses a mask or decode array; cleanup would not preserve it")
    }
    return Resolved(placement: placement)
  }
}
