import CryptoKit
import Foundation
import PDFCore

/// P31-001/P31-002/P31-003: a size inventory with resource classes, reference
/// counts, and physical duplicates.
public struct PDFSizeInventory: Sendable, Equatable {
  public enum ResourceClass: String, Sendable, CaseIterable, Equatable {
    case images
    case fonts
    case content
    case metadata
    case attachments
    case annotations
    case forms
    case ocrLayers
    case other
  }

  public struct Entry: Sendable, Equatable {
    public let objectID: PDFObjectID
    public let resourceClass: ResourceClass
    public let bytes: Int
    public let referenceCount: Int
  }

  public let entries: [Entry]
  /// Objects whose serialized content is byte-identical (physical duplicates).
  public let duplicateGroups: [[PDFObjectID]]
  public let totalBytes: Int
  public let sourceBytes: Int?

  public var bytesByClass: [ResourceClass: Int] {
    var result: [ResourceClass: Int] = [:]
    for entry in entries { result[entry.resourceClass, default: 0] += entry.bytes }
    return result
  }
}

public enum PDFOptimizer {
  // MARK: Inventory

  /// P31-001–P31-003: attribute every object to a resource class, count its
  /// references, and group physically identical objects.
  public static func inventory(
    in graph: PDFGraph, sourceBytes: Int? = nil, limits: PDFLimits = PDFLimits()
  ) throws -> PDFSizeInventory {
    var referenceCounts: [PDFObjectID: Int] = [:]
    for value in graph.objects.values {
      countReferences(in: value, into: &referenceCounts)
    }
    let pageContentIDs = try pageContentObjectIDs(in: graph)

    var entries: [PDFSizeInventory.Entry] = []
    var fingerprints: [Data: [PDFObjectID]] = [:]
    for (id, value) in graph.objects.sorted(by: { $0.key < $1.key }) {
      let bytes = objectSize(value, limits: limits)
      entries.append(
        PDFSizeInventory.Entry(
          objectID: id,
          resourceClass: classify(value, objectID: id, pageContentIDs: pageContentIDs),
          bytes: bytes, referenceCount: referenceCounts[id] ?? 0))
      if case .stream(let stream) = value, !stream.bytes.isEmpty {
        fingerprints[fingerprint(stream, limits: limits), default: []].append(id)
      }
    }
    let duplicateGroups = fingerprints.values.filter { $0.count > 1 }
      .map { $0.sorted() }
      .sorted { ($0.first?.number ?? 0) < ($1.first?.number ?? 0) }
    return PDFSizeInventory(
      entries: entries, duplicateGroups: duplicateGroups,
      totalBytes: entries.reduce(0) { $0 + $1.bytes }, sourceBytes: sourceBytes)
  }

  static func countReferences(in value: PDFValue, into counts: inout [PDFObjectID: Int]) {
    switch value {
    case .reference(let id):
      counts[id, default: 0] += 1
    case .array(let values):
      for value in values { countReferences(in: value, into: &counts) }
    case .dictionary(let dictionary):
      for value in dictionary.values { countReferences(in: value, into: &counts) }
    case .stream(let stream):
      countReferences(in: .dictionary(stream.dictionary), into: &counts)
    default:
      break
    }
  }

  static func objectSize(_ value: PDFValue, limits: PDFLimits) -> Int {
    switch value {
    case .stream(let stream):
      let dictionary = (try? PDFWriter.serializedValue(.dictionary(stream.dictionary)))?.count ?? 0
      return dictionary + stream.bytes.count
    default:
      return (try? PDFWriter.serializedValue(value))?.count ?? 0
    }
  }

  static func classify(
    _ value: PDFValue, objectID: PDFObjectID, pageContentIDs: Set<PDFObjectID>
  ) -> PDFSizeInventory.ResourceClass {
    guard case .stream(let stream) = value else {
      if case .dictionary(let dictionary) = value {
        if dictionary[PDFName("Type")] == .name(PDFName("Metadata")) { return .metadata }
        if dictionary[PDFName("Subtype")] == .name(PDFName("Form"))
          && dictionary[PDFName("Type")] == .name(PDFName("XObject"))
        {
          return .forms
        }
        if dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
          || dictionary[PDFName("Subtype")] == .name(PDFName("Annot"))
        {
          return .annotations
        }
        if dictionary[PDFName("Type")] == .name(PDFName("Font"))
          || dictionary[PDFName("Type")] == .name(PDFName("FontDescriptor"))
        {
          return .fonts
        }
      }
      return .other
    }
    let dictionary = stream.dictionary
    if dictionary[PDFName("Subtype")] == .name(PDFName("Image")) { return .images }
    if dictionary[PDFName("Type")] == .name(PDFName("Metadata")) { return .metadata }
    if dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile")) { return .attachments }
    if dictionary[PDFName("Subtype")] == .name(PDFName("Form")) { return .forms }
    if dictionary[PDFName("SPDFOCR")] == .boolean(true) { return .ocrLayers }
    if pageContentIDs.contains(objectID) { return .content }
    if dictionary[PDFName("Type")] == .name(PDFName("FontFile"))
      || dictionary[PDFName("Type")] == .name(PDFName("FontFile2"))
      || dictionary[PDFName("Type")] == .name(PDFName("FontFile3"))
    {
      return .fonts
    }
    return .other
  }

  static func pageContentObjectIDs(in graph: PDFGraph) throws -> Set<PDFObjectID> {
    try pageContentObjectIDs(in: graph, pageIndexes: nil)
  }

  static func pageContentObjectIDs(
    in graph: PDFGraph, pageIndexes: Set<Int>?
  ) throws -> Set<PDFObjectID> {
    var ids: Set<PDFObjectID> = []
    guard let pages = try? PDFPageTree.pageIDs(in: graph) else { return ids }
    for (index, pageID) in pages.enumerated() {
      if let pageIndexes, !pageIndexes.contains(index) { continue }
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      switch page[PDFName("Contents")] {
      case .reference(let id)?:
        ids.insert(id)
      case .array(let values)?:
        for value in values {
          if case .reference(let id) = value { ids.insert(id) }
        }
      default:
        break
      }
    }
    return ids
  }

  static func fingerprint(_ stream: PDFStream, limits: PDFLimits) -> Data {
    var dictionary = stream.dictionary
    dictionary.removeValue(forKey: PDFName("Length"))
    let dictionaryBytes =
      (try? PDFWriter.serializedValue(.dictionary(dictionary))) ?? Data()
    var key = dictionaryBytes
    key.append(Data(SHA256.hash(data: stream.bytes)))
    return key
  }

  // MARK: Lossless preset (P31-004)

  /// P31-004/P31-005/P31-006/P31-007/P31-009/P31-018: the lossless preset.
  /// Unreachable objects, duplicate streams, stale linearization data, and
  /// uncompressed content streams are handled; images, metadata, attachments,
  /// annotations, forms, and OCR layers are preserved. Signed and protected
  /// graphs refuse the transformation.
  public static func lossless(
    _ graph: PDFGraph, options: PDFOptimizationOptions = PDFOptimizationOptions(),
    sourceBytes: Int? = nil, limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, data: Data, report: PDFOptimizationReport) {
    try Task.checkCancellation()
    guard graph.trailer[PDFName("Encrypt")] == nil else {
      throw PDFError(
        .unsupported, "Optimization needs a dedicated policy for protected documents")
    }
    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    guard signatures.isEmpty else {
      throw PDFError(.unsupported, "Optimization needs a dedicated policy for signed documents")
    }
    let before = try inventory(in: graph, sourceBytes: sourceBytes, limits: limits)
    var optimized = graph
    var transformations: [String] = []

    // P31-009: stale linearization/optimization data is invalidated.
    var removedHints = 0
    for (id, value) in optimized.objects {
      if case .dictionary(let dictionary) = value,
        dictionary[PDFName("Linearized")] != nil
      {
        optimized.objects[id] = nil
        removedHints += 1
      }
    }
    if optimized.trailer[PDFName("Prev")] != nil {
      optimized.trailer[PDFName("Prev")] = nil
      removedHints += 1
    }
    if optimized.trailer[PDFName("XRefStm")] != nil {
      optimized.trailer[PDFName("XRefStm")] = nil
      removedHints += 1
    }
    if removedHints > 0 { transformations.append("removed stale linearization data") }

    // P31-007/P31-022: recompress uncompressed content and form streams,
    // limited to the requested pages and resource classes.
    try Task.checkCancellation()
    var recompressed = 0
    let pageContentIDs = try pageContentObjectIDs(in: optimized)
    let targetedPageContentIDs: Set<PDFObjectID>
    if let indexes = options.recompressPageIndexes {
      targetedPageContentIDs = try pageContentObjectIDs(in: optimized, pageIndexes: indexes)
    } else {
      targetedPageContentIDs = pageContentIDs
    }
    for (id, value) in optimized.objects {
      guard case .stream(var stream) = value, stream.dictionary[PDFName("Filter")] == nil,
        stream.bytes.count > 64
      else { continue }
      let isContent = targetedPageContentIDs.contains(id)
      let isForm = stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form"))
      let isOCRLayer = stream.dictionary[PDFName("SPDFOCR")] == .boolean(true)
      guard (isContent && options.recompressClasses.contains(.content))
        || (isForm && options.recompressClasses.contains(.forms))
        || (isOCRLayer && options.recompressClasses.contains(.ocrLayers))
      else { continue }
      guard let encoded = try? PDFFilters.encodeFlate(stream.bytes, limits: limits) else {
        continue
      }
      // Verified framing: the encoded stream must decode back exactly.
      let candidate = PDFStream(
        dictionary: stream.dictionary.merging([
          PDFName("Filter"): .name(PDFName("FlateDecode")),
          PDFName("Length"): .integer(Int64(encoded.count)),
        ]) { _, new in new }, bytes: encoded)
      guard let decoded = try? PDFFilters.decoded(candidate, limits: limits),
        decoded == stream.bytes
      else { continue }
      stream.dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
      stream.dictionary.removeValue(forKey: PDFName("DecodeParms"))
      stream.dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
      stream.bytes = encoded
      optimized.objects[id] = .stream(stream)
      recompressed += 1
    }
    if recompressed > 0 { transformations.append("recompressed \(recompressed) content streams") }

    // P31-006: merge byte-identical streams that are not semantically distinct.
    var merged = 0
    let groups = try inventory(in: optimized, limits: limits).duplicateGroups
    var redirect: [PDFObjectID: PDFObjectID] = [:]
    for group in groups {
      guard group.count > 1 else { continue }
      let keeper = group[0]
      for duplicate in group.dropFirst() {
        guard let value = optimized.objects[duplicate] else { continue }
        if isProtectedResource(value) { continue }
        redirect[duplicate] = keeper
      }
    }
    if !redirect.isEmpty {
      for (id, value) in optimized.objects {
        optimized.objects[id] = rewritingReferences(in: value, redirect: redirect)
      }
      merged = redirect.count
      transformations.append("merged \(merged) duplicate streams")
    }

    // P31-005: remove objects unreachable from the trailer under the valid
    // graph policy (reachability from root and info).
    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: optimized)
    var removed = 0
    for id in optimized.objects.keys where !reachable.contains(id) {
      optimized.objects[id] = nil
      removed += 1
    }
    if removed > 0 { transformations.append("removed \(removed) unreachable objects") }

    // P31-021: metadata removal is a separate explicit pass, never part of
    // ordinary compression.
    var removedMetadata = 0
    if options.removeMetadata {
      try Task.checkCancellation()
      if optimized.trailer[PDFName("Info")] != nil {
        optimized.trailer[PDFName("Info")] = nil
        removedMetadata += 1
      }
      for (id, value) in optimized.objects {
        let dictionary: [PDFName: PDFValue]?
        if case .dictionary(let direct) = value {
          dictionary = direct
        } else if case .stream(let stream) = value {
          dictionary = stream.dictionary
        } else {
          dictionary = nil
        }
        guard let dictionary, dictionary[PDFName("Type")] == .name(PDFName("Metadata")) else {
          continue
        }
        optimized.objects[id] = nil
        removedMetadata += 1
      }
      // The catalog's /Metadata reference and any now-empty /Info entries.
      if case .reference(let rootID)? = optimized.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = optimized.objects[rootID]
      {
        if catalog[PDFName("Metadata")] != nil {
          catalog[PDFName("Metadata")] = nil
          optimized.objects[rootID] = .dictionary(catalog)
        }
      }
      if removedMetadata > 0 { transformations.append("removed \(removedMetadata) metadata objects") }
    }

    // P31-005 again: metadata removal can orphan objects.
    let reachableAfterMetadata = SanitizeDocumentCommand.reachableObjectIDs(in: optimized)
    var removedAfterMetadata = 0
    for id in optimized.objects.keys where !reachableAfterMetadata.contains(id) {
      optimized.objects[id] = nil
      removedAfterMetadata += 1
    }
    removed += removedAfterMetadata

    let after = try inventory(in: optimized, sourceBytes: sourceBytes, limits: limits)
    _ = after
    let classicBytes = try PDFWriter.serialize(optimized, limits: limits)
    var output = classicBytes
    var usedCompressed = false
    if options.compressedOutput,
      let compressed = try? PDFWriter.writeCompressed(optimized, limits: limits),
      compressed.count < classicBytes.count
    {
      output = compressed
      usedCompressed = true
    }
    let report = PDFOptimizationReport(
      originalBytes: sourceBytes ?? before.totalBytes, optimizedBytes: output.count,
      removedUnreachableObjects: removed, mergedDuplicateStreams: merged,
      recompressedStreams: recompressed, removedLinearizationHints: removedHints,
      removedMetadataObjects: removedMetadata, usedCompressedOutput: usedCompressed,
      bytesByClass: before.bytesByClass, transformations: transformations)
    return (optimized, output, report)
  }

  static func isProtectedResource(_ value: PDFValue) -> Bool {
    switch value {
    case .dictionary(let dictionary):
      if dictionary[PDFName("ByteRange")] != nil { return true }
      if dictionary[PDFName("Type")] == .name(PDFName("Metadata")) { return true }
      if dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile")) { return true }
      if dictionary[PDFName("Type")] == .name(PDFName("Sig")) { return true }
      if dictionary[PDFName("Type")] == .name(PDFName("DocTimeStamp")) { return true }
      return false
    case .stream(let stream):
      return isProtectedResource(.dictionary(stream.dictionary))
    default:
      return false
    }
  }

  static func rewritingReferences(
    in value: PDFValue, redirect: [PDFObjectID: PDFObjectID]
  ) -> PDFValue {
    switch value {
    case .reference(let id):
      if let target = redirect[id] { return .reference(target) }
      return value
    case .array(let values):
      return .array(values.map { rewritingReferences(in: $0, redirect: redirect) })
    case .dictionary(let dictionary):
      var result: [PDFName: PDFValue] = [:]
      for (key, entry) in dictionary {
        result[key] = rewritingReferences(in: entry, redirect: redirect)
      }
      return .dictionary(result)
    case .stream(let stream):
      var stream = stream
      if case .dictionary(let dictionary) = rewritingReferences(
        in: .dictionary(stream.dictionary), redirect: redirect)
      {
        stream.dictionary = dictionary
      }
      return .stream(stream)
    default:
      return value
    }
  }
}

/// P31-008/P31-021/P31-022/P31-023: explicit options for the lossless
/// preset. Metadata removal is a separate pass (off by default), targeting
/// limits recompression, and compressed-object output is used when it is
/// smaller. The preset checks cancellation between stages.
public struct PDFOptimizationOptions: Sendable, Equatable {
  public let removeMetadata: Bool
  public let recompressPageIndexes: Set<Int>?
  public let recompressClasses: Set<PDFSizeInventory.ResourceClass>
  public let compressedOutput: Bool

  public init(
    removeMetadata: Bool = false, recompressPageIndexes: Set<Int>? = nil,
    recompressClasses: Set<PDFSizeInventory.ResourceClass> = [.content, .forms, .ocrLayers],
    compressedOutput: Bool = true
  ) {
    self.removeMetadata = removeMetadata
    self.recompressPageIndexes = recompressPageIndexes
    self.recompressClasses = recompressClasses
    self.compressedOutput = compressedOutput
  }
}

/// P31-019/P31-020: before/after sizes, class attribution, and the
/// transformations that were applied. Lossy conversions never appear here.
public struct PDFOptimizationReport: Sendable, Equatable {
  public let originalBytes: Int
  public let optimizedBytes: Int
  public let removedUnreachableObjects: Int
  public let mergedDuplicateStreams: Int
  public let recompressedStreams: Int
  public let removedLinearizationHints: Int
  public let removedMetadataObjects: Int
  public let usedCompressedOutput: Bool
  public let bytesByClass: [PDFSizeInventory.ResourceClass: Int]
  public let transformations: [String]

  public var savedBytes: Int { originalBytes - optimizedBytes }
  public var isImprovement: Bool { optimizedBytes < originalBytes }

  public var summary: String {
    let before = ByteCountFormatter.string(
      fromByteCount: Int64(originalBytes), countStyle: .file)
    let after = ByteCountFormatter.string(
      fromByteCount: Int64(optimizedBytes), countStyle: .file)
    let changes = transformations.isEmpty ? "no changes" : transformations.joined(separator: ", ")
    return "\(before) → \(after) (\(savedBytes >= 0 ? "saved" : "grew") \(abs(savedBytes)) bytes): \(changes)"
  }
}
