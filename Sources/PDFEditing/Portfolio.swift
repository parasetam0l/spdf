import Foundation
import PDFCore

/// SPC-01: a portfolio metadata column from the collection schema.
public struct PortfolioColumn: Sendable, Equatable, Codable {
  /// Visible column title.
  public let title: String
  /// Standard collection field subtype (for example S for size, D for
  /// description, F for file name, ModDate, CreationDate) or a custom key.
  public let subtype: String
  public let order: Int

  public init(title: String, subtype: String, order: Int = 0) {
    self.title = title
    self.subtype = subtype
    self.order = order
  }
}

/// SPC-01: one component file in a portfolio. The embedded bytes are held
/// exactly as read or supplied; the declared folder path is a grouping
/// convention over the embedded-file name tree.
public struct PortfolioComponent: Sendable, Equatable, Codable {
  /// Name-tree key; the file name with its declared folder path.
  public let name: String
  public let fileName: String
  public let folderPath: [String]
  public let description: String?
  public let mimeType: String?
  public let createdDate: String?
  public let modifiedDate: String?
  public let data: Data

  public init(
    name: String, fileName: String, folderPath: [String] = [], description: String? = nil,
    mimeType: String? = nil, createdDate: String? = nil, modifiedDate: String? = nil,
    data: Data
  ) {
    self.name = name
    self.fileName = fileName
    self.folderPath = folderPath
    self.description = description
    self.mimeType = mimeType
    self.createdDate = createdDate
    self.modifiedDate = modifiedDate
    self.data = data
  }

  public var fullName: String {
    folderPath.isEmpty ? fileName : (folderPath + [fileName]).joined(separator: "/")
  }

  public var byteCount: Int { data.count }
}

public struct PortfolioInventory: Sendable, Equatable {
  public let hasCollection: Bool
  public let title: String?
  public let columns: [PortfolioColumn]
  public let components: [PortfolioComponent]

  public init(
    hasCollection: Bool, title: String?, columns: [PortfolioColumn],
    components: [PortfolioComponent]
  ) {
    self.hasCollection = hasCollection
    self.title = title
    self.columns = columns
    self.components = components
  }

  public var folderPaths: [[String]] {
    Array(Set(components.filter { !$0.folderPath.isEmpty }.map(\.folderPath)))
      .sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
  }

  public var totalByteCount: Int { components.reduce(0) { $0 + $1.byteCount } }

  public func components(inFolder folder: [String]) -> [PortfolioComponent] {
    components.filter { $0.folderPath == folder }
  }

  /// SPC-01: a read-only browsing report used by the panel and by evidence.
  public func report() -> String {
    var lines = [
      "# PDF portfolio inventory", "",
      PortfolioBoundary.declaredProfile, "",
      "Portfolio collection: \(hasCollection ? "yes" : "no")",
      "Title: \(title ?? "none")",
      "Components: \(components.count); folders: \(folderPaths.count); bytes: \(totalByteCount)",
      "",
      "| Path | File name | Bytes | MIME | Description |",
      "| --- | --- | --- | --- | --- |",
    ]
    for component in components.sorted(by: { $0.fullName < $1.fullName }) {
      let mime = component.mimeType ?? ""
      let description = (component.description ?? "").replacingOccurrences(of: "|", with: " ")
      lines.append(
        "| \(component.folderPath.isEmpty ? "-" : component.folderPath.joined(separator: " / ")) "
          + "| \(component.fileName) | \(component.byteCount) | \(mime) | \(description) |")
    }
    if !columns.isEmpty {
      lines.append("")
      lines.append(
        "Columns: " + columns.map { "\($0.title) (\($0.subtype))" }.joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
  }
}

/// SPC-01: what the portfolio feature can and cannot claim.
public enum PortfolioBoundary {
  public static let declaredProfile =
    "Declared portfolio profile: components are ordinary embedded files in the catalog "
    + "EmbeddedFiles name tree; the catalog Collection dictionary carries the title and "
    + "column schema. Folder grouping is represented by '/' in the embedded file name "
    + "(a declared sPDF convention) and is browsed by sPDF; independent readers list the "
    + "components with their path-like names and are not claimed to render Acrobat-style "
    + "folder rows. Component bytes are never re-encoded."

  public static let editStatement =
    "Compatible portfolio edits preserve every other component's embedded bytes exactly "
    + "and keep component identities (name-tree keys); no page content is touched."

  public static let independentReaderStatement =
    "The written portfolio is a valid PDF package validated by the project parser/reader; "
    + "it was not opened in an external desktop reader in this environment."
}

/// SPC-01: read the portfolio collection and its component bytes.
public enum PortfolioReader {
  public struct Limits: Sendable, Equatable {
    public var maximumComponents: Int
    public var maximumTotalBytes: Int
    public var maximumComponentBytes: Int

    public init(
      maximumComponents: Int = 200, maximumTotalBytes: Int = 256 * 1_024 * 1_024,
      maximumComponentBytes: Int = 64 * 1_024 * 1_024
    ) {
      self.maximumComponents = maximumComponents
      self.maximumTotalBytes = maximumTotalBytes
      self.maximumComponentBytes = maximumComponentBytes
    }
  }

  public static let defaultColumns: [PortfolioColumn] = [
    PortfolioColumn(title: "Name", subtype: "F", order: 0),
    PortfolioColumn(title: "Size", subtype: "S", order: 1),
    PortfolioColumn(title: "Description", subtype: "D", order: 2),
    PortfolioColumn(title: "Modified", subtype: "ModDate", order: 3),
  ]

  public static func read(
    in graph: PDFGraph, limits: Limits = Limits()
  ) throws -> PortfolioInventory {
    let catalog = try catalogDictionary(in: graph)
    let collection = PDFAttachmentInventory.resolved(
      catalog[PDFName("Collection")], in: graph)
    var collectionDictionary: [PDFName: PDFValue] = [:]
    if case .dictionary(let dictionary)? = collection {
      collectionDictionary = dictionary
    }
    var title: String?
    if case .string(let raw)? = collectionDictionary[PDFName("Title")] {
      title = AnnotationText.decode(raw)
    }
    var columns: [PortfolioColumn] = []
    if case .array(let schema)? = collectionDictionary[PDFName("Schema")] {
      for entry in schema {
        guard case .dictionary(let field)? = PDFAttachmentInventory.resolved(entry, in: graph)
        else { continue }
        let fieldTitle = PDFAttachmentInventory.string(field[PDFName("Title")])
          ?? PDFAttachmentInventory.nameString(field[PDFName("Subtype")])
          ?? "Column"
        let subtype = PDFAttachmentInventory.nameString(field[PDFName("Subtype")])
          ?? PDFAttachmentInventory.string(field[PDFName("Name")]) ?? "F"
        var order = 0
        if case .integer(let value)? = field[PDFName("Order")] { order = Int(value) }
        columns.append(PortfolioColumn(title: fieldTitle, subtype: subtype, order: order))
      }
    }
    columns.sort { ($0.order, $0.title) < ($1.order, $1.title) }
    if columns.isEmpty { columns = defaultColumns }

    var components: [PortfolioComponent] = []
    var budget = limits.maximumComponents
    var totalBytes = 0
    for attachment in PDFAttachmentInventory.attachments(in: graph) {
      guard budget > 0 else { break }
      let data = (try? PDFAttachmentInventory.data(of: attachment, in: graph)) ?? Data()
      guard data.count <= limits.maximumComponentBytes else {
        throw PDFError(
          .limitExceeded,
          "The portfolio component \(attachment.name) exceeds the supported size limit")
      }
      totalBytes += data.count
      guard totalBytes <= limits.maximumTotalBytes else {
        throw PDFError(.limitExceeded, "The portfolio exceeds the supported total size limit")
      }
      let pathComponents = attachment.name
        .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      let fileName = attachment.fileName
        ?? pathComponents.last.flatMap { $0.isEmpty ? nil : $0 }
        ?? "component"
      let folderPath = pathComponents.count > 1
        ? Array(pathComponents.dropLast()).filter { !$0.isEmpty } : []
      components.append(
        PortfolioComponent(
          name: attachment.name, fileName: fileName, folderPath: folderPath,
          description: attachment.description, mimeType: attachment.mimeType,
          createdDate: attachment.creationDate, modifiedDate: attachment.modificationDate,
          data: data))
      budget -= 1
    }
    return PortfolioInventory(
      hasCollection: !collectionDictionary.isEmpty, title: title, columns: columns,
      components: components)
  }

  static func catalogDictionary(in graph: PDFGraph) throws -> [PDFName: PDFValue] {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    return catalog
  }
}

/// SPC-01: portfolio authoring and compatible component edits at graph level.
/// The App wraps these graph results in its own command/transaction; no page
/// content is touched and no component bytes are re-encoded.
public enum PortfolioAuthoring {
  public static let maximumComponents = PortfolioReader.Limits().maximumComponents
  public static let maximumComponentBytes = 64 * 1_024 * 1_024
  public static let maximumNameBytes = 1_024

  public static func makeComponent(
    fileName: String, folderPath: [String] = [], data: Data,
    description: String? = nil, mimeType: String? = nil
  ) throws -> PortfolioComponent {
    let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty, cleanName != ".", cleanName != "..",
      !cleanName.contains("/"), !cleanName.contains("\\"),
      cleanName.utf8.count <= maximumNameBytes
    else {
      throw PDFError(.malformed, "A component file name is empty, unsafe or too long")
    }
    for folder in folderPath {
      guard !folder.isEmpty, folder != ".", folder != "..",
        !folder.contains("/"), !folder.contains("\\")
      else {
        throw PDFError(.malformed, "A component folder name is empty or unsafe")
      }
    }
    var totalNameBytes = cleanName.utf8.count
    for folder in folderPath { totalNameBytes += folder.utf8.count + 1 }
    guard totalNameBytes <= maximumNameBytes else {
      throw PDFError(.limitExceeded, "The component path is too long")
    }
    guard data.count <= maximumComponentBytes else {
      throw PDFError(.limitExceeded, "The component exceeds the supported size limit")
    }
    return PortfolioComponent(
      name: (folderPath + [cleanName]).joined(separator: "/"), fileName: cleanName,
      folderPath: folderPath, description: description, mimeType: mimeType, data: data)
  }

  /// Create a new portfolio PDF: one blank page, a collection dictionary with
  /// the declared columns, and every component as an embedded file.
  public static func create(
    components: [PortfolioComponent], title: String? = nil,
    columns: [PortfolioColumn] = PortfolioReader.defaultColumns,
    pageBox: [Double] = [0, 0, 612, 792]
  ) throws -> Data {
    try validateCollection(components)
    var objects: [PDFObjectID: PDFValue] = [:]
    let catalogID = PDFObjectID(1)
    let pagesID = PDFObjectID(2)
    let pageID = PDFObjectID(3)
    let contentsID = PDFObjectID(4)
    objects[catalogID] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(pagesID),
    ])
    objects[pagesID] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(pageID)]),
    ])
    objects[pageID] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(pagesID),
      PDFName("MediaBox"): .array(pageBox.map { .real($0) }),
      PDFName("Resources"): .dictionary([:]),
      PDFName("Contents"): .reference(contentsID),
    ])
    objects[contentsID] = .stream(PDFStream(bytes: Data()))
    var graph = PDFGraph(
      objects: objects,
      trailer: [PDFName("Root"): .reference(catalogID)])
    var catalog = graph.objects[catalogID]?.dictionaryValue ?? [:]
    var pairs: [(String, PDFValue)] = []
    var filespecReferences: [PDFValue] = []
    for component in components {
      let filespecID = try appendComponent(component, graph: &graph)
      pairs.append((component.name, .reference(filespecID)))
      filespecReferences.append(.reference(filespecID))
    }
    AttachmentTree.write(pairs: pairs, into: &catalog, graph: &graph)
    catalog[PDFName("Collection")] = .dictionary(collectionDictionary(title: title, columns: columns))
    catalog[PDFName("AF")] = .array(filespecReferences)
    graph.objects[catalogID] = .dictionary(catalog)
    return try PDFWriter.write(graph)
  }

  /// Add one component to an existing document and keep the collection
  /// metadata consistent. Existing component objects and bytes are untouched.
  public static func add(_ component: PortfolioComponent, to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let catalogID = try catalogID(in: graph)
    guard case .dictionary(var catalog)? = graph.objects[catalogID] else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    let existing = PDFAttachmentInventory.pairs(in: graph)
    guard !existing.contains(where: { $0.0 == component.name }) else {
      throw PDFError(.malformed, "A component with that path already exists")
    }
    guard existing.count < maximumComponents else {
      throw PDFError(.limitExceeded, "The portfolio exceeds the component-count limit")
    }
    let existingBytes = PDFAttachmentInventory.attachments(in: graph)
      .reduce(0) { $0 + ($1.size ?? 0) }
    guard existingBytes + component.data.count <= PortfolioReader.Limits().maximumTotalBytes else {
      throw PDFError(.limitExceeded, "The portfolio exceeds the supported total size limit")
    }
    let filespecID = try appendComponent(component, graph: &graph)
    var pairs = existing
    pairs.append((component.name, .reference(filespecID)))
    AttachmentTree.write(pairs: pairs, into: &catalog, graph: &graph)
    if case .dictionary? = PDFAttachmentInventory.resolved(
      catalog[PDFName("Collection")], in: graph)
    {} else {
      catalog[PDFName("Collection")] = .dictionary(
        collectionDictionary(title: nil, columns: PortfolioReader.defaultColumns))
    }
    var filespecs: [PDFValue] = []
    if case .array(let values)? = catalog[PDFName("AF")] { filespecs = values }
    filespecs.append(.reference(filespecID))
    catalog[PDFName("AF")] = .array(filespecs)
    graph.objects[catalogID] = .dictionary(catalog)
    return graph
  }

  /// Remove one component and its now-unreferenced filespec/stream objects.
  public static func removeComponent(named name: String, from graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let catalogID = try catalogID(in: graph)
    guard case .dictionary(var catalog)? = graph.objects[catalogID] else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    let pairs = PDFAttachmentInventory.pairs(in: graph)
    let removed = pairs.filter { $0.0 == name }
    guard !removed.isEmpty else {
      throw PDFError(.malformed, "No portfolio component with that path exists")
    }
    let remaining = pairs.filter { $0.0 != name }
    AttachmentTree.write(pairs: remaining, into: &catalog, graph: &graph)
    var filespecIDs = Set<PDFObjectID>()
    for (_, value) in removed {
      if case .reference(let filespecID) = value { filespecIDs.insert(filespecID) }
    }
    if case .array(let values)? = catalog[PDFName("AF")] {
      catalog[PDFName("AF")] = .array(
        values.filter { value in
          if case .reference(let id) = value { return !filespecIDs.contains(id) }
          return true
        })
    }
    graph.objects[catalogID] = .dictionary(catalog)
    let referenced = AttachmentTree.references(in: graph, excluding: filespecIDs)
    for filespecID in filespecIDs {
      guard case .dictionary(let filespec)? = graph.objects[filespecID] else { continue }
      if let streamID = embeddedStreamID(in: filespec, graph: graph),
        !referenced.contains(streamID)
      {
        graph.objects[streamID] = nil
      }
      if !referenced.contains(filespecID) { graph.objects[filespecID] = nil }
    }
    return graph
  }

  /// Replace one component's bytes while keeping its identity and every other
  /// component's embedded bytes exactly as they were.
  public static func replaceBytes(
    named name: String, with data: Data, in graph: PDFGraph
  ) throws -> PDFGraph {
    guard data.count <= maximumComponentBytes else {
      throw PDFError(.limitExceeded, "The component exceeds the supported size limit")
    }
    var graph = graph
    let catalogID = try catalogID(in: graph)
    guard case .dictionary? = graph.objects[catalogID] else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    guard
      let value = PDFAttachmentInventory.pairs(in: graph).first(where: { $0.0 == name })?.1,
      case .reference(let filespecID) = value,
      case .dictionary(var filespec)? = graph.objects[filespecID]
    else {
      throw PDFError(.malformed, "No portfolio component with that path exists")
    }
    let streamID = AttachmentTree.nextObjectID(in: graph)
    var streamDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("EmbeddedFile")),
      PDFName("Params"): .dictionary([PDFName("Size"): .integer(Int64(data.count))]),
    ]
    if let mimeType = PDFAttachmentInventory.nameString(filespec[PDFName("Subtype")]),
      !mimeType.isEmpty
    {
      streamDictionary[PDFName("Subtype")] = .name(PDFName(mimeType))
    }
    graph.objects[streamID] = .stream(PDFStream(dictionary: streamDictionary, bytes: data))
    filespec[PDFName("EF")] = .dictionary([PDFName("F"): .reference(streamID)])
    graph.objects[filespecID] = .dictionary(filespec)
    return graph
  }

  // MARK: - Internals

  static func catalogID(in graph: PDFGraph) throws -> PDFObjectID {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    return catalogID
  }

  static func validateCollection(_ components: [PortfolioComponent]) throws {
    guard components.count <= maximumComponents else {
      throw PDFError(.limitExceeded, "The portfolio exceeds the component-count limit")
    }
    var names = Set<String>()
    var totalBytes = 0
    for component in components {
      if !component.folderPath.isEmpty || component.fullName != component.fileName {
        _ = try makeComponent(
          fileName: component.fileName, folderPath: component.folderPath, data: component.data,
          description: component.description, mimeType: component.mimeType)
      }
      guard names.insert(component.fullName).inserted else {
        throw PDFError(.malformed, "Two components use the same path: \(component.fullName)")
      }
      totalBytes += component.data.count
      guard component.data.count <= maximumComponentBytes else {
        throw PDFError(.limitExceeded, "A component exceeds the supported size limit")
      }
    }
    guard totalBytes <= PortfolioReader.Limits().maximumTotalBytes else {
      throw PDFError(.limitExceeded, "The portfolio exceeds the supported total size limit")
    }
  }

  static func appendComponent(
    _ component: PortfolioComponent, graph: inout PDFGraph
  ) throws -> PDFObjectID {
    let streamID = AttachmentTree.nextObjectID(in: graph)
    var streamDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("EmbeddedFile")),
      PDFName("Params"): .dictionary([
        PDFName("Size"): .integer(Int64(component.data.count))
      ]),
    ]
    if let mimeType = component.mimeType, !mimeType.isEmpty {
      streamDictionary[PDFName("Subtype")] = .name(PDFName(mimeType))
    }
    graph.objects[streamID] = .stream(
      PDFStream(dictionary: streamDictionary, bytes: component.data))
    let filespecID = AttachmentTree.nextObjectID(in: graph)
    var filespec: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Filespec")),
      PDFName("F"): .string(AnnotationText.encode(component.fileName)),
      PDFName("UF"): .string(AnnotationText.encode(component.fileName)),
      PDFName("EF"): .dictionary([PDFName("F"): .reference(streamID)]),
      PDFName("AFRelationship"): .name(PDFName("Supplement")),
    ]
    if let description = component.description, !description.isEmpty {
      filespec[PDFName("Desc")] = .string(AnnotationText.encode(description))
    }
    if let mimeType = component.mimeType, !mimeType.isEmpty {
      filespec[PDFName("Subtype")] = .name(PDFName(mimeType))
    }
    graph.objects[filespecID] = .dictionary(filespec)
    return filespecID
  }

  static func embeddedStreamID(
    in filespec: [PDFName: PDFValue], graph: PDFGraph
  ) -> PDFObjectID? {
    guard case .dictionary(let embedded)? = PDFAttachmentInventory.resolved(
      filespec[PDFName("EF")], in: graph)
    else { return nil }
    for key in ["F", "UF", "Unix", "DOS", "Mac"] {
      if case .reference(let id)? = embedded[PDFName(key)] { return id }
    }
    return nil
  }

  static func collectionDictionary(
    title: String?, columns: [PortfolioColumn]
  ) -> [PDFName: PDFValue] {
    var dictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .dictionary([PDFName("S"): .name(PDFName("Collection"))]),
      PDFName("View"): .name(PDFName("D")),
      PDFName("Schema"): .array(
        columns.map { column in
          .dictionary([
            PDFName("Type"): .name(PDFName("CollectionField")),
            PDFName("Subtype"): .name(PDFName(column.subtype)),
            PDFName("Title"): .string(AnnotationText.encode(column.title)),
            PDFName("Order"): .integer(Int64(column.order)),
          ])
        }),
    ]
    if let title, !title.isEmpty {
      dictionary[PDFName("Title")] = .string(AnnotationText.encode(title))
    }
    return dictionary
  }
}

extension PDFValue {
  fileprivate var dictionaryValue: [PDFName: PDFValue]? {
    if case .dictionary(let dictionary) = self { return dictionary }
    return nil
  }
}
