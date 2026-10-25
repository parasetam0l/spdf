import Foundation
import PDFCore

// MARK: - PAG-04 Replace Pages

/// PAG-04: which destination-page data survives when pages are replaced. The
/// matrix is explicit because Acrobat-style replacement is not a merge: the
/// selected destination pages and everything attached to them disappear, while
/// the rest of the destination document (fields on retained pages, labels,
/// catalog data) is expected to keep working.
public struct ReplacePagesOptions: Sendable, Equatable {
  public enum FormFieldConflictPolicy: String, Sendable, CaseIterable {
    case rename
    case refuse

    public var title: String {
      self == .rename ? "Rename imported colliding fields" : "Refuse colliding fields"
    }
  }

  public enum PageLabelPolicy: String, Sendable, CaseIterable {
    case retainDestination
    case reset

    public var title: String {
      self == .retainDestination
        ? "Retain the destination page labels"
        : "Reset page labels to physical numbers"
    }
  }

  public enum StructureTreePolicy: String, Sendable, CaseIterable {
    case dropDestination
    case refuseWhenPresent

    public var title: String {
      self == .dropDestination
        ? "Drop the destination structure tree (reported)"
        : "Refuse documents that carry a structure tree"
    }
  }

  public var formFieldConflicts: FormFieldConflictPolicy
  public var pageLabels: PageLabelPolicy
  public var structureTree: StructureTreePolicy

  public init(
    formFieldConflicts: FormFieldConflictPolicy = .rename,
    pageLabels: PageLabelPolicy = .retainDestination,
    structureTree: StructureTreePolicy = .dropDestination
  ) {
    self.formFieldConflicts = formFieldConflicts
    self.pageLabels = pageLabels
    self.structureTree = structureTree
  }
}

/// PAG-04 preview/report: the retention matrix result and the exact counts the
/// review panel shows before applying.
public struct ReplacePagesReport: Sendable, Equatable {
  public var destinationPagesReplaced = 0
  public var replacementPagesInserted = 0
  public var destinationAnnotationsDropped = 0
  public var sourceAnnotationsImported = 0
  public var destinationLinksDropped = 0
  public var sourceLinksImported = 0
  public var destinationFormFieldsRemoved: [String] = []
  public var sourceFormFieldsImported: [String] = []
  public var renamedFields: [String] = []
  public var destinationPageLabelsRetained = false
  public var structureTreeDropped = false
  public var notes: [String] = []

  public init() {}

  public var matrixLines: [String] {
    var lines: [String] = []
    lines.append(
      "Destination pages replaced: \(destinationPagesReplaced); replacement pages inserted: \(replacementPagesInserted).")
    lines.append(
      "Destination annotations on replaced pages: dropped (\(destinationAnnotationsDropped)).")
    lines.append(
      "Source annotations on replacement pages: imported (\(sourceAnnotationsImported)).")
    lines.append(
      "Links: destination links to replaced pages dropped (\(destinationLinksDropped)); "
        + "source links among replacement pages imported (\(sourceLinksImported)).")
    lines.append(
      "Destination form fields removed: "
        + (destinationFormFieldsRemoved.isEmpty
          ? "none" : destinationFormFieldsRemoved.joined(separator: ", ")))
    lines.append(
      "Source form fields imported: "
        + (sourceFormFieldsImported.isEmpty
          ? "none" : sourceFormFieldsImported.joined(separator: ", ")))
    if !renamedFields.isEmpty {
      lines.append("Renamed fields: " + renamedFields.joined(separator: ", "))
    }
    lines.append(
      "Page labels: "
        + (destinationPageLabelsRetained
          ? "destination label ranges retained (positional; page count may differ)"
          : "reset to physical page numbers"))
    lines.append(
      "Structure tree: "
        + (structureTreeDropped ? "destination structure tree dropped" : "not present / kept"))
    for note in notes { lines.append("Note: " + note) }
    return lines
  }

  public var report: String { matrixLines.joined(separator: "\n") }
}

/// PAG-04: replace selected destination pages with pages from another PDF as
/// one undoable command. Destination annotations, links and field widgets on
/// the replaced pages are dropped; annotations, links and widgets on the
/// replacement pages are imported; fields on retained destination pages stay
/// available through a rebuilt AcroForm; incoming references to removed pages
/// are removed or remapped by the assembly remapper so nothing dangles.
public struct ReplacePagesCommand: PDFEditCommand, Equatable, Sendable {
  public let sourceDocumentBytes: Data
  /// Destination pages to replace, in any order (document order is used).
  public let destinationPageIDs: [PDFObjectID]
  /// Zero-based source-document page indices used as replacements, in order.
  public let sourcePageIndices: [Int]
  public let options: ReplacePagesOptions

  public init(
    sourceDocumentBytes: Data, destinationPageIDs: [PDFObjectID],
    sourcePageIndices: [Int], options: ReplacePagesOptions = ReplacePagesOptions()
  ) {
    self.sourceDocumentBytes = sourceDocumentBytes
    self.destinationPageIDs = destinationPageIDs
    self.sourcePageIndices = sourcePageIndices
    self.options = options
  }

  /// New page identities make the precise affected page set unknown.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }
  public var name: String { "Replace Pages" }

  public func validate(in graph: PDFGraph) throws {
    let preview = try preflight(in: graph)
    try preview.graph.validate(limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try preflight(in: graph).graph
  }

  /// Non-mutating preview used by the replace-pages panel: parses and stages
  /// the replacement and returns the retention-matrix report.
  public func preflight(
    in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: ReplacePagesReport) {
    var report = ReplacePagesReport()
    guard !destinationPageIDs.isEmpty else {
      throw PDFError(.malformed, "Select at least one destination page to replace")
    }
    guard !sourcePageIndices.isEmpty else {
      throw PDFError(.malformed, "Select at least one replacement page")
    }
    guard Set(destinationPageIDs).count == destinationPageIDs.count else {
      throw PDFError(.malformed, "The replacement selection repeats a destination page")
    }
    guard Set(sourcePageIndices).count == sourcePageIndices.count else {
      throw PDFError(.malformed, "The replacement selection repeats a source page")
    }
    if graph.trailer[PDFName("Encrypt")] != nil {
      throw PDFError(.unsupported, "Unlock the destination document before replacing pages")
    }
    let parsed: ParsedPDF
    do {
      parsed = try PDFParser.parse(sourceDocumentBytes, limits: limits)
    } catch let error as PDFError {
      throw error
    }
    if parsed.graph.trailer[PDFName("Encrypt")] != nil {
      throw PDFError(.unsupported, "Encrypted documents cannot be replacement sources")
    }
    let sourceSignatures = (try? PDFSignatureInventory.signatures(in: parsed.graph)) ?? []
    guard sourceSignatures.isEmpty else {
      throw PDFError(
        .unsupported, "Signed documents cannot be replacement sources without invalidating signatures")
    }
    let destinationSignatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    guard destinationSignatures.isEmpty else {
      throw PDFError(
        .unsupported, "Replace Pages is refused while the destination carries signatures; the signatures would be invalidated")
    }

    let destinationPages = try PDFPageTree.pageIDs(in: graph)
    var destinationIndices: [Int] = []
    for pageID in destinationPageIDs {
      guard let index = destinationPages.firstIndex(of: pageID) else {
        throw PDFError(.malformed, "A destination replace target is not a page")
      }
      destinationIndices.append(index)
    }
    destinationIndices.sort()
    let removed = Set(destinationIndices)
    let sourcePages = try PDFPageTree.pageIDs(in: parsed.graph)
    var selectedSourcePages: [PDFObjectID] = []
    for index in sourcePageIndices {
      guard index >= 0, index < sourcePages.count else {
        throw PDFError(.malformed, "A replacement page index is outside the source document")
      }
      selectedSourcePages.append(sourcePages[index])
    }

    // XFA is never authored; replacing pages would corrupt it.
    if let acroForm = Self.acroFormDictionary(in: graph),
      acroForm[PDFName("XFA")] != nil
    {
      throw PDFError(
        .unsupported, "Replace Pages cannot preserve XFA form data; remove/replace XFA outside this profile")
    }
    let destinationAcroForm = Self.acroFormDictionary(in: graph)
    var baseAcroFormScalars: [PDFName: PDFValue] = [:]
    for key in ["DA", "Q", "NeedAppearances"] {
      if let value = destinationAcroForm?[PDFName(key)] { baseAcroFormScalars[PDFName(key)] = value }
    }
    let structurePresent = Self.catalog(in: graph)?.dictionary[PDFName("StructTreeRoot")] != nil
    if structurePresent, options.structureTree == .refuseWhenPresent {
      throw PDFError(
        .unsupported,
        "This document carries a structure tree; use the drop-structure replacement profile or remove tagging first")
    }

    // Retention matrix inputs from the destination before replacement.
    let removedPageSet = Set(destinationIndices.map { destinationPages[$0] })
    var destinationAnnotationCount = 0
    var destinationLinkCount = 0
    var removedWidgetCount = 0
    for pageIndex in destinationIndices {
      let annotations = (try? AnnotationInventory.annotations(
        in: graph, pageID: destinationPages[pageIndex])) ?? []
      for annotation in annotations {
        if annotation.subtype == PDFName("Link") { destinationLinkCount += 1 }
        if Self.isWidget(annotation.dictionary) {
          removedWidgetCount += 1
        } else {
          destinationAnnotationCount += 1
        }
      }
    }
    let destinationFieldsBefore = (try? FormInventory.fields(
      in: graph, pageIDs: destinationPages)) ?? []
    var removedFieldNames: [String] = []
    for field in destinationFieldsBefore {
      let indexes = Set(field.widgets.compactMap(\.pageIndex))
      if !indexes.isEmpty, indexes.isSubset(of: removed) {
        removedFieldNames.append(field.name)
      }
    }
    let destinationLabels = PDFPageLabels.ranges(in: graph)
    let retainedBeforeLinkCount = Self.linkCount(
      graph: graph, pageIDs: destinationPages.enumerated()
        .filter { !removed.contains($0.offset) }.map(\.element))

    // Extract the replacement pages into a self-contained assembly source.
    let extracted = try DocumentAssembly.extract(
      parsed.graph, pageIDs: selectedSourcePages, labels: .reset,
      catalogData: .firstDocument, limits: limits)
    let extractedPages = try PDFPageTree.pageIDs(in: extracted.graph)
    guard extractedPages.count == selectedSourcePages.count else {
      throw PDFError(.malformed, "The replacement pages did not survive extraction")
    }
    var sourceAnnotationCount = 0
    var sourceLinkCount = 0
    for pageID in extractedPages {
      let annotations = (try? AnnotationInventory.annotations(
        in: extracted.graph, pageID: pageID)) ?? []
      for annotation in annotations {
        if annotation.subtype == PDFName("Link") {
          sourceLinkCount += 1
        } else if !Self.isWidget(annotation.dictionary) {
          sourceAnnotationCount += 1
        }
      }
    }
    let sourceFieldsBefore = (try? FormInventory.fields(
      in: parsed.graph, pageIDs: selectedSourcePages)) ?? []
    // FormInventory page indices refer to the source document; a field is
    // imported when at least one widget sits on a selected source page.
    let sourceSelectedIndices = Set(sourcePageIndices)
    var sourceFieldNames: [String] = []
    for field in sourceFieldsBefore {
      let indexes = Set(field.widgets.compactMap(\.pageIndex))
      if !indexes.isDisjoint(with: sourceSelectedIndices) {
        sourceFieldNames.append(field.name)
      }
    }

    // Field-name collisions are a policy decision; the assembly would rename
    // widgets internally before the AcroForm rebuild sees them, so preflight
    // the visible field names instead.
    let retainedFieldNames = Set(
      destinationFieldsBefore.filter { field in
        let indexes = Set(field.widgets.compactMap(\.pageIndex))
        return !indexes.isEmpty && !indexes.isSubset(of: removed)
      }.map(\.name))
    let importedFieldNameSet = Set(sourceFieldNames)
    let collisions = retainedFieldNames.intersection(importedFieldNameSet)
    if !collisions.isEmpty, options.formFieldConflicts == .refuse {
      throw PDFError(
        .unsupported,
        "The replacement introduces duplicate form-field name(s): "
          + collisions.sorted().joined(separator: ", "))
    }

    // The tested assembly path remaps every reachable object with collision-free
    // identities; the destination is the first source so its catalog data wins.
    let retainedPages = destinationPages.enumerated()
      .filter { !removed.contains($0.offset) }.map(\.element)
    let merged = try DocumentAssembly.merge(
      [
        (graph: graph, pageIDs: retainedPages),
        (graph: extracted.graph, pageIDs: extractedPages),
      ], labels: .reset, catalogData: .firstDocument, limits: limits)
    var result = merged.graph
    report.notes.append(contentsOf: merged.report.notes)
    report.renamedFields.append(contentsOf: merged.report.renamedFields)

    // Place the replacement block at the first replaced destination position.
    let firstRemovedIndex = destinationIndices.first ?? destinationPages.count
    let mergedPages = try PDFPageTree.pageIDs(in: result)
    let imported = Array(mergedPages.suffix(extractedPages.count))
    result = try PageOrganizer.moveBlock(
      pageIDs: imported, toIndex: firstRemovedIndex, in: result)
    let finalPages = try PDFPageTree.pageIDs(in: result)
    let importedPageIndices = Set(
      imported.compactMap { finalPages.firstIndex(of: $0) })

    // Page labels: positional number tree, retained only when the destination
    // had ranges. Labels after the replaced range simply shift with the pages.
    if options.pageLabels == .retainDestination, !destinationLabels.isEmpty {
      try Self.writePageLabels(destinationLabels, in: &result)
      report.destinationPageLabelsRetained = true
      if extractedPages.count != destinationIndices.count {
        report.notes.append(
          "Page labels are positional: the page count changed by \(extractedPages.count - destinationIndices.count), so later labels shift.")
      }
    }

    // Tagged structure: the assembly remapper cannot keep the destination
    // page-to-parent-tree relationships when pages disappear, so the declared
    // profile drops the structure tree and reports it.
    if structurePresent {
      if options.structureTree == .dropDestination {
        Self.dropStructureTree(in: &result)
        report.structureTreeDropped = true
      }
    }

    // Rebuild the AcroForm for retained destination fields and the imported
    // source fields; the assembly drops catalog-level AcroForm data.
    let fieldOutcome = try Self.rebuildAcroForm(
      in: &result, baseScalars: baseAcroFormScalars,
      conflictPolicy: options.formFieldConflicts)
    report.renamedFields.append(contentsOf: fieldOutcome.renamed)

    let retainedAfterLinkCount = Self.linkCount(
      graph: result, pageIDs: finalPages.enumerated()
        .filter { !importedPageIndices.contains($0.offset) }
        .map(\.element))
    let finalFields = (try? FormInventory.fields(
      in: result, pageIDs: finalPages)) ?? []
    let importedFieldNames = finalFields.filter { field in
      field.widgets.contains { widget in
        guard let index = widget.pageIndex else { return false }
        return importedPageIndices.contains(index)
      }
    }.map(\.name)

    report.destinationPagesReplaced = destinationIndices.count
    report.replacementPagesInserted = extractedPages.count
    report.destinationAnnotationsDropped =
      destinationAnnotationCount + max(0, retainedBeforeLinkCount - retainedAfterLinkCount)
    report.sourceAnnotationsImported = sourceAnnotationCount
    report.destinationLinksDropped =
      destinationLinkCount + max(0, retainedBeforeLinkCount - retainedAfterLinkCount)
    report.sourceLinksImported = sourceLinkCount
    report.destinationFormFieldsRemoved = removedFieldNames
    report.sourceFormFieldsImported = importedFieldNames.sorted()
    if removedWidgetCount > 0 {
      report.notes.append(
        "Destination field widgets on the replaced pages were removed (\(removedWidgetCount) widget(s)).")
    }
    let partialDestinationFields = destinationFieldsBefore.filter { field in
      let indexes = Set(field.widgets.compactMap(\.pageIndex))
      return !indexes.isEmpty && !indexes.isDisjoint(with: removed)
        && !indexes.isSubset(of: removed)
    }
    for field in partialDestinationFields {
      report.notes.append(
        "Field \(field.name) kept on retained pages; its widgets on replaced pages were removed.")
    }
    let sourcePartial = sourceFieldsBefore.filter { field in
      let indexes = Set(field.widgets.compactMap(\.pageIndex))
      return !indexes.isDisjoint(with: Set(sourcePageIndices))
        && !indexes.isSubset(of: Set(sourcePageIndices))
    }
    for field in sourcePartial {
      report.notes.append(
        "Imported field \(field.name) lost widgets that were on unselected source pages.")
    }
    if report.renamedFields.isEmpty, options.formFieldConflicts == .rename {
      report.notes.append("No form-field name collisions were found.")
    }
    report.notes.append(
      "AcroForm appearance resources were rebuilt with a standard Helvetica DR; field values and generated appearances are preserved.")
    report.notes.append(
      "Assembly dropped \(merged.report.droppedDestinations) destination reference(s) whose page objects did not survive and \(merged.report.droppedOutlines) outline entr(ies) targeting removed pages.")
    // Every surviving field name is either reported as imported or removed;
    // retain the pre-merge list only for the partial-import notes above.
    _ = sourceFieldNames
    return (result, report)
  }

  // MARK: Catalog helpers

  struct CatalogAccess {
    let objectID: PDFObjectID
    let dictionary: [PDFName: PDFValue]
  }

  static func catalog(in graph: PDFGraph) -> CatalogAccess? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { return nil }
    return CatalogAccess(objectID: catalogID, dictionary: catalog)
  }

  static func acroFormDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard let catalog = catalog(in: graph) else { return nil }
    switch catalog.dictionary[PDFName("AcroForm")] {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }

  // MARK: Annotations and links

  static func isWidget(_ dictionary: [PDFName: PDFValue]) -> Bool {
    dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
      || dictionary[PDFName("FT")] != nil
  }

  static func linkCount(graph: PDFGraph, pageIDs: [PDFObjectID]) -> Int {
    var count = 0
    for pageID in pageIDs {
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      count += annotations.filter { $0.subtype == PDFName("Link") }.count
    }
    return count
  }

  // MARK: Page labels

  static func writePageLabels(
    _ ranges: [PDFPageLabelRange], in graph: inout PDFGraph
  ) throws {
    guard let catalog = catalog(in: graph) else { return }
    var numbers: [PDFValue] = []
    for range in ranges {
      var dictionary: [PDFName: PDFValue] = [
        PDFName("S"): .name(Self.labelStyleName(range.style))
      ]
      if !range.prefix.isEmpty {
        dictionary[PDFName("P")] = .string(AnnotationText.encode(range.prefix))
      }
      if range.startValue != 1 {
        dictionary[PDFName("St")] = .integer(Int64(range.startValue))
      }
      numbers.append(.integer(Int64(range.startPageIndex)))
      numbers.append(.dictionary(dictionary))
    }
    let objectID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[objectID] = .dictionary([
      PDFName("Nums"): .array(numbers)
    ])
    var updated = catalog.dictionary
    updated[PDFName("PageLabels")] = .reference(objectID)
    graph.objects[catalog.objectID] = .dictionary(updated)
  }

  static func labelStyleName(_ style: PDFPageLabelRange.Style) -> PDFName {
    switch style {
    case .decimal: return PDFName("D")
    case .upperRoman: return PDFName("R")
    case .lowerRoman: return PDFName("r")
    case .upperAlpha: return PDFName("A")
    case .lowerAlpha: return PDFName("a")
    case .none: return PDFName("D")
    }
  }

  // MARK: Structure tree

  static func dropStructureTree(in graph: inout PDFGraph) {
    guard let catalog = catalog(in: graph) else { return }
    var updated = catalog.dictionary
    updated[PDFName("StructTreeRoot")] = nil
    updated[PDFName("MarkInfo")] = nil
    graph.objects[catalog.objectID] = .dictionary(updated)
    let pages = (try? PDFPageTree.pageIDs(in: graph)) ?? []
    for pageID in pages {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      page[PDFName("StructParents")] = nil
      graph.objects[pageID] = .dictionary(page)
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations {
        guard let annotationID = annotation.objectID,
          case .dictionary(var dictionary)? = graph.objects[annotationID]
        else { continue }
        dictionary[PDFName("StructParent")] = nil
        graph.objects[annotationID] = .dictionary(dictionary)
      }
    }
  }

  // MARK: AcroForm rebuild

  struct FieldRebuildOutcome {
    var renamed: [String]
    var names: [String]
  }

  /// Rebuild the catalog AcroForm from the widget annotations that survive on
  /// the final pages. Field dictionaries and widget appearances are already
  /// carried by the assembly; only the catalog entry and name uniqueness are
  /// reconstructed.
  static func rebuildAcroForm(
    in graph: inout PDFGraph, baseScalars: [PDFName: PDFValue],
    conflictPolicy: ReplacePagesOptions.FormFieldConflictPolicy
  ) throws -> FieldRebuildOutcome {
    let pages = try PDFPageTree.pageIDs(in: graph)
    struct Root {
      var name: String?
    }
    var roots: [PDFObjectID: Root] = [:]
    var order: [PDFObjectID?] = []
    for pageID in pages {
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations where isWidget(annotation.dictionary) {
        // Direct (non-indirect) widget dictionaries cannot be listed in an
        // AcroForm /Fields array, so they are not carried by this profile.
        guard let widgetID = annotation.objectID else { continue }
        let chain = Self.parentChain(from: widgetID, in: graph)
        guard let rootEntry = chain.last else { continue }
        let rootID = rootEntry.0
        var root = roots[rootID] ?? Root(name: nil)
        if root.name == nil {
          var components: [String] = []
          for (_, dictionary) in chain {
            if case .string(let data)? = dictionary[PDFName("T")] {
              let text = AnnotationText.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
              if !text.isEmpty { components.append(text) }
            }
          }
          root.name = components.isEmpty ? nil : components.joined(separator: ".")
        }
        if roots[rootID] == nil { order.append(rootID) }
        roots[rootID] = root
      }
    }

    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    var acroForm: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = catalog[PDFName("AcroForm")] {
      acroForm = existing
    } else if case .reference(let existingID)? = catalog[PDFName("AcroForm")],
      case .dictionary(let existing)? = graph.objects[existingID]
    {
      acroForm = existing
    }
    acroForm[PDFName("Fields")] = .array([])
    acroForm[PDFName("XFA")] = nil
    for (key, value) in baseScalars { acroForm[key] = value }
    if acroForm[PDFName("NeedAppearances")] == nil {
      acroForm[PDFName("NeedAppearances")] = .boolean(false)
    }
    catalog[PDFName("AcroForm")] = .dictionary(acroForm)
    graph.objects[catalogID] = .dictionary(catalog)
    var context = try FormAuthoringSupport.ensureAcroForm(in: &graph)
    var rebuiltAcroForm = context.acroForm
    for (key, value) in baseScalars { rebuiltAcroForm[key] = value }

    var usedNames = Set<String>()
    var renamed: [String] = []
    var fieldReferences: [PDFValue] = []
    var names: [String] = []
    for rootID in order.compactMap({ $0 }) {
      guard var root = roots[rootID] else { continue }
      var name = root.name ?? "Field_\(rootID.number)"
      if usedNames.contains(name) {
        switch conflictPolicy {
        case .refuse:
          throw PDFError(
            .unsupported,
            "The replacement introduces a duplicate form-field name: \(name)")
        case .rename:
          let old = name
          var counter = 2
          while usedNames.contains(name) {
            name = "\(old)_\(counter)"
            counter += 1
          }
          renamed.append("\(old) → \(name)")
          if var dictionary = Self.dictionary(of: rootID, in: graph) {
            dictionary[PDFName("T")] = .string(AnnotationText.encode(name))
            graph.objects[rootID] = .dictionary(dictionary)
          }
        }
      }
      usedNames.insert(name)
      root.name = name
      roots[rootID] = root
      names.append(name)
      fieldReferences.append(.reference(rootID))
    }
    rebuiltAcroForm[PDFName("Fields")] = .array(fieldReferences)
    try FormAuthoringSupport.writeAcroForm(
      rebuiltAcroForm, catalogID: context.catalogID, in: &graph)
    return FieldRebuildOutcome(renamed: renamed, names: names.sorted())
  }

  static func dictionary(of objectID: PDFObjectID, in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard case .dictionary(let dictionary)? = graph.objects[objectID] else { return nil }
    return dictionary
  }

  /// Annotation/field chain from a widget up to its root field, root first.
  static func parentChain(
    from objectID: PDFObjectID, in graph: PDFGraph
  ) -> [(PDFObjectID, [PDFName: PDFValue])] {
    var chain: [(PDFObjectID, [PDFName: PDFValue])] = []
    var current: PDFObjectID? = objectID
    var visited: Set<PDFObjectID> = []
    while let id = current, visited.insert(id).inserted, chain.count < 64 {
      guard case .dictionary(let dictionary)? = graph.objects[id] else { break }
      chain.append((id, dictionary))
      if case .reference(let parent)? = dictionary[PDFName("Parent")] {
        current = parent
      } else {
        current = nil
      }
    }
    return chain.reversed()
  }
}
