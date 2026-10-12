import Foundation
import PDFCore

/// P18-017: text inside a reusable form (Form XObject) with local
/// copy-on-write. A form's stream is parsed exactly like page content, its
/// fonts resolve against the form's own resources (falling back to the
/// page's, recorded), and an edit first privatizes a shared form so other
/// pages keep the original bytes. Only the top form level is indexed;
/// nested forms keep their bytes untouched and their text is out of scope.
enum FormTextContent {
  /// One form use: the page that draws it plus the XObject resource name.
  struct Scope: Sendable, Equatable {
    let resource: PDFName
  }

  struct Loaded {
    let content: PageContent
    let runs: [TextRun]
    /// The form object the runs index into (pre-COW identity).
    let formID: PDFObjectID
    /// Effective font resources (the form's own, or the page's fallback).
    let resources: [PDFName: PDFValue]
    /// True when the form carries no /Resources of its own.
    let usedPageFallback: Bool
  }

  /// Read this page's /Resources/XObject dictionary (direct or referenced).
  static func xobjectEntries(
    of owner: PDFObjectID, in graph: PDFGraph
  ) throws -> [PDFName: PDFValue] {
    guard case .dictionary(let ownerDict)? = graph.objects[owner] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let resources: [PDFName: PDFValue]?
    switch ownerDict[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      resources = dictionary
    case .reference(let id)?:
      guard case .dictionary(let dictionary)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      resources = dictionary
    default:
      resources = nil
    }
    guard let resources else { return [:] }
    switch resources[PDFName("XObject")] {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      guard case .dictionary(let dictionary)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page resources are malformed")
      }
      return dictionary
    default:
      return [:]
    }
  }

  static func load(
    pageID: PDFObjectID, resource: PDFName, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> Loaded {
    let entries = try xobjectEntries(of: pageID, in: graph)
    guard case .reference(let formID)? = entries[resource] else {
      throw PDFError(
        .unsupported, "This page has no reusable form under that resource name")
    }
    guard case .stream(let stream)? = graph.objects[formID] else {
      throw PDFError(.malformed, "The reusable form object is missing")
    }
    guard stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form")) else {
      throw PDFError(.unsupported, "The named resource is not a reusable form")
    }
    let formDict = stream.dictionary
    let decoded = [UInt8](try PDFFilters.decoded(stream, limits: limits))
    let filters = try PDFFilters.filterNames(in: stream.dictionary)
    guard filters.isEmpty || filters == [PDFName("FlateDecode")] else {
      throw PDFError(
        .unsupported, "This form uses filters that cannot be edited")
    }
    // Effective font resources: the form's own /Resources win; a form
    // without any falls back to the page's, recorded for the caller.
    var usedPageFallback = false
    let resources: [PDFName: PDFValue]
    switch formDict[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      resources = dictionary
    case .reference(let id)?:
      guard case .dictionary(let dictionary)? = graph.objects[id] else {
        throw PDFError(.malformed, "The form resources are missing")
      }
      resources = dictionary
    default:
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .dictionary(let pageResources)? = page[PDFName("Resources")]
      else {
        throw PDFError(.malformed, "Page is missing")
      }
      resources = pageResources
      usedPageFallback = true
    }
    let segment = PageContentSegment(
      objectID: formID, dictionary: stream.dictionary, decoded: decoded,
      filters: filters, range: 0..<decoded.count)
    let instructions = try ContentParser.instructions(in: decoded, limits: limits)
    let content = PageContent(
      pageID: pageID, segments: [segment], bytes: decoded,
      instructions: instructions)
    let runs = try TextRunIndexer.runs(
      in: content, graph: graph, limits: limits, resources: resources)
    return Loaded(
      content: content, runs: runs, formID: formID, resources: resources,
      usedPageFallback: usedPageFallback)
  }
}

/// P18-017: copy-on-write for reusable forms. A form stream referenced from
/// anywhere besides this page's named entry is copied and only that entry
/// is repointed, so editing one page's form text never changes another
/// page (or another form that nests the same form). Returns the graph and
/// the form object the caller must now address.
extension PageContentCopy {
  static func makeFormPrivate(
    pageID: PDFObjectID, resource: PDFName, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, formID: PDFObjectID) {
    let entries = try FormTextContent.xobjectEntries(of: pageID, in: graph)
    guard case .reference(let formID)? = entries[resource] else {
      throw PDFError(
        .unsupported, "This page has no reusable form under that resource name")
    }
    _ = limits
    // Every (owner, name) pair that addresses this form: all page XObject
    // entries plus every form's nested XObject entries.
    var users: [(owner: PDFObjectID, name: PDFName)] = []
    let pages = try PDFPageTree.pageIDs(in: graph)
    for owner in pages {
      let owned = (try? FormTextContent.xobjectEntries(of: owner, in: graph)) ?? [:]
      for (name, value) in owned where value == .reference(formID) {
        users.append((owner, name))
      }
    }
    for (id, value) in graph.objects {
      guard case .dictionary(let form) = value,
        form[PDFName("Subtype")] == .name(PDFName("Form"))
      else { continue }
      let nested = (try? FormTextContent.xobjectEntries(of: id, in: graph)) ?? [:]
      for (name, entryValue) in nested where entryValue == .reference(formID) {
        users.append((id, name))
      }
    }
    let isOurs = { (user: (owner: PDFObjectID, name: PDFName)) in
      user.owner == pageID && user.name == resource
    }
    guard users.count != 1 || !isOurs(users[0]) else { return (graph, formID) }
    // Shared: copy the stream, then repoint only this page's entry. The
    // resource dictionaries on the path are copied first when shared, so
    // the repoint never leaks into another page or form.
    guard case .stream(let stream)? = graph.objects[formID] else {
      throw PDFError(.malformed, "The reusable form object is missing")
    }
    var graph = graph
    let copy = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[copy] = .stream(stream)
    try repointXObjectEntry(
      owner: pageID, name: resource, to: copy, in: &graph)
    return (graph, copy)
  }

  /// Set one owner's XObject entry, copying shared /Resources or /XObject
  /// dictionaries on the path so no other owner observes the change.
  private static func repointXObjectEntry(
    owner: PDFObjectID, name: PDFName, to target: PDFObjectID,
    in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var ownerDict)? = graph.objects[owner] else {
      throw PDFError(.malformed, "Page is missing")
    }
    // Resolve the /Resources dictionary to a privately owned object.
    let resourcesID: PDFObjectID?
    switch ownerDict[PDFName("Resources")] {
    case .dictionary:
      resourcesID = nil
    case .reference(let id)?:
      resourcesID = id
    default:
      throw PDFError(.malformed, "Page resources are malformed")
    }
    if let resourcesID {
      if isDictionaryShared(object: resourcesID, in: graph, except: owner) {
        let copy = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
        guard case .dictionary(let resources)? = graph.objects[resourcesID] else {
          throw PDFError(.malformed, "Page resources are missing")
        }
        graph.objects[copy] = .dictionary(resources)
        ownerDict[PDFName("Resources")] = .reference(copy)
        graph.objects[owner] = .dictionary(ownerDict)
      }
    }
    var resources: [PDFName: PDFValue]
    switch ownerDict[PDFName("Resources")] {
    case .dictionary(let dictionary)?:
      resources = dictionary
    case .reference(let id)?:
      guard case .dictionary(let dictionary)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      resources = dictionary
    default:
      throw PDFError(.malformed, "Page resources are malformed")
    }
    // Same treatment for the /XObject subdictionary.
    switch resources[PDFName("XObject")] {
    case .dictionary(var xobjects)?:
      xobjects[name] = .reference(target)
      resources[PDFName("XObject")] = .dictionary(xobjects)
      ownerDict[PDFName("Resources")] = .dictionary(resources)
      graph.objects[owner] = .dictionary(ownerDict)
    case .reference(let id)?:
      if isDictionaryShared(object: id, in: graph, except: owner) {
        let copy = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
        guard case .dictionary(var xobjects)? = graph.objects[id] else {
          throw PDFError(.malformed, "Page resources are malformed")
        }
        xobjects[name] = .reference(target)
        graph.objects[copy] = .dictionary(xobjects)
        resources[PDFName("XObject")] = .reference(copy)
        ownerDict[PDFName("Resources")] = .dictionary(resources)
        graph.objects[owner] = .dictionary(ownerDict)
      } else {
        guard case .dictionary(var xobjects)? = graph.objects[id] else {
          throw PDFError(.malformed, "Page resources are malformed")
        }
        xobjects[name] = .reference(target)
        graph.objects[id] = .dictionary(xobjects)
      }
    default:
      throw PDFError(.malformed, "Page resources are malformed")
    }
  }

  /// Whether any object besides `owner`'s own /Resources chain addresses
  /// this dictionary object.
  private static func isDictionaryShared(
    object id: PDFObjectID, in graph: PDFGraph, except owner: PDFObjectID
  ) -> Bool {
    for (objectID, value) in graph.objects {
      guard objectID != owner, objectID != id,
        case .dictionary(let dictionary) = value
      else { continue }
      if dictionary.values.contains(.reference(id)) { return true }
      if case .dictionary(let resources)? = dictionary[PDFName("Resources")] {
        if resources.values.contains(.reference(id)) { return true }
      }
      if case .reference(let resourcesID)? = dictionary[PDFName("Resources")],
        resourcesID == id
      {
        return true
      }
    }
    return false
  }
}
