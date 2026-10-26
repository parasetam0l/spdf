import Foundation
import PDFCore
import PDFEditing
import PDFFixtures

/// SPC-06/SPC-07 fixtures: scripted actions across every inventoried owner and
/// static/dynamic XFA attachments with and without AcroForm fallback fields.
enum CompatibilityFixtures {
  enum XFAShape {
    case staticXFA
    case dynamicXFA
  }

  static func pageIDs(of graph: PDFGraph) throws -> [PDFObjectID] {
    try PDFParser.parse(try PDFWriter.write(graph)).pageIDs
  }

  static func jsAction(_ source: String) -> PDFValue {
    .dictionary([
      PDFName("S"): .name(PDFName("JavaScript")),
      PDFName("JS"): .string(Data(source.utf8)),
    ])
  }

  static func uriAction(_ target: String) -> PDFValue {
    .dictionary([
      PDFName("S"): .name(PDFName("URI")),
      PDFName("URI"): .string(Data(target.utf8)),
    ])
  }

  static func catalog(
    of graph: PDFGraph
  ) throws -> (rootID: PDFObjectID, catalog: [PDFName: PDFValue]) {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { throw PDFError(.malformed, "Fixture catalog is missing") }
    return (rootID, catalog)
  }

  /// A document with document, page, annotation and field JavaScript actions,
  /// a document-wide function and a scripted calculation order, plus one URI
  /// annotation action that must survive neutralization.
  static func scriptedDocument() throws -> PDFGraph {
    var graph = PDFFixtures.graph(pages: 2)
    let pageIDs = try self.pageIDs(of: graph)
    var (rootID, catalogValue) = try catalog(of: graph)
    catalogValue[PDFName("OpenAction")] = jsAction(
      "app.launchURL('https://example.invalid');")
    catalogValue[PDFName("AA")] = .dictionary([
      PDFName("WS"): jsAction("app.alert('saving');")
    ])
    catalogValue[PDFName("Names")] = .dictionary([
      PDFName("JavaScript"): .dictionary([
        PDFName("Names"): .array([
          .string(Data("init".utf8)),
          jsAction("this.importDataObject('attachment.txt');"),
        ])
      ])
    ])
    graph.objects[rootID] = .dictionary(catalogValue)

    if case .dictionary(var page)? = graph.objects[pageIDs[0]] {
      page[PDFName("AA")] = .dictionary([
        PDFName("O"): jsAction("app.alert('page');")
      ])
      graph.objects[pageIDs[0]] = .dictionary(page)
    }

    graph = try AddNoteCommand(
      pageID: pageIDs[0], at: [72, 700], contents: "scripted note").apply(to: graph)
    graph = try AddNoteCommand(
      pageID: pageIDs[0], at: [110, 700], contents: "safe link note").apply(to: graph)
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageIDs[0])
    for annotation in annotations {
      guard let objectID = annotation.objectID,
        case .dictionary(var dictionary)? = graph.objects[objectID]
      else { continue }
      if annotation.index == 0 {
        dictionary[PDFName("A")] = jsAction("app.launchURL('https://x.invalid');")
      } else {
        dictionary[PDFName("A")] = uriAction("https://example.invalid")
      }
      graph.objects[objectID] = .dictionary(dictionary)
    }

    graph = try AddTextFieldCommand(
      pageID: pageIDs[0], rect: [72, 560, 340, 584], name: "Total",
      defaultValue: "0").apply(to: graph)
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let total = fields.first(where: { $0.name == "Total" }),
      let fieldID = total.fieldID,
      case .dictionary(var fieldDictionary)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Fixture form field is missing") }
    fieldDictionary[PDFName("AA")] = .dictionary([
      PDFName("C"): jsAction("this.getField('Total').value = 1;")
    ])
    graph.objects[fieldID] = .dictionary(fieldDictionary)
    try attachCalculationOrder(fieldID, to: &graph)
    return graph
  }

  static func attachCalculationOrder(
    _ fieldID: PDFObjectID, to graph: inout PDFGraph
  ) throws {
    var (rootID, catalogValue) = try catalog(of: graph)
    switch catalogValue[PDFName("AcroForm")] {
    case .dictionary(var acro):
      acro[PDFName("CO")] = .array([.reference(fieldID)])
      catalogValue[PDFName("AcroForm")] = .dictionary(acro)
    case .reference(let acroID)?:
      guard case .dictionary(var acro)? = graph.objects[acroID] else { return }
      acro[PDFName("CO")] = .array([.reference(fieldID)])
      graph.objects[acroID] = .dictionary(acro)
      return
    default:
      return
    }
    graph.objects[rootID] = .dictionary(catalogValue)
  }

  static func documentWithOpenActionScript() throws -> PDFGraph {
    var graph = PDFFixtures.graph(pages: 1)
    var (rootID, catalogValue) = try catalog(of: graph)
    catalogValue[PDFName("OpenAction")] = jsAction("app.alert('open');")
    graph.objects[rootID] = .dictionary(catalogValue)
    return graph
  }

  /// Attach an XFA value and optional fallback text field.
  static func indirectStream(
    _ bytes: Data, in graph: inout PDFGraph
  ) -> PDFValue {
    let id = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[id] = .stream(PDFStream(bytes: bytes))
    return .reference(id)
  }

  static func xfaDocument(
    _ shape: XFAShape, fallbackField: Bool
  ) throws -> PDFGraph {
    var graph = PDFFixtures.graph(pages: 1)
    let pageIDs = try self.pageIDs(of: graph)
    if fallbackField {
      graph = try AddTextFieldCommand(
        pageID: pageIDs[0], rect: [72, 560, 340, 584], name: "Name",
        defaultValue: "Ada").apply(to: graph)
    }
    let xfaValue: PDFValue
    let needsRendering: Bool
    switch shape {
    case .staticXFA:
      xfaValue = Self.indirectStream(
        Data(
          "<xdp:xdp xmlns:xdp='http://ns.adobe.com/xdp/'><template/></xdp:xdp>"
            .utf8), in: &graph)
      needsRendering = false
    case .dynamicXFA:
      let template = Self.indirectStream(Data("<template/>".utf8), in: &graph)
      let datasets = Self.indirectStream(Data("<datasets/>".utf8), in: &graph)
      xfaValue = .array([
        .string(Data("template".utf8)), template,
        .string(Data("datasets".utf8)), datasets,
      ])
      needsRendering = true
    }
    var (rootID, catalogValue) = try catalog(of: graph)
    switch catalogValue[PDFName("AcroForm")] {
    case .dictionary(var acro):
      acro[PDFName("XFA")] = xfaValue
      if needsRendering { acro[PDFName("NeedsRendering")] = .boolean(true) }
      catalogValue[PDFName("AcroForm")] = .dictionary(acro)
    case .reference(let acroID)?:
      guard case .dictionary(var acro)? = graph.objects[acroID] else { return graph }
      acro[PDFName("XFA")] = xfaValue
      if needsRendering { acro[PDFName("NeedsRendering")] = .boolean(true) }
      graph.objects[acroID] = .dictionary(acro)
      return graph
    default:
      var acro: [PDFName: PDFValue] = [
        PDFName("Fields"): .array([]),
        PDFName("XFA"): xfaValue,
      ]
      if needsRendering { acro[PDFName("NeedsRendering")] = .boolean(true) }
      catalogValue[PDFName("AcroForm")] = .dictionary(acro)
    }
    graph.objects[rootID] = .dictionary(catalogValue)
    return graph
  }

  /// An XFA value with an unsupported representation (a number), which the
  /// profile must disclose as unknown rather than claim to render.
  static func xfaWithUnclassifiedValue() throws -> PDFGraph {
    var graph = PDFFixtures.graph(pages: 1)
    var (rootID, catalogValue) = try catalog(of: graph)
    catalogValue[PDFName("AcroForm")] = .dictionary([
      PDFName("Fields"): .array([]),
      PDFName("XFA"): .integer(7),
    ])
    graph.objects[rootID] = .dictionary(catalogValue)
    return graph
  }
}
