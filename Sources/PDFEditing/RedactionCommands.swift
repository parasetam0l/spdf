import Foundation
import PDFCore

/// P27-001: region redaction, distinct from whole-document sanitization.
/// Regions are in unrotated page space; the command removes intersecting
/// text, image draws, annotations, and form fields according to a
/// conservative supported policy, paints a fill over each region, and
/// refuses anything it cannot remove safely (P27-006/P27-011/P27-016).
public struct RedactRegionsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let regions: [[Double]]
  public let fillColor: [Double]
  public let paintsFill: Bool

  public init(
    pageID: PDFObjectID, regions: [[Double]], fillColor: [Double] = [0, 0, 0],
    paintsFill: Bool = true
  ) {
    self.pageID = pageID
    self.regions = regions
    self.fillColor = fillColor
    self.paintsFill = paintsFill
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Redact Regions" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !regions.isEmpty else {
      throw PDFError(.malformed, "Redaction needs at least one region")
    }
    for region in regions { try AnnotationSupport.validateRect(region) }
    try AnnotationSupport.validateColor(fillColor, label: "Redaction fill")

    let limits = PDFLimits()
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard content.segments.allSatisfy(\.isEditable) else {
      throw PDFError(
        .unsupported, "This page content uses filters that redaction cannot edit safely")
    }
    try validateText(in: graph, content: content, limits: limits)
    try validateImages(in: graph, content: content)
    try validateVectorContent(in: content)
    try validateAnnotationsAndForms(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    // P17-005: redaction rewrites the page's content; shared content is
    // copied first so removing text here never removes it from another page.
    var graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph)
    let limits = PDFLimits()
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)

    // 1. Remove intersecting image draw sequences (`q cm /Name Do Q`).
    var removalSpans: [Range<Int>] = []
    var removedResourceNames: Set<PDFName> = []
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    for placement in placements where Self.intersects(placement.bounds, anyRegion: regions) {
      guard placement.depth == 0, placement.isDirectlyEditable else { continue }
      let doIndex = placement.instructionIndex
      guard doIndex >= 2, doIndex + 1 < content.instructions.count,
        content.instructions[doIndex - 2].operatorName == "q",
        content.instructions[doIndex - 1].operatorName == "cm",
        content.instructions[doIndex + 1].operatorName == "Q"
      else { continue }
      removalSpans.append(
        content.instructions[doIndex - 2].span.lowerBound
          ..< content.instructions[doIndex + 1].span.upperBound)
      removedResourceNames.insert(placement.resourceName)
    }
    if !removalSpans.isEmpty {
      var grouped: [Int: [Range<Int>]] = [:]
      for span in removalSpans {
        if let index = content.segmentIndex(for: span) {
          grouped[index, default: []].append(span)
        }
      }
      for (_, spans) in grouped.sorted(by: { $0.key < $1.key }) {
        graph = try content.replacing(
          ranges: spans.map { ($0, [UInt8]()) }, in: graph, limits: limits)
      }
      // P27-009: drop resource entries whose draws are all gone so the image
      // objects become unreachable and sanitization can prune them.
      graph = try Self.removeUnusedImageResources(
        removedNames: removedResourceNames, pageID: pageID, in: graph, limits: limits)
    }

    // 2. Delete fully covered text runs, descending so earlier indices stay
    // stable (P27-005).
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    var runIndexes: Set<Int> = []
    for cluster in layout.clusters where Self.intersects(cluster.bounds, anyRegion: regions) {
      runIndexes.insert(cluster.runIndex)
    }
    for runIndex in runIndexes.sorted(by: >) {
      graph = try ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: "")
        .apply(to: graph)
    }

    // 3. Remove intersecting annotations, descending (P27-012).
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let annotationIndexes = annotations.filter { annotation in
      annotation.subtype != PDFName("Widget")
        && (annotation.bounds.map { Self.intersects($0, anyRegion: regions) } ?? false)
    }.map(\.index).sorted(by: >)
    for index in annotationIndexes {
      graph = try DeleteAnnotationCommand(pageID: pageID, annotationIndex: index)
        .apply(to: graph)
    }

    // 4. Remove whole fields whose widgets intersect (P27-013).
    graph = try removeIntersectingFields(in: graph)

    // 5. Remove a generated OCR layer (invisible text, P27-005).
    try OCRLayer.removeLayer(pageID: pageID, in: &graph)

    // P33-027: structure references to removed content are pruned so
    // alternate/actual text cannot retain redacted content.
    graph = try PDFStructureRepair.pruneRemovedContent(
      in: graph, pageIDs: try PDFPageTree.pageIDs(in: graph)).graph

    // 6. Paint the visible fill over each region.
    if paintsFill {
      graph = try Self.appendFillStream(
        regions: regions, color: fillColor, pageID: pageID, in: graph)
    }

    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  // MARK: - Preflight

  func validateText(in graph: PDFGraph, content: PageContent, limits: PDFLimits) throws {
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    // P27-016: text in fonts this profile cannot decode has unknowable bounds;
    // refusing is the only safe policy for a page under redaction.
    // Runs inside a generated OCR layer are removed wholesale by `apply`;
    // every other run must be inspectable.
    let layerIDs = Set(OCRLayer.layerStreamIDs(in: graph, pageID: pageID))
    let layerRanges = content.segments.filter { layerIDs.contains($0.objectID) }.map(\.range)
    for run in runs {
      if layerRanges.contains(where: { $0.contains(run.stringSpan.lowerBound) }) { continue }
      guard let font = SimpleFont.resolve(resource: run.fontResource, page: page, in: graph),
        font.isSupported
      else {
        throw PDFError(
          .unsupported,
          "Redaction refuses: the page contains text in a font this profile cannot inspect")
      }
      // P14-023: a Type 3 glyph program may paint arbitrary content outside
      // the advance-derived text box, so covering the box cannot guarantee
      // removal; refusing is the only safe policy.
      guard !font.isType3 else {
        throw PDFError(
          .unsupported,
          "Redaction refuses: Type 3 glyph programs can paint beyond their text bounds")
      }
    }
    let layout = try PageTextLayout.build(in: content, graph: graph, limits: limits)
    var runIndexes: Set<Int> = []
    for cluster in layout.clusters where Self.intersects(cluster.bounds, anyRegion: regions) {
      runIndexes.insert(cluster.runIndex)
    }
    guard !runIndexes.isEmpty else { return }
    for runIndex in runIndexes.sorted() {
      guard runIndex < runs.count else { continue }
      // P27-006: a run may only be removed when one region covers all of it.
      let runClusters = layout.clusters.filter { $0.runIndex == runIndex }
      let covered = runClusters.allSatisfy { cluster in
        regions.contains { Self.contains($0, cluster.bounds) }
      }
      guard covered else {
        throw PDFError(
          .unsupported,
          "Redaction would partially intersect a text run; extend the region to cover the whole run"
        )
      }
      try ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: "")
        .validate(in: graph)
    }
  }

  func validateImages(in graph: PDFGraph, content: PageContent) throws {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    for placement in placements where Self.intersects(placement.bounds, anyRegion: regions) {
      guard placement.depth == 0, placement.isDirectlyEditable else {
        throw PDFError(
          .unsupported,
          "Redaction intersects image content that this profile cannot isolate safely")
      }
      guard case .stream(let image)? = graph.objects[placement.imageID] else {
        throw PDFError(.malformed, "Image resource is missing")
      }
      for key in ["ImageMask", "Mask", "SMask", "Decode"]
      where image.dictionary[PDFName(key)] != nil {
        throw PDFError(
          .unsupported, "Redaction intersects an image with masks or decode arrays")
      }
      let doIndex = placement.instructionIndex
      guard doIndex >= 2, doIndex + 1 < content.instructions.count,
        content.instructions[doIndex - 2].operatorName == "q",
        content.instructions[doIndex - 1].operatorName == "cm",
        content.instructions[doIndex + 1].operatorName == "Q"
      else {
        throw PDFError(
          .unsupported, "Redaction intersects an image draw this profile cannot remove exactly")
      }
    }
  }

  /// P27-011: vector graphics are rejected rather than partially left behind.
  func validateVectorContent(in content: PageContent) throws {
    var pathBounds: [Double]?
    var lineWidth = 1.0
    for instruction in content.instructions {
      let numbers = instruction.operands.compactMap { Annotation.number($0.value) }
      switch instruction.operatorName {
      case "w" where numbers.count == 1:
        lineWidth = max(numbers[0], 0)
      case "re" where numbers.count == 4:
        pathBounds = Self.union(
          pathBounds,
          [numbers[0], numbers[1], numbers[0] + numbers[2], numbers[1] + numbers[3]])
      case "m" where numbers.count == 2, "l" where numbers.count == 2:
        pathBounds = Self.union(pathBounds, [numbers[0], numbers[1], numbers[0], numbers[1]])
      case "c" where numbers.count == 6:
        pathBounds = Self.union(
          pathBounds,
          Self.union(
            [numbers[0], numbers[1], numbers[0], numbers[1]],
            Self.union(
              [numbers[2], numbers[3], numbers[2], numbers[3]],
              [numbers[4], numbers[5], numbers[4], numbers[5]])))
      case "v" where numbers.count == 4, "y" where numbers.count == 4:
        pathBounds = Self.union(
          pathBounds,
          Self.union(
            [numbers[0], numbers[1], numbers[0], numbers[1]],
            [numbers[2], numbers[3], numbers[2], numbers[3]]))
      case "f", "F", "f*", "S", "s", "B", "B*", "b", "b*":
        if let bounds = pathBounds {
          let strokes = ["S", "s", "B", "B*", "b", "b*"].contains(instruction.operatorName)
          let margin = strokes ? max(lineWidth, 1.0) : 0.0
          let expanded = [
            bounds[0] - margin, bounds[1] - margin, bounds[2] + margin, bounds[3] + margin,
          ]
          if Self.intersects(expanded, anyRegion: regions) {
            throw PDFError(
              .unsupported,
              "Redaction intersects vector graphics; this profile refuses rather than leaving partial marks"
            )
          }
        }
        pathBounds = nil
      default:
        break
      }
    }
  }

  func validateAnnotationsAndForms(in graph: PDFGraph) throws {
    // Nested form content cannot be inspected safely.
    let content = try PageContent.load(pageID: pageID, in: graph)
    for instruction in content.instructions where instruction.operatorName == "Do" {
      guard case .name(let name)? = instruction.operands.first?.value,
        let resources = OCRLayer.pageResources(in: graph, pageID: pageID),
        case .dictionary(let xobjects)? = resources[PDFName("XObject")],
        case .reference(let objectID)? = xobjects[name],
        case .stream(let stream)? = graph.objects[objectID]
      else { continue }
      if stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form")) {
        throw PDFError(
          .unsupported,
          "Redaction intersects form XObject content that this profile cannot inspect")
      }
    }

    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    for annotation in annotations {
      guard annotation.subtype != PDFName("Widget"),
        let bounds = annotation.bounds, Self.intersects(bounds, anyRegion: regions),
        let objectID = annotation.objectID
      else { continue }
      for (id, value) in graph.objects where id != objectID {
        if case .dictionary(let dictionary) = value,
          case .reference(let target)? = dictionary[PDFName("IRT")], target == objectID
        {
          throw PDFError(
            .unsupported, "Redaction intersects an annotation that has replies; resolve them first")
        }
      }
    }
  }

  // MARK: - Resource cleanup

  /// P27-009: after image draws are removed, drop the page's now-unused image
  /// resource entries so the image objects become unreachable. The page's
  /// resource dictionary is copied when it is shared (indirect), and nothing
  /// is touched while a form XObject is drawn, because forms can inherit page
  /// resources.
  static func removeUnusedImageResources(
    removedNames: Set<PDFName>, pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits
  ) throws -> PDFGraph {
    guard !removedNames.isEmpty else { return graph }
    var graph = graph
    if let resources = OCRLayer.pageResources(in: graph, pageID: pageID),
      case .dictionary(let xobjects)? = resources[PDFName("XObject")]
    {
      for value in xobjects.values {
        guard case .reference(let id) = value, case .stream(let stream)? = graph.objects[id]
        else { continue }
        if stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form")) {
          return graph
        }
      }
    }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    var usedNames: Set<PDFName> = []
    for instruction in content.instructions where instruction.operatorName == "Do" {
      if case .name(let name)? = instruction.operands.first?.value { usedNames.insert(name) }
    }
    guard case .dictionary(var page)? = graph.objects[pageID] else { return graph }
    switch page[PDFName("Resources")] {
    case .dictionary(var resources)?:
      guard case .dictionary(var xobjects)? = resources[PDFName("XObject")] else { return graph }
      for name in removedNames where !usedNames.contains(name) {
        xobjects[name] = nil
      }
      resources[PDFName("XObject")] = .dictionary(xobjects)
      page[PDFName("Resources")] = .dictionary(resources)
    case .reference(let resourcesID)?:
      guard case .dictionary(let shared)? = graph.objects[resourcesID] else { return graph }
      var resources = shared
      guard case .dictionary(var xobjects)? = resources[PDFName("XObject")] else { return graph }
      for name in removedNames where !usedNames.contains(name) {
        xobjects[name] = nil
      }
      resources[PDFName("XObject")] = .dictionary(xobjects)
      // Copy-on-write: the shared object stays for other pages.
      page[PDFName("Resources")] = .dictionary(resources)
    default:
      return graph
    }
    graph.objects[pageID] = .dictionary(page)
    return graph
  }

  // MARK: - Field removal

  func removeIntersectingFields(in graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    guard let pageIndex = pageIDs.firstIndex(of: pageID) else { return graph }
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let names = fields.filter { field in
      field.widgets.contains { widget in
        widget.pageIndex == pageIndex
          && (widget.rect.map { Self.intersects($0, anyRegion: regions) } ?? false)
      }
    }.map(\.name)
    for name in names {
      graph = try Self.removeField(named: name, in: graph)
    }
    return graph
  }

  static func removeField(named name: String, in graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let field = fields.first(where: { $0.name == name }) else { return graph }
    var removedObjectIDs: [PDFObjectID] = []
    if let fieldID = field.fieldID { removedObjectIDs.append(fieldID) }
    for widget in field.widgets {
      guard let widgetID = widget.objectID, let pageIndex = widget.pageIndex,
        pageIndex < pageIDs.count
      else { continue }
      removedObjectIDs.append(widgetID)
      let annotations = try AnnotationInventory.annotations(
        in: graph, pageID: pageIDs[pageIndex])
      if let annotation = annotations.first(where: { $0.objectID == widgetID }) {
        try AnnotationSupport.removeAnnotation(
          pageID: pageIDs[pageIndex], index: annotation.index, in: &graph)
      }
    }
    // Drop the field entry from the AcroForm tree.
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID],
      case .reference(let acroID)? = catalog[PDFName("AcroForm")],
      case .dictionary(var acroForm)? = graph.objects[acroID],
      case .array(let roots)? = acroForm[PDFName("Fields")]
    {
      let filtered = try filterFields(roots, dropping: name, prefix: "", in: &graph)
      acroForm[PDFName("Fields")] = .array(filtered)
      graph.objects[acroID] = .dictionary(acroForm)
    }
    for id in removedObjectIDs where !AnnotationSupport.isReferenced(id, in: graph) {
      graph.objects[id] = nil
    }
    return graph
  }

  static func filterFields(
    _ entries: [PDFValue], dropping name: String, prefix: String, in graph: inout PDFGraph
  ) throws -> [PDFValue] {
    var result: [PDFValue] = []
    for entry in entries {
      guard let field = FormInventory.resolvedDictionary(entry, in: graph) else { continue }
      let partial = FormInventory.text(field[PDFName("T")]) ?? ""
      let qualified =
        prefix.isEmpty
        ? FormInventory.escapeName(partial)
        : (partial.isEmpty ? prefix : prefix + "." + FormInventory.escapeName(partial))
      if qualified == name { continue }
      if case .reference(let objectID) = entry,
        case .dictionary(var referenced)? = graph.objects[objectID],
        case .array(let kids)? = referenced[PDFName("Kids")]
      {
        referenced[PDFName("Kids")] = .array(
          try filterFields(kids, dropping: name, prefix: qualified, in: &graph))
        graph.objects[objectID] = .dictionary(referenced)
        result.append(entry)
      } else if case .dictionary(var direct) = entry, case .array(let kids)? = direct[PDFName("Kids")]
      {
        direct[PDFName("Kids")] = .array(
          try filterFields(kids, dropping: name, prefix: qualified, in: &graph))
        result.append(.dictionary(direct))
      } else {
        result.append(entry)
      }
    }
    return result
  }

  static func appendFillStream(
    regions: [[Double]], color: [Double], pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> PDFGraph {
    var graph = graph
    var content = "q\n"
    content += "\(AnnotationSupport.number(color[0])) "
    content += "\(AnnotationSupport.number(color[1])) "
    content += "\(AnnotationSupport.number(color[2])) rg\n"
    for region in regions {
      content += "\(AnnotationSupport.number(region[0])) "
      content += "\(AnnotationSupport.number(region[1])) "
      content += "\(AnnotationSupport.number(region[2] - region[0])) "
      content += "\(AnnotationSupport.number(region[3] - region[1])) re f\n"
    }
    content += "Q\n"
    let bytes = Data(content.utf8)
    let id = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[id] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
    try FlattenAnnotationsCommand.appendContents([.reference(id)], pageID: pageID, in: &graph)
    return graph
  }

  // MARK: - Geometry helpers

  static func intersects(_ rect: [Double], anyRegion regions: [[Double]]) -> Bool {
    regions.contains { region in
      rect[0] < region[2] && rect[2] > region[0] && rect[1] < region[3] && rect[3] > region[1]
    }
  }

  static func contains(_ region: [Double], _ rect: [Double]) -> Bool {
    let tolerance = 0.5
    return rect[0] >= region[0] - tolerance && rect[1] >= region[1] - tolerance
      && rect[2] <= region[2] + tolerance && rect[3] <= region[3] + tolerance
  }

  static func union(_ lhs: [Double]?, _ rhs: [Double]) -> [Double] {
    guard let lhs else { return rhs }
    return [
      min(lhs[0], rhs[0]), min(lhs[1], rhs[1]), max(lhs[2], rhs[2]), max(lhs[3], rhs[3]),
    ]
  }
}

/// P27-001/P27-022/P27-023: whole-document sanitization. Removes every object
/// unreachable from the trailer so a sanitized full rewrite (no earlier
/// revisions) contains no orphaned sensitive objects.
public struct SanitizeDocumentCommand: PDFEditCommand, Equatable, Sendable {
  public init() {}

  public var name: String { "Sanitize Document" }

  public func validate(in graph: PDFGraph) throws {}

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let reachable = Self.reachableObjectIDs(in: graph)
    graph.objects = graph.objects.filter { reachable.contains($0.key) }
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    graph.trailer[PDFName("Size")] = .integer(Int64(highest) + 1)
    return graph
  }

  /// Objects reachable from the trailer (root, info, identifiers, and so on).
  public static func reachableObjectIDs(in graph: PDFGraph) -> Set<PDFObjectID> {
    var reachable: Set<PDFObjectID> = []
    var stack: [PDFValue] = Array(graph.trailer.values)
    while let value = stack.popLast() {
      switch value {
      case .reference(let id):
        guard reachable.insert(id).inserted, let object = graph.objects[id] else { continue }
        stack.append(object)
      case .array(let values):
        stack.append(contentsOf: values)
      case .dictionary(let dictionary):
        stack.append(contentsOf: dictionary.values)
      case .stream(let stream):
        stack.append(.dictionary(stream.dictionary))
      default:
        break
      }
    }
    return reachable
  }
}
