import Foundation
import PDFCore

// MARK: - RED-06 independent output inspection

public struct RedactionAdversarialLocation: Sendable, Equatable {
  public enum Category: String, Sendable, Equatable {
    case rawBytes
    case earlierRevision
    case orphanObject
    case objectString
    case streamBytes
    case pageText
    case metadata
    case xmpMetadata
    case pageMetadata
    case comment
    case attachment
    case action
    case structureAlternateText
    case formValue
    case thumbnail
    case documentIdentifier
  }

  public let seed: String
  public let category: Category
  public let detail: String

  public init(seed: String, category: Category, detail: String) {
    self.seed = seed
    self.category = category
    self.detail = detail
  }
}

public enum RedactionOutputInspector {
  /// Independent inspection of distributed bytes: raw bytes, decoded streams,
  /// object strings, rendered page text, metadata, forms, structure alternate
  /// text, attachments, actions and revision/orphan markers. It shares no
  /// code with the redaction/sanitization passes that produced the output.
  public static func locate(
    seeds: [String], in data: Data, limits: PDFLimits = PDFLimits()
  ) -> [RedactionAdversarialLocation] {
    let needles = seeds.filter { !$0.isEmpty }
    guard !needles.isEmpty else { return [] }
    var locations: [RedactionAdversarialLocation] = []
    func record(_ seed: String, _ category: RedactionAdversarialLocation.Category, _ detail: String) {
      locations.append(.init(seed: seed, category: category, detail: detail))
    }
    for seed in needles where data.range(of: Data(seed.utf8)) != nil {
      record(seed, .rawBytes, "raw file bytes")
    }
    if data.range(of: Data("/Prev".utf8)) != nil {
      for seed in needles {
        record(seed, .earlierRevision, "earlier revision chain marker present")
      }
    }
    guard let parsed = try? PDFParser.parse(data, limits: limits) else {
      return locations
    }
    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: parsed.graph)
    if reachable.count != parsed.graph.objects.count {
      for seed in needles {
        record(seed, .orphanObject, "unreachable objects present in output")
      }
    }
    let pageIDs = (try? PDFPageTree.pageIDs(in: parsed.graph)) ?? []
    var xmpIDs: Set<PDFObjectID> = []
    for (id, value) in parsed.graph.objects {
      guard case .stream(let stream) = value else { continue }
      if stream.dictionary[PDFName("Type")] == .name(PDFName("Metadata")) {
        xmpIDs.insert(id)
        if stream.dictionary[PDFName("Subtype")] != .name(PDFName("XML")) {
          xmpIDs.insert(id)
        }
      }
    }
    for (id, value) in parsed.graph.objects {
      var dictionary: [PDFName: PDFValue]?
      var stream: PDFStream?
      switch value {
      case .dictionary(let direct): dictionary = direct
      case .stream(let value): dictionary = value.dictionary; stream = value
      default: break
      }
      var strings: [Data] = []
      collectStrings(in: value, into: &strings)
      let baseCategory = category(for: dictionary, stream: stream, id: id, graph: parsed.graph)
      for stringData in strings {
        let text = AnnotationText.decode(stringData)
        for seed in needles where text.contains(seed) {
          record(seed, baseCategory, "object \(id.number) string")
        }
      }
      if let stream, let decoded = try? PDFFilters.decoded(stream, limits: limits) {
        let text = String(decoding: decoded, as: UTF8.self)
        for seed in needles where text.contains(seed) {
          let category = streamCategory(
            seed: seed, stream: stream, id: id, xmpIDs: xmpIDs, pageIDs: pageIDs,
            graph: parsed.graph, base: baseCategory)
          record(seed, category, "decoded stream object \(id.number)")
        }
      }
    }
    for pageID in pageIDs {
      guard let layout = try? PageTextLayout.buildForParagraphEditing(
        pageID: pageID, in: parsed.graph, limits: limits)
      else { continue }
      let text = layout.text(in: 0..<layout.clusters.count)
      for seed in needles where text.contains(seed) {
        record(seed, .pageText, "rendered page text (page \(pageID.number))")
      }
    }
    return locations
  }

  static func streamCategory(
    seed: String, stream: PDFStream, id: PDFObjectID, xmpIDs: Set<PDFObjectID>,
    pageIDs: [PDFObjectID], graph: PDFGraph, base: RedactionAdversarialLocation.Category
  ) -> RedactionAdversarialLocation.Category {
    if xmpIDs.contains(id) { return .xmpMetadata }
    if stream.dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile")) {
      return .attachment
    }
    for pageID in pageIDs {
      if case .dictionary(let page)? = graph.objects[pageID],
        case .reference(let thumbID)? = page[PDFName("Thumb")], thumbID == id
      {
        return .thumbnail
      }
    }
    return base == .rawBytes ? .streamBytes : base
  }

  static func category(
    for dictionary: [PDFName: PDFValue]?, stream: PDFStream?, id: PDFObjectID,
    graph: PDFGraph
  ) -> RedactionAdversarialLocation.Category {
    guard let dictionary else { return .objectString }
    if dictionary[PDFName("Type")] == .name(PDFName("Metadata")) { return .xmpMetadata }
    if dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile")) { return .attachment }
    if dictionary[PDFName("S")] == .name(PDFName("JavaScript"))
      || dictionary[PDFName("S")] == .name(PDFName("Launch"))
    { return .action }
    if dictionary[PDFName("FT")] != nil {
      for key in [PDFName("V"), PDFName("DV"), PDFName("RV")] {
        if dictionary[key] != nil { return .formValue }
      }
      return .formValue
    }
    if case .reference(let infoID)? = graph.trailer[PDFName("Info")], infoID == id {
      return .metadata
    }
    if dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
      || dictionary[PDFName("Subtype")] == .name(PDFName("Text"))
      || dictionary[PDFName("Contents")] != nil
    { return .comment }
    if dictionary[PDFName("Alt")] != nil || dictionary[PDFName("ActualText")] != nil {
      return .structureAlternateText
    }
    if dictionary[PDFName("Type")] == .name(PDFName("Filespec")) { return .attachment }
    if stream != nil { return .streamBytes }
    return .objectString
  }

  static func collectStrings(in value: PDFValue, into strings: inout [Data], depth: Int = 0) {
    guard depth < 32 else { return }
    switch value {
    case .string(let data):
      strings.append(data)
    case .array(let values):
      for value in values { collectStrings(in: value, into: &strings, depth: depth + 1) }
    case .dictionary(let dictionary):
      for value in dictionary.values {
        collectStrings(in: value, into: &strings, depth: depth + 1)
      }
    case .stream(let stream):
      for value in stream.dictionary.values {
        collectStrings(in: value, into: &strings, depth: depth + 1)
      }
    default:
      break
    }
  }
}

// MARK: - RED-06 adversarial validation

public struct RedactionAdversarialResult: Sendable, Equatable {
  public let seeds: [String]
  public let distributedClean: Bool
  public let survivingLocations: [RedactionAdversarialLocation]
  public let sourceRetainedSeeds: [String]
  public let sourceLocations: [RedactionAdversarialLocation]
  public let checks: [String]
  public let recoveryDisclosure: String

  public var survivingSeeds: [String] {
    Array(Set(survivingLocations.map(\.seed))).sorted()
  }

  public var summary: String {
    var lines: [String] = []
    lines.append(
      distributedClean
        ? "Distributed output: no protected seed is recoverable."
        : "Distributed output: protected seeds are recoverable.")
    if !survivingSeeds.isEmpty {
      lines.append("  surviving: " + survivingSeeds.joined(separator: ", "))
    }
    if !sourceRetainedSeeds.isEmpty {
      lines.append(
        "  source retention: the opened source and any recovery snapshots may still retain "
          + sourceRetainedSeeds.joined(separator: ", "))
    }
    lines.append("  " + recoveryDisclosure)
    return lines.joined(separator: "\n")
  }
}

public enum RedactionAdversarialValidator {
  /// RED-06: validate a distributed redacted/sanitized output with independent
  /// extraction and object inspection. Pass the source bytes as well so the
  /// result explicitly distinguishes source retention/recovery from the
  /// distributed output.
  public static func validate(
    distributed: Data, seeds: [String], source: Data? = nil,
    limits: PDFLimits = PDFLimits()
  ) -> RedactionAdversarialResult {
    let surviving = RedactionOutputInspector.locate(seeds: seeds, in: distributed, limits: limits)
    var sourceLocations: [RedactionAdversarialLocation] = []
    if let source {
      sourceLocations = RedactionOutputInspector.locate(seeds: seeds, in: source, limits: limits)
    }
    var checks: [String] = [
      "raw bytes, decoded streams and object strings inspected",
      "rendered page text inspected",
      "attachments, forms, metadata and structure alternate text classified",
      "orphan-object and earlier-revision markers inspected",
    ]
    if let parsed = try? PDFParser.parse(distributed, limits: limits) {
      if parsed.graph.trailer[PDFName("Prev")] == nil {
        checks.append("distributed output is a single revision")
      }
      let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: parsed.graph)
      if reachable.count == parsed.graph.objects.count {
        checks.append("distributed output has no unreachable objects")
      }
    } else {
      checks.append("distributed output could not be parsed by the independent inspector")
    }
    let sourceRetained = Array(Set(sourceLocations.map(\.seed))).sorted()
    let recoveryDisclosure =
      "Removed data may remain in the open source document, undo history and recovery snapshots; "
      + "the distributed copy is the artifact this validation covers."
    return RedactionAdversarialResult(
      seeds: seeds, distributedClean: surviving.isEmpty, survivingLocations: surviving,
      sourceRetainedSeeds: sourceRetained, sourceLocations: sourceLocations,
      checks: checks, recoveryDisclosure: recoveryDisclosure)
  }
}

