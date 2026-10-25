import Foundation
import PDFCore

// MARK: - Whole-page redaction

/// Removes every representation of one page: its content stream and resource
/// references are replaced by the redaction paint, page annotations and widgets
/// linked to form fields are deleted, and the generated OCR layer is dropped.
/// A whole-page mark therefore never leaves the old page content reachable.
enum RedactionWholePage {
  static func validate(
    pageID: PDFObjectID, rect: [Double], in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    try AnnotationSupport.validateRect(rect)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    _ = page
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let ids = Set(annotations.compactMap(\.objectID))
    guard !ids.isEmpty else { return }
    // Deleting a page makes its annotations disappear. Refuse when a comment
    // thread links one of them to another page or object so the rewrite never
    // leaves a dangling reply/popup thread.
    for (objectID, value) in graph.objects where !ids.contains(objectID) {
      guard case .dictionary(let dictionary) = value else { continue }
      for key in [PDFName("IRT"), PDFName("Parent"), PDFName("Popup")] {
        if case .reference(let target)? = dictionary[key], ids.contains(target) {
          throw PDFError(
            .unsupported,
            "A page annotation is linked to another page or object; resolve its thread before redacting the whole page")
        }
      }
    }
  }

  static func apply(
    pageID: PDFObjectID, rect: [Double], fillColor: [Double], paintsFill: Bool,
    in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    var graph = graph
    // Form fields first: their widgets are page annotations and must be removed
    // through the field tree, never left dangling by clearing /Annots.
    graph = try RedactRegionsCommand(
      pageID: pageID, regions: [rect], fillColor: fillColor, paintsFill: paintsFill
    ).removeIntersectingFields(in: graph)
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let annotationIDs = annotations.compactMap(\.objectID)
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    page[PDFName("Annots")] = nil
    page[PDFName("Thumb")] = nil
    page[PDFName("Metadata")] = nil
    graph.objects[pageID] = .dictionary(page)
    for objectID in annotationIDs {
      var appearanceID: PDFObjectID?
      if case .dictionary(let dictionary)? = graph.objects[objectID],
        case .dictionary(let appearance)? = dictionary[PDFName("AP")],
        case .reference(let id)? = appearance[PDFName("N")]
      {
        appearanceID = id
      }
      graph.objects[objectID] = nil
      if let appearanceID, !AnnotationSupport.isReferenced(appearanceID, in: graph) {
        graph.objects[appearanceID] = nil
      }
    }
    try OCRLayer.removeLayer(pageID: pageID, in: &graph)
    let bytes: Data
    if paintsFill {
      var content = "q\n"
      content += "\(AnnotationSupport.number(fillColor[0])) "
      content += "\(AnnotationSupport.number(fillColor[1])) "
      content += "\(AnnotationSupport.number(fillColor[2])) rg\n"
      content += "\(AnnotationSupport.number(rect[0])) "
      content += "\(AnnotationSupport.number(rect[1])) "
      content += "\(AnnotationSupport.number(rect[2] - rect[0])) "
      content += "\(AnnotationSupport.number(rect[3] - rect[1])) re f\n"
      content += "Q\n"
      bytes = Data(content.utf8)
    } else {
      bytes = Data()
    }
    let newID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[newID] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
    guard case .dictionary(var updated)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    updated[PDFName("Contents")] = .reference(newID)
    // Dropping the resource dictionary makes every old font, image and form
    // reference unreachable, so the verified full rewrite prunes them all.
    updated[PDFName("Resources")] = .dictionary([:])
    updated[PDFName("Annots")] = nil
    graph.objects[pageID] = .dictionary(updated)
    return graph
  }
}

// MARK: - RED-01 apply command

/// One atomic command that applies every pending redaction mark: text marks
/// remove exactly the reviewed glyphs, region marks use the conservative region
/// policy, whole-page marks replace the page content, and hidden/OCR text on
/// affected pages is removed according to the explicit policy. The command is
/// committed as one transaction, so one Undo restores the entire pre-apply
/// graph, and it requires a full rewrite on save so earlier revisions cannot
/// retain removed content.
public struct RedactMarksCommand: PDFEditCommand, Equatable, Sendable {
  public let marks: [RedactionMark]
  public let options: RedactionApplicationOptions

  public init(
    marks: [RedactionMark], options: RedactionApplicationOptions = RedactionApplicationOptions()
  ) {
    self.marks = marks
    self.options = options
  }

  public init(
    store: RedactionMarkStore, options: RedactionApplicationOptions = RedactionApplicationOptions()
  ) {
    self.init(marks: store.pendingMarks, options: options)
  }

  public var name: String { "Apply Redactions" }

  /// SAF-02: the saved base revision still holds every byte this command
  /// removes, so the next save must be a full rewrite.
  public var requiresFullRewriteOnSave: Bool { true }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    var seen = Set<PDFObjectID>()
    var result: [PDFObjectID] = []
    for mark in marks where seen.insert(mark.pageID).inserted {
      result.append(mark.pageID)
    }
    return result
  }

  public func validate(in graph: PDFGraph) throws {
    let limits = PDFLimits()
    guard !marks.isEmpty else {
      throw PDFError(.malformed, "There are no pending redaction marks to apply")
    }
    try AnnotationSupport.validateColor(options.fillColor, label: "Redaction fill")
    let pageIDs = try PageTreeView(graph: graph).pages
    let pageSet = Set(pageIDs)
    var grouped: [PDFObjectID: [RedactionMark]] = [:]
    for mark in marks {
      guard pageSet.contains(mark.pageID) else {
        throw PDFError(
          .malformed, "A redaction mark targets a page that is not in the document")
      }
      grouped[mark.pageID, default: []].append(mark)
    }
    for pageID in pageIDs {
      guard let pageMarks = grouped[pageID] else { continue }
      let pageMarksOnly = pageMarks.filter { $0.kind == .page }
      if !pageMarksOnly.isEmpty {
        guard pageMarksOnly.count == 1 else {
          throw PDFError(
            .malformed, "A page carries more than one whole-page redaction mark")
        }
        try RedactionWholePage.validate(
          pageID: pageID, rect: pageMarksOnly[0].rects[0], in: graph, limits: limits)
        continue
      }
      let hidden = try RedactionHiddenText.inventory(
        pageID: pageID, in: graph, limits: limits)
      if options.hiddenTextPolicy == .refuseWhenPresent, hidden.hasHiddenText {
        throw PDFError(
          .unsupported,
          "This page carries hidden or OCR text and the hidden-text policy refuses to apply; nothing was removed")
      }
      let regionMarks = pageMarks.filter { $0.kind == .region }
      if !regionMarks.isEmpty {
        try RedactRegionsCommand(
          pageID: pageID, regions: regionMarks.flatMap(\.rects),
          fillColor: options.fillColor, paintsFill: options.paintsFill
        ).validate(in: graph)
      }
      let textMarks = pageMarks.filter { $0.kind == .text }
      let visible = textMarks.filter { !$0.isHiddenText }
      if !visible.isEmpty {
        let rects = visible.flatMap(\.rects)
        _ = try RedactionTextPrecision.analyze(
          pageID: pageID, rects: rects, hiddenOnly: false, in: graph, limits: limits)
        try validateIntersectingAnnotations(
          pageID: pageID, rects: rects, in: graph)
      }
      for mark in textMarks where mark.isHiddenText {
        let analysis = try RedactionTextPrecision.analyze(
          pageID: pageID, rects: mark.rects, hiddenOnly: true, in: graph, limits: limits)
        guard analysis.removedClusterCount > 0 else {
          throw PDFError(
            .unsupported,
            "No hidden text was found under the reviewed geometry; re-run the search review")
        }
      }
      if options.hiddenTextPolicy == .removeFromAffectedPages {
        _ = try RedactionTextPrecision.allHiddenRunRemovals(
          pageID: pageID, in: graph, limits: limits)
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let limits = PDFLimits()
    let pageIDs = try PageTreeView(graph: graph).pages
    var grouped: [PDFObjectID: [RedactionMark]] = [:]
    for mark in marks { grouped[mark.pageID, default: []].append(mark) }
    for pageID in pageIDs {
      guard let pageMarks = grouped[pageID], !pageMarks.isEmpty else { continue }
      if let pageMark = pageMarks.first(where: { $0.kind == .page }) {
        graph = try RedactionWholePage.apply(
          pageID: pageID, rect: pageMark.rects[0], fillColor: options.fillColor,
          paintsFill: options.paintsFill, in: graph, limits: limits)
        continue
      }
      let regionMarks = pageMarks.filter { $0.kind == .region }
      if !regionMarks.isEmpty {
        graph = try RedactRegionsCommand(
          pageID: pageID, regions: regionMarks.flatMap(\.rects),
          fillColor: options.fillColor, paintsFill: options.paintsFill
        ).apply(to: graph)
      }
      let textMarks = pageMarks.filter { $0.kind == .text }
      let visibleRects = textMarks.filter { !$0.isHiddenText }.flatMap(\.rects)
      var removals: [Int: Set<Int>] = [:]
      if !visibleRects.isEmpty {
        let analysis = try RedactionTextPrecision.analyze(
          pageID: pageID, rects: visibleRects, hiddenOnly: false, in: graph, limits: limits)
        merge(&removals, analysis.removedGlyphs)
      }
      for mark in textMarks where mark.isHiddenText {
        let analysis = try RedactionTextPrecision.analyze(
          pageID: pageID, rects: mark.rects, hiddenOnly: true, in: graph, limits: limits)
        // The mark was validated against the pre-apply graph. A region mark on
        // the same page may already have removed the generated layer, in which
        // case there is no hidden text left to remove precisely.
        merge(&removals, analysis.removedGlyphs)
      }
      if options.hiddenTextPolicy == .removeFromAffectedPages {
        let hiddenRemovals = try RedactionTextPrecision.allHiddenRunRemovals(
          pageID: pageID, in: graph, limits: limits)
        merge(&removals, hiddenRemovals)
      }
      // Remove the reviewed glyphs before the OCR layer is dropped: the run
      // indices were analyzed against this graph.
      if !removals.isEmpty {
        graph = try RedactionTextPrecision.apply(
          pageID: pageID, removals: removals, in: graph, limits: limits)
      }
      if options.hiddenTextPolicy == .removeFromAffectedPages {
        try OCRLayer.removeLayer(pageID: pageID, in: &graph)
      }
      if !visibleRects.isEmpty {
        graph = try removeIntersectingAnnotations(pageID: pageID, rects: visibleRects, in: graph)
        graph = try RedactRegionsCommand(pageID: pageID, regions: visibleRects)
          .removeIntersectingFields(in: graph)
        if options.paintsFill {
          graph = try RedactRegionsCommand.appendFillStream(
            regions: visibleRects, color: options.fillColor, pageID: pageID, in: graph)
        }
      }
    }
    let allPages = try PDFPageTree.pageIDs(in: graph)
    graph = try PDFStructureRepair.pruneRemovedContent(in: graph, pageIDs: allPages).graph
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  private func merge(_ target: inout [Int: Set<Int>], _ source: [Int: Set<Int>]) {
    for (runIndex, glyphs) in source {
      target[runIndex, default: []].formUnion(glyphs)
    }
  }

  /// Annotations under a text mark are removed when they can be deleted
  /// without orphaning a reply thread; the refusal matches the region policy.
  private func validateIntersectingAnnotations(
    pageID: PDFObjectID, rects: [[Double]], in graph: PDFGraph
  ) throws {
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    for annotation in annotations {
      guard annotation.subtype != PDFName("Widget"),
        let bounds = annotation.bounds,
        RedactRegionsCommand.intersects(bounds, anyRegion: rects),
        let objectID = annotation.objectID
      else { continue }
      for (id, value) in graph.objects where id != objectID {
        if case .dictionary(let dictionary) = value,
          case .reference(let target)? = dictionary[PDFName("IRT")], target == objectID
        {
          throw PDFError(
            .unsupported,
            "A redaction mark intersects an annotation that has replies; resolve them first")
        }
      }
    }
  }

  private func removeIntersectingAnnotations(
    pageID: PDFObjectID, rects: [[Double]], in graph: PDFGraph
  ) throws -> PDFGraph {
    var graph = graph
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let indexes = annotations.filter { annotation in
      annotation.subtype != PDFName("Widget")
        && (annotation.bounds.map {
          RedactRegionsCommand.intersects($0, anyRegion: rects)
        } ?? false)
    }.map(\.index).sorted(by: >)
    for index in indexes {
      graph = try DeleteAnnotationCommand(pageID: pageID, annotationIndex: index)
        .apply(to: graph)
    }
    return graph
  }
}
