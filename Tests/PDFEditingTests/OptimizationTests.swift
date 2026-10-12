import AppKit
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// P31-001–P31-007/P31-009/P31-016–P31-020/P31-024–P31-026/P31-028 evidence:
/// size inventory with class attribution, the lossless optimization preset
/// (unreachable removal, duplicate-stream merging, verified content
/// recompression, linearization cleanup), preservation of text/fields/OCR/
/// unsupported resources, refusals for signed and protected graphs, and
/// visual comparison within tolerance.
@Suite("Optimization")
struct OptimizationTests {
  @Test func inventoryAttributesClassesAndDuplicates() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let inventory = try PDFOptimizer.inventory(in: parsed.graph, sourceBytes: parsed.source.count)
    #expect(inventory.sourceBytes == parsed.source.count)
    #expect(inventory.totalBytes > 0)
    let classes = inventory.bytesByClass
    #expect((classes[.content] ?? 0) > 0)
    #expect((classes[.forms] ?? 0) > 0)
    #expect((classes[.fonts] ?? 0) > 0)
    // The fixture repeats identical "q Q" appearance streams, so physical
    // duplicates must be detected separately from repeated references.
    #expect(!inventory.duplicateGroups.isEmpty)
    let referenced = inventory.entries.filter { $0.referenceCount > 1 }
    #expect(!referenced.isEmpty)
  }

  @Test func losslessOptimizationPreservesTextAndFields() throws {
    let data = try PDFFixtures.formPages()
    let parsed = try PDFParser.parse(data)
    let (optimized, _, report) = try PDFOptimizer.lossless(
      parsed.graph, sourceBytes: data.count)
    #expect(report.isImprovement)
    #expect(report.recompressedStreams > 0)
    #expect(!report.transformations.isEmpty)
    #expect(report.savedBytes > 0)

    let optimizedBytes = try PDFWriter.serialize(optimized, limits: PDFLimits())
    #expect(optimizedBytes.count < data.count)
    // P31-025: extracted text and field values are preserved exactly.
    let beforeDocument = try #require(PDFDocument(data: data))
    let afterDocument = try #require(PDFDocument(data: optimizedBytes))
    #expect(beforeDocument.string == afterDocument.string)
    let beforeValues = try FormValues.export(in: parsed.graph, pageIDs: parsed.pageIDs)
    let reparsed = try PDFParser.parse(optimizedBytes)
    let afterValues = try FormValues.export(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(beforeValues == afterValues)
    let beforeAnnotations = try AnnotationInventory.annotations(
      in: parsed.graph, pageID: parsed.pageIDs[0])
    let afterAnnotations = try AnnotationInventory.annotations(
      in: reparsed.graph, pageID: reparsed.pageIDs[0])
    #expect(beforeAnnotations.count == afterAnnotations.count)
  }

  @Test func recompressedStreamsDecodeExactly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = parsed.pageIDs[0]
    guard case .dictionary(let page)? = parsed.graph.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .stream(let original)? = parsed.graph.objects[contentID]
    else {
      Issue.record("Page content missing")
      return
    }
    let originalDecoded = try PDFFilters.decoded(original)
    let (optimized, _, report) = try PDFOptimizer.lossless(parsed.graph)
    #expect(report.recompressedStreams > 0)
    guard case .stream(let recompressed)? = optimized.objects[contentID] else {
      Issue.record("Recompressed stream missing")
      return
    }
    #expect(recompressed.dictionary[PDFName("Filter")] == .name(PDFName("FlateDecode")))
    #expect(try PDFFilters.decoded(recompressed) == originalDecoded)
  }

  @Test func duplicateStreamsAreMergedButDistinctResourcesKept() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let payload = Data(repeating: 0x41, count: 200)
    let dictionary: [PDFName: PDFValue] = [PDFName("Subtype"): .name(PDFName("Form"))]
    graph.objects[PDFObjectID(40)] = .stream(PDFStream(dictionary: dictionary, bytes: payload))
    graph.objects[PDFObjectID(41)] = .stream(PDFStream(dictionary: dictionary, bytes: payload))
    graph.objects[PDFObjectID(42)] = .stream(
      PDFStream(dictionary: dictionary, bytes: Data(repeating: 0x42, count: 200)))
    // References to the duplicates and the distinct stream so rewriting is
    // observable and nothing is pruned as unreachable.
    graph.objects[PDFObjectID(43)] = .dictionary([
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(41))]),
      PDFName("DR"): .reference(PDFObjectID(42)),
    ])
    graph.trailer[PDFName("Info")] = .reference(PDFObjectID(43))

    let (optimized, _, report) = try PDFOptimizer.lossless(graph)
    #expect(report.mergedDuplicateStreams == 1)
    #expect(optimized.objects[PDFObjectID(41)] == nil)
    #expect(optimized.objects[PDFObjectID(40)] != nil)
    #expect(optimized.objects[PDFObjectID(42)] != nil)
    guard case .dictionary(let info)? = optimized.objects[PDFObjectID(43)],
      case .dictionary(let appearance)? = info[PDFName("AP")],
      case .reference(let target)? = appearance[PDFName("N")]
    else {
      Issue.record("Rewritten reference missing")
      return
    }
    #expect(target == PDFObjectID(40))
  }

  @Test func unreachableObjectsAreRemoved() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    graph.objects[PDFObjectID(70)] = .dictionary([PDFName("Marker"): .string(Data("orphan".utf8))])
    let (optimized, _, report) = try PDFOptimizer.lossless(graph)
    #expect(optimized.objects[PDFObjectID(70)] == nil)
    #expect(report.removedUnreachableObjects >= 1)
  }

  @Test func signedAndProtectedGraphsRefuseOptimization() throws {
    let signedData = try fixture("Signed/signed-one-page.pdf")
    let signed = try PDFParser.parse(signedData)
    #expect(throws: PDFError.self) {
      _ = try PDFOptimizer.lossless(signed.graph)
    }
    let encryptedData = try fixture("Encrypted/aes-256-r6.pdf")
    let encrypted = try PDFParser.parse(encryptedData, password: "abc")
    #expect(throws: PDFError.self) {
      _ = try PDFOptimizer.lossless(encrypted.graph)
    }
  }

  @Test func unsupportedResourcesSurviveUnchanged() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let dctBytes = Data((0..<300).map { UInt8($0 % 251) })
    let metadataXML = Data("<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta/>".utf8)
    graph.objects[PDFObjectID(80)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Filter"): .name(PDFName("DCTDecode")),
          PDFName("Width"): .integer(10), PDFName("Height"): .integer(10),
        ], bytes: dctBytes))
    graph.objects[PDFObjectID(81)] = .stream(
      PDFStream(
        dictionary: [PDFName("Type"): .name(PDFName("Metadata"))], bytes: metadataXML))
    // P31-017: an attachment stream survives untouched as well.
    let attachmentBytes = Data("attached payload".utf8)
    graph.objects[PDFObjectID(83)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("EmbeddedFile")),
          PDFName("F"): .string(Data("note.txt".utf8)),
        ], bytes: attachmentBytes))
    // Reference the resources so they survive reachability pruning.
    graph.objects[PDFObjectID(82)] = .dictionary([
      PDFName("Metadata"): .reference(PDFObjectID(81)),
      PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(80))]),
      PDFName("EF"): .dictionary([PDFName("F"): .reference(PDFObjectID(83))]),
    ])
    graph.trailer[PDFName("Info")] = .reference(PDFObjectID(82))

    let (optimized, _, _) = try PDFOptimizer.lossless(graph)
    guard case .stream(let image)? = optimized.objects[PDFObjectID(80)],
      case .stream(let metadata)? = optimized.objects[PDFObjectID(81)]
    else {
      Issue.record("Protected resources missing")
      return
    }
    #expect(image.bytes == dctBytes)
    #expect(image.dictionary[PDFName("Filter")] == .name(PDFName("DCTDecode")))
    #expect(metadata.bytes == metadataXML)
    guard case .stream(let attachment)? = optimized.objects[PDFObjectID(83)] else {
      Issue.record("Attachment missing")
      return
    }
    #expect(attachment.bytes == attachmentBytes)
  }

  @Test func linearizationHintsAreRemoved() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    graph.objects[PDFObjectID(90)] = .dictionary([
      PDFName("Linearized"): .integer(1),
      PDFName("L"): .integer(500),
    ])
    graph.objects[PDFObjectID(91)] = .stream(
      PDFStream(dictionary: [PDFName("Length"): .integer(4)], bytes: Data("hint".utf8)))
    // The hint stream is only reachable through the linearization dictionary.
    if case .dictionary(var linearized)? = graph.objects[PDFObjectID(90)] {
      linearized[PDFName("H")] = .reference(PDFObjectID(91))
      graph.objects[PDFObjectID(90)] = .dictionary(linearized)
    }
    graph.trailer[PDFName("Prev")] = .integer(1234)

    let (optimized, _, report) = try PDFOptimizer.lossless(graph)
    #expect(optimized.objects[PDFObjectID(90)] == nil)
    #expect(optimized.objects[PDFObjectID(91)] == nil)
    #expect(optimized.trailer[PDFName("Prev")] == nil)
    #expect(report.removedLinearizationHints >= 2)
  }

  @Test func ocrLayersSurviveOptimization() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let lines = [
      SearchableTextLine(text: "optimized layer", rect: [10, 10, 120, 30], confidence: 0.9)
    ]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([AddSearchableTextLayerCommand(pageID: pageID, lines: lines)]),
      to: parsed.graph)
    #expect(OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID))
    let (optimized, _, report) = try PDFOptimizer.lossless(graph)
    #expect(OCRLayer.hasGeneratedLayer(in: optimized, pageID: pageID))
    #expect((report.bytesByClass[.ocrLayers] ?? 0) > 0)
    let data = try PDFWriter.serialize(optimized, limits: PDFLimits())
    let document = try #require(PDFDocument(data: data))
    #expect(document.string?.contains("optimized layer") == true)
  }

  @Test func visualComparisonWithinTolerance() throws {
    // P31-026: lossless optimization renders within a recorded tolerance.
    let data = try PDFFixtures.formPages()
    let parsed = try PDFParser.parse(data)
    let (optimized, _, _) = try PDFOptimizer.lossless(parsed.graph)
    let optimizedBytes = try PDFWriter.serialize(optimized, limits: PDFLimits())
    let before = try render(data, pageIndex: 0)
    let after = try render(optimizedBytes, pageIndex: 0)
    #expect(before.count == after.count)
    var maximumDifference = 0
    var totalDifference = 0
    for (lhs, rhs) in zip(before, after) {
      let difference = abs(Int(lhs) - Int(rhs))
      maximumDifference = max(maximumDifference, difference)
      totalDifference += difference
    }
    let meanDifference = Double(totalDifference) / Double(max(before.count, 1))
    // Recorded tolerance: antialiasing may differ by at most 2 per channel,
    // with a negligible mean.
    #expect(maximumDifference <= 2)
    #expect(meanDifference < 0.5)
  }

  // MARK: Helpers

  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
  }

  private func render(_ data: Data, pageIndex: Int) throws -> [UInt8] {
    let document = try #require(PDFDocument(data: data))
    let page = try #require(document.page(at: pageIndex))
    let size = NSSize(width: 300, height: 400)
    let image = page.thumbnail(of: size, for: .cropBox)
    let representation = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let pixels = representation.bitmapData else {
      throw PDFError(.malformed, "Rendered page has no pixels")
    }
    let length = representation.bytesPerRow * representation.pixelsHigh
    return Array(UnsafeBufferPointer(start: pixels, count: length))
  }
}

extension OptimizationTests {
  @Test func compressedObjectOutputReparsesIdentically() throws {
    let data = try PDFFixtures.formPages()
    let parsed = try PDFParser.parse(data)
    let compressed = try PDFWriter.writeCompressed(parsed.graph)
    // P31-008: object streams and an xref stream are used.
    #expect(compressed.range(of: Data("/ObjStm".utf8)) != nil)
    #expect(compressed.range(of: Data("/XRef".utf8)) != nil)
    let reparsed = try PDFParser.parse(compressed)
    for (id, value) in parsed.graph.objects {
      #expect(reparsed.graph.objects[id] == value, "object \(id.number)")
    }
    // The only extra objects are the ObjStm and XRef containers.
    for (id, value) in reparsed.graph.objects where parsed.graph.objects[id] == nil {
      guard case .stream(let stream) = value else {
        Issue.record("Unexpected extra object \(id.number)")
        continue
      }
      let type = stream.dictionary[PDFName("Type")]
      #expect(
        type == .name(PDFName("ObjStm")) || type == .name(PDFName("XRef")),
        "object \(id.number)")
    }
    // The independent reader accepts it and the text survives.
    let document = try #require(PDFDocument(data: compressed))
    #expect(document.string == PDFDocument(data: data)?.string)

    // The preset chooses the smaller framing and reports which one it used.
    let classic = try PDFWriter.serialize(parsed.graph)
    let (_, presetData, report) = try PDFOptimizer.lossless(parsed.graph)
    #expect(presetData.count <= classic.count)
    if report.usedCompressedOutput {
      #expect(presetData.range(of: Data("/ObjStm".utf8)) != nil)
    }
    let presetDocument = try #require(PDFDocument(data: presetData))
    #expect(presetDocument.string == PDFDocument(data: data)?.string)
  }

  @Test func metadataRemovalIsSeparateAndExplicit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let metadataXML = Data("<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta/>".utf8)
    graph.objects[PDFObjectID(45)] = .stream(
      PDFStream(
        dictionary: [PDFName("Type"): .name(PDFName("Metadata"))], bytes: metadataXML))
    graph.objects[PDFObjectID(46)] = .dictionary([
      PDFName("Title"): .string(Data("fixture".utf8))
    ])
    graph.trailer[PDFName("Info")] = .reference(PDFObjectID(46))
    guard case .dictionary(var catalog)? = graph.objects[PDFObjectID(1)] else {
      Issue.record("Catalog missing")
      return
    }
    catalog[PDFName("Metadata")] = .reference(PDFObjectID(45))
    graph.objects[PDFObjectID(1)] = .dictionary(catalog)

    // Default: metadata survives ordinary compression.
    let (preserved, _, defaultReport) = try PDFOptimizer.lossless(graph)
    #expect(preserved.trailer[PDFName("Info")] != nil)
    #expect(preserved.objects[PDFObjectID(45)] != nil)
    #expect(defaultReport.removedMetadataObjects == 0)

    // Explicit removal is a separate pass.
    let (removed, _, report) = try PDFOptimizer.lossless(
      graph, options: PDFOptimizationOptions(removeMetadata: true))
    #expect(removed.trailer[PDFName("Info")] == nil)
    #expect(removed.objects[PDFObjectID(45)] == nil)
    #expect(report.removedMetadataObjects >= 2)
    #expect(report.transformations.contains { $0.contains("metadata") })
  }

  @Test func pageAndClassTargetingLimitRecompression() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let (_, _, pageReport) = try PDFOptimizer.lossless(
      parsed.graph, options: PDFOptimizationOptions(recompressPageIndexes: [0]))
    #expect(pageReport.recompressedStreams == 1)
    let (_, _, formReport) = try PDFOptimizer.lossless(
      parsed.graph, options: PDFOptimizationOptions(recompressClasses: [.forms]))
    #expect(formReport.recompressedStreams == 0)
    let (_, _, allReport) = try PDFOptimizer.lossless(parsed.graph)
    #expect(allReport.recompressedStreams == 3)
  }

  @Test func optimizationIsCancellable() async throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let task = Task { () -> Int in
      try PDFOptimizer.lossless(parsed.graph).report.optimizedBytes
    }
    task.cancel()
    let result = await task.result
    switch result {
    case .success:
      Issue.record("A cancelled optimization completed")
    case .failure(let error):
      #expect(error is CancellationError)
    }
  }
}
