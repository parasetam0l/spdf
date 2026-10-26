import CoreGraphics
import Foundation
import PDFCore

// PRE-05: color-managed conversion through public CoreGraphics color APIs.
// Declared profile: DeviceRGB is interpreted as sRGB, DeviceGray as Generic Gray
// gamma 2.2, DeviceCMYK as Generic CMYK; embedded ICCBased profiles are used as
// authored. Rendering intents map to CGColorRenderingIntent, black point
// compensation is explicit, and CMYK black preservation is an owned declared
// rule for neutral colors. Lab uses the public generic Lab color space.
// Everything unsupported is refused with a reason; profiles are never silently
// dropped (the target profile is written as an output intent unless disabled).

public enum ColorRenderingIntent: String, Sendable, CaseIterable, Hashable {
  case perceptual
  case relativeColorimetric
  case saturation
  case absoluteColorimetric

  public var title: String {
    switch self {
    case .perceptual: return "Perceptual"
    case .relativeColorimetric: return "Relative colorimetric"
    case .saturation: return "Saturation"
    case .absoluteColorimetric: return "Absolute colorimetric"
    }
  }

  var cgIntent: CGColorRenderingIntent {
    switch self {
    case .perceptual: return .perceptual
    case .relativeColorimetric: return .relativeColorimetric
    case .saturation: return .saturation
    case .absoluteColorimetric: return .absoluteColorimetric
    }
  }
}

public enum ColorSourceSpace: Sendable, Equatable {
  case deviceRGB
  case deviceGray
  case deviceCMYK
  case labD50
  case icc(name: String, data: Data, components: Int)

  public var title: String {
    switch self {
    case .deviceRGB: return "DeviceRGB (declared sRGB)"
    case .deviceGray: return "DeviceGray (declared Generic Gray gamma 2.2)"
    case .deviceCMYK: return "DeviceCMYK (declared Generic CMYK)"
    case .labD50: return "Lab (D50)"
    case .icc(let name, _, let components):
      return "ICC profile " + name + " (" + String(components) + " components)"
    }
  }
}

public enum ColorManagementTarget: Sendable, Equatable {
  case sRGB
  case genericGray
  case genericCMYK
  case labD50
  case icc(name: String, data: Data)

  public var title: String {
    switch self {
    case .sRGB: return "sRGB (declared DeviceRGB target)"
    case .genericGray: return "Generic Gray gamma 2.2 (declared DeviceGray target)"
    case .genericCMYK: return "Generic CMYK (declared DeviceCMYK target)"
    case .labD50: return "Lab (D50) (no output intent)"
    case .icc(let name, _): return "ICC profile " + name
    }
  }

  public var isCMYK: Bool {
    if case .genericCMYK = self { return true }
    if case .icc(_, let data) = self {
      return CGColorSpace(iccData: data as CFData)?.model == .cmyk
    }
    return false
  }

  func colorSpace() throws -> CGColorSpace {
    switch self {
    case .sRGB:
      return CGColorSpace(name: CGColorSpace.sRGB)!
    case .genericGray:
      return CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    case .genericCMYK:
      return CGColorSpace(name: CGColorSpace.genericCMYK)!
    case .labD50:
      return CGColorSpace(name: CGColorSpace.genericLab)!
    case .icc(_, let data):
      guard let space = CGColorSpace(iccData: data as CFData) else {
        throw PDFError(.unsupported, "The target ICC profile cannot be read")
      }
      return space
    }
  }

  func profileData() throws -> Data? {
    try colorSpace().copyICCData().map { $0 as Data }
  }

  public var components: Int {
    switch self {
    case .sRGB: return 3
    case .genericGray: return 1
    case .genericCMYK: return 4
    case .labD50: return 3
    case .icc(_, let data):
      return CGColorSpace(iccData: data as CFData)?.numberOfComponents ?? 0
    }
  }
}

public struct ColorManagementOptions: Sendable, Equatable {
  public let intent: ColorRenderingIntent
  public let blackPreservation: Bool
  public let blackPointCompensation: Bool
  public let writeOutputIntent: Bool
  public let outputConditionIdentifier: String
  /// Bounded deterministic profile: images with more unique colors than this
  /// are refused instead of silently approximated or partially converted.
  public let maximumUniqueColors: Int

  public init(
    intent: ColorRenderingIntent = .relativeColorimetric,
    blackPreservation: Bool = true,
    blackPointCompensation: Bool = true,
    writeOutputIntent: Bool = true,
    outputConditionIdentifier: String = "sPDF color-managed target",
    maximumUniqueColors: Int = 8_192
  ) {
    self.intent = intent
    self.blackPreservation = blackPreservation
    self.blackPointCompensation = blackPointCompensation
    self.writeOutputIntent = writeOutputIntent
    self.outputConditionIdentifier = outputConditionIdentifier
    self.maximumUniqueColors = maximumUniqueColors
  }

  public var summary: String {
    "Intent: " + intent.title + "; black preservation: "
      + (blackPreservation ? "on (neutral colors keep a K-only build)" : "off")
      + "; black point compensation: " + (blackPointCompensation ? "on" : "off")
      + "; output intent: " + (writeOutputIntent ? "written" : "not written") + "."
  }
}

public struct ColorManagementReport: Sendable, Equatable {
  public let convertedImages: Int
  public let convertedColors: Int
  public let fromSpaces: [String]
  public let toSpace: String
  public let options: ColorManagementOptions
  public let outputIntentWritten: Bool
  public let refused: [String]
  public let notes: [String]

  public init(
    convertedImages: Int, convertedColors: Int, fromSpaces: [String], toSpace: String,
    options: ColorManagementOptions, outputIntentWritten: Bool, refused: [String],
    notes: [String]
  ) {
    self.convertedImages = convertedImages
    self.convertedColors = convertedColors
    self.fromSpaces = fromSpaces
    self.toSpace = toSpace
    self.options = options
    self.outputIntentWritten = outputIntentWritten
    self.refused = refused
    self.notes = notes
  }

  public func report() -> String {
    var lines = [
      "Color-managed conversion - \(convertedImages) image(s) converted to \(toSpace)",
      "  " + options.summary,
      "  Source spaces: "
        + (fromSpaces.isEmpty ? "none" : fromSpaces.sorted().joined(separator: ", ")),
      "  Unique colors converted: \(convertedColors)",
      "  Output intent written: \(outputIntentWritten ? "yes" : "no")",
    ]
    for note in notes { lines.append("  Note: " + note) }
    for reason in refused { lines.append("  Refused: " + reason) }
    return lines.joined(separator: "\n")
  }
}

public enum ColorManagedConversion {
  /// Convert one color through public CoreGraphics color management with the
  /// declared intent and black-point settings. Returns target components in
  /// 0...1 (no alpha). Neutral black preservation is an owned, declared rule.
  public static func convertColor(
    _ components: [Double], from source: ColorSourceSpace, to target: ColorManagementTarget,
    options: ColorManagementOptions = ColorManagementOptions()
  ) throws -> [Double] {
    guard components.allSatisfy({ $0.isFinite }) else {
      throw PDFError(.malformed, "Color components must be finite")
    }
    let sourceSpace = try colorSpace(for: source)
    let targetSpace = try target.colorSpace()
    guard components.count == sourceSpace.numberOfComponents else {
      throw PDFError(.malformed, "Color components do not match the source space")
    }
    if let preserved = blackPreservedComponents(
      components, from: source, to: target, options: options)
    {
      return preserved
    }
    var cgComponents = components.map { CGFloat($0) }
    if case .labD50 = source { cgComponents.append(1.0) }
    guard let color = CGColor(colorSpace: sourceSpace, components: cgComponents) else {
      throw PDFError(.unsupported, "The source color cannot be constructed in " + source.title)
    }
    var conversionOptions: CFDictionary?
    if options.blackPointCompensation {
      conversionOptions = [CGColor.conversionBlackPointCompensation: true] as CFDictionary
    }
    guard
      let converted = color.converted(
        to: targetSpace, intent: options.intent.cgIntent, options: conversionOptions)
    else {
      throw PDFError(.unsupported, "Color conversion to " + target.title + " failed")
    }
    let targetComponents = Array((converted.components ?? []).map { Double($0) })
    let expected = target.components
    guard expected > 0, targetComponents.count >= expected else {
      throw PDFError(.unsupported, "The converted color has an unexpected component count")
    }
    return Array(targetComponents.prefix(expected))
  }

  static func colorSpace(for source: ColorSourceSpace) throws -> CGColorSpace {
    switch source {
    case .deviceRGB:
      return CGColorSpace(name: CGColorSpace.sRGB)!
    case .deviceGray:
      return CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    case .deviceCMYK:
      return CGColorSpace(name: CGColorSpace.genericCMYK)!
    case .labD50:
      return CGColorSpace(name: CGColorSpace.genericLab)!
    case .icc(_, let data, _):
      guard let space = CGColorSpace(iccData: data as CFData) else {
        throw PDFError(.unsupported, "The source ICC profile cannot be read")
      }
      return space
    }
  }

  /// Owned declared black-preservation rule: neutral gray/black input keeps a
  /// K-only build when converting to CMYK. Non-neutral colors always use the
  /// managed conversion.
  static func blackPreservedComponents(
    _ components: [Double], from source: ColorSourceSpace, to target: ColorManagementTarget,
    options: ColorManagementOptions
  ) -> [Double]? {
    guard options.blackPreservation, target.isCMYK else { return nil }
    let tolerance = 1.0 / 255.0
    switch source {
    case .deviceGray:
      guard components.count == 1 else { return nil }
      let gray = min(1, max(0, components[0]))
      return [0, 0, 0, 1 - gray]
    case .deviceRGB:
      guard components.count == 3 else { return nil }
      let red = min(1, max(0, components[0]))
      let green = min(1, max(0, components[1]))
      let blue = min(1, max(0, components[2]))
      guard abs(red - green) <= tolerance, abs(green - blue) <= tolerance else { return nil }
      return [0, 0, 0, 1 - red]
    case .deviceCMYK:
      guard components.count == 4 else { return nil }
      let cyan = min(1, max(0, components[0]))
      let magenta = min(1, max(0, components[1]))
      let yellow = min(1, max(0, components[2]))
      let black = min(1, max(0, components[3]))
      guard cyan <= 0.01, magenta <= 0.01, yellow <= 0.01 else { return nil }
      return [0, 0, 0, black]
    case .labD50, .icc:
      return nil
    }
  }
}

// MARK: - Image conversion

extension ColorManagedConversion {
  /// PRE-05: convert images in the document to the declared target and write an
  /// output intent. Refusals are explicit; no image is silently flattened.
  public static func convertImages(
    in graph: PDFGraph, pageIDs: [PDFObjectID], to target: ColorManagementTarget,
    options: ColorManagementOptions = ColorManagementOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: ColorManagementReport) {
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs, limits: limits)
    var objects = graph.objects
    var converted = 0
    var convertedColors = 0
    var fromSpaces: Set<String> = []
    var refused: [String] = []
    var notes: [String] = [
      "Declared profile: DeviceRGB is interpreted as sRGB, DeviceGray as Generic "
        + "Gray gamma 2.2, DeviceCMYK as Generic CMYK; embedded ICC profiles are used as authored.",
      "Target profile: " + target.title + ". Lab uses the public generic Lab color space.",
    ]
    var convertedIDs: Set<PDFObjectID> = []
    for image in images {
      try Task.checkCancellation()
      if let objectID = image.objectID, convertedIDs.contains(objectID) { continue }
      guard let objectID = image.objectID else {
        refused.append(image.name + ": the image stream is not directly addressable")
        continue
      }
      guard image.bitsPerComponent == 8 else {
        refused.append(image.name + ": only 8-bit samples are supported")
        continue
      }
      guard !image.hasSMask, !image.isImageMask, !image.hasColorKeyMask,
        !image.hasExplicitMask
      else {
        refused.append(image.name + ": masked images are not converted")
        continue
      }
      guard !image.decodeArrayPresent else {
        refused.append(image.name + ": Decode arrays are not applied")
        continue
      }
      let filters = image.filters.filter { $0 != "FlateDecode" }
      guard filters.isEmpty else {
        refused.append(
          image.name + ": filters " + filters.joined(separator: ", ")
            + " are not supported (lossy/compressed source samples are not re-interpreted)")
        continue
      }
      guard case .stream(let stream)? = objects[objectID] else {
        refused.append(image.name + ": the image stream is missing")
        continue
      }
      let source: ColorSourceSpace
      let sampleCount: Int
      do {
        (source, sampleCount) = try sourceSpace(for: stream, name: image.name, graph: graph)
      } catch {
        refused.append(image.name + ": " + error.localizedDescription)
        continue
      }
      let decoded = try PDFFilters.decoded(stream, limits: limits)
      let pixelCount = image.width * image.height
      guard pixelCount > 0,
        decoded.count >= pixelCount * sampleCount * (image.bitsPerComponent / 8)
      else {
        refused.append(image.name + ": decoded samples are shorter than the declared size")
        continue
      }
      let componentCount = sampleCount
      var uniqueKeys: Set<UInt64> = []
      let maxColors = max(1, options.maximumUniqueColors)
      var exceeded = false
      for pixel in 0..<pixelCount {
        if pixel % 4_096 == 0 { try Task.checkCancellation() }
        var key: UInt64 = 0
        for component in 0..<componentCount {
          let value = Int(decoded[pixel * componentCount + component])
          key = key &* 257 &+ UInt64(value)
        }
        uniqueKeys.insert(key)
        if uniqueKeys.count > maxColors {
          exceeded = true
          break
        }
      }
      if exceeded {
        refused.append(
          image.name + ": more than " + String(maxColors)
            + " unique colors; the declared bounded profile refuses rather than approximates")
        continue
      }
      var cache: [String: [Double]] = [:]
      var output = Data(capacity: pixelCount * max(1, target.components))
      for pixel in 0..<pixelCount {
        if pixel % 4_096 == 0 { try Task.checkCancellation() }
        let raw = (0..<componentCount).map {
          Double(decoded[pixel * componentCount + $0])
        }
        var components: [Double]
        switch source {
        case .deviceRGB, .icc:
          components = raw.map { $0 / 255.0 }
        case .deviceGray:
          components = raw.map { $0 / 255.0 }
        case .deviceCMYK:
          components = raw.map { $0 / 255.0 }
        case .labD50:
          components = labComponents(fromBytes: raw)
        }
        let key = components.map { String(Int(($0 * 1_000).rounded())) }.joined(separator: ",")
        let convertedComponents: [Double]
        if let cached = cache[key] {
          convertedComponents = cached
        } else {
          convertedComponents = try convertColor(
            components, from: source, to: target, options: options)
          cache[key] = convertedComponents
        }
        append(
          convertedComponents, to: target, into: &output)
      }
      var dictionary = stream.dictionary
      dictionary[PDFName("ColorSpace")] = try colorSpaceValue(
        for: target, graph: &objects)
      dictionary[PDFName("BitsPerComponent")] = .integer(8)
      dictionary[PDFName("Decode")] = nil
      let encoded = try PDFFilters.encodeFlate(output, limits: limits)
      dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
      dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
      objects[objectID] = .stream(PDFStream(dictionary: dictionary, bytes: encoded))
      convertedIDs.insert(objectID)
      converted += 1
      convertedColors += uniqueKeys.count
      fromSpaces.insert(source.title)
      if case .icc = source {
        notes.append(
          image.name
            + ": embedded ICC profile was used as authored; the target profile is "
            + "written as the output intent, so no profile is silently dropped.")
      }
    }
    var outputGraph = PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer)
    var outputIntentWritten = false
    if options.writeOutputIntent, target != .labD50, converted > 0 {
      do {
        outputGraph = try writeOutputIntent(
          in: outputGraph, target: target,
          identifier: options.outputConditionIdentifier)
        outputIntentWritten = true
      } catch {
        notes.append(
          "Output intent not written: " + error.localizedDescription
            + ". The target profile is declared in this report but not embedded.")
      }
    } else if target == .labD50 {
      notes.append("Lab target cannot carry an ICC output intent.")
    }
    let report = ColorManagementReport(
      convertedImages: converted, convertedColors: convertedColors,
      fromSpaces: Array(fromSpaces), toSpace: target.title, options: options,
      outputIntentWritten: outputIntentWritten, refused: refused, notes: notes)
    return (outputGraph, report)
  }

  static func sourceSpace(
    for stream: PDFStream, name: String, graph: PDFGraph
  ) throws -> (ColorSourceSpace, Int) {
    guard let value = stream.dictionary[PDFName("ColorSpace")] else {
      throw PDFError(.unsupported, "the image has no ColorSpace")
    }
    switch value {
    case .name(let colorSpaceName):
      switch Self.nameString(colorSpaceName) {
      case "DeviceRGB": return (.deviceRGB, 3)
      case "DeviceGray": return (.deviceGray, 1)
      case "DeviceCMYK": return (.deviceCMYK, 4)
      case "Lab": return (.labD50, 3)
      default:
        throw PDFError(
          .unsupported,
          "the source color space " + Self.nameString(colorSpaceName) + " is not supported")
      }
    case .array(let array):
      guard case .name(let family)? = array.first else {
        throw PDFError(.unsupported, "the image color space is not recognized")
      }
      switch Self.nameString(family) {
      case "ICCBased":
        guard array.count > 1, case .reference(let profileID) = array[1],
          case .stream(let profileStream)? = graph.objects[profileID]
        else {
          throw PDFError(.unsupported, "the ICCBased profile stream is missing")
        }
        guard case .integer(let components)? = profileStream.dictionary[PDFName("N")],
          (1...4).contains(Int(components))
        else {
          throw PDFError(.unsupported, "the ICCBased profile has no valid /N")
        }
        let data = try PDFFilters.decoded(profileStream, limits: PDFLimits())
        let label = "ICCBased/" + String(components) + "/" + String(data.count) + "B"
        return (.icc(name: label, data: data, components: Int(components)), Int(components))
      case "Lab":
        guard array.count > 1, case .dictionary(let lab) = array[1],
          let whitePoint = lab[PDFName("WhitePoint")]
        else {
          throw PDFError(.unsupported, "the Lab color space has no WhitePoint")
        }
        _ = whitePoint
        return (.labD50, 3)
      case "Separation", "DeviceN", "Indexed", "Pattern":
        throw PDFError(
          .unsupported,
          "the image color space " + Self.nameString(family)
            + " requires separation/spot handling that PRE-06 preview only reports")
      default:
        throw PDFError(.unsupported, "the image color space is not supported")
      }
    default:
      throw PDFError(.unsupported, "the image color space is not recognized")
    }
  }

  static func nameString(_ name: PDFName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
  }

  static func labComponents(fromBytes raw: [Double]) -> [Double] {
    guard raw.count >= 3 else { return raw }
    return [
      min(100, max(0, raw[0] / 255.0 * 100.0)),
      min(127, max(-128, raw[1] / 255.0 * 255.0 - 128.0)),
      min(127, max(-128, raw[2] / 255.0 * 255.0 - 128.0)),
    ]
  }

  static func append(
    _ components: [Double], to target: ColorManagementTarget, into data: inout Data
  ) {
    switch target {
    case .labD50:
      let l = min(255, max(0, (components[0] / 100.0 * 255.0).rounded()))
      let a = min(255, max(0, (components[1] + 128.0).rounded()))
      let b = min(255, max(0, (components[2] + 128.0).rounded()))
      data.append(UInt8(l))
      data.append(UInt8(a))
      data.append(UInt8(b))
    default:
      for component in components.prefix(max(1, target.components)) {
        data.append(UInt8(min(255, max(0, (component * 255.0).rounded()))))
      }
    }
  }

  static func colorSpaceValue(
    for target: ColorManagementTarget, graph: inout [PDFObjectID: PDFValue]
  ) throws -> PDFValue {
    switch target {
    case .sRGB: return .name(PDFName("DeviceRGB"))
    case .genericGray: return .name(PDFName("DeviceGray"))
    case .genericCMYK: return .name(PDFName("DeviceCMYK"))
    case .labD50:
      return .array([
        .name(PDFName("Lab")),
        .dictionary([
          PDFName("WhitePoint"): .array([
            .real(0.9642), .real(1.0), .real(0.8249),
          ]),
          PDFName("Range"): .array([
            .integer(-128), .integer(127), .integer(-128), .integer(127),
          ]),
        ]),
      ])
    case .icc(_, let data):
      let components = target.components
      let profileID = PDFObjectID((graph.keys.map(\.number).max() ?? 0) + 1)
      let alternate: PDFName =
        components == 4 ? PDFName("DeviceCMYK") : (components == 1 ? PDFName("DeviceGray") : PDFName("DeviceRGB"))
      graph[profileID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("N"): .integer(Int64(components)),
            PDFName("Alternate"): .name(alternate),
            PDFName("Length"): .integer(Int64(data.count)),
          ], bytes: data))
      return .array([.name(PDFName("ICCBased")), .reference(profileID)])
    }
  }

  /// PRE-05: write /OutputIntents with the declared target profile. The profile
  /// bytes are exactly the CoreGraphics target profile; they are not guessed.
  @discardableResult
  static func writeOutputIntent(
    in graph: PDFGraph, target: ColorManagementTarget, identifier: String
  ) throws -> PDFGraph {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "The document catalog is missing")
    }
    guard let profileData = try target.profileData(), !profileData.isEmpty else {
      throw PDFError(.unsupported, "The target profile has no ICC bytes")
    }
    let components = max(1, target.components)
    var objects = graph.objects
    let profileID = PDFObjectID((objects.keys.map(\.number).max() ?? 0) + 1)
    objects[profileID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("N"): .integer(Int64(components)),
          PDFName("Length"): .integer(Int64(profileData.count)),
        ], bytes: profileData))
    let intent: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("OutputIntent")),
      PDFName("S"): .name(PDFName("GTS_PDFX")),
      PDFName("OutputConditionIdentifier"): .string(
        Data(identifier.utf8)),
      PDFName("Info"): .string(Data(identifier.utf8)),
      PDFName("DestOutputProfile"): .reference(profileID),
    ]
    catalog[PDFName("OutputIntents")] = .array([.dictionary(intent)])
    objects[catalogID] = .dictionary(catalog)
    return PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer)
  }
}

// MARK: - Command

/// PRE-05: apply a declared color-managed image conversion and output intent.
/// Cancellation/refusals are reported by a dry run first; the command itself
/// only commits the converted graph. No image is silently flattened.
public struct ColorManagedConversionCommand: PDFEditCommand, Equatable, Sendable {
  public let target: ColorManagementTarget
  public let options: ColorManagementOptions

  public init(
    target: ColorManagementTarget, options: ColorManagementOptions = ColorManagementOptions()
  ) {
    self.target = target
    self.options = options
  }

  public var name: String { "Color-Managed Conversion" }

  public func validate(in graph: PDFGraph) throws {
    let pageIDs = try PageTreeView(graph: graph).pages
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    guard !images.isEmpty else {
      throw PDFError(.unsupported, "No images are available for color conversion")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let pageIDs = try PageTreeView(graph: graph).pages
    let result = try ColorManagedConversion.convertImages(
      in: graph, pageIDs: pageIDs, to: target, options: options)
    guard result.report.convertedImages > 0 else {
      throw PDFError(
        .unsupported,
        result.report.refused.first
          ?? "No image could be converted for the declared target")
    }
    return result.graph
  }
}
