import Foundation
import PDFCore

// MARK: - RED-04 paint inventory

/// RED-04: how much of the page the broadened region profile removes.
public enum RedactionPaintScope: String, Sendable, Equatable, CaseIterable {
  /// Every supported paint kind: text runs, image draws, fully covered form
  /// XObjects, fully covered vector paint, annotations and fields.
  case allPaint
  /// Only whole intersecting image draws. Used by a text mark whose visible
  /// pixels live in a scan, where removing the raster is the only safe removal.
  case imagesOnly

  public var title: String {
    switch self {
    case .allPaint: return "All supported paint"
    case .imagesOnly: return "Image and scan draws only"
    }
  }
}

/// RED-04: the kinds of page paint the broadened region profile can identify.
public enum RedactionPaintKind: String, Sendable, Equatable, CaseIterable {
  case text
  case image
  case formXObject
  case vectorPaint
  case shading
  case inlineImage
  case annotation
  case formField

  public var title: String {
    switch self {
    case .text: return "Text"
    case .image: return "Image or scan"
    case .formXObject: return "Reusable form content"
    case .vectorPaint: return "Vector paint"
    case .shading: return "Gradient shading"
    case .inlineImage: return "Inline image"
    case .annotation: return "Annotation"
    case .formField: return "Form field"
    }
  }
}

/// One paint unit the reviewed regions cover.
public struct RedactionPaintItem: Sendable, Equatable {
  public let kind: RedactionPaintKind
  public let bounds: [Double]
  public let description: String
  /// True when the whole painted object is removed (supported); false when the
  /// item is the reason the mark refuses.
  public let isRemovable: Bool
  public let refusal: String?

  public init(
    kind: RedactionPaintKind, bounds: [Double], description: String,
    isRemovable: Bool, refusal: String? = nil
  ) {
    self.kind = kind
    self.bounds = bounds
    self.description = description
    self.isRemovable = isRemovable
    self.refusal = refusal
  }
}

/// Non-mutating result of RED-04 paint analysis. The same analysis drives the
/// review plan and the apply command, so the reviewed removal set cannot differ
/// from the committed one.
public struct RedactionPaintAnalysis: Sendable, Equatable {
  public let items: [RedactionPaintItem]
  public let refusals: [String]
  /// Decoded page-content byte ranges removed by apply.
  public let contentRemovalRanges: [Range<Int>]
  /// XObject resource names whose every page draw is removed.
  public let removedXObjectNames: [String]
  public let textRunIndices: [Int]
  public let imageCount: Int
  public let formCount: Int
  public let vectorCount: Int
  public let shadingCount: Int
  public let inlineImageCount: Int
  public let annotationCount: Int
  public let formFieldCount: Int
  public let disclosures: [String]

  public var isApplicable: Bool { refusals.isEmpty }
  public var removalCount: Int { textRunIndices.count + contentRemovalRanges.count }
  public var removesImages: Bool { imageCount > 0 }
  public var removesForms: Bool { formCount > 0 }
  public var removesVectorPaint: Bool { vectorCount > 0 }

  /// Short plan line naming what a reviewed region removes.
  public var summary: String {
    if items.isEmpty { return "Nothing inspectable intersects the reviewed regions." }
    var parts: [String] = []
    if imageCount > 0 { parts.append("\(imageCount) image/scan") }
    if formCount > 0 { parts.append("\(formCount) form XObject") }
    if vectorCount > 0 { parts.append("\(vectorCount) vector paint") }
    if !textRunIndices.isEmpty { parts.append("\(textRunIndices.count) text run(s)") }
    if annotationCount > 0 { parts.append("\(annotationCount) annotation(s)") }
    if formFieldCount > 0 { parts.append("\(formFieldCount) form field(s)") }
    if shadingCount + inlineImageCount > 0 {
      parts.append("\(shadingCount + inlineImageCount) unsupported paint")
    }
    var text = parts.joined(separator: ", ")
    text += refusals.isEmpty ? " removed." : "; \(refusals.count) refusal(s)."
    return text
  }

  init(
    items: [RedactionPaintItem], refusals: [String],
    contentRemovalRanges: [Range<Int>], removedXObjectNames: [String],
    textRunIndices: [Int], imageCount: Int, formCount: Int, vectorCount: Int,
    shadingCount: Int, inlineImageCount: Int, annotationCount: Int,
    formFieldCount: Int, disclosures: [String]
  ) {
    self.items = items
    self.refusals = refusals
    self.contentRemovalRanges = contentRemovalRanges
    self.removedXObjectNames = removedXObjectNames
    self.textRunIndices = textRunIndices
    self.imageCount = imageCount
    self.formCount = formCount
    self.vectorCount = vectorCount
    self.shadingCount = shadingCount
    self.inlineImageCount = inlineImageCount
    self.annotationCount = annotationCount
    self.formFieldCount = formFieldCount
    self.disclosures = disclosures
  }
}

/// RED-04: inspect a page's paint without mutating it. The analyzer tracks the
/// CTM, graphics-state stack, rectangular clipping and the pending path, and
/// resolves XObject resources (including reusable forms) to classify what the
/// reviewed regions cover.
public enum RedactionPaintAnalyzer {
  public static func analyze(
    pageID: PDFObjectID, regions: [[Double]], graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> RedactionPaintAnalysis {
    try analyze(
      pageID: pageID, regions: regions, graph: graph, limits: limits, scope: .allPaint)
  }

  /// Image-only analysis for a text mark over a scan: the visible pixels live
  /// in image draws, so the whole intersecting draw is removed.
  public static func imageDraws(
    pageID: PDFObjectID, regions: [[Double]], graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> RedactionPaintAnalysis {
    try analyze(
      pageID: pageID, regions: regions, graph: graph, limits: limits, scope: .imagesOnly)
  }

  struct State {
    var ctm: [Double] = [1, 0, 0, 1, 0, 0]
    var clip: [Double]?
    var lineWidth: Double = 1
    var fillPattern: Bool = false
    var strokePattern: Bool = false
  }

  static func analyze(
    pageID: PDFObjectID, regions: [[Double]], graph: PDFGraph,
    limits: PDFLimits, scope: RedactionPaintScope
  ) throws -> RedactionPaintAnalysis {
    guard !regions.isEmpty else {
      throw PDFError(.malformed, "Redaction needs at least one region")
    }
    for region in regions { try AnnotationSupport.validateRect(region) }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard content.segments.allSatisfy(\.isEditable) else {
      throw PDFError(
        .unsupported, "This page content uses filters that redaction cannot edit safely")
    }
    let resources = try pageResources(pageID: pageID, in: graph)
    let xobjects = try xobjectEntries(resources: resources, in: graph)

    var items: [RedactionPaintItem] = []
    var refusals: [String] = []
    var removals: [Range<Int>] = []
    var removedNames: Set<PDFName> = []
    var doUses: [PDFName: Int] = [:]
    var inlineImageCount = 0
    var shadingCount = 0
    var refusedRunIndices: Set<Int> = []

    var state = State()
    var stack: [State] = []
    var pathActive = false
    var pathStartByte: Int?
    var pathBounds: [Double]?
    var pathHasStateOps = false
    var pendingClipBounds: [Double]?

    func addRefusal(_ reason: String) {
      if !refusals.contains(reason) { refusals.append(reason) }
    }

    func resetPath() {
      pathActive = false
      pathStartByte = nil
      pathBounds = nil
      pathHasStateOps = false
    }

    func applyPendingClip() {
      guard let pending = pendingClipBounds else { return }
      if let existing = state.clip {
        state.clip = intersection(existing, pending)
      } else {
        state.clip = pending
      }
      pendingClipBounds = nil
    }

    func startPath(_ instruction: ContentInstruction) {
      guard !pathActive else { return }
      pathActive = true
      pathStartByte =
        instruction.operands.first?.span.lowerBound ?? instruction.span.lowerBound
    }

    func markStateChangeInPath() {
      if pathActive { pathHasStateOps = true }
    }

    for instruction in content.instructions.enumerated().map({ ($0.offset, $0.element) }) {
      let operands = numericOperands(instruction.1)
      switch instruction.1.operatorName {
      case "q":
        stack.append(state)
        markStateChangeInPath()
      case "Q":
        if let restored = stack.popLast() { state = restored }
        markStateChangeInPath()
      case "cm":
        if let values = operands, values.count == 6 {
          state.ctm = concatenate(state.ctm, values)
        }
        markStateChangeInPath()
      case "w":
        if let values = operands, let width = values.first { state.lineWidth = width }
        markStateChangeInPath()
      case "gs", "J", "j", "M", "d", "RI", "i":
        markStateChangeInPath()
      case "cs", "CS":
        if case .name(let name)? = instruction.1.operands.first?.value {
          let pattern = String(decoding: name.bytes, as: UTF8.self) == "Pattern"
          if instruction.1.operatorName == "cs" { state.fillPattern = pattern }
          if instruction.1.operatorName == "CS" { state.strokePattern = pattern }
        }
        markStateChangeInPath()
      case "RG", "rg", "G", "g", "K", "k", "SC", "sc", "SCN", "scn":
        markStateChangeInPath()
      case "re":
        if let values = operands, values.count == 4 {
          startPath(instruction.1)
          extend(
            &pathBounds,
            corners: [
              [values[0], values[1]], [values[0] + values[2], values[1]],
              [values[0], values[1] + values[3]],
              [values[0] + values[2], values[1] + values[3]],
            ], ctm: state.ctm)
        }
      case "m", "l":
        if let values = operands, values.count == 2 {
          startPath(instruction.1)
          extend(&pathBounds, corners: [[values[0], values[1]]], ctm: state.ctm)
        }
      case "c":
        if let values = operands, values.count == 6 {
          startPath(instruction.1)
          extend(
            &pathBounds,
            corners: [[values[0], values[1]], [values[2], values[3]], [values[4], values[5]]],
            ctm: state.ctm)
        }
      case "v", "y":
        if let values = operands, values.count == 4 {
          startPath(instruction.1)
          extend(
            &pathBounds, corners: [[values[0], values[1]], [values[2], values[3]]],
            ctm: state.ctm)
        }
      case "h":
        startPath(instruction.1)
      case "W", "W*":
        if let bounds = pathBounds {
          pendingClipBounds = bounds
          if RedactRegionsCommand.intersects(bounds, anyRegion: regions) {
            addRefusal(
              "Redaction intersects a clipping path; the clipped paint cannot be removed "
                + "without changing unrelated content")
            items.append(
              RedactionPaintItem(
                kind: .vectorPaint, bounds: bounds, description: "clipping path",
                isRemovable: false, refusal: "clipping path intersects the region"))
          }
        }
        pathHasStateOps = true
      case "n":
        applyPendingClip()
        resetPath()
      case "f", "F", "f*", "S", "s", "B", "B*", "b", "b*":
        guard var bounds = pathBounds else {
          applyPendingClip()
          resetPath()
          continue
        }
        let strokes = ["S", "s", "B", "B*", "b", "b*"].contains(instruction.1.operatorName)
        let fill = !["S", "s"].contains(instruction.1.operatorName)
        let margin = strokes ? max(state.lineWidth, 1) * 0.5 * ctmScale(state.ctm) : 0
        bounds = [
          bounds[0] - margin, bounds[1] - margin, bounds[2] + margin, bounds[3] + margin,
        ]
        applyPendingClip()
        if let clip = state.clip {
          bounds = intersection(bounds, clip)
        }
        let intersects =
          bounds[0] <= bounds[2] && bounds[1] <= bounds[3]
          && RedactRegionsCommand.intersects(bounds, anyRegion: regions)
        let patterned = (fill && state.fillPattern) || (strokes && state.strokePattern)
        if intersects, scope == .allPaint {
          if patterned {
            addRefusal(
              "Redaction intersects pattern paint; this profile cannot remove a tiled pattern "
                + "safely")
            items.append(
              RedactionPaintItem(
                kind: .vectorPaint, bounds: bounds, description: "pattern paint",
                isRemovable: false, refusal: "pattern paint cannot be removed safely"))
          } else if pathHasStateOps {
            addRefusal(
              "Redaction intersects vector paint whose path interleaves graphics-state changes; "
                + "extend the region to cover a plain painted path or flatten the page")
            items.append(
              RedactionPaintItem(
                kind: .vectorPaint, bounds: bounds, description: "vector paint",
                isRemovable: false, refusal: "path state changes cannot be removed safely"))
          } else if let start = pathStartByte,
            regions.contains(where: { RedactRegionsCommand.contains($0, bounds) })
          {
            removals.append(start..<instruction.1.span.upperBound)
            items.append(
              RedactionPaintItem(
                kind: .vectorPaint, bounds: bounds,
                description: "vector paint (fully covered)", isRemovable: true))
          } else {
            addRefusal(
              "Redaction would partially intersect vector paint; extend the region to cover the "
                + "whole painted path or flatten the page")
            items.append(
              RedactionPaintItem(
                kind: .vectorPaint, bounds: bounds, description: "vector paint (partial)",
                isRemovable: false, refusal: "partial vector intersection"))
          }
        }
        resetPath()
      case "sh":
        shadingCount += 1
        if let clip = state.clip,
          !RedactRegionsCommand.intersects(clip, anyRegion: regions)
        {
          break
        }
        addRefusal(
          "Redaction intersects gradient shading paint; this profile cannot remove a shading "
            + "safely (use a whole-page mark or flatten the page)")
        items.append(
          RedactionPaintItem(
            kind: .shading, bounds: state.clip ?? [0, 0, 0, 0],
            description: "gradient shading", isRemovable: false,
            refusal: "shading cannot be removed safely"))
      case "Do":
        guard case .name(let name)? = instruction.1.operands.first?.value,
          let entry = xobjects[name]
        else { break }
        doUses[name, default: 0] += 1
        guard let stream = resolveStream(entry, in: graph) else { break }
        let subtype = nameString(stream.dictionary[PDFName("Subtype")])
        let resourceName = String(decoding: name.bytes, as: UTF8.self)
        if subtype == "Image" {
          let bounds = transformUnitSquare(ctm: state.ctm, clip: state.clip)
          guard RedactRegionsCommand.intersects(bounds, anyRegion: regions) else { break }
          removals.append(operatorRange(instruction.1))
          removedNames.insert(name)
          items.append(
            RedactionPaintItem(
              kind: .image, bounds: bounds, description: imageDescription(stream),
              isRemovable: true))
        } else if subtype == "Form" {
          let bounds = formPlacementBounds(stream: stream, ctm: state.ctm, clip: state.clip)
          guard RedactRegionsCommand.intersects(bounds, anyRegion: regions) else { break }
          guard scope == .allPaint else {
            addRefusal(
              "The reviewed text sits over reusable form content; a text mark cannot remove "
                + "nested paint. Use a rectangle region over it.")
            items.append(
              RedactionPaintItem(
                kind: .formXObject, bounds: bounds,
                description: "reusable form XObject \(resourceName) (nested)",
                isRemovable: false, refusal: "nested form content"))
            break
          }
          if regions.contains(where: { RedactRegionsCommand.contains($0, bounds) }) {
            removals.append(operatorRange(instruction.1))
            removedNames.insert(name)
            items.append(
              RedactionPaintItem(
                kind: .formXObject, bounds: bounds,
                description: "reusable form XObject \(resourceName) (nested paint)",
                isRemovable: true))
          } else {
            addRefusal(
              "Redaction would partially intersect reusable form content (XObject "
                + "\(resourceName)); extend the region to cover its whole placement or flatten "
                + "the page")
            items.append(
              RedactionPaintItem(
                kind: .formXObject, bounds: bounds,
                description: "reusable form XObject \(resourceName) (partial)",
                isRemovable: false, refusal: "partial form intersection"))
          }
        } else if let subtype {
          let bounds = transformUnitSquare(ctm: state.ctm, clip: state.clip)
          if RedactRegionsCommand.intersects(bounds, anyRegion: regions), scope == .allPaint {
            addRefusal("Redaction intersects an unsupported XObject subtype (\(subtype))")
          }
        }
      case "BI":
        inlineImageCount += 1
        if scope == .allPaint {
          addRefusal(
            "Redaction intersects inline image paint; inline image payloads cannot be inspected "
              + "or removed safely (use a whole-page mark or flatten the page)")
          items.append(
            RedactionPaintItem(
              kind: .inlineImage, bounds: state.clip ?? [0, 0, 0, 0],
              description: "inline image", isRemovable: false,
              refusal: "inline image cannot be removed safely"))
        }
      default:
        break
      }
    }

    // Whole-run text removal: a reviewed region must cover every glyph of the
    // run, matching the conservative region policy.
    var textRunIndices: Set<Int> = []
    if scope == .allPaint {
      let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
      let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
      var runBounds: [Int: [Double]] = [:]
      for cluster in layout.clusters
      where RedactRegionsCommand.intersects(cluster.bounds, anyRegion: regions) {
        textRunIndices.insert(cluster.runIndex)
        runBounds[cluster.runIndex] =
          runBounds[cluster.runIndex].map { union($0, cluster.bounds) } ?? cluster.bounds
      }
      for runIndex in textRunIndices.sorted() {
        let clusters = layout.clusters.filter { $0.runIndex == runIndex }
        let covered = clusters.allSatisfy { cluster in
          regions.contains { RedactRegionsCommand.contains($0, cluster.bounds) }
        }
        if !covered {
          refusedRunIndices.insert(runIndex)
          addRefusal(
            "Redaction would partially intersect a text run; extend the region to cover the "
              + "whole run")
          items.append(
            RedactionPaintItem(
              kind: .text, bounds: runBounds[runIndex] ?? [0, 0, 0, 0],
              description: "text run (partial)", isRemovable: false,
              refusal: "partial text run"))
          continue
        }
        do {
          try validateRun(
            runIndex: runIndex, runs: runs, pageID: pageID, graph: graph)
          items.append(
            RedactionPaintItem(
              kind: .text, bounds: runBounds[runIndex] ?? [0, 0, 0, 0],
              description: "text run", isRemovable: true))
        } catch {
          refusedRunIndices.insert(runIndex)
          addRefusal(error.localizedDescription)
        }
      }
      textRunIndices.subtract(refusedRunIndices)
    }

    // Annotations and fields under the reviewed geometry.
    var annotations = 0
    var fields = 0
    if scope == .allPaint {
      let pageAnnotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
      for annotation in pageAnnotations {
        guard annotation.subtype != PDFName("Widget"),
          let bounds = annotation.bounds,
          RedactRegionsCommand.intersects(bounds, anyRegion: regions)
        else { continue }
        annotations += 1
        if let objectID = annotation.objectID {
          for (id, value) in graph.objects where id != objectID {
            if case .dictionary(let dictionary) = value,
              case .reference(let target)? = dictionary[PDFName("IRT")],
              target == objectID
            {
              addRefusal(
                "Redaction intersects an annotation that has replies; resolve them first")
              break
            }
          }
        }
        items.append(
          RedactionPaintItem(
            kind: .annotation, bounds: bounds, description: "annotation", isRemovable: true))
      }
      fields = try intersectingFieldCount(pageID: pageID, regions: regions, graph: graph)
      if fields > 0 {
        items.append(
          RedactionPaintItem(
            kind: .formField, bounds: [0, 0, 0, 0],
            description: "\(fields) form field(s)", isRemovable: true))
      }
    }

    // Only XObject names whose every page draw is removed may drop their
    // resource entry, so shared or still-painted resources never disappear.
    var removableNames: [String] = []
    for (name, uses) in doUses where uses > 0 && removedNames.contains(name) {
      let remaining = content.instructions.filter { instruction in
        guard instruction.operatorName == "Do",
          case .name(let value)? = instruction.operands.first?.value,
          value == name
        else { return false }
        let range = operatorRange(instruction)
        return !removals.contains { $0.overlaps(range) }
      }.count
      if remaining == 0 {
        removableNames.append(String(decoding: name.bytes, as: UTF8.self))
      }
    }

    var sortedRemovals = removals.sorted { $0.lowerBound < $1.lowerBound }
    // Merge overlapping spans defensively, then require each span to live in a
    // single, non-shared content stream that the rewrite can edit exactly.
    var mergedRemovals: [Range<Int>] = []
    for range in sortedRemovals {
      if let last = mergedRemovals.last, range.lowerBound < last.upperBound {
        mergedRemovals[mergedRemovals.count - 1] =
          last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        mergedRemovals.append(range)
      }
    }
    sortedRemovals = mergedRemovals
    for range in sortedRemovals {
      guard let indices = content.segmentIndices(for: range), indices.count == 1,
        let index = indices.first
      else {
        throw PDFError(
          .unsupported,
          "Redaction removal straddles page content streams; this page cannot be edited safely")
      }
      let objectID = content.segments[index].objectID
      guard content.segments.filter({ $0.objectID == objectID }).count == 1 else {
        throw PDFError(
          .unsupported,
          "This page reuses one content stream more than once; redaction cannot edit it safely")
      }
    }

    let disclosures: [String] = [
      "Whole intersecting image draws are removed, including scanned, masked and decoded images; "
        + "the image object becomes unreachable and the verified full rewrite prunes it.",
      "Reusable form XObject paint is removed only when one reviewed region covers its whole "
        + "placement; partial coverage refuses instead of leaving part of the form painted.",
      "Vector paint is removed only when one reviewed region covers the whole painted path and "
        + "the path does not interleave graphics-state changes.",
      "Inline images, gradient shading, tiling patterns, clipping paths and unsupported XObject "
        + "subtypes refuse rather than leave partial paint behind.",
    ]
    return RedactionPaintAnalysis(
      items: items, refusals: refusals, contentRemovalRanges: sortedRemovals,
      removedXObjectNames: removableNames.sorted(),
      textRunIndices: textRunIndices.sorted(),
      imageCount: items.filter { $0.kind == .image && $0.isRemovable }.count,
      formCount: items.filter { $0.kind == .formXObject && $0.isRemovable }.count,
      vectorCount: items.filter { $0.kind == .vectorPaint && $0.isRemovable }.count,
      shadingCount: shadingCount, inlineImageCount: inlineImageCount,
      annotationCount: annotations, formFieldCount: fields,
      disclosures: disclosures)
  }

  // MARK: Value helpers

  static func numericOperands(_ instruction: ContentInstruction) -> [Double]? {
    var result: [Double] = []
    for operand in instruction.operands {
      switch operand.value {
      case .integer(let value): result.append(Double(value))
      case .real(let value): result.append(value)
      default: return nil
      }
    }
    return result
  }

  static func operatorRange(_ instruction: ContentInstruction) -> Range<Int> {
    let start = instruction.operands.first?.span.lowerBound ?? instruction.span.lowerBound
    return start..<instruction.span.upperBound
  }

  static func nameString(_ value: PDFValue?) -> String? {
    guard case .name(let name)? = value else { return nil }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  static func integerValue(_ value: PDFValue?) -> Int? {
    switch value {
    case .integer(let raw)?: return Int(exactly: raw)
    case .real(let raw)?: return Int(exactly: raw)
    default: return nil
    }
  }

  static func extend(
    _ bounds: inout [Double]?, corners: [[Double]], ctm: [Double]
  ) {
    for point in corners {
      let mapped = [
        ctm[0] * point[0] + ctm[2] * point[1] + ctm[4],
        ctm[1] * point[0] + ctm[3] * point[1] + ctm[5],
      ]
      let rect = [mapped[0], mapped[1], mapped[0], mapped[1]]
      bounds = bounds.map { union($0, rect) } ?? rect
    }
  }

  static func union(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
    [min(lhs[0], rhs[0]), min(lhs[1], rhs[1]), max(lhs[2], rhs[2]), max(lhs[3], rhs[3])]
  }

  static func intersection(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
    [
      max(lhs[0], rhs[0]), max(lhs[1], rhs[1]), min(lhs[2], rhs[2]), min(lhs[3], rhs[3]),
    ]
  }

  static func concatenate(_ a: [Double], _ b: [Double]) -> [Double] {
    [
      a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
      a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
      a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5],
    ]
  }

  static func ctmScale(_ ctm: [Double]) -> Double {
    let determinant = ctm[0] * ctm[3] - ctm[1] * ctm[2]
    return max(sqrt(abs(determinant)), 0.01)
  }

  static func transformUnitSquare(ctm: [Double], clip: [Double]?) -> [Double] {
    var bounds = transformBox([0, 0, 1, 1], ctm: ctm)
    if let clip { bounds = intersection(bounds, clip) }
    return bounds
  }

  static func transformBox(_ box: [Double], ctm: [Double]) -> [Double] {
    guard box.count == 4 else { return [0, 0, 0, 0] }
    let corners: [[Double]] = [
      [box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]],
    ].map { point in
      [ctm[0] * point[0] + ctm[2] * point[1] + ctm[4],
       ctm[1] * point[0] + ctm[3] * point[1] + ctm[5]]
    }
    return [
      corners.map { $0[0] }.min() ?? 0, corners.map { $0[1] }.min() ?? 0,
      corners.map { $0[0] }.max() ?? 0, corners.map { $0[1] }.max() ?? 0,
    ]
  }

  static func formPlacementBounds(
    stream: PDFStream, ctm: [Double], clip: [Double]?
  ) -> [Double] {
    var effective = ctm
    if case .array(let matrix)? = stream.dictionary[PDFName("Matrix")] {
      let values = matrix.compactMap { value -> Double? in
        switch value {
        case .integer(let raw): return Double(raw)
        case .real(let raw): return raw
        default: return nil
        }
      }
      if values.count == 6 { effective = concatenate(effective, values) }
    }
    var box: [Double] = [0, 0, 1, 1]
    if case .array(let values)? = stream.dictionary[PDFName("BBox")] {
      let numbers = values.compactMap { value -> Double? in
        switch value {
        case .integer(let raw): return Double(raw)
        case .real(let raw): return raw
        default: return nil
        }
      }
      if numbers.count == 4 { box = numbers }
    }
    var bounds = transformBox(box, ctm: effective)
    if let clip { bounds = intersection(bounds, clip) }
    return bounds
  }

  static func imageDescription(_ stream: PDFStream) -> String {
    let width = integerValue(stream.dictionary[PDFName("Width")]) ?? 0
    let height = integerValue(stream.dictionary[PDFName("Height")]) ?? 0
    let masked =
      stream.dictionary[PDFName("SMask")] != nil
      || stream.dictionary[PDFName("Mask")] != nil
      || stream.dictionary[PDFName("ImageMask")] != nil
      || stream.dictionary[PDFName("Decode")] != nil
    var description = "image \(width)x\(height)"
    if masked { description += " (masked/scanned)" }
    return description
  }

  static func pageResources(
    pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> [PDFName: PDFValue] {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    for _ in 0..<64 {
      switch page[PDFName("Resources")] {
      case .dictionary(let resources)?:
        return resources
      case .reference(let id)?:
        if case .dictionary(let resources)? = graph.objects[id] { return resources }
        return [:]
      case nil, .null?:
        guard case .reference(let parentID)? = page[PDFName("Parent")],
          case .dictionary(let parent)? = graph.objects[parentID]
        else { return [:] }
        page = parent
      default:
        return [:]
      }
    }
    return [:]
  }

  static func xobjectEntries(
    resources: [PDFName: PDFValue], in graph: PDFGraph
  ) throws -> [PDFName: PDFValue] {
    guard let value = resources[PDFName("XObject")] else { return [:] }
    switch value {
    case .dictionary(let entries): return entries
    case .reference(let id):
      if case .dictionary(let entries)? = graph.objects[id] { return entries }
      return [:]
    default:
      return [:]
    }
  }

  static func resolveStream(_ value: PDFValue, in graph: PDFGraph) -> PDFStream? {
    switch value {
    case .stream(let stream): return stream
    case .reference(let id):
      if case .stream(let stream)? = graph.objects[id] { return stream }
      return nil
    default: return nil
    }
  }

  static func validateRun(
    runIndex: Int, runs: [TextRun], pageID: PDFObjectID, graph: PDFGraph
  ) throws {
    guard runs.indices.contains(runIndex) else {
      throw PDFError(.malformed, "A reviewed text run is missing from the page")
    }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let run = runs[runIndex]
    guard let font = SimpleFont.resolve(
      resource: run.fontResource, page: page, in: graph)
    else {
      throw PDFError(
        .unsupported,
        "Redaction refuses: the page contains text in a font this profile cannot inspect")
    }
    guard font.isSupported else {
      throw PDFError(
        .unsupported,
        "Redaction refuses: the page contains text in a font this profile cannot inspect")
    }
    guard !font.isType3 else {
      throw PDFError(
        .unsupported,
        "Redaction refuses: Type 3 glyph programs can paint beyond their text bounds")
    }
    try ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: "")
      .validate(in: graph)
  }

  static func intersectingFieldCount(
    pageID: PDFObjectID, regions: [[Double]], graph: PDFGraph
  ) throws -> Int {
    let pageIDs = try PageTreeView(graph: graph).pages
    guard let pageIndex = pageIDs.firstIndex(of: pageID) else { return 0 }
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    return fields.filter { field in
      field.widgets.contains { widget in
        widget.pageIndex == pageIndex
          && (widget.rect.map { RedactRegionsCommand.intersects($0, anyRegion: regions) }
            ?? false)
      }
    }.count
  }
}

// MARK: - RED-04 apply command

/// RED-04: region redaction with the broadened supported paint profile.
///
/// It performs removal only. The RED-03 overlay is painted by a separate step,
/// so paint and removal never blur together. Supported: whole intersecting
/// image draws (including masked/scanned images), whole reusable-form
/// invocations covered by one region, fully covered vector paint paths, whole
/// text runs, intersecting annotations/fields and the generated OCR layer.
/// Anything the profile cannot isolate refuses before mutation with a reason.
public struct RedactPaintRegionsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let regions: [[Double]]
  public let scope: RedactionPaintScope

  public init(
    pageID: PDFObjectID, regions: [[Double]], scope: RedactionPaintScope = .allPaint
  ) {
    self.pageID = pageID
    self.regions = regions
    self.scope = scope
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Redact Painted Regions" }
  public var requiresFullRewriteOnSave: Bool { true }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    let analysis = try RedactionPaintAnalyzer.analyze(
      pageID: pageID, regions: regions, graph: graph, limits: PDFLimits(), scope: scope)
    guard analysis.refusals.isEmpty else {
      throw PDFError(.unsupported, analysis.refusals.joined(separator: " "))
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = try PageContentCopy.makePrivate(
      pageID: pageID, in: graph, limits: PDFLimits())
    var analysis = try RedactionPaintAnalyzer.analyze(
      pageID: pageID, regions: regions, graph: graph, limits: PDFLimits(), scope: scope)
    guard analysis.refusals.isEmpty else {
      throw PDFError(.unsupported, analysis.refusals.joined(separator: " "))
    }
    // 1. Whole text runs first: run indices are stable across paint removal.
    if scope == .allPaint {
      for runIndex in analysis.textRunIndices.sorted(by: >) {
        graph = try ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: "")
          .apply(to: graph)
      }
      // Re-analyze so content byte ranges match the text-edited streams.
      analysis = try RedactionPaintAnalyzer.analyze(
        pageID: pageID, regions: regions, graph: graph, limits: PDFLimits(), scope: scope)
      guard analysis.refusals.isEmpty else {
        throw PDFError(.unsupported, analysis.refusals.joined(separator: " "))
      }
    }
    // 2. Remove whole paint units from the page content.
    if !analysis.contentRemovalRanges.isEmpty {
      let content = try PageContent.load(pageID: pageID, in: graph, limits: PDFLimits())
      let ranges = analysis.contentRemovalRanges.map {
        (range: $0, replacement: [UInt8]())
      }
      graph = try content.replacing(ranges: ranges, in: graph, limits: PDFLimits())
    }
    // 3. Drop resource entries whose every draw is gone so the objects become
    // unreachable for the verified full rewrite.
    graph = try Self.removeUnusedXObjectResources(
      names: Set(analysis.removedXObjectNames.map { PDFName($0) }),
      pageID: pageID, in: graph, limits: PDFLimits())
    if scope == .allPaint {
      graph = try Self.removeIntersectingAnnotations(
        pageID: pageID, rects: regions, in: graph)
      graph = try RedactRegionsCommand(pageID: pageID, regions: regions)
        .removeIntersectingFields(in: graph)
      try OCRLayer.removeLayer(pageID: pageID, in: &graph)
      let allPages = try PDFPageTree.pageIDs(in: graph)
      graph = try PDFStructureRepair.pruneRemovedContent(in: graph, pageIDs: allPages).graph
    }
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
    return graph
  }

  /// Drop page XObject resource entries whose last draw was removed, copying a
  /// shared resource dictionary first so other pages are untouched.
  static func removeUnusedXObjectResources(
    names: Set<PDFName>, pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits
  ) throws -> PDFGraph {
    guard !names.isEmpty else { return graph }
    var graph = graph
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    var used: Set<PDFName> = []
    for instruction in content.instructions where instruction.operatorName == "Do" {
      if case .name(let name)? = instruction.operands.first?.value { used.insert(name) }
    }
    guard case .dictionary(var page)? = graph.objects[pageID] else { return graph }
    func pruned(_ resources: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
      var resources = resources
      guard case .dictionary(var xobjects)? = resources[PDFName("XObject")] else {
        return resources
      }
      for name in names where !used.contains(name) { xobjects[name] = nil }
      if xobjects.isEmpty {
        resources.removeValue(forKey: PDFName("XObject"))
      } else {
        resources[PDFName("XObject")] = .dictionary(xobjects)
      }
      return resources
    }
    switch page[PDFName("Resources")] {
    case .dictionary(let resources)?:
      page[PDFName("Resources")] = .dictionary(pruned(resources))
    case .reference(let resourcesID)?:
      guard case .dictionary(let shared)? = graph.objects[resourcesID] else { return graph }
      // Copy-on-write: the shared object stays for other pages.
      page[PDFName("Resources")] = .dictionary(pruned(shared))
    default:
      return graph
    }
    graph.objects[pageID] = .dictionary(page)
    return graph
  }

  static func removeIntersectingAnnotations(
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
