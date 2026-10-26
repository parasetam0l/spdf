import Foundation
import PDFCore

/// P37-023/P37-025: read-only preflight checks over the print inventory. The
/// checks never modify the document and never claim PDF/X conformance; PDF/X
/// export is a separate declared-subset converter (see PDFXOutput.swift).
public struct PreflightCheckReport: Sendable, Equatable {
  public struct Finding: Sendable, Equatable {
    public let rule: String
    public let severity: ArchivalInventory.Finding.Severity
    public let detail: String

    public init(rule: String, severity: ArchivalInventory.Finding.Severity, detail: String) {
      self.rule = rule
      self.severity = severity
      self.detail = detail
    }
  }

  public let findings: [Finding]

  public init(findings: [Finding]) {
    self.findings = findings
  }

  public var errorCount: Int { findings.filter { $0.severity == .error }.count }
  public var warningCount: Int { findings.filter { $0.severity == .warning }.count }

  /// P37-025: these read-only checks do not implement PDF/X output. The
  /// declared-subset PDF/X converter is a separate route; no ISO PDF/X
  /// certification is claimed by either.
  public static let pdfxSupported = false

  /// P37-023: supported checks, computed from the print inventory without
  /// altering anything.
  public static func run(
    _ graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> PreflightCheckReport {
    var findings: [Finding] = []
    let inventory = PrintPreflightInventory.inventory(graph, pageIDs: pageIDs)

    if inventory.fontsNotEmbedded > 0 {
      findings.append(
        Finding(
          rule: "Font embedding", severity: .error,
          detail:
            "\(inventory.fontsNotEmbedded) font\(inventory.fontsNotEmbedded == 1 ? "" : "s") not embedded; press workflows require embedded fonts."))
    } else if inventory.fontsEmbedded > 0 {
      findings.append(
        Finding(
          rule: "Font embedding", severity: .info,
          detail: "\(inventory.fontsEmbedded) embedded font\(inventory.fontsEmbedded == 1 ? "" : "s")."))
    }

    if inventory.lowResolutionImages > 0 {
      let below = inventory.images.filter {
        $0.dpiX < PrintPreflightInventory.lowResolutionDPI
          || $0.dpiY < PrintPreflightInventory.lowResolutionDPI
      }
      let worst = below.map { min($0.dpiX, $0.dpiY) }.min() ?? 0
      findings.append(
        Finding(
          rule: "Image resolution", severity: .warning,
          detail:
            "\(below.count) image\(below.count == 1 ? "" : "s") below \(Int(PrintPreflightInventory.lowResolutionDPI)) dpi at placement size (lowest \(Int(worst)) dpi)."))
    }

    if !inventory.hasOutputIntent {
      findings.append(
        Finding(
          rule: "Color management", severity: .warning,
          detail:
            "No output intent: color management cannot be verified; no PDF/X conformance is claimed."))
    } else {
      findings.append(
        Finding(
          rule: "Color management", severity: .info,
          detail: "An output intent is present."))
    }

    if inventory.spotColorSpaces > 0 {
      findings.append(
        Finding(
          rule: "Spot colors", severity: .warning,
          detail:
            "\(inventory.spotColorSpaces) Separation/DeviceN image\(inventory.spotColorSpaces == 1 ? "" : "s"); spot handling needs explicit review and is never converted silently."))
    }
    if inventory.iccProfiles > 0 {
      findings.append(
        Finding(
          rule: "ICC profiles", severity: .info,
          detail:
            "\(inventory.iccProfiles) ICCBased image\(inventory.iccProfiles == 1 ? "" : "s"); embedded profiles stay authoritative."))
    }
    if inventory.overprintUses > 0 {
      findings.append(
        Finding(
          rule: "Overprint", severity: .info,
          detail: "\(inventory.overprintUses) overprint state\(inventory.overprintUses == 1 ? "" : "s"); appearance is preserved."))
    }
    if inventory.transparencyUses > 0 {
      findings.append(
        Finding(
          rule: "Transparency", severity: .warning,
          detail:
            "\(inventory.transparencyUses) transparency use\(inventory.transparencyUses == 1 ? "" : "s"); flattening may be required but is never applied silently."))
    }

    let pagesWithoutPrintBoxes = inventory.pages.filter {
      $0.trimBox == nil && $0.bleedBox == nil
    }
    if !pagesWithoutPrintBoxes.isEmpty {
      findings.append(
        Finding(
          rule: "Print boxes", severity: .info,
          detail:
            "\(pagesWithoutPrintBoxes.count) page\(pagesWithoutPrintBoxes.count == 1 ? "" : "s") without TrimBox/BleedBox; press geometry is unknown."))
    }
    let sizes = Set(inventory.pages.map { $0.mediaBox.map { String(format: "%.1f", $0) }.joined(separator: ",") })
    if sizes.count > 1 {
      findings.append(
        Finding(
          rule: "Page geometry", severity: .warning,
          detail: "\(sizes.count) distinct MediaBox sizes; mixed page geometry needs review."))
    }

    // P37-025: the honest PDF/X statement. PDF/X export lives in the separate
    // declared-subset converter; these checks certify nothing.
    findings.append(
      Finding(
        rule: "PDF/X", severity: .info,
        detail:
          "Read-only checks; PDF/X export is a separate declared-subset route. No ISO PDF/X conformance is claimed by these checks."))
    return PreflightCheckReport(findings: findings)
  }

  public func report() -> String {
    var lines = [
      "Print preflight checks — \(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")",
      "Read-only: nothing is modified, flattened, or converted by these checks.",
    ]
    for finding in findings {
      lines.append("  [\(finding.severity.rawValue)] \(finding.rule): \(finding.detail)")
    }
    return lines.joined(separator: "\n")
  }
}

/// P37-024: explicit, supported color conversions with before/after previews.
/// Only 8-bit DeviceRGB/DeviceGray image samples are converted; CMYK, ICC
/// profiles, masks, and unusual filters are refused with reasons.
public struct ColorConversionReport: Sendable, Equatable {
  public let convertedImages: Int
  public let fromSpaces: [String]
  public let toSpace: String
  public let refused: [String]

  public init(
    convertedImages: Int, fromSpaces: [String], toSpace: String, refused: [String]
  ) {
    self.convertedImages = convertedImages
    self.fromSpaces = fromSpaces
    self.toSpace = toSpace
    self.refused = refused
  }

  public func report() -> String {
    var lines = [
      "Color conversion — \(convertedImages) image\(convertedImages == 1 ? "" : "s") converted to \(toSpace)"
    ]
    if !fromSpaces.isEmpty {
      lines.append("  From: \(fromSpaces.sorted().joined(separator: ", "))")
    }
    for reason in refused {
      lines.append("  Refused: \(reason)")
    }
    return lines.joined(separator: "\n")
  }
}

public enum ColorConversion {
  public enum Target: String, Sendable, Equatable {
    case gray = "DeviceGray"
    case rgb = "DeviceRGB"
  }

  /// P37-024: convert supported 8-bit device images. The conversion is
  /// explicit and reported; everything unsupported is refused, never guessed.
  public static func convert(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], to target: Target,
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: ColorConversionReport) {
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    var objects = graph.objects
    var converted = 0
    var fromSpaces: Set<String> = []
    var refused: [String] = []
    var convertedIDs: Set<PDFObjectID> = []
    for image in images {
      try Task.checkCancellation()
      // A shared image object appears once per page; convert it only once.
      if let objectID = image.objectID, convertedIDs.contains(objectID) { continue }
      guard image.bitsPerComponent == 8 else {
        refused.append("\(image.name): only 8-bit samples are supported")
        continue
      }
      guard !image.hasSMask, !image.isImageMask else {
        refused.append("\(image.name): masked images are not converted")
        continue
      }
      guard image.colorSpace == "DeviceRGB" || image.colorSpace == "DeviceGray" else {
        refused.append("\(image.name): \(image.colorSpace) is not supported (no ICC conversion)")
        continue
      }
      let source: Target = image.colorSpace == "DeviceRGB" ? .rgb : .gray
      guard source != target else { continue }
      guard let objectID = image.objectID, case .stream(var stream)? = objects[objectID] else {
        refused.append("\(image.name): the stream is not directly addressable")
        continue
      }
      let filters = image.filters.filter { $0 != "FlateDecode" }
      guard filters.isEmpty else {
        refused.append("\(image.name): filters \(filters.joined(separator: ", ")) are not supported")
        continue
      }
      let samples = try PDFFilters.decoded(stream, limits: limits)
      let convertedSamples: Data
      switch (source, target) {
      case (.rgb, .gray):
        convertedSamples = try rgbToGray(samples, width: image.width, height: image.height)
      case (.gray, .rgb):
        convertedSamples = try grayToRGB(samples, width: image.width, height: image.height)
      default:
        continue
      }
      let encoded = try PDFFilters.encodeFlate(convertedSamples, limits: limits)
      stream.dictionary[PDFName("ColorSpace")] = .name(PDFName(target.rawValue))
      stream.dictionary[PDFName("Width")] = .integer(Int64(image.width))
      stream.dictionary[PDFName("Height")] = .integer(Int64(image.height))
      stream.dictionary[PDFName("BitsPerComponent")] = .integer(8)
      stream.dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
      stream.dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
      objects[objectID] = .stream(PDFStream(dictionary: stream.dictionary, bytes: encoded))
      convertedIDs.insert(objectID)
      converted += 1
      fromSpaces.insert(image.colorSpace)
    }
    let report = ColorConversionReport(
      convertedImages: converted, fromSpaces: Array(fromSpaces), toSpace: target.rawValue,
      refused: refused)
    return (PDFGraph(version: graph.version, objects: objects, trailer: graph.trailer), report)
  }

  static func rgbToGray(_ samples: Data, width: Int, height: Int) throws -> Data {
    let pixelCount = width * height
    guard samples.count >= pixelCount * 3 else {
      throw PDFError(.malformed, "Image samples are shorter than the declared size")
    }
    var output = Data(capacity: pixelCount)
    var index = 0
    for pixel in 0..<pixelCount {
      // Cancellation is checked inside large images too.
      if pixel % 4_096 == 0 { try Task.checkCancellation() }
      let red = Double(samples[index])
      let green = Double(samples[index + 1])
      let blue = Double(samples[index + 2])
      output.append(UInt8((0.299 * red + 0.587 * green + 0.114 * blue).rounded()))
      index += 3
    }
    return output
  }

  static func grayToRGB(_ samples: Data, width: Int, height: Int) throws -> Data {
    let pixelCount = width * height
    guard samples.count >= pixelCount else {
      throw PDFError(.malformed, "Image samples are shorter than the declared size")
    }
    var output = Data(capacity: pixelCount * 3)
    for index in 0..<pixelCount {
      if index % 4_096 == 0 { try Task.checkCancellation() }
      let value = samples[index]
      output.append(value)
      output.append(value)
      output.append(value)
    }
    return output
  }
}
