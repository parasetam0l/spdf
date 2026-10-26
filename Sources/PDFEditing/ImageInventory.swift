import Foundation
import PDFCore

/// P34-007/P34-008: one image placement on a page with the metadata needed to
/// decide whether the encoded data is independently usable or must be
/// reconstructed by rendering.
public struct PDFImageResource: Sendable, Equatable {
  public let pageIndex: Int
  /// Resource name (for example `Im1`).
  public let name: String
  public let objectID: PDFObjectID?
  public let width: Int
  public let height: Int
  public let bitsPerComponent: Int
  public let colorSpace: String
  public let filters: [String]
  public let hasSMask: Bool
  public let isImageMask: Bool
  /// IMG-03: mask/decode semantics needed to classify extraction honestly.
  public let softMaskObjectID: PDFObjectID?
  public let hasColorKeyMask: Bool
  public let hasExplicitMask: Bool
  public let decodeArrayPresent: Bool
  /// Placement bounds in unrotated page content space.
  public let bounds: [Double]
  /// The raw encoded stream bytes (as stored, before filters).
  public let encodedData: Data

  public init(
    pageIndex: Int, name: String, objectID: PDFObjectID?, width: Int, height: Int,
    bitsPerComponent: Int, colorSpace: String, filters: [String], hasSMask: Bool,
    isImageMask: Bool, bounds: [Double], encodedData: Data,
    softMaskObjectID: PDFObjectID? = nil, hasColorKeyMask: Bool = false,
    hasExplicitMask: Bool = false, decodeArrayPresent: Bool = false
  ) {
    self.pageIndex = pageIndex
    self.name = name
    self.objectID = objectID
    self.width = width
    self.height = height
    self.bitsPerComponent = bitsPerComponent
    self.colorSpace = colorSpace
    self.filters = filters
    self.hasSMask = hasSMask
    self.isImageMask = isImageMask
    self.softMaskObjectID = softMaskObjectID
    self.hasColorKeyMask = hasColorKeyMask
    self.hasExplicitMask = hasExplicitMask
    self.decodeArrayPresent = decodeArrayPresent
    self.bounds = bounds
    self.encodedData = encodedData
  }

  /// A standalone JPEG stream can be written as-is.
  public var isStandaloneJPEG: Bool {
    filters == ["DCTDecode"]
  }

  /// A standalone JPEG 2000 stream can be written as-is.
  public var isStandaloneJPEG2000: Bool {
    filters == ["JPXDecode"]
  }

  /// Stored samples that can be wrapped into a PNG without resampling.
  public var isWrappableSamples: Bool {
    guard !hasSMask, !isImageMask, bitsPerComponent == 8 else { return false }
    guard filters.isEmpty || filters == ["FlateDecode"] else { return false }
    return colorSpace == "DeviceRGB" || colorSpace == "DeviceGray"
  }

  /// True when the bytes can be exported without rendering.
  public var hasUsableOriginal: Bool {
    isStandaloneJPEG || isStandaloneJPEG2000 || isWrappableSamples
  }
}

public enum PDFImageInventory {
  /// Every image placement on the given pages, in page order. The same
  /// resource drawn twice yields two placements.
  public static func images(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> [PDFImageResource] {
    var result: [PDFImageResource] = []
    for (pageIndex, pageID) in pageIDs.enumerated() {
      try Task.checkCancellation()
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      var resources: [PDFName: PDFValue] = [:]
      if case .dictionary(let dictionary)? = page[PDFName("Resources")] {
        resources = dictionary
      } else if case .reference(let id)? = page[PDFName("Resources")],
        case .dictionary(let dictionary)? = graph.objects[id]
      {
        resources = dictionary
      }
      var xobjects: [PDFName: PDFValue] = [:]
      switch resources[PDFName("XObject")] {
      case .dictionary(let dictionary)?:
        xobjects = dictionary
      case .reference(let id)?:
        if case .dictionary(let dictionary)? = graph.objects[id] { xobjects = dictionary }
      default:
        break
      }
      let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
      let placements = try StructureTaggingAssistant.imagePlacements(in: content, graph: graph)
      for placement in placements {
        guard let entry = xobjects[PDFName(placement.name)] else { continue }
        let objectID: PDFObjectID?
        let stream: PDFStream
        switch entry {
        case .reference(let id):
          guard case .stream(let referenced)? = graph.objects[id] else { continue }
          objectID = id
          stream = referenced
        case .stream(let direct):
          objectID = nil
          stream = direct
        default:
          continue
        }
        guard stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image")) else { continue }
        let filters = (try? PDFFilters.filterNames(in: stream.dictionary))?.map {
          String(decoding: $0.bytes, as: UTF8.self)
        } ?? []
        let colorSpace: String
        switch stream.dictionary[PDFName("ColorSpace")] {
        case .name(let name)?:
          colorSpace = String(decoding: name.bytes, as: UTF8.self)
        case .array(let values)?:
          // Family arrays declare their space as the first entry (Separation,
          // DeviceN, ICCBased, Indexed, CalRGB, …).
          if case .name(let name)? = values.first {
            colorSpace = String(decoding: name.bytes, as: UTF8.self)
          } else if case .reference(let id)? = values.first,
            case .dictionary(let dictionary)? = graph.objects[id],
            case .name(let name)? = dictionary[PDFName("N")] ?? dictionary[PDFName("Alternate")]
          {
            colorSpace = String(decoding: name.bytes, as: UTF8.self)
          } else {
            colorSpace = ""
          }
        default:
          colorSpace = ""
        }
        result.append(
          PDFImageResource(
            pageIndex: pageIndex, name: placement.name, objectID: objectID,
            width: integer(stream.dictionary[PDFName("Width")]) ?? 0,
            height: integer(stream.dictionary[PDFName("Height")]) ?? 0,
            bitsPerComponent: integer(stream.dictionary[PDFName("BitsPerComponent")]) ?? 8,
            colorSpace: colorSpace, filters: filters,
            hasSMask: stream.dictionary[PDFName("SMask")] != nil
              || stream.dictionary[PDFName("Mask")] != nil,
            isImageMask: stream.dictionary[PDFName("ImageMask")] == .boolean(true),
            bounds: placement.bounds, encodedData: stream.bytes,
            softMaskObjectID: softMaskID(stream.dictionary[PDFName("SMask")]),
            hasColorKeyMask: isColorKeyMask(stream.dictionary[PDFName("Mask")]),
            hasExplicitMask: isExplicitMask(stream.dictionary[PDFName("Mask")]),
            decodeArrayPresent: stream.dictionary[PDFName("Decode")] != nil))
      }
    }
    return result
  }

  private static func integer(_ value: PDFValue?) -> Int? {
    guard case .integer(let raw)? = value else { return nil }
    return Int(exactly: raw)
  }

  private static func softMaskID(_ value: PDFValue?) -> PDFObjectID? {
    guard case .reference(let id)? = value else { return nil }
    return id
  }

  private static func isColorKeyMask(_ value: PDFValue?) -> Bool {
    if case .array? = value { return true }
    return false
  }

  private static func isExplicitMask(_ value: PDFValue?) -> Bool {
    if case .reference? = value { return true }
    return false
  }
}
