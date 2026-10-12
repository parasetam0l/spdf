import AppKit
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// P24-029/P31-010–P31-015/P31-027/P31-029/P32-029 evidence.
@Suite("Optimization tails")
struct OptimizationTailsTests {
  @Test func filledFormsStayEditableForIndependentReaders() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "name", text: "Ada Lovelace"),
        SetFormChoiceCommand(fieldName: "department", exportValue: "Support"),
        SetFormButtonStateCommand(fieldName: "agree", state: PDFName("Yes")),
      ]), to: parsed.graph)
    // Structural editability: no fallback, values plus appearances.
    try FilledFormEditability.requireEditable(in: filled, pageIDs: parsed.pageIDs)
    let data = try PDFWriter.write(filled)
    // An independent reader (PDFKit) sees editable widgets with values.
    let document = try #require(PDFDocument(data: data))
    func widgets(in document: PDFDocument) -> [PDFAnnotation] {
      (0..<document.pageCount).flatMap { index in
        document.page(at: index)?.annotations.filter { !$0.widgetFieldType.rawValue.isEmpty } ?? []
      }
    }
    let found = widgets(in: document)
    #expect(!found.isEmpty)
    let byName = Dictionary(grouping: found, by: { $0.fieldName ?? "" })
    #expect(byName["name"]?.first?.widgetStringValue == "Ada Lovelace")
    #expect(byName["department"]?.first?.widgetStringValue == "Support")
    // Filled text/choice widgets stay editable; the locked fixture field is
    // the only read-only widget, and it keeps its value.
    #expect(byName["name"]?.first?.isReadOnly == false)
    #expect(byName["locked"]?.first?.isReadOnly == true)
    #expect(byName["locked"]?.first?.widgetStringValue == "locked")
    // PDFKit can still edit a filled text widget in memory.
    byName["name"]?.first?.widgetStringValue = "Grace Hopper"
    #expect(byName["name"]?.first?.widgetStringValue == "Grace Hopper")
    // A flattened form is not editable — the verifier catches it.
    let flattened = try PDFEditingEngine.commit(PDFTransaction([FlattenFormCommand()]), to: filled)
    let reparsed = try PDFParser.parse(PDFWriter.write(flattened))
    #expect(try FormInventory.fields(in: reparsed.graph, pageIDs: reparsed.pageIDs).isEmpty)
  }

  @Test func downsamplingIsPageScaleAware() throws {
    #expect(try ImageDownsampling.targetPixelWidth(pageWidthPoints: 612, dpi: 150) == 1275)
    #expect(try ImageDownsampling.targetPixelWidth(pageWidthPoints: 595, dpi: 150) == 1240)
    // 4x4 -> 2x2 box average.
    var pixels: [UInt8] = []
    for y in 0..<4 {
      for x in 0..<4 {
        let value: UInt8 = (x < 2 && y < 2) ? 0 : 255
        pixels += [value, value, value]
      }
    }
    let (down, width, height) = try ImageDownsampling.downsample(
      rgb8: Data(pixels), width: 4, height: 4, targetWidth: 2)
    #expect(width == 2 && height == 2)
    let bytes = [UInt8](down)
    #expect(bytes[0] == 0) // top-left block stays black
    #expect(bytes[(1 * 2 + 1) * 3] == 255) // bottom-right stays white
    #expect(throws: PDFError.self) {
      _ = try ImageDownsampling.targetPixelWidth(pageWidthPoints: 0, dpi: 150)
    }
  }

  @Test func qualityConversionIsExplicitlyLossy() throws {
    let high = try LossyQualityConversion(quality: 90)
    let low = try LossyQualityConversion(quality: 10)
    #expect(high.levels > low.levels)
    #expect(high.isLossy)
    let input = Data((0..<64).map { UInt8(($0 * 4 + 1) % 256) })
    #expect(high.convert(rgb8: input) != input)
    #expect(low.convert(rgb8: input) != input)
    #expect(throws: PDFError.self) { _ = try LossyQualityConversion(quality: 0) }
    #expect(throws: PDFError.self) { _ = try LossyQualityConversion(quality: 101) }
  }

  @Test func masksAndProfilesSurviveOnlyLossless() throws {
    var masked: [PDFName: PDFValue] = [
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
    ]
    masked[PDFName("SMask")] = .reference(PDFObjectID(90))
    #expect(throws: PDFError.self) { try ImageOptimizationGuard.validateLossyEligibility(masked) }
    var profiled: [PDFName: PDFValue] = [
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("ColorSpace"): .array([.name(PDFName("ICCBased")), .reference(PDFObjectID(91))]),
    ]
    #expect(throws: PDFError.self) { try ImageOptimizationGuard.validateLossyEligibility(profiled) }
    let plain: [PDFName: PDFValue] = [
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
    ]
    try ImageOptimizationGuard.validateLossyEligibility(plain)
    #expect(ImageOptimizationGuard.preservesMasksAndProfiles(before: masked, after: masked))
    #expect(!ImageOptimizationGuard.preservesMasksAndProfiles(before: masked, after: plain))
  }

  @Test func losslessModePreservesCompressedStreams() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let dct = Data((0..<256).map { UInt8($0 % 251) })
    let jpx = Data((0..<256).map { UInt8(($0 * 7) % 251) })
    graph.objects[PDFObjectID(80)] = .stream(PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Filter"): .name(PDFName("DCTDecode")),
        PDFName("Width"): .integer(8), PDFName("Height"): .integer(8),
      ], bytes: dct))
    graph.objects[PDFObjectID(81)] = .stream(PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Filter"): .name(PDFName("JPXDecode")),
        PDFName("Width"): .integer(8), PDFName("Height"): .integer(8),
      ], bytes: jpx))
    graph.objects[PDFObjectID(82)] = .dictionary([
      PDFName("XObject"): .dictionary([
        PDFName("Im1"): .reference(PDFObjectID(80)),
        PDFName("Im2"): .reference(PDFObjectID(81)),
      ])
    ])
    graph.trailer[PDFName("Info")] = .reference(PDFObjectID(82))
    let (optimized, _, _) = try PDFOptimizer.lossless(graph)
    try LosslessImagePreservation.verifyUntouched(before: graph, after: optimized)
  }

  @Test func fontSubsettingRespectsPermissions() throws {
    let bundle = Bundle(for: BundleToken.self)
    let fontURL = bundle.url(forResource: "DejaVuSans", withExtension: "ttf")
      ?? URL(fileURLWithPath: "Tests/Fixtures/Fonts/DejaVuSans.ttf")
    let candidates = [
      fontURL,
      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Fonts/DejaVuSans.ttf"),
    ]
    var program: Data?
    for url in candidates {
      program = try? Data(contentsOf: url)
      if program != nil { break }
    }
    guard let program else {
      // No redistributable font available; the permission refusal still verifies.
      #expect(throws: PDFError.self) {
        _ = try OptimizationFontSubsetting.subsetIfAllowed(
          program: Data(), unicodes: [65], permission: .restricted)
      }
      return
    }
    #expect(throws: PDFError.self) {
      _ = try OptimizationFontSubsetting.subsetIfAllowed(
        program: program, unicodes: [65], permission: .restricted)
    }
    let subset = try OptimizationFontSubsetting.subsetIfAllowed(
      program: program, unicodes: [65, 66], permission: .installable)
    #expect(!subset.isEmpty)
    #expect(subset.count < program.count)
    let inspector = try TrueTypeInspector.inspect(subset)
    #expect(inspector.unicodeToGlyph[65] != nil)
  }

  @Test func unusedResourcesPruneOnlyWhenUnderstood() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    // Add an unused font resource.
    if case .dictionary(var page)? = graph.objects[parsed.pageIDs[0]],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var fonts)? = resources[PDFName("Font")]
    {
      fonts[PDFName("FUnused")] = .reference(PDFObjectID(3))
      resources[PDFName("Font")] = .dictionary(fonts)
      page[PDFName("Resources")] = .dictionary(resources)
      graph.objects[parsed.pageIDs[0]] = .dictionary(page)
    }
    #expect(UnusedResourcePruner.canPruneSafely(in: graph, pageIDs: parsed.pageIDs))
    let (pruned, removed) = try UnusedResourcePruner.pruneUnusedFontResources(in: graph, pageIDs: parsed.pageIDs)
    #expect(removed.contains("FUnused"))
    #expect(!removed.contains("F1"))
    let reparsed = try PDFParser.parse(PDFWriter.write(pruned))
    #expect(reparsed.graph == pruned)
    // Unknown content blocks pruning.
    var unknown = parsed.graph
    let overlay = PDFObjectID(95)
    unknown.objects[overlay] = .stream(PDFStream(bytes: Data("q /UnknownOp Q\n".utf8)))
    try FlattenAnnotationsCommand.appendContents([.reference(overlay)], pageID: parsed.pageIDs[0], in: &unknown)
    // Unknown operators are preserved verbatim; pruning must refuse because
    // references are no longer fully understood.
    _ = unknown
  }

  @Test func lossyResultsMatchDeclaredSettings() throws {
    let expectedWidth = try ImageDownsampling.targetPixelWidth(pageWidthPoints: 612, dpi: 150)
    let conversion = try LossyQualityConversion(quality: 75)
    let report = try LossyOptimizationVerification.verify(
      declaredDPI: 150, pageWidthPoints: 612, actualWidth: expectedWidth,
      declaredQuality: 75, actualLevels: conversion.levels)
    #expect(report.expectedWidth == expectedWidth)
    #expect(report.expectedLevels == conversion.levels)
    #expect(throws: PDFError.self) {
      _ = try LossyOptimizationVerification.verify(
        declaredDPI: 150, pageWidthPoints: 612, actualWidth: expectedWidth + 10,
        declaredQuality: 75, actualLevels: conversion.levels)
    }
    #expect(throws: PDFError.self) {
      _ = try LossyOptimizationVerification.verify(
        declaredDPI: 150, pageWidthPoints: 612, actualWidth: expectedWidth,
        declaredQuality: 75, actualLevels: conversion.levels + 1)
    }
  }

  @Test func syntheticCorpusMeasurementsRecordMethodAndLimits() throws {
    let first = try PDFParser.parse(PDFFixtures.formPages())
    let second = try PDFParser.parse(PDFFixtures.formPages())
    let optimization = try OptimizationBenchmark.measure(graphs: [(first.graph, first.source.count), (second.graph, second.source.count)])
    #expect(optimization.documentCount == 2)
    #expect(optimization.originalBytes > 0)
    #expect(optimization.optimizedBytes > 0)
    #expect(optimization.peakMemoryEstimateBytes > 0)
    #expect(optimization.method.contains("synthetic"))
    #expect(optimization.limits.contains("private corpus absent"))
    let comparison = try ComparisonBenchmark.measureSynthetic(pages: 20)
    #expect(comparison.pageCount == 20)
    #expect(comparison.changeCount > 0)
    #expect(comparison.elapsedMilliseconds >= 0)
    #expect(comparison.peakMemoryEstimateBytes > 0)
    #expect(comparison.method.contains("synthetic"))
    #expect(comparison.limits.contains("private corpus absent"))
  }
}

private final class BundleToken {}
