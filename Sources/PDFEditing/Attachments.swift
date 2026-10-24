import Foundation
import PDFCore

/// P34-017: one embedded file (attachment) with its filespec metadata.
public struct PDFAttachment: Sendable, Equatable {
  public let name: String
  public let fileName: String?
  public let description: String?
  public let mimeType: String?
  public let size: Int?
  public let creationDate: String?
  public let modificationDate: String?
  public let checksum: Data?
  public let filespecObjectID: PDFObjectID?
  public let streamObjectID: PDFObjectID?

  public init(
    name: String, fileName: String?, description: String?, mimeType: String?, size: Int?,
    creationDate: String?, modificationDate: String?, checksum: Data?,
    filespecObjectID: PDFObjectID?, streamObjectID: PDFObjectID?
  ) {
    self.name = name
    self.fileName = fileName
    self.description = description
    self.mimeType = mimeType
    self.size = size
    self.creationDate = creationDate
    self.modificationDate = modificationDate
    self.checksum = checksum
    self.filespecObjectID = filespecObjectID
    self.streamObjectID = streamObjectID
  }
}

/// P34-017/P34-018: attachment inventory and byte-exact extraction. Nothing is
/// ever executed or opened; extraction only writes bytes to chosen
/// destinations.
public enum PDFAttachmentInventory {
  public static func attachments(in graph: PDFGraph) -> [PDFAttachment] {
    var result: [PDFAttachment] = []
    for (name, value) in pairs(in: graph) {
      guard case .reference(let filespecID) = value,
        case .dictionary(let filespec)? = graph.objects[filespecID]
      else { continue }
      let fileName = string(filespec[PDFName("UF")]) ?? string(filespec[PDFName("F")])
      let stream = embeddedStream(in: filespec, graph: graph)
      var size: Int?
      var creationDate: String?
      var modificationDate: String?
      var checksum: Data?
      var mimeType = nameString(filespec[PDFName("Subtype")])
      if let stream {
        if case .dictionary(let params)? = resolved(
          stream.stream.dictionary[PDFName("Params")], in: graph)
        {
          if case .integer(let raw)? = params[PDFName("Size")] { size = Int(exactly: raw) }
          creationDate = string(params[PDFName("CreationDate")])
          modificationDate = string(params[PDFName("ModDate")])
          if case .string(let raw)? = params[PDFName("CheckSum")] { checksum = raw }
        }
        if mimeType == nil {
          mimeType = nameString(stream.stream.dictionary[PDFName("Subtype")])
        }
        if size == nil {
          size = (try? PDFFilters.decoded(stream.stream).count) ?? stream.stream.bytes.count
        }
      }
      result.append(
        PDFAttachment(
          name: name, fileName: fileName, description: string(filespec[PDFName("Desc")]),
          mimeType: mimeType, size: size, creationDate: creationDate,
          modificationDate: modificationDate, checksum: checksum,
          filespecObjectID: filespecID, streamObjectID: stream?.objectID))
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The attachment's bytes exactly as embedded (filters decoded).
  public static func data(
    of attachment: PDFAttachment, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    guard let filespecID = attachment.filespecObjectID,
      case .dictionary(let filespec)? = graph.objects[filespecID]
    else { throw PDFError(.malformed, "The attachment is no longer present") }
    guard let stream = embeddedStream(in: filespec, graph: graph) else {
      throw PDFError(.malformed, "The attachment has no embedded file stream")
    }
    return try PDFFilters.decoded(stream.stream, limits: limits)
  }

  // MARK: - Internals

  struct EmbeddedStream {
    let objectID: PDFObjectID?
    let stream: PDFStream
  }

  static func embeddedStream(
    in filespec: [PDFName: PDFValue], graph: PDFGraph
  ) -> EmbeddedStream? {
    guard case .dictionary(let embedded)? = resolved(filespec[PDFName("EF")], in: graph) else {
      return nil
    }
    for key in ["F", "UF", "Unix", "DOS", "Mac"] {
      guard let value = embedded[PDFName(key)] else { continue }
      if case .reference(let id) = value, case .stream(let stream)? = graph.objects[id] {
        return EmbeddedStream(objectID: id, stream: stream)
      }
      if case .stream(let stream) = value {
        return EmbeddedStream(objectID: nil, stream: stream)
      }
    }
    return nil
  }

  /// Name-tree pairs under the catalog's /EmbeddedFiles entry.
  static func pairs(in graph: PDFGraph) -> [(String, PDFValue)] {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .dictionary(let names)? = resolved(catalog[PDFName("Names")], in: graph),
      let tree = resolved(names[PDFName("EmbeddedFiles")], in: graph)
    else { return [] }
    var pairs: [(String, PDFValue)] = []
    var budget = 10_000
    func walk(_ value: PDFValue, depth: Int) {
      guard depth < 32, budget > 0, case .dictionary(let dictionary) = value else { return }
      if case .array(let numbers)? = dictionary[PDFName("Names")] {
        var index = 0
        while index + 1 < numbers.count, budget > 0 {
          if case .string(let data) = numbers[index] {
            pairs.append((AnnotationText.decode(data), numbers[index + 1]))
            budget -= 1
          }
          index += 2
        }
      }
      if case .array(let kids)? = dictionary[PDFName("Kids")] {
        for kid in kids {
          walk(resolved(kid, in: graph) ?? kid, depth: depth + 1)
        }
      }
    }
    walk(tree, depth: 0)
    return pairs
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    guard let value else { return nil }
    if case .reference(let id) = value { return graph.objects[id] }
    return value
  }

  static func string(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  static func nameString(_ value: PDFValue?) -> String? {
    switch value {
    case .name(let name)?: return String(decoding: name.bytes, as: UTF8.self)
    case .string(let data)?: return AnnotationText.decode(data)
    default: return nil
    }
  }
}

/// P34-018/P34-020/P34-028: extraction to explicitly chosen destinations with
/// sanitized names; traversal-shaped names can never escape the directory.
public enum PDFAttachmentExport {
  /// Strip directory components from either separator style, neutralize
  /// control characters and colons, and never return "." or "..".
  public static func safeFileName(_ raw: String) -> String {
    var name = raw
    let components = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
    if let last = components.last {
      name = String(last)
    } else {
      // A name made only of separators has no usable component.
      name = ""
    }
    // Hidden-file prefixes are stripped; "." and ".." fall through to the
    // default name below.
    while name.hasPrefix(".") { name.removeFirst() }
    var cleaned = ""
    for scalar in name.unicodeScalars {
      if scalar.value < 32 || scalar == ":" {
        cleaned.append("_")
      } else {
        cleaned.unicodeScalars.append(scalar)
      }
    }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
    // P38-017: bound the name to 255 bytes, keeping a short extension.
    if cleaned.utf8.count > 255 {
      let extensionPart = (cleaned as NSString).pathExtension
      let suffix = extensionPart.isEmpty ? "" : "." + extensionPart
      let base = (cleaned as NSString).deletingPathExtension
      let allowed = max(1, 255 - suffix.utf8.count)
      var truncated = ""
      var used = 0
      for character in base {
        let size = String(character).utf8.count
        if used + size > allowed { break }
        truncated.append(character)
        used += size
      }
      cleaned = (truncated.isEmpty ? "attachment" : truncated) + suffix
    }
    return cleaned
  }

  public static func extract(
    _ attachments: [PDFAttachment], from graph: PDFGraph, to directory: URL
  ) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let base = directory.standardizedFileURL
    var used: Set<String> = []
    var urls: [URL] = []
    for attachment in attachments {
      try Task.checkCancellation()
      let data = try PDFAttachmentInventory.data(of: attachment, in: graph)
      var name = safeFileName(attachment.fileName ?? attachment.name)
      if used.contains(name.lowercased()) {
        let pathExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var counter = 1
        while used.contains("\(stem)-\(counter).\(pathExtension)".lowercased()) { counter += 1 }
        name = pathExtension.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(pathExtension)"
      }
      used.insert(name.lowercased())
      let url = base.appendingPathComponent(name)
      // Defense in depth: sanitized names cannot escape, but refuse anyway.
      guard url.standardizedFileURL.path.hasPrefix(base.path + "/") else {
        throw PDFError(.unsupported, "Attachment name escapes the destination directory")
      }
      try data.write(to: url, options: .atomic)
      urls.append(url)
    }
    return urls
  }
}

/// P34-019: add an attachment with safe file specifications.
public struct AddAttachmentCommand: PDFEditCommand, Equatable, Sendable {
  public static let maximumBytes = 64 * 1_024 * 1_024

  public let attachmentName: String
  public let fileName: String
  public let mimeType: String?
  public let description: String?
  public let data: Data

  public init(
    name: String, fileName: String, mimeType: String? = nil, description: String? = nil,
    data: Data
  ) {
    self.attachmentName = name
    self.fileName = fileName
    self.mimeType = mimeType
    self.description = description
    self.data = data
  }

  public var name: String { "Add Attachment" }

  public func validate(in graph: PDFGraph) throws {
    guard !attachmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw PDFError(.malformed, "Attachments need a name and a file name") }
    guard data.count <= Self.maximumBytes else {
      throw PDFError(.limitExceeded, "The attachment exceeds the 64 MiB embedding limit")
    }
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    guard !PDFAttachmentInventory.pairs(in: graph).contains(where: { $0.0 == attachmentName })
    else {
      throw PDFError(.malformed, "An attachment with that name already exists")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }

    let streamID = AttachmentTree.nextObjectID(in: graph)
    var streamDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("EmbeddedFile")),
      PDFName("Params"): .dictionary([PDFName("Size"): .integer(Int64(data.count))]),
    ]
    if let mimeType, !mimeType.isEmpty {
      streamDictionary[PDFName("Subtype")] = .name(PDFName(mimeType))
    }
    graph.objects[streamID] = .stream(
      PDFStream(dictionary: streamDictionary, bytes: data))

    let filespecID = AttachmentTree.nextObjectID(in: graph)
    var filespec: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Filespec")),
      PDFName("F"): .string(AnnotationText.encode(fileName)),
      PDFName("UF"): .string(AnnotationText.encode(fileName)),
      PDFName("EF"): .dictionary([PDFName("F"): .reference(streamID)]),
    ]
    if let mimeType, !mimeType.isEmpty {
      filespec[PDFName("Subtype")] = .name(PDFName(mimeType))
    }
    if let description, !description.isEmpty {
      filespec[PDFName("Desc")] = .string(AnnotationText.encode(description))
    }
    graph.objects[filespecID] = .dictionary(filespec)

    var pairs = PDFAttachmentInventory.pairs(in: graph)
    pairs.append((attachmentName, .reference(filespecID)))
    AttachmentTree.write(pairs: pairs, into: &catalog, graph: &graph)
    graph.objects[catalogID] = .dictionary(catalog)
    return graph
  }
}

/// PAG-09: edit an attachment's /Desc without replacing its bytes or identity.
public struct SetAttachmentDescriptionCommand: PDFEditCommand, Equatable, Sendable {
  public let attachmentName: String
  public let description: String

  public init(name: String, description: String) {
    self.attachmentName = name
    self.description = description
  }

  public var name: String { "Set Attachment Description" }

  public func validate(in graph: PDFGraph) throws {
    guard
      let value = PDFAttachmentInventory.pairs(in: graph).first(where: {
        $0.0 == attachmentName
      })?.1,
      case .reference(let filespecID) = value,
      case .dictionary = graph.objects[filespecID]
    else {
      throw PDFError(.malformed, "No attachment with that name exists")
    }
    guard description.count <= 10_000 else {
      throw PDFError(.limitExceeded, "The attachment description is too long")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard
      let value = PDFAttachmentInventory.pairs(in: graph).first(where: {
        $0.0 == attachmentName
      })?.1,
      case .reference(let filespecID) = value,
      case .dictionary(var filespec)? = graph.objects[filespecID]
    else {
      throw PDFError(.malformed, "No attachment with that name exists")
    }
    let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      filespec[PDFName("Desc")] = nil
    } else {
      filespec[PDFName("Desc")] = .string(AnnotationText.encode(description))
    }
    graph.objects[filespecID] = .dictionary(filespec)
    return graph
  }
}

/// P34-019: remove an attachment and its unreferenced filespec/stream objects.
public struct RemoveAttachmentCommand: PDFEditCommand, Equatable, Sendable {
  public let attachmentName: String

  public init(name: String) {
    self.attachmentName = name
  }

  public var name: String { "Remove Attachment" }

  public func validate(in graph: PDFGraph) throws {
    guard PDFAttachmentInventory.pairs(in: graph).contains(where: { $0.0 == attachmentName })
    else {
      throw PDFError(.malformed, "No attachment with that name exists")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    let pairs = PDFAttachmentInventory.pairs(in: graph)
    let removed = pairs.filter { $0.0 == attachmentName }
    let remaining = pairs.filter { $0.0 != attachmentName }
    AttachmentTree.write(pairs: remaining, into: &catalog, graph: &graph)
    graph.objects[catalogID] = .dictionary(catalog)

    // References from the objects being removed must not keep themselves
    // alive: collect references while skipping the removed filespecs.
    var removedFilespecs: Set<PDFObjectID> = []
    for (_, value) in removed {
      if case .reference(let filespecID) = value { removedFilespecs.insert(filespecID) }
    }
    let referenced = AttachmentTree.references(in: graph, excluding: removedFilespecs)
    for (_, value) in removed {
      guard case .reference(let filespecID) = value,
        case .dictionary(let filespec)? = graph.objects[filespecID]
      else { continue }
      guard !referenced.contains(filespecID) else { continue }
      if case .dictionary(let embedded)? = PDFAttachmentInventory.resolved(
        filespec[PDFName("EF")], in: graph)
      {
        for key in ["F", "UF", "Unix", "DOS", "Mac"] {
          if case .reference(let streamID)? = embedded[PDFName(key)],
            !referenced.contains(streamID)
          {
            graph.objects[streamID] = nil
          }
        }
      }
      graph.objects[filespecID] = nil
    }
    return graph
  }
}

enum AttachmentTree {
  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }

  /// Rebuild the catalog's /EmbeddedFiles name tree as a flat, sorted tree.
  static func write(
    pairs: [(String, PDFValue)], into catalog: inout [PDFName: PDFValue], graph: inout PDFGraph
  ) {
    var names: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = PDFAttachmentInventory.resolved(
      catalog[PDFName("Names")], in: graph)
    {
      names = existing
    }
    if pairs.isEmpty {
      names.removeValue(forKey: PDFName("EmbeddedFiles"))
    } else {
      let sorted = pairs.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
      var numbers: [PDFValue] = []
      for (name, value) in sorted {
        numbers.append(.string(AnnotationText.encode(name)))
        numbers.append(value)
      }
      names[PDFName("EmbeddedFiles")] = .dictionary([PDFName("Names"): .array(numbers)])
    }
    if names.isEmpty {
      catalog.removeValue(forKey: PDFName("Names"))
    } else {
      catalog[PDFName("Names")] = .dictionary(names)
    }
  }

  /// All object IDs referenced anywhere in the graph (bounded), optionally
  /// skipping the objects that are about to be removed.
  static func references(in graph: PDFGraph, excluding: Set<PDFObjectID> = []) -> Set<PDFObjectID> {
    var result: Set<PDFObjectID> = []
    func collect(_ value: PDFValue, depth: Int) {
      guard depth < 32 else { return }
      switch value {
      case .reference(let id): result.insert(id)
      case .array(let values): for item in values { collect(item, depth: depth + 1) }
      case .dictionary(let dictionary):
        for (_, item) in dictionary { collect(item, depth: depth + 1) }
      case .stream(let stream):
        for (_, item) in stream.dictionary { collect(item, depth: depth + 1) }
      default: break
      }
    }
    for (id, value) in graph.objects where !excluding.contains(id) { collect(value, depth: 0) }
    for (_, value) in graph.trailer { collect(value, depth: 0) }
    return result
  }
}
