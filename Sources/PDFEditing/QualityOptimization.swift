import Foundation
import PDFCore

// PRE-09: quality-aware optimization presets on top of the shipped lossless
// optimizer. Images are downsampled to the preset DPI (lossless Flate) or
// additionally quantized (explicitly lossy). Every plan reports per-resource
// before/after sizes and a measured output size, and refuses unless forms, OCR
// layers, structure tags, masks and fonts remain valid (images with masks or
// profiles are refused, never flattened or converted).

public enum OptimizationQualityPreset: String, Sendable, Equatable, CaseIterable {
  case lossless, print, web, smallest
  public var title: String {
    switch self {
    case .lossless: return "Lossless"
    case .print: return "Print (300 dpi)"
    case .web: return "Web (150 dpi)"
    case .smallest: return "Smallest (96 dpi, lossy)"
    }
  }
  public var targetDPI: Double? {
    switch self {
    case .lossless: return nil
    case .print: return 300
    case .web: return 150
    case .smallest: return 96
    }
  }
  public var lossyQuality: Int? { self == .smallest ? 55 : nil }
  public var isLossy: Bool { lossyQuality != nil }
}

public struct QualityOptimizationOptions: Sendable, Equatable {
  public var removeMetadata: Bool
  public var preserveFormEditability: Bool
  public init(removeMetadata: Bool = false, preserveFormEditability: Bool = true) {
    self.removeMetadata = removeMetadata
    self.preserveFormEditability = preserveFormEditability
  }
}

public struct QualityResourceChange: Sendable, Equatable {
  public let kind: String
  public let name: String
  public let pageIndex: Int?
  public let before: String
  public let after: String
  public let beforeBytes: Int
  public let afterBytes: Int
  public init(kind: String, name: String, pageIndex: Int?, before: String, after: String, beforeBytes: Int, afterBytes: Int) {
    self.kind = kind; self.name = name; self.pageIndex = pageIndex
    self.before = before; self.after = after
    self.beforeBytes = beforeBytes; self.afterBytes = afterBytes
  }
}

public struct QualityPreservationReport: Sendable, Equatable {
  public let formsIntact: Bool
  public let ocrLayersIntact: Bool
  public let tagsIntact: Bool
  public let masksIntact: Bool
  public let fontsIntact: Bool
  public let issues: [String]
  public init(formsIntact: Bool, ocrLayersIntact: Bool, tagsIntact: Bool, masksIntact: Bool, fontsIntact: Bool, issues: [String]) {
    self.formsIntact = formsIntact; self.ocrLayersIntact = ocrLayersIntact
    self.tagsIntact = tagsIntact; self.masksIntact = masksIntact
    self.fontsIntact = fontsIntact; self.issues = issues
  }
  public var passed: Bool { issues.isEmpty }
}

public struct QualityOptimizationPlan: Sendable, Equatable {
  public let preset: OptimizationQualityPreset
  public let options: QualityOptimizationOptions
  public let changes: [QualityResourceChange]
  public let refusals: [String]
  public let sourceBytes: Int
  public let estimatedBytes: Int
  public let preservation: QualityPreservationReport
  public init(preset: OptimizationQualityPreset, options: QualityOptimizationOptions, changes: [QualityResourceChange], refusals: [String], sourceBytes: Int, estimatedBytes: Int, preservation: QualityPreservationReport) {
    self.preset = preset; self.options = options; self.changes = changes
    self.refusals = refusals; self.sourceBytes = sourceBytes
    self.estimatedBytes = estimatedBytes; self.preservation = preservation
  }
  public var isUsable: Bool { refusals.isEmpty && preservation.passed }
  public var summary: String {
    var lines = ["\(preset.title): \(sourceBytes) -> \(estimatedBytes) bytes, \(changes.count) resource change(s)"]
    for change in changes.prefix(20) {
      lines.append("  \(change.kind) \(change.name): \(change.before) -> \(change.after) [\(change.beforeBytes) -> \(change.afterBytes) bytes]")
    }
    for refusal in refusals { lines.append("  refused: " + refusal) }
    for issue in preservation.issues { lines.append("  preservation: " + issue) }
    return lines.joined(separator: "\n")
  }
}

public struct QualityOptimizationReport: Sendable, Equatable {
  public let preset: OptimizationQualityPreset
  public let originalBytes: Int
  public let optimizedBytes: Int
  public let losslessBytes: Int?
  public let measuredDPI: [String: Double]
  public let changes: [QualityResourceChange]
  public let preservation: QualityPreservationReport
  public let transformations: [String]
  public var isImprovement: Bool { optimizedBytes < originalBytes }
  public var summary: String {
    var lines = ["\(preset.title): \(originalBytes) -> \(optimizedBytes) bytes" + (losslessBytes.map { " (lossless optimizer: \($0) bytes)" } ?? "")]
    if !measuredDPI.isEmpty {
      lines.append("  achieved DPI: " + measuredDPI.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value))" }.joined(separator: ", "))
    }
    lines.append(contentsOf: transformations.map { "  " + $0 })
    lines.append("  forms=\(preservation.formsIntact) ocr=\(preservation.ocrLayersIntact) tags=\(preservation.tagsIntact) masks=\(preservation.masksIntact) fonts=\(preservation.fontsIntact)")
    return lines.joined(separator: "\n")
  }
}

public enum QualityOptimizer {
  public static func plan(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], preset: OptimizationQualityPreset,
    options: QualityOptimizationOptions = QualityOptimizationOptions(), limits: PDFLimits = PDFLimits()
  ) throws -> QualityOptimizationPlan {
    let sourceBytes = (try? PDFWriter.write(graph).count) ?? 0
    let images = try PDFImageInventory.images(in: graph, pageIDs: pageIDs)
    var changes: [QualityResourceChange] = []
    var refusals: [String] = []
    var estimated = sourceBytes
    if let targetDPI = preset.targetDPI {
      for image in images {
        guard let objectID = image.objectID, case .stream(let stream)? = graph.objects[objectID] else {
          continue
        }
        let widthPoints = image.bounds.count == 4 ? image.bounds[2] - image.bounds[0] : 0
        guard widthPoints > 0 else { continue }
        let dictionary = stream.dictionary
        if dictionary[PDFName("ImageMask")] != nil || dictionary[PDFName("SMask")] != nil
          || dictionary[PDFName("Mask")] != nil || dictionary[PDFName("Decode")] != nil
        {
          refusals.append("\(image.name): masked/Decode image is preserved (not flattened or converted)")
          continue
        }
        let currentDPI = Double(image.width) / (widthPoints / 72)
        guard currentDPI > targetDPI * 1.05 else { continue }
        guard image.colorSpace == "DeviceRGB", image.bitsPerComponent == 8 else {
          refusals.append("\(image.name): \(image.colorSpace)/\(image.bitsPerComponent)-bit is not downsampled by this profile")
          continue
        }
        let targetWidth = try ImageDownsampling.targetPixelWidth(pageWidthPoints: widthPoints, dpi: targetDPI)
        let sourceData = try PDFFilters.decoded(stream, limits: limits)
        let downsampled = try ImageDownsampling.downsample(
          rgb8: sourceData, width: image.width, height: image.height, targetWidth: targetWidth)
        var samples = downsampled.rgb8
        var filter = "FlateDecode"
        if let quality = preset.lossyQuality {
          samples = try LossyQualityConversion(quality: quality).convert(rgb8: samples)
          filter = "FlateDecode (explicitly lossy quantization)"
        } else if dictionary[PDFName("Filter")] as? PDFName == PDFName("DCTDecode") {
          refusals.append("\(image.name): DCTDecode re-compression is not implemented; left untouched")
          continue
        }
        let encoded = try PDFFilters.encodeFlate(samples, limits: limits)
        estimated += encoded.count - stream.bytes.count
        changes.append(QualityResourceChange(
          kind: "image", name: image.name, pageIndex: image.pageIndex,
          before: "\(image.width)x\(image.height) @ \(Int(currentDPI)) dpi",
          after: "\(downsampled.width)x\(downsampled.height) @ \(Int(targetDPI)) dpi (\(filter))",
          beforeBytes: stream.bytes.count, afterBytes: encoded.count))
      }
    }
    let lossless = try PDFOptimizer.lossless(graph, options: PDFOptimizationOptions(removeMetadata: options.removeMetadata), sourceBytes: sourceBytes, limits: limits)
    estimated = min(estimated, lossless.data.count + max(0, estimated - sourceBytes))
    let preservation = try preservationReport(before: graph, after: lossless.graph, pageIDs: pageIDs, options: options)
    return QualityOptimizationPlan(
      preset: preset, options: options, changes: changes, refusals: refusals,
      sourceBytes: sourceBytes, estimatedBytes: estimated, preservation: preservation)
  }

  public static func apply(
    _ plan: QualityOptimizationPlan, to graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: QualityOptimizationReport) {
    guard plan.isUsable else {
      throw PDFError(.unsupported, "Optimization plan is not usable: " + (plan.refusals + plan.preservation.issues).joined(separator: "; "))
    }
    var work = graph
    var transformations: [String] = []
    var measuredDPI: [String: Double] = [:]
    if let targetDPI = plan.preset.targetDPI {
      for image in try PDFImageInventory.images(in: work, pageIDs: pageIDs) {
        guard let objectID = image.objectID, case .stream(let stream)? = work.objects[objectID] else { continue }
        let widthPoints = image.bounds.count == 4 ? image.bounds[2] - image.bounds[0] : 0
        guard widthPoints > 0, image.colorSpace == "DeviceRGB", image.bitsPerComponent == 8 else { continue }
        let currentDPI = Double(image.width) / (widthPoints / 72)
        guard currentDPI > targetDPI * 1.05 else { continue }
        let dictionary = stream.dictionary
        if dictionary[PDFName("ImageMask")] != nil || dictionary[PDFName("SMask")] != nil || dictionary[PDFName("Mask")] != nil { continue }
        let targetWidth = try ImageDownsampling.targetPixelWidth(pageWidthPoints: widthPoints, dpi: targetDPI)
        var samples = try ImageDownsampling.downsample(
          rgb8: try PDFFilters.decoded(stream, limits: limits),
          width: image.width, height: image.height, targetWidth: targetWidth)
        if let quality = plan.preset.lossyQuality {
          samples.rgb8 = try LossyQualityConversion(quality: quality).convert(rgb8: samples.rgb8)
        }
        let encoded = try PDFFilters.encodeFlate(samples.rgb8, limits: limits)
        var dict = dictionary
        dict[PDFName("Width")] = .integer(Int64(samples.width))
        dict[PDFName("Height")] = .integer(Int64(samples.height))
        dict[PDFName("Filter")] = .name(PDFName("FlateDecode"))
        dict[PDFName("Length")] = .integer(Int64(encoded.count))
        work.objects[objectID] = .stream(PDFStream(dictionary: dict, bytes: encoded))
        measuredDPI[image.name] = Double(samples.width) / (widthPoints / 72)
        transformations.append("downsampled \(image.name) to \(samples.width)x\(samples.height)")
      }
    }
    let lossless = try PDFOptimizer.lossless(work, options: PDFOptimizationOptions(removeMetadata: plan.options.removeMetadata), sourceBytes: plan.sourceBytes, limits: limits)
    work = lossless.graph
    transformations.append(contentsOf: lossless.report.transformations)
    let preservation = try preservationReport(before: graph, after: work, pageIDs: pageIDs, options: plan.options)
    guard preservation.passed else {
      throw PDFError(.unsupported, "Optimization would invalidate retained content: " + preservation.issues.joined(separator: "; "))
    }
    let data = try PDFWriter.write(work)
    let report = QualityOptimizationReport(
      preset: plan.preset, originalBytes: plan.sourceBytes, optimizedBytes: data.count,
      losslessBytes: lossless.data.count, measuredDPI: measuredDPI, changes: plan.changes,
      preservation: preservation, transformations: transformations)
    return (work, report)
  }

  public static func optimize(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], preset: OptimizationQualityPreset,
    options: QualityOptimizationOptions = QualityOptimizationOptions(), limits: PDFLimits = PDFLimits()
  ) throws -> (data: Data, report: QualityOptimizationReport) {
    let plan = try self.plan(graph, pageIDs: pageIDs, preset: preset, options: options, limits: limits)
    let applied = try apply(plan, to: graph, pageIDs: pageIDs, limits: limits)
    let data = try PDFWriter.write(applied.graph)
    let parsed = try PDFParser.parse(data, limits: limits)
    guard parsed.pageCount == pageIDs.count else {
      throw PDFError(.malformed, "Optimized output failed page-count verification")
    }
    return (data, applied.report)
  }

  public static func preservationReport(
    before: PDFGraph, after: PDFGraph, pageIDs: [PDFObjectID],
    options: QualityOptimizationOptions
  ) throws -> QualityPreservationReport {
    var issues: [String] = []
    let beforeForms = try FormInventory.fields(in: before, pageIDs: pageIDs)
    let afterForms = try FormInventory.fields(in: after, pageIDs: pageIDs)
    let formsIntact = beforeForms.map(\.name) == afterForms.map(\.name)
      && beforeForms.map { $0.stringValue ?? "" } == afterForms.map { $0.stringValue ?? "" }
    if !formsIntact { issues.append("form fields or values changed") }
    let beforeOCR = pageIDs.filter { OCRLayer.hasGeneratedLayer(in: before, pageID: $0) }
    let afterOCR = pageIDs.filter { OCRLayer.hasGeneratedLayer(in: after, pageID: $0) }
    let ocrIntact = beforeOCR.count == afterOCR.count
    if !ocrIntact { issues.append("generated OCR layers changed") }
    let beforeTags = try? PDFStructureInspector.inspect(in: before, pageIDs: pageIDs)
    let afterTags = try? PDFStructureInspector.inspect(in: after, pageIDs: pageIDs)
    let tagsIntact = beforeTags?.elements.map(\.role) == afterTags?.elements.map(\.role)
      && (beforeTags?.issues.count ?? 0) == (afterTags?.issues.count ?? 0)
    if !tagsIntact { issues.append("structure tags changed") }
    func maskCount(_ graph: PDFGraph) -> Int {
      var count = 0
      for (_, value) in graph.objects {
        if case .stream(let stream) = value,
          stream.dictionary[PDFName("SMask")] != nil || stream.dictionary[PDFName("Mask")] != nil
            || stream.dictionary[PDFName("ImageMask")] != nil
        { count += 1 }
      }
      return count
    }
    let masksIntact = maskCount(before) == maskCount(after)
    if !masksIntact { issues.append("image masks changed") }
    let beforeFonts = try PDFFontInventory.fonts(in: before, pageIDs: pageIDs).count
    let afterFonts = try PDFFontInventory.fonts(in: after, pageIDs: pageIDs).count
    let fontsIntact = beforeFonts == afterFonts
    if !fontsIntact { issues.append("fonts changed") }
    if options.preserveFormEditability, !formsIntact {
      issues.append("form editability was not preserved")
    }
    return QualityPreservationReport(
      formsIntact: formsIntact, ocrLayersIntact: ocrIntact, tagsIntact: tagsIntact,
      masksIntact: masksIntact, fontsIntact: fontsIntact, issues: issues)
  }
}

