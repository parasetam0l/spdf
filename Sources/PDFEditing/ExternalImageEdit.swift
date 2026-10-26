import Foundation
import PDFCore

/// IMG-06: an explicit external-image-edit round trip for one image instance.
///
/// The profile is deliberately narrow and honest about provenance:
///
/// * Export: only an image whose stored stream is a standalone JPEG/JPEG 2000
///   can leave the document as original sample bytes. Everything else
///   (Flate/stored samples, masks, unusual color spaces, nested transforms) is
///   exported as a rendered reconstruction and the caller must say so.
/// * Reimport: the returned raster replaces this one placement only, through
///   the existing copy-on-write per-instance replacement command. The
///   placement matrix, bounds and orientation are preserved exactly, so size
///   and orientation survive; masks are preserved only when the returned
///   pixels carry an alpha plane (a soft mask), or when the caller explicitly
///   discards the old mask. Color-key, explicit-mask and stencil images refuse
///   this profile instead of silently changing transparency semantics.
/// * A reconstructed export can be edited externally, but reimporting it is
///   always labelled lossy and requires an explicit acknowledgement.
public enum ExternalImageExportProvenance: String, Sendable, Equatable {
  /// The exported file contains the image's original encoded bytes (JPEG/JP2).
  case originalEncodedBytes
  /// The exported file is the image's original stored samples, wrapped
  /// losslessly into PNG by the App (no resampling and no color conversion).
  case originalStoredSamples
  /// The exported file is a rendered reconstruction of the placement.
  case renderedReconstruction

  public var displayName: String {
    switch self {
    case .originalEncodedBytes: return "Original encoded sample bytes"
    case .originalStoredSamples: return "Original stored samples (lossless PNG)"
    case .renderedReconstruction: return "Rendered reconstruction"
    }
  }

  public var isOriginal: Bool { self != .renderedReconstruction }
}

/// Decoded 8-bit samples the App can wrap into a PNG losslessly for external
/// editing. Only plain DeviceGray/DeviceRGB 8-bit images with identity decode
/// and no mask qualify.
public struct ExternalImageLosslessSamples: Sendable, Equatable {
  public enum Components: String, Sendable, Equatable {
    case gray
    case rgb
  }

  public let width: Int
  public let height: Int
  public let components: Components
  /// Row-major 8-bit samples, exactly the stored grid.
  public let samples: Data

  public init(width: Int, height: Int, components: Components, samples: Data) {
    self.width = width
    self.height = height
    self.components = components
    self.samples = samples
  }
}

/// How the image dictionary reaches transparency.
public enum ExternalImageMaskKind: String, Sendable, Equatable {
  case none
  case softMask
  case colorKeyMask
  case explicitMask
  case stencilMask

  public var displayName: String {
    switch self {
    case .none: return "No mask"
    case .softMask: return "Soft mask (per-pixel alpha)"
    case .colorKeyMask: return "Color-key mask"
    case .explicitMask: return "Explicit mask"
    case .stencilMask: return "Stencil mask"
    }
  }
}

/// Export plan for one image instance: what kind of file the App should write
/// and why that provenance is the honest one.
public struct ExternalImageExportPlan: Sendable, Equatable {
  public let provenance: ExternalImageExportProvenance
  /// Original bytes when provenance is originalEncodedBytes; nil otherwise.
  public let originalBytes: Data?
  public let suggestedFileExtension: String
  public let pixelWidth: Int
  public let pixelHeight: Int
  /// Original decoded samples when provenance is originalStoredSamples.
  public let losslessSamples: ExternalImageLosslessSamples?
  /// True when the App must render the placement region to a raster instead of
  /// writing stored bytes.
  public let requiresRendering: Bool
  public let notes: [String]

  public init(
    provenance: ExternalImageExportProvenance, originalBytes: Data?,
    losslessSamples: ExternalImageLosslessSamples? = nil, suggestedFileExtension: String,
    pixelWidth: Int, pixelHeight: Int, requiresRendering: Bool, notes: [String]
  ) {
    self.provenance = provenance
    self.originalBytes = originalBytes
    self.losslessSamples = losslessSamples
    self.suggestedFileExtension = suggestedFileExtension
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.requiresRendering = requiresRendering
    self.notes = notes
  }
}

/// Everything the App needs to export, edit and reimport one image instance.
public struct ExternalImageTarget: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let resourceName: String
  public let imageObjectID: PDFObjectID
  /// Complete page-space placement matrix and bounds (unchanged by reimport).
  public let matrix: [Double]
  public let bounds: [Double]
  public let depth: Int
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let colorDescription: String
  public let filters: [String]
  public let mask: ExternalImageMaskKind
  public let hasDecodeArray: Bool
  public let exportPlan: ExternalImageExportPlan
  /// Nil when the instance can be reimported; otherwise the actionable reason.
  public let replacementRefusal: String?

  public init(
    pageID: PDFObjectID, placementIndex: Int, resourceName: String,
    imageObjectID: PDFObjectID, matrix: [Double], bounds: [Double], depth: Int,
    pixelWidth: Int, pixelHeight: Int, colorDescription: String, filters: [String],
    mask: ExternalImageMaskKind, hasDecodeArray: Bool,
    exportPlan: ExternalImageExportPlan, replacementRefusal: String?
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.resourceName = resourceName
    self.imageObjectID = imageObjectID
    self.matrix = matrix
    self.bounds = bounds
    self.depth = depth
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.colorDescription = colorDescription
    self.filters = filters
    self.mask = mask
    self.hasDecodeArray = hasDecodeArray
    self.exportPlan = exportPlan
    self.replacementRefusal = replacementRefusal
  }

  public var canReimport: Bool { replacementRefusal == nil }
  public var summary: String {
    "\(colorDescription) \(pixelWidth)x\(pixelHeight), \(mask.displayName)"
  }
}

/// Raster returned by the external editor, already decoded to straight 8-bit
/// RGB samples with an optional grayscale alpha plane (the App's ImageImport
/// contract).
public struct ExternalImageReplacementRequest: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let rgb8: Data
  public let alpha8: Data?
  /// File name/editor label used only in previews and warnings.
  public let sourceLabel: String

  public init(
    width: Int, height: Int, rgb8: Data, alpha8: Data? = nil, sourceLabel: String = ""
  ) {
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.alpha8 = alpha8
    self.sourceLabel = sourceLabel
  }
}

public struct ExternalImageReplacementOptions: Sendable, Equatable {
  /// Reimporting a rendered reconstruction is lossy; the caller must opt in.
  public var allowReconstructedExport: Bool
  /// Drop the original per-pixel mask when the returned raster has no alpha.
  public var discardExistingSoftMask: Bool
  /// Refuse when the returned aspect ratio no longer matches the placed image
  /// (avoids silent stretching). Set false to allow stretching to the same box.
  public var requireMatchingAspectRatio: Bool

  public init(
    allowReconstructedExport: Bool = false, discardExistingSoftMask: Bool = false,
    requireMatchingAspectRatio: Bool = true
  ) {
    self.allowReconstructedExport = allowReconstructedExport
    self.discardExistingSoftMask = discardExistingSoftMask
    self.requireMatchingAspectRatio = requireMatchingAspectRatio
  }
}

/// How reimport treats transparency.
public enum ExternalImageMaskOutcome: String, Sendable, Equatable {
  case originalHadNoMask
  case replacedWithReturnedAlpha
  case addedReturnedAlpha
  case discardedOriginalMask

  public var displayName: String {
    switch self {
    case .originalHadNoMask: return "No mask on the original image"
    case .replacedWithReturnedAlpha: return "Original soft mask replaced by the returned alpha"
    case .addedReturnedAlpha: return "Returned alpha added as a new soft mask"
    case .discardedOriginalMask: return "Original soft mask explicitly discarded"
    }
  }
}

/// The previewed replacement: one command, honest warnings and the preserved
/// geometry contract. The App commits the commands as one transaction.
public struct ExternalImageReplacementPlan: Sendable {
  public let target: ExternalImageTarget
  public let commands: [any PDFEditCommand]
  public let warnings: [String]
  public let maskOutcome: ExternalImageMaskOutcome
  public let aspectRatioChanged: Bool
  public let returnedPixelWidth: Int
  public let returnedPixelHeight: Int
  /// Matrix and bounds are never touched by this profile.
  public let preservesPlacementGeometry = true

  public init(
    target: ExternalImageTarget, commands: [any PDFEditCommand], warnings: [String],
    maskOutcome: ExternalImageMaskOutcome, aspectRatioChanged: Bool,
    returnedPixelWidth: Int, returnedPixelHeight: Int
  ) {
    self.target = target
    self.commands = commands
    self.warnings = warnings
    self.maskOutcome = maskOutcome
    self.aspectRatioChanged = aspectRatioChanged
    self.returnedPixelWidth = returnedPixelWidth
    self.returnedPixelHeight = returnedPixelHeight
  }

  public var summary: String {
    "Replace \(target.resourceName) on page content with the returned \(returnedPixelWidth)x"
      + "\(returnedPixelHeight) raster; placement, size and orientation stay unchanged."
  }
}

/// IMG-06 workflow support: resolve one target, describe its export
/// provenance, and plan a previewed reimport.
public enum ExternalImageEdit {
  /// Resolve the image instance under a placement index.
  public static func target(
    pageID: PDFObjectID, placementIndex: Int, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> ExternalImageTarget {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID, limits: limits)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "Image placement index is outside the page")
    }
    let placement = placements[placementIndex]
    guard case .stream(let stream)? = graph.objects[placement.imageID] else {
      throw PDFError(.malformed, "Image resource is missing")
    }
    let width = integer(stream.dictionary[PDFName("Width")]) ?? 0
    let height = integer(stream.dictionary[PDFName("Height")]) ?? 0
    let bits = integer(stream.dictionary[PDFName("BitsPerComponent")]) ?? 0
    let filters = ((try? PDFFilters.filterNames(in: stream.dictionary)) ?? []).map {
      String(decoding: $0.bytes, as: UTF8.self)
    }
    let colorDescription = colorSpaceDescription(stream.dictionary[PDFName("ColorSpace")])
    let mask = maskKind(stream.dictionary)
    let hasDecode = stream.dictionary[PDFName("Decode")] != nil
    let exportPlan = exportPlan(
      imageID: placement.imageID, in: graph, filters: filters, width: width, height: height)
    var refusal: String?
    if placement.depth > 0 {
      refusal =
        "This image is drawn inside a reusable form XObject. External reimport is "
        + "disabled because this profile cannot copy shared form content; the "
        + "instance-editing profile owns that case."
    } else if mask == .stencilMask {
      refusal =
        "This stencil mask paints with the graphics-state color and has no color "
        + "samples; external raster replacement cannot preserve it."
    } else if mask == .colorKeyMask {
      refusal =
        "This image uses a color-key mask. Replacing its samples would change which "
        + "colors are transparent, so external reimport is refused."
    } else if mask == .explicitMask {
      refusal =
        "This image uses a separate explicit mask image. External reimport would have "
        + "to combine two sources, so it is refused."
    }
    return ExternalImageTarget(
      pageID: pageID, placementIndex: placementIndex,
      resourceName: String(decoding: placement.resourceName.bytes, as: UTF8.self),
      imageObjectID: placement.imageID, matrix: placement.matrix, bounds: placement.bounds,
      depth: placement.depth, pixelWidth: width, pixelHeight: height,
      colorDescription: colorDescription, filters: filters, mask: mask,
      hasDecodeArray: hasDecode, exportPlan: exportPlan, replacementRefusal: refusal)
  }

  /// Every image placement on a page that the external round trip can address,
  /// with refusals kept visible for point-of-use explanations.
  public static func targets(pageID: PDFObjectID, in graph: PDFGraph) throws
    -> [ExternalImageTarget]
  {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    return try (0..<placements.count).map { index in
      try target(pageID: pageID, placementIndex: index, in: graph)
    }
  }

  /// Validate the returned raster and build the previewed replacement plan.
  public static func planReplacement(
    target: ExternalImageTarget,
    returned: ExternalImageReplacementRequest,
    options: ExternalImageReplacementOptions = ExternalImageReplacementOptions(),
    in graph: PDFGraph
  ) throws -> ExternalImageReplacementPlan {
    if let refusal = target.replacementRefusal {
      throw PDFError(.unsupported, refusal)
    }
    guard returned.width >= 1, returned.width <= 10_000,
      returned.height >= 1, returned.height <= 10_000,
      returned.rgb8.count == returned.width * returned.height * 3
    else {
      throw PDFError(
        .malformed, "The returned image dimensions do not match its RGB pixel data")
    }
    if let alpha = returned.alpha8, alpha.count != returned.width * returned.height {
      throw PDFError(.malformed, "The returned image alpha does not match its dimensions")
    }
    if target.exportPlan.provenance == .renderedReconstruction,
      !options.allowReconstructedExport
    {
      throw PDFError(
        .unsupported,
        "The exported file was a rendered reconstruction, not the original image "
          + "samples. Reimporting it is lossy; confirm the reconstruction round trip "
          + "explicitly instead of pretending the original pixels were preserved.")
    }
    var warnings: [String] = []
    if target.exportPlan.provenance == .renderedReconstruction {
      warnings.append(
        "The exported source was a rendered reconstruction (\(target.exportPlan.notes.first ?? "encoded bytes are not independently usable")); reimporting it is lossy.")
    }
    let maskOutcome: ExternalImageMaskOutcome
    switch target.mask {
    case .softMask:
      if returned.alpha8 != nil {
        maskOutcome = .replacedWithReturnedAlpha
      } else if options.discardExistingSoftMask {
        maskOutcome = .discardedOriginalMask
        warnings.append(
          "The original soft mask is discarded because the returned image has no alpha "
            + "plane; the replacement is fully opaque.")
      } else {
        throw PDFError(
          .unsupported,
          "The original image uses a soft mask. Return the edited image with "
            + "transparency, or explicitly discard the existing mask; transparency is "
            + "never dropped silently.")
      }
    case .none:
      maskOutcome = returned.alpha8 == nil ? .originalHadNoMask : .addedReturnedAlpha
    case .colorKeyMask, .explicitMask, .stencilMask:
      throw PDFError(
        .unsupported, "This mask profile is refused before any replacement is planned")
    }
    let originalAspect = Double(target.pixelWidth) / Double(max(1, target.pixelHeight))
    let returnedAspect = Double(returned.width) / Double(max(1, returned.height))
    let aspectChanged = abs(originalAspect - returnedAspect) > 0.02 * max(1, originalAspect)
    if aspectChanged {
      if options.requireMatchingAspectRatio {
        throw PDFError(
          .unsupported,
          "The returned image has a different aspect ratio than the placed image. "
            + "Keep the original aspect ratio, or allow stretching explicitly; the "
            + "placement box itself is never resized by this profile.")
      }
      warnings.append(
        "The returned image has a different aspect ratio and will be stretched to the "
          + "existing placement box; the placement geometry is unchanged.")
    }
    if let converted = explicitColorConversionNote(target) {
      warnings.append(converted)
    }
    warnings.append(
      "Only this placement is replaced; other drawings of the same image resource keep "
        + "their original bytes.")
    // A soft-mask image with no returned alpha can only be replaced through the
    // explicitly named RGB-conversion command: after IMG-03 the legacy direct-RGB
    // replacement refuses to drop a mask silently, and only the conversion
    // command honours the explicit soft-mask discard.
    let discardSoftMask =
      target.mask == .softMask && returned.alpha8 == nil && options.discardExistingSoftMask
    let command: any PDFEditCommand
    if discardSoftMask {
      command = ReplaceImageInstanceWithConversionCommand(
        pageID: target.pageID, placementIndex: target.placementIndex,
        width: returned.width, height: returned.height, rgb8: returned.rgb8,
        alpha8: returned.alpha8, discardSoftMask: true)
    } else {
      command = ReplaceImageDataCommand(
        pageID: target.pageID, placementIndex: target.placementIndex,
        width: returned.width, height: returned.height, rgb8: returned.rgb8,
        alpha8: returned.alpha8)
    }
    try command.validate(in: graph)
    return ExternalImageReplacementPlan(
      target: target, commands: [command], warnings: warnings, maskOutcome: maskOutcome,
      aspectRatioChanged: aspectChanged, returnedPixelWidth: returned.width,
      returnedPixelHeight: returned.height)
  }

  // MARK: - Classification

  private static func exportPlan(
    imageID: PDFObjectID, in graph: PDFGraph, filters: [String], width: Int, height: Int
  ) -> ExternalImageExportPlan {
    if let extracted = try? ImageOriginalExtraction.extract(imageID: imageID, in: graph) {
      let extensionName = extracted.suggestedExtension.lowercased()
      let standalone = extracted.usableAsStandaloneFile
      let isOriginalCodec =
        standalone && (extensionName == "jpg" || extensionName == "jpeg" || extensionName == "jp2")
      if isOriginalCodec {
        return ExternalImageExportPlan(
          provenance: .originalEncodedBytes, originalBytes: extracted.originalBytes,
          suggestedFileExtension: extensionName, pixelWidth: width, pixelHeight: height,
          requiresRendering: false,
          notes: [
            "Original \(extensionName.uppercased()) sample bytes are exported byte-for-byte; "
              + "the external editor may re-encode them on return.",
            extracted.note,
          ].filter { !$0.isEmpty })
      }
      if standalone, extensionName == "png",
        let samples = losslessSamples(from: extracted)
      {
        return ExternalImageExportPlan(
          provenance: .originalStoredSamples, originalBytes: nil,
          losslessSamples: samples, suggestedFileExtension: "png",
          pixelWidth: width, pixelHeight: height, requiresRendering: false,
          notes: [
            "Original stored samples are wrapped into a PNG losslessly; no resampling "
              + "and no color conversion.",
            extracted.note,
          ].filter { !$0.isEmpty })
      }
      return ExternalImageExportPlan(
        provenance: .renderedReconstruction, originalBytes: nil,
        suggestedFileExtension: "png", pixelWidth: width, pixelHeight: height,
        requiresRendering: true,
        notes: [
          extracted.note.isEmpty
            ? "This image's stored bytes are not independently usable as a file; the "
              + "export is a rendered reconstruction."
            : extracted.note,
          "The export is rendered at page scale, so it is not the original sample grid.",
        ])
    }
    return ExternalImageExportPlan(
      provenance: .renderedReconstruction, originalBytes: nil,
      suggestedFileExtension: "png", pixelWidth: width, pixelHeight: height,
      requiresRendering: true,
      notes: [
        "The image could not be extracted as a file; the export is a rendered "
          + "reconstruction.",
        "Original storage: \(filters.isEmpty ? "uncompressed samples" : filters.joined(separator: "+")).",
      ])
  }

  private static func losslessSamples(from extracted: ExtractedImageOriginal)
    -> ExternalImageLosslessSamples?
  {
    guard extracted.usableAsStandaloneFile, extracted.suggestedExtension == "png",
      extracted.bitsPerComponent == 8,
      extracted.colorSpace == "DeviceRGB" || extracted.colorSpace == "DeviceGray",
      !extracted.filters.contains(where: { $0 != "FlateDecode" }),
      let decoded = extracted.decodedSamples
    else { return nil }
    let components: ExternalImageLosslessSamples.Components =
      extracted.colorSpace == "DeviceGray" ? .gray : .rgb
    let componentCount = components == .gray ? 1 : 3
    guard decoded.count >= extracted.width * extracted.height * componentCount else {
      return nil
    }
    return ExternalImageLosslessSamples(
      width: extracted.width, height: extracted.height, components: components,
      samples: Data(decoded.prefix(extracted.width * extracted.height * componentCount)))
  }

  private static func explicitColorConversionNote(_ target: ExternalImageTarget) -> String? {
    let lower = target.colorDescription.lowercased()
    if lower.contains("devicergb") && target.filters == [] {
      return nil
    }
    if lower.contains("devicergb") && target.filters == ["FlateDecode"] {
      return nil
    }
    return
      "The returned pixels are stored as 8-bit DeviceRGB (lossless Flate); the original "
      + "\(target.colorDescription) \(target.filters.isEmpty ? "samples" : target.filters.joined(separator: "+")) "
      + "storage is replaced by that explicit conversion."
  }

  private static func maskKind(_ dictionary: [PDFName: PDFValue]) -> ExternalImageMaskKind {
    if dictionary[PDFName("ImageMask")] == .boolean(true) { return .stencilMask }
    if dictionary[PDFName("SMask")] != nil { return .softMask }
    switch dictionary[PDFName("Mask")] {
    case .array?: return .colorKeyMask
    case .reference?: return .explicitMask
    default: return .none
    }
  }

  private static func colorSpaceDescription(_ value: PDFValue?) -> String {
    switch value {
    case .name(let name)?:
      return String(decoding: name.bytes, as: UTF8.self)
    case .array(let values)?:
      guard let first = values.first, case .name(let name) = first else { return "unknown" }
      return String(decoding: name.bytes, as: UTF8.self)
    default:
      return "unknown"
    }
  }

  private static func integer(_ value: PDFValue?) -> Int? {
    switch value {
    case .integer(let number)?: return Int(number)
    case .real(let number)?: return Int(number)
    default: return nil
    }
  }
}
