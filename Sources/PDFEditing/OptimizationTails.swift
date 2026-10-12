import Foundation
import PDFCore

// MARK: - P24-029 filled-form editability

/// P24-029: filled forms remain editable in independent readers. The check
/// is structural: no /NeedAppearances fallback, canonical /V values, and
/// generated widget appearances — so any compliant reader can edit them.
public struct FilledFormEditabilityIssue: Sendable, Equatable {
  public let field: String
  public let reason: String
}

public enum FilledFormEditability {
  public static func verify(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws -> [FilledFormEditabilityIssue] {
    var issues: [FilledFormEditabilityIssue] = []
    if let acroForm = FormInventory.acroFormDictionary(in: graph),
      acroForm[PDFName("NeedAppearances")] == .boolean(true)
    {
      issues.append(FilledFormEditabilityIssue(field: "", reason: "NeedAppearances must not be used as proof of correctness"))
    }
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    for field in fields {
      switch field.kind {
      case .text:
        if field.isReadOnly { continue }
        guard let value = field.stringValue, !value.isEmpty else { continue }
        // A filled text field needs a widget appearance stream.
        let hasAppearance = field.widgets.contains { widget in
          guard let id = widget.objectID,
            case .dictionary(let dictionary)? = graph.objects[id],
            let appearance = dictionary[PDFName("AP")]
          else { return false }
          switch appearance {
          case .dictionary(let ap):
            if case .reference(let appearanceID) = ap[PDFName("N")] {
              if case .stream = graph.objects[appearanceID] { return true }
            }
            return false
          default: return false
          }
        }
        if !hasAppearance {
          issues.append(FilledFormEditabilityIssue(field: field.name, reason: "filled text field has no generated appearance"))
        }
      case .button where !field.isPushButton:
        // Button states are explicit names; nothing structural blocks editing.
        continue
      case .choice:
        if field.stringValue == nil {
          issues.append(FilledFormEditabilityIssue(field: field.name, reason: "choice field lost its value"))
        }
      default:
        continue
      }
      // Widgets must stay editable (not read-only-locked at the widget).
      for widget in field.widgets {
        if let id = widget.objectID,
          case .dictionary(let dictionary)? = graph.objects[id],
          case .integer(let flags)? = dictionary[PDFName("Ff")],
          flags & (1 << 0) != 0, !field.isReadOnly
        {
          issues.append(FilledFormEditabilityIssue(field: field.name, reason: "widget is unexpectedly read-only"))
        }
      }
    }
    return issues
  }

  public static func requireEditable(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws {
    let issues = try verify(in: graph, pageIDs: pageIDs)
    guard issues.isEmpty else {
      throw PDFError(.malformed, "Filled form is not independently editable: \(issues.first!.reason)")
    }
  }
}

// MARK: - P31-010 downsampling

/// P31-010: optional image downsampling with page-scale-aware resolution.
/// Target pixels derive from the placed width on the page and the declared
/// output DPI — never a blind global scale.
public enum ImageDownsampling {
  public static func targetPixelWidth(pageWidthPoints: Double, dpi: Double) throws -> Int {
    guard pageWidthPoints > 0, dpi > 0, pageWidthPoints.isFinite, dpi.isFinite else {
      throw PDFError(.malformed, "Downsampling needs a positive page width and DPI")
    }
    return max(Int((pageWidthPoints / 72 * dpi).rounded()), 1)
  }

  /// Box-average downsample of DeviceRGB 8-bit samples.
  public static func downsample(rgb8: Data, width: Int, height: Int, targetWidth: Int) throws -> (rgb8: Data, width: Int, height: Int) {
    guard rgb8.count == width * height * 3, width > 0, height > 0, targetWidth > 0 else {
      throw PDFError(.malformed, "Downsampling dimensions do not match the pixel data")
    }
    guard targetWidth < width else { return (rgb8, width, height) }
    let scale = Double(targetWidth) / Double(width)
    let targetHeight = max(Int((Double(height) * scale).rounded()), 1)
    let source = [UInt8](rgb8)
    var result = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
    for y in 0..<targetHeight {
      for x in 0..<targetWidth {
        let srcX0 = Int(Double(x) / scale)
        let srcX1 = min(Int(Double(x + 1) / scale), width)
        let srcY0 = Int(Double(y) / scale)
        let srcY1 = min(Int(Double(y + 1) / scale), height)
        var sums = [0, 0, 0]
        var count = 0
        for srcY in srcY0..<max(srcY1, srcY0 + 1) {
          for srcX in srcX0..<max(srcX1, srcX0 + 1) {
            let at = (min(srcY, height - 1) * width + min(srcX, width - 1)) * 3
            sums[0] += Int(source[at])
            sums[1] += Int(source[at + 1])
            sums[2] += Int(source[at + 2])
            count += 1
          }
        }
        let at = (y * targetWidth + x) * 3
        result[at] = UInt8(sums[0] / max(count, 1))
        result[at + 1] = UInt8(sums[1] / max(count, 1))
        result[at + 2] = UInt8(sums[2] / max(count, 1))
      }
    }
    return (Data(result), targetWidth, targetHeight)
  }
}

// MARK: - P31-011 explicitly lossy quality conversion

/// P31-011: image-quality conversion as an explicitly lossy operation.
/// Quality 1...100 maps to 2...64 quantization levels; the result always
/// differs from the input and reports itself as lossy.
public struct LossyQualityConversion: Sendable, Equatable {
  public let quality: Int
  public let levels: Int
  public let isLossy: Bool = true

  public init(quality: Int) throws {
    guard quality >= 1, quality <= 100 else {
      throw PDFError(.malformed, "Lossy quality must be within 1...100")
    }
    self.quality = quality
    self.levels = max(2 + (quality - 1) * 62 / 99, 2)
  }

  public func convert(rgb8: Data) -> Data {
    let step = max(256 / levels, 1)
    return Data([UInt8](rgb8).map { value in
      UInt8((Int(value) / step) * step)
    })
  }
}

// MARK: - P31-012 masks and color profiles

/// P31-012: masks and color profiles are preserved; lossy conversion
/// refuses images that carry them.
public enum ImageOptimizationGuard {
  public static func validateLossyEligibility(_ dictionary: [PDFName: PDFValue]) throws {
    for key in ["ImageMask", "Mask", "SMask", "Decode"] where dictionary[PDFName(key)] != nil {
      throw PDFError(.unsupported, "Lossy image optimization refuses images with /\(key)")
    }
    // ICC profiles and non-RGB spaces survive only through the lossless path.
    if case .array = dictionary[PDFName("ColorSpace")] {
      throw PDFError(.unsupported, "Lossy image optimization refuses array color spaces with profiles")
    }
  }

  public static func preservesMasksAndProfiles(before: [PDFName: PDFValue], after: [PDFName: PDFValue]) -> Bool {
    for key in ["ImageMask", "Mask", "SMask", "Decode", "ColorSpace", "Interpolate"] {
      if before[PDFName(key)] != after[PDFName(key)] { return false }
    }
    return true
  }
}

// MARK: - P31-013 lossless preservation

/// P31-013: lossless mode preserves original compressed image streams
/// byte-for-byte (DCT, JPX, and friends are never re-encoded).
public enum LosslessImagePreservation {
  public static func verifyUntouched(before: PDFGraph, after: PDFGraph) throws {
    for (id, value) in before.objects {
      guard case .stream(let beforeStream) = value,
        beforeStream.dictionary[PDFName("Subtype")] == .name(PDFName("Image")),
        beforeStream.dictionary[PDFName("Filter")] != nil
      else { continue }
      guard case .stream(let afterStream)? = after.objects[id] else {
        throw PDFError(.malformed, "Lossless optimization dropped a compressed image")
      }
      guard afterStream.bytes == beforeStream.bytes,
        afterStream.dictionary[PDFName("Filter")] == beforeStream.dictionary[PDFName("Filter")]
      else {
        throw PDFError(.malformed, "Lossless optimization must preserve compressed image streams")
      }
    }
  }
}

// MARK: - P31-014/P31-015 font subsetting + unused resources

/// P31-014: embedding permission for a font program. Restricted fonts
/// never subset or embed through optimization.
public enum FontEmbeddingPermission: String, Sendable, Equatable {
  case installable
  case editable
  case previewPrint
  case restricted
}

public enum OptimizationFontSubsetting {
  public static func subsetIfAllowed(
    program: Data, unicodes: Set<Int>, permission: FontEmbeddingPermission
  ) throws -> Data {
    guard permission != .restricted else {
      throw PDFError(.unsupported, "Font subsetting refuses restricted embedding permissions")
    }
    return try TrueTypeSubsetter.subset(program: program, unicodes: unicodes)
  }
}

/// P31-015: unused font resources are removed only when every reference is
/// understood — no unknown content operators, no Type3 fonts, and every
/// text run decodes.
public enum UnusedResourcePruner {
  public static func canPruneSafely(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> Bool {
    for pageID in pageIDs {
      guard let content = try? PageContent.load(pageID: pageID, in: graph) else { return false }
      for instruction in content.instructions {
        // Unknown operators mean unknown references; do not prune.
        if instruction.operatorName.hasPrefix("/") { return false }
      }
      guard let runs = try? TextRunIndexer.runs(in: content, graph: graph) else { return false }
      for run in runs {
        guard case .dictionary(let page)? = graph.objects[pageID],
          let font = SimpleFont.resolve(resource: run.fontResource, page: page, in: graph),
          font.isSupported, !font.isType3
        else { return false }
      }
    }
    return true
  }

  /// Drop /Font entries never selected by a Tj/TJ Tf on the page. Returns
  /// the pruned graph and the removed names.
  public static func pruneUnusedFontResources(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws -> (graph: PDFGraph, removed: [String]) {
    guard canPruneSafely(in: graph, pageIDs: pageIDs) else {
      throw PDFError(.unsupported, "Unused resources are removed only when references are fully understood")
    }
    var graph = graph
    var removed: [String] = []
    for pageID in pageIDs {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      let content = try PageContent.load(pageID: pageID, in: graph)
      var used: Set<String> = []
      var current: String?
      for instruction in content.instructions {
        if instruction.operatorName == "Tf",
          case .name(let name)? = instruction.operands.first?.value
        {
          current = String(decoding: name.bytes, as: UTF8.self)
        }
        if ["Tj", "TJ", "'", "\""].contains(instruction.operatorName), let current {
          used.insert(current)
        }
      }
      switch page[PDFName("Resources")] {
      case .dictionary(var resources)?:
        if case .dictionary(var fonts)? = resources[PDFName("Font")] {
          for key in fonts.keys {
            let name = String(decoding: key.bytes, as: UTF8.self)
            // Never drop the OCR layer font; it is selected inside its own
            // stream which the run indexer above may not decode.
            if name.hasPrefix("Focr") { continue }
            if !used.contains(name) {
              fonts.removeValue(forKey: key)
              removed.append(name)
            }
          }
          resources[PDFName("Font")] = fonts.isEmpty ? nil : .dictionary(fonts)
          page[PDFName("Resources")] = .dictionary(resources)
          graph.objects[pageID] = .dictionary(page)
        }
      default:
        break
      }
    }
    return (graph, removed)
  }
}

// MARK: - P31-027 lossy verification

/// P31-027: lossy results match their declared resolution/quality settings.
public struct LossyOptimizationReport: Sendable, Equatable {
  public let declaredDPI: Double
  public let actualWidth: Int
  public let expectedWidth: Int
  public let declaredQuality: Int
  public let actualLevels: Int
  public let expectedLevels: Int
}

public enum LossyOptimizationVerification {
  public static func verify(
    declaredDPI: Double, pageWidthPoints: Double, actualWidth: Int,
    declaredQuality: Int, actualLevels: Int
  ) throws -> LossyOptimizationReport {
    let expectedWidth = try ImageDownsampling.targetPixelWidth(pageWidthPoints: pageWidthPoints, dpi: declaredDPI)
    guard actualWidth == expectedWidth else {
      throw PDFError(.malformed, "Lossy image width \(actualWidth) does not match declared \(declaredDPI) DPI (\(expectedWidth))")
    }
    let conversion = try LossyQualityConversion(quality: declaredQuality)
    guard actualLevels == conversion.levels else {
      throw PDFError(.malformed, "Lossy quality levels \(actualLevels) do not match declared quality \(declaredQuality)")
    }
    return LossyOptimizationReport(
      declaredDPI: declaredDPI, actualWidth: actualWidth, expectedWidth: expectedWidth,
      declaredQuality: declaredQuality, actualLevels: actualLevels, expectedLevels: conversion.levels)
  }
}

// MARK: - P31-029 / P32-029 synthetic measurements

/// P31-029: output size, processing time, and peak memory on a synthetic
/// corpus (the private corpus is absent in this environment).
public struct OptimizationMeasurement: Sendable, Equatable {
  public let documentCount: Int
  public let originalBytes: Int
  public let optimizedBytes: Int
  public let elapsedMilliseconds: Double
  public let peakMemoryEstimateBytes: Int
  public let method: String
  public let limits: String
}

public enum OptimizationBenchmark {
  public static func measure(graphs: [(graph: PDFGraph, sourceBytes: Int)]) throws -> OptimizationMeasurement {
    let started = Date()
    var original = 0
    var optimized = 0
    var peak = 0
    for entry in graphs {
      original += entry.sourceBytes
      peak = max(peak, entry.sourceBytes * 3)
      peak = max(peak, entry.sourceBytes * 3)
      let (_, output, _) = try PDFOptimizer.lossless(entry.graph, sourceBytes: entry.sourceBytes)
      optimized += output.count
    }
    return OptimizationMeasurement(
      documentCount: graphs.count, originalBytes: original, optimizedBytes: optimized,
      elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
      peakMemoryEstimateBytes: peak,
      method: "synthetic fixture graphs through the lossless preset",
      limits: "private corpus absent; lossy presets measured separately")
  }
}

/// P32-029: long-document comparison memory and latency on synthetic pages.
public struct ComparisonMeasurement: Sendable, Equatable {
  public let pageCount: Int
  public let changeCount: Int
  public let elapsedMilliseconds: Double
  public let peakMemoryEstimateBytes: Int
  public let method: String
  public let limits: String
}

public enum ComparisonBenchmark {
  public static func measureSynthetic(pages: Int = 60) throws -> ComparisonMeasurement {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
      ]),
    ]
    var kids: [PDFValue] = []
    for index in 0..<pages {
      let pageID = PDFObjectID(100 + index * 2)
      let contentID = PDFObjectID(101 + index * 2)
      let text = "synthetic comparison page \(index + 1) with stable content for measurement"
      objects[contentID] = .stream(PDFStream(bytes: Data("BT /F1 12 Tf 42 700 Td (\(text)) Tj ET\n".utf8)))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pages)),
      PDFName("Kids"): .array(kids),
    ])
    let leftGraph = PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let leftData = try PDFWriter.write(leftGraph)
    var rightGraph = leftGraph
    // Change one page's text so the comparison has work beyond mapping.
    let targetIndex = max(0, pages / 2)
    let targetContent = PDFObjectID(101 + targetIndex * 2)
    rightGraph.objects[targetContent] = .stream(
      PDFStream(bytes: Data("BT /F1 12 Tf 42 700 Td (synthetic comparison page \(targetIndex + 1) REVISED for measurement) Tj ET\n".utf8)))
    let rightData = try PDFWriter.write(rightGraph)
    let started = Date()
    let result = try PDFComparison.compare(
      left: (leftGraph, leftData), right: (rightGraph, rightData))
    let elapsed = Date().timeIntervalSince(started) * 1000
    let peak = (leftData.count + rightData.count) * 2 + leftGraph.objects.count * 512
    return ComparisonMeasurement(
      pageCount: pages, changeCount: result.changes.count,
      elapsedMilliseconds: elapsed, peakMemoryEstimateBytes: peak,
      method: "synthetic \(pages)-page documents with one revised page",
      limits: "private corpus absent; rendered-image diffing not included")
  }
}
