import Foundation
import PDFCore

/// IMG-02: complete enclosing path for one image draw, including every Form
/// XObject that must be copied before the draw's local matrix or image
/// resource can be edited in isolation.
///
/// A Form XObject is a reusable object: several page-level draws (or several
/// forms, or several pages) may execute the same form stream. Rewriting the
/// form stream in place would move or replace every instance. The isolation
/// engine therefore copies the whole form chain for the target instance and
/// gives the target a fresh resource name at every level, leaving the original
/// form objects and their other instances byte-identical.
public struct ImageInstancePath: Sendable, Equatable {
  /// One Form XObject on the path from the page to the draw, outermost first.
  public struct FormStep: Sendable, Equatable {
    /// The original (shared) form object that must be copied.
    public let formObjectID: PDFObjectID
    /// Resource name by which the parent content stream addresses the form.
    public let resourceNameInParent: PDFName
    /// Index of the form's `Do` instruction inside the parent content stream.
    public let drawInstructionIndex: Int
    /// Resources in effect for the form's own content (own or inherited).
    public let effectiveResources: [PDFName: PDFValue]

    public init(
      formObjectID: PDFObjectID, resourceNameInParent: PDFName,
      drawInstructionIndex: Int, effectiveResources: [PDFName: PDFValue]
    ) {
      self.formObjectID = formObjectID
      self.resourceNameInParent = resourceNameInParent
      self.drawInstructionIndex = drawInstructionIndex
      self.effectiveResources = effectiveResources
    }
  }

  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let steps: [FormStep]
  public let imageID: PDFObjectID
  public let resourceName: PDFName
  /// Index of the image `Do` instruction in the innermost content stream.
  public let instructionIndex: Int
  /// The `cm` operands immediately before the image draw.
  public let localMatrix: [Double]
  /// Page-space transform active before those local operands.
  public let outerMatrix: [Double]
  /// Complete page-space placement after all enclosing transforms.
  public let matrix: [Double]
  public let bounds: [Double]
  public let depth: Int
  /// Nil when the draw uses the supported `q <matrix> cm /Name Do Q` pattern;
  /// otherwise the exact reason the instance cannot be transformed safely.
  public let refusal: String?

  public var isNested: Bool { depth > 0 }
  public var isDirectlyTransformable: Bool { refusal == nil }

  public init(
    pageID: PDFObjectID, placementIndex: Int, steps: [FormStep],
    imageID: PDFObjectID, resourceName: PDFName, instructionIndex: Int,
    localMatrix: [Double], outerMatrix: [Double], matrix: [Double],
    bounds: [Double], depth: Int, refusal: String?
  ) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.steps = steps
    self.imageID = imageID
    self.resourceName = resourceName
    self.instructionIndex = instructionIndex
    self.localMatrix = localMatrix
    self.outerMatrix = outerMatrix
    self.matrix = matrix
    self.bounds = bounds
    self.depth = depth
    self.refusal = refusal
  }
}

/// IMG-02: resolve the enclosing matrix chain and the exact editing pattern for
/// one placement. Placement indices are the same stable, top-to-bottom order
/// produced by `ImageInventory.placements`; this resolver validates that order
/// against the shared inventory before returning edit instructions.
public enum ImageInstanceEditingSupport {
  public static func resolve(
    pageID: PDFObjectID, placementIndex: Int, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> ImageInstancePath {
    let placements = try ImageInventory.placements(in: graph, pageID: pageID, limits: limits)
    guard placementIndex >= 0, placementIndex < placements.count else {
      throw PDFError(.malformed, "Image placement index is outside the page")
    }
    let expected = placements[placementIndex]
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let pageResources = resourceDictionary(page[PDFName("Resources")], in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    var collector = CandidateCollector(
      pageID: pageID, graph: graph, limits: limits)
    try collector.walk(
      instructions: content.instructions, resources: pageResources,
      transform: [1, 0, 0, 1, 0, 0], depth: 0, chain: [], visited: [])
    guard collector.candidates.count == placements.count,
      collector.candidates.indices.contains(placementIndex)
    else {
      throw PDFError(
        .malformed, "The image inventory and the enclosing-matrix resolver disagree")
    }
    let candidate = collector.candidates[placementIndex]
    guard candidate.imageID == expected.imageID,
      candidate.depth == expected.depth,
      approxEqual(candidate.matrix, expected.matrix),
      approxEqual(candidate.bounds, expected.bounds)
    else {
      throw PDFError(
        .malformed, "The image inventory and the enclosing-matrix resolver disagree")
    }
    return ImageInstancePath(
      pageID: pageID, placementIndex: placementIndex, steps: candidate.chain,
      imageID: candidate.imageID, resourceName: candidate.resourceName,
      instructionIndex: candidate.instructionIndex,
      localMatrix: candidate.localMatrix, outerMatrix: candidate.outerMatrix,
      matrix: candidate.matrix, bounds: candidate.bounds,
      depth: candidate.depth, refusal: candidate.refusal)
  }

  private struct Candidate {
    let imageID: PDFObjectID
    let resourceName: PDFName
    let instructionIndex: Int
    let localMatrix: [Double]
    let outerMatrix: [Double]
    let matrix: [Double]
    let bounds: [Double]
    let depth: Int
    let chain: [ImageInstancePath.FormStep]
    let refusal: String?
  }

  private struct CandidateCollector {
    let pageID: PDFObjectID
    let graph: PDFGraph
    let limits: PDFLimits
    var candidates: [Candidate] = []

    mutating func walk(
      instructions: [ContentInstruction], resources: [PDFName: PDFValue]?,
      transform initial: [Double], depth: Int,
      chain: [ImageInstancePath.FormStep], visited: Set<PDFObjectID>
    ) throws {
      var transform = initial
      var lastCMOuter: [Double]?
      var lastCMIndex: Int?
      var lastCMOperands: [Double]?
      for (index, instruction) in instructions.enumerated() {
        try Task.checkCancellation()
        switch instruction.operatorName {
        case "cm":
          guard instruction.operands.count == 6 else { continue }
          let values = instruction.operands.compactMap { number(of: $0.value) }
          guard values.count == 6 else { continue }
          lastCMOuter = transform
          lastCMIndex = index
          lastCMOperands = values
          transform = concat(transform, values)
        case "Do":
          guard case .name(let name)? = instruction.operands.first?.value,
            let xobjects = xobjects(in: resources, in: graph),
            case .reference(let objectID)? = xobjects[name],
            case .stream(let stream)? = graph.objects[objectID]
          else { continue }
          let subtype = stream.dictionary[PDFName("Subtype")]
          if subtype == .name(PDFName("Image")) {
            var local = transform
            var outer = [1.0, 0, 0, 1, 0, 0]
            var pattern = false
            if let lastCMIndex, lastCMIndex == index - 1,
              let lastCMOuter, let lastCMOperands
            {
              local = lastCMOperands
              outer = lastCMOuter
              pattern = index >= 2
                && instructions[index - 2].operatorName == "q"
                && index + 1 < instructions.count
                && instructions[index + 1].operatorName == "Q"
            }
            let refusal: String?
            if !pattern {
              refusal = "This image draw does not use the supported q <matrix> cm /Name Do Q pattern in its content stream; editing it needs an isolated local transform"
            } else if !isInvertible(outer) {
              refusal = "The image has a singular enclosing transform"
            } else {
              refusal = nil
            }
            candidates.append(
              Candidate(
                imageID: objectID, resourceName: name, instructionIndex: index,
                localMatrix: local, outerMatrix: outer,
                matrix: concat(outer, local), bounds: ImageInventory.bounds(of: concat(outer, local)),
                depth: depth, chain: chain, refusal: refusal))
            continue
          }
          guard subtype == .name(PDFName("Form")) else { continue }
          guard depth < limits.nesting else {
            throw PDFError(.limitExceeded, "Form XObject nesting exceeds the configured limit")
          }
          guard !visited.contains(objectID) else {
            throw PDFError(.malformed, "Form XObject cycle detected")
          }
          let decoded = [UInt8](try PDFFilters.decoded(stream, limits: limits))
          let childInstructions = try ContentParser.instructions(in: decoded, limits: limits)
          var childResources = resources
          if case .dictionary(let formResources)? = FontValue.resolve(
            stream.dictionary[PDFName("Resources")], in: graph)
          {
            childResources = formResources
          }
          var formMatrix: [Double] = [1, 0, 0, 1, 0, 0]
          if case .array(let values)? = stream.dictionary[PDFName("Matrix")],
            values.count == 6
          {
            let parsed = values.compactMap { number(of: $0) }
            if parsed.count == 6 { formMatrix = parsed }
          }
          var childVisited = visited
          childVisited.insert(objectID)
          var childChain = chain
          childChain.append(
            ImageInstancePath.FormStep(
              formObjectID: objectID, resourceNameInParent: name,
              drawInstructionIndex: index,
              effectiveResources: childResources ?? [:]))
          try walk(
            instructions: childInstructions, resources: childResources,
            transform: concat(transform, formMatrix), depth: depth + 1,
            chain: childChain, visited: childVisited)
        default:
          break
        }
      }
    }
  }

  static func resourceDictionary(
    _ value: PDFValue?, in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
      return dictionary
    default:
      return nil
    }
  }

  static func xobjects(
    in resources: [PDFName: PDFValue]?, in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    guard let resources, let value = resources[PDFName("XObject")] else { return nil }
    return resourceDictionary(value, in: graph)
  }

  static func number(of value: PDFValue) -> Double? {
    switch value {
    case .integer(let raw): return Double(raw)
    case .real(let raw): return raw
    default: return nil
    }
  }

  static func concat(_ first: [Double], _ second: [Double]) -> [Double] {
    guard first.count == 6, second.count == 6 else { return [1, 0, 0, 1, 0, 0] }
    return [
      first[0] * second[0] + first[2] * second[1],
      first[1] * second[0] + first[3] * second[1],
      first[0] * second[2] + first[2] * second[3],
      first[1] * second[2] + first[3] * second[3],
      first[0] * second[4] + first[2] * second[5] + first[4],
      first[1] * second[4] + first[3] * second[5] + first[5],
    ]
  }

  static func invert(_ matrix: [Double]) -> [Double]? {
    guard matrix.count == 6, matrix.allSatisfy(\.isFinite) else { return nil }
    let determinant = matrix[0] * matrix[3] - matrix[1] * matrix[2]
    guard determinant.isFinite, abs(determinant) > 1e-9 else { return nil }
    let inverse = [
      matrix[3] / determinant,
      -matrix[1] / determinant,
      -matrix[2] / determinant,
      matrix[0] / determinant,
      0.0,
      0.0,
    ]
    let e = -(inverse[0] * matrix[4] + inverse[2] * matrix[5])
    let f = -(inverse[1] * matrix[4] + inverse[3] * matrix[5])
    guard (inverse[0...3] + [e, f]).allSatisfy(\.isFinite) else { return nil }
    return [inverse[0], inverse[1], inverse[2], inverse[3], e, f]
  }

  static func isInvertible(_ matrix: [Double]) -> Bool { invert(matrix) != nil }

  static func approxEqual(_ first: [Double], _ second: [Double]) -> Bool {
    first.count == second.count
      && zip(first, second).allSatisfy { abs($0 - $1) <= 1e-6 }
  }
}

/// IMG-02: one isolated (copy-on-write) image instance ready for content
/// surgery. `baseGraph` has private page content streams and, for nested
/// draws, a fresh form chain reachable only from this placement.
struct IsolatedImageInstance {
  var graph: PDFGraph
  let path: ImageInstancePath
  /// Innermost copied form whose content stream contains the image draw.
  let targetFormID: PDFObjectID?
  /// Image draw instruction index inside the innermost content stream.
  let targetInstructionIndex: Int

  var targetContentIsPage: Bool { targetFormID == nil }
}

/// IMG-02: copy-on-write isolation for an image instance. It never edits an
/// object reachable from an unselected instance:
///
/// * page content streams shared with another page are copied first
///   (`PageContentCopy.makePrivate`);
/// * every enclosing Form XObject is copied and the parent draw is repointed
///   through a fresh resource name, so other draws/pages keep the original
///   form and resource mapping;
/// * resources dictionaries that need a new mapping are copied, not mutated
///   in place.
enum ImageInstanceIsolation {
  static func isolate(_ path: ImageInstancePath, in graph: PDFGraph) throws -> IsolatedImageInstance {
    guard path.isDirectlyTransformable else {
      throw PDFError(.unsupported, path.refusal ?? "This image instance cannot be edited safely")
    }
    var graph = try PageContentCopy.makePrivate(pageID: path.pageID, in: graph)
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    func allocate() -> PDFObjectID {
      let id = PDFObjectID(nextNumber)
      nextNumber += 1
      return id
    }
    var parentFormID: PDFObjectID?
    for (level, step) in path.steps.enumerated() {
      guard case .stream(let original)? = graph.objects[step.formObjectID] else {
        throw PDFError(.malformed, "A form XObject on the image path is missing")
      }
      guard case .dictionary(let page)? = graph.objects[path.pageID] else {
        throw PDFError(.malformed, "Page is missing")
      }
      let currentParentResources: [PDFName: PDFValue]?
      if level == 0 {
        currentParentResources = ImageInstanceEditingSupport.resourceDictionary(
          page[PDFName("Resources")], in: graph)
      } else if let parentFormID,
        case .stream(let parentStream)? = graph.objects[parentFormID]
      {
        currentParentResources = ImageInstanceEditingSupport.resourceDictionary(
          parentStream.dictionary[PDFName("Resources")], in: graph)
      } else {
        throw PDFError(.malformed, "A parent form XObject on the image path is missing")
      }
      let existingNames = Set(
        (ImageInstanceEditingSupport.xobjects(in: currentParentResources, in: graph) ?? [:]).keys)
      let freshName = uniqueResourceName(
        base: step.resourceNameInParent, existing: existingNames)
      let decoded = [UInt8](try PDFFilters.decoded(original))
      var dictionary = original.dictionary
      dictionary.removeValue(forKey: PDFName("Filter"))
      dictionary.removeValue(forKey: PDFName("DecodeParms"))
      dictionary.removeValue(forKey: PDFName("DP"))
      dictionary[PDFName("Length")] = .integer(Int64(decoded.count))
      dictionary[PDFName("Resources")] = .dictionary(step.effectiveResources)
      let newFormID = allocate()
      graph.objects[newFormID] = .stream(PDFStream(dictionary: dictionary, bytes: Data(decoded)))
      try repointParent(
        level: level, pageID: path.pageID, parentFormID: parentFormID,
        drawInstructionIndex: step.drawInstructionIndex, freshName: freshName,
        childFormID: newFormID, in: &graph)
      parentFormID = newFormID
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return IsolatedImageInstance(
      graph: graph, path: path, targetFormID: parentFormID,
      targetInstructionIndex: path.instructionIndex)
  }

  /// Add the copied form under a fresh resource name in the parent's resource
  /// dictionary and rewrite only the target parent draw to use that name.
  private static func repointParent(
    level: Int, pageID: PDFObjectID, parentFormID: PDFObjectID?,
    drawInstructionIndex: Int, freshName: PDFName, childFormID: PDFObjectID,
    in graph: inout PDFGraph
  ) throws {
    if level == 0 {
      try addPageXObject(
        pageID: pageID, name: freshName, objectID: childFormID, in: &graph)
      let content = try PageContent.load(pageID: pageID, in: graph)
      guard content.instructions.indices.contains(drawInstructionIndex) else {
        throw PDFError(.malformed, "The enclosing form draw is missing")
      }
      try rewriteDoOperand(
        content.instructions[drawInstructionIndex], name: freshName, in: &graph, pageID: pageID)
    } else {
      guard let parentFormID,
        case .stream(var parentStream)? = graph.objects[parentFormID]
      else {
        throw PDFError(.malformed, "A parent form XObject on the image path is missing")
      }
      var resources = ImageInstanceEditingSupport.resourceDictionary(
        parentStream.dictionary[PDFName("Resources")], in: graph) ?? [:]
      addXObjectMapping(&resources, name: freshName, objectID: childFormID)
      parentStream.dictionary[PDFName("Resources")] = .dictionary(resources)
      var bytes = [UInt8](parentStream.bytes)
      let instructions = try ContentParser.instructions(in: bytes)
      guard instructions.indices.contains(drawInstructionIndex),
        instructions[drawInstructionIndex].operatorName == "Do"
      else {
        throw PDFError(.malformed, "The enclosing form draw is missing")
      }
      guard let operand = instructions[drawInstructionIndex].operands.first,
        case .name = operand.value
      else {
        throw PDFError(.malformed, "The enclosing form draw lost its resource operand")
      }
      let nameBytes = Array(("/" + String(decoding: freshName.bytes, as: UTF8.self)).utf8)
      bytes.replaceSubrange(operand.span, with: nameBytes)
      parentStream.bytes = Data(bytes)
      parentStream.dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
      graph.objects[parentFormID] = .stream(parentStream)
    }
  }

  private static func rewriteDoOperand(
    _ instruction: ContentInstruction, name: PDFName, in graph: inout PDFGraph,
    pageID: PDFObjectID
  ) throws {
    guard instruction.operatorName == "Do",
      let operand = instruction.operands.first, case .name = operand.value
    else {
      throw PDFError(.malformed, "The enclosing form draw lost its resource operand")
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    let nameBytes = Array(("/" + String(decoding: name.bytes, as: UTF8.self)).utf8)
    graph = try content.replacing(range: operand.span, with: nameBytes, in: graph)
  }

  static func addPageXObject(
    pageID: PDFObjectID, name: PDFName, objectID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let original = page[PDFName("Resources")]
    var resources = ImageInstanceEditingSupport.resourceDictionary(original, in: graph) ?? [:]
    addXObjectMapping(&resources, name: name, objectID: objectID)
    switch original {
    case .reference?:
      guard let resourcesID = nextObjectID(in: graph) else {
        throw PDFError(.limitExceeded, "No object identifier is available for page resources")
      }
      graph.objects[resourcesID] = .dictionary(resources)
      page[PDFName("Resources")] = .reference(resourcesID)
    default:
      page[PDFName("Resources")] = .dictionary(resources)
    }
    graph.objects[pageID] = .dictionary(page)
  }

  static func addFormXObject(
    formID: PDFObjectID, name: PDFName, objectID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .stream(var stream)? = graph.objects[formID] else {
      throw PDFError(.malformed, "The enclosing form XObject is missing")
    }
    var resources = ImageInstanceEditingSupport.resourceDictionary(
      stream.dictionary[PDFName("Resources")], in: graph) ?? [:]
    addXObjectMapping(&resources, name: name, objectID: objectID)
    stream.dictionary[PDFName("Resources")] = .dictionary(resources)
    graph.objects[formID] = .stream(stream)
  }

  static func addXObjectMapping(
    _ resources: inout [PDFName: PDFValue], name: PDFName, objectID: PDFObjectID
  ) {
    var entries: [PDFName: PDFValue] = [:]
    if case .dictionary(let direct)? = resources[PDFName("XObject")] {
      entries = direct
    }
    entries[name] = .reference(objectID)
    resources[PDFName("XObject")] = .dictionary(entries)
  }

  static func uniqueResourceName(base: PDFName, existing: Set<PDFName>) -> PDFName {
    var counter = 1
    while true {
      let candidate = PDFName(bytes: base.bytes + Array("-i\(counter)".utf8))
      if !existing.contains(candidate) { return candidate }
      counter += 1
    }
  }

  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID? {
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    return next > 0 ? PDFObjectID(next) : nil
  }
}

/// IMG-02: geometry edit applied to one image instance, page-level or nested.
/// Move and rotation use page-space numbers; scale keeps the existing profile
/// (positive axis-aligned enclosing scale, unrotated local matrix).
public enum ImageInstanceTransform: Sendable, Equatable {
  case move(dx: Double, dy: Double)
  case scale(scaleX: Double, scaleY: Double)
  case rotate(degrees: Int)
  case flip(horizontal: Bool)
}

/// IMG-02: transform one image placement through its complete enclosing
/// matrix chain. For a nested draw the form chain is copied first, so only the
/// selected visible instance changes; other draws of the same form and other
/// pages keep the original bytes. The clip is untouched: the command rewrites
/// only the local `cm` operands inside the instance's `q … Do … Q` block.
public struct TransformImageInstanceCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let transform: ImageInstanceTransform

  public init(pageID: PDFObjectID, placementIndex: Int, transform: ImageInstanceTransform) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.transform = transform
  }

  public var name: String {
    switch transform {
    case .move: return "Move Image"
    case .scale: return "Resize Image"
    case .rotate: return "Rotate Image"
    case .flip: return "Flip Image"
    }
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolvedTarget(in: graph)
  }

  private func resolvedTarget(in graph: PDFGraph) throws -> (
    path: ImageInstancePath, local: [Double]
  ) {
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    _ = try ImageInstanceTransformMath.localMatrix(for: transform, path: path)
    return (path, [])
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    let local = try ImageInstanceTransformMath.localMatrix(for: transform, path: path)
    var isolated = try ImageInstanceIsolation.isolate(path, in: graph)
    let instructionIndex = isolated.targetInstructionIndex
    let tokens = local.map(ImageInventory.numberToken)
    var ranges: [(range: Range<Int>, replacement: [UInt8])] = []
    if isolated.targetContentIsPage {
      let content = try PageContent.load(pageID: pageID, in: isolated.graph)
      guard instructionIndex >= 1, instructionIndex < content.instructions.count,
        content.instructions[instructionIndex - 1].operatorName == "cm"
      else {
        throw PDFError(.malformed, "The image draw lost its local matrix")
      }
      let spans = content.instructions[instructionIndex - 1].operands.map(\.span)
      guard spans.count == 6 else {
        throw PDFError(.malformed, "The image draw lost its local matrix")
      }
      ranges = zip(spans, tokens).map { ($0.0, Array($0.1.utf8)) }
      isolated.graph = try content.replacing(ranges: ranges, in: isolated.graph)
    } else {
      guard let formID = isolated.targetFormID,
        case .stream(var stream)? = isolated.graph.objects[formID]
      else {
        throw PDFError(.malformed, "The isolated form XObject is missing")
      }
      var bytes = [UInt8](stream.bytes)
      let instructions = try ContentParser.instructions(in: bytes)
      guard instructionIndex >= 1, instructionIndex < instructions.count,
        instructions[instructionIndex - 1].operatorName == "cm",
        instructions[instructionIndex - 1].operands.count == 6
      else {
        throw PDFError(.malformed, "The image draw lost its local matrix")
      }
      ranges = zip(instructions[instructionIndex - 1].operands.map(\.span), tokens).map {
        ($0.0, Array($0.1.utf8))
      }
      for entry in ranges.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        bytes.replaceSubrange(entry.range, with: entry.replacement)
      }
      stream.bytes = Data(bytes)
      stream.dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
      isolated.graph.objects[formID] = .stream(stream)
    }
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &isolated.graph)
    try ImageInstanceTransformMath.verify(
      path: path, local: local, in: isolated.graph)
    return isolated.graph
  }
}

enum ImageInstanceTransformMath {
  static func localMatrix(
    for transform: ImageInstanceTransform, path: ImageInstancePath
  ) throws -> [Double] {
    guard path.refusal == nil else {
      throw PDFError(.unsupported, path.refusal ?? "This image instance cannot be edited safely")
    }
    switch transform {
    case .move(let dx, let dy):
      guard dx.isFinite, dy.isFinite else {
        throw PDFError(.malformed, "Image movement must be finite")
      }
      guard let inverseOuter = ImageInstanceEditingSupport.invert(path.outerMatrix) else {
        throw PDFError(.unsupported, "The image has a singular enclosing transform")
      }
      var local = path.localMatrix
      local[4] += inverseOuter[0] * dx + inverseOuter[2] * dy
      local[5] += inverseOuter[1] * dx + inverseOuter[3] * dy
      guard local.allSatisfy(\.isFinite) else {
        throw PDFError(.unsupported, "The image movement is outside the supported numeric range")
      }
      return local
    case .scale(let scaleX, let scaleY):
      guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
        throw PDFError(.malformed, "Image scale factors must be positive finite numbers")
      }
      guard abs(path.localMatrix[1]) < 1e-9, abs(path.localMatrix[2]) < 1e-9 else {
        throw PDFError(
          .unsupported, "Resizing a rotated local image matrix needs a corner-specific transform")
      }
      guard ImageInventory.canvasSafeOuter(path.outerMatrix) else {
        throw PDFError(
          .unsupported,
          "Resizing an image inside a rotated or sheared enclosing transform needs a corner-specific transform")
      }
      var local = path.localMatrix
      local[0] *= scaleX
      local[3] *= scaleY
      guard local.allSatisfy(\.isFinite) else {
        throw PDFError(.unsupported, "The image scale is outside the supported numeric range")
      }
      return local
    case .rotate(let degrees):
      guard degrees % 90 == 0 else {
        throw PDFError(.malformed, "Image rotation must be a multiple of 90 degrees")
      }
      let rotation: [Double]
      switch ((degrees % 360) + 360) % 360 {
      case 0: rotation = [1, 0, 0, 1, 0, 0]
      case 90: rotation = [0, 1, -1, 0, 0, 0]
      case 180: rotation = [-1, 0, 0, -1, 0, 0]
      default: rotation = [0, -1, 1, 0, 0, 0]
      }
      let matrix = path.matrix
      let localAxes = [matrix[0], matrix[1], matrix[2], matrix[3], 0, 0]
      let rotated = ImageInstanceEditingSupport.concat(rotation, localAxes)
      let bounds = ImageInventory.bounds(of: matrix)
      let center = [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2]
      let e = center[0] - (rotated[0] + rotated[2]) / 2
      let f = center[1] - (rotated[1] + rotated[3]) / 2
      return try composePageSpace(
        desiredPage: [rotated[0], rotated[1], rotated[2], rotated[3], e, f], path: path)
    case .flip(let horizontal):
      let mirror: [Double] = horizontal ? [-1, 0, 0, 1, 0, 0] : [1, 0, 0, -1, 0, 0]
      let matrix = path.matrix
      let localAxes = [matrix[0], matrix[1], matrix[2], matrix[3], 0, 0]
      let mirrored = ImageInstanceEditingSupport.concat(mirror, localAxes)
      let bounds = ImageInventory.bounds(of: matrix)
      let center = [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2]
      let e = center[0] - (mirrored[0] + mirrored[2]) / 2
      let f = center[1] - (mirrored[1] + mirrored[3]) / 2
      return try composePageSpace(
        desiredPage: [mirrored[0], mirrored[1], mirrored[2], mirrored[3], e, f], path: path)
    }
  }

  private static func composePageSpace(desiredPage: [Double], path: ImageInstancePath) throws
    -> [Double]
  {
    guard let inverseOuter = ImageInstanceEditingSupport.invert(path.outerMatrix) else {
      throw PDFError(.unsupported, "The image has a singular enclosing transform")
    }
    let local = ImageInstanceEditingSupport.concat(inverseOuter, desiredPage)
    guard local.count == 6, local.allSatisfy(\.isFinite) else {
      throw PDFError(.unsupported, "The image transform is outside the supported numeric range")
    }
    return local
  }

  /// Post-condition: the saved matrix of the edited placement must equal the
  /// intended page-space matrix and the placement count must not change. This
  /// catches an isolation error before it can be committed.
  static func verify(path: ImageInstancePath, local: [Double], in graph: PDFGraph) throws {
    let expected = ImageInstanceEditingSupport.concat(path.outerMatrix, local)
    let placements = try ImageInventory.placements(in: graph, pageID: path.pageID)
    guard placements.count >= path.placementIndex + 1,
      ImageInstanceEditingSupport.approxEqual(
        placements[path.placementIndex].matrix, expected)
    else {
      throw PDFError(.malformed, "The isolated image placement did not match its intended matrix")
    }
  }
}

/// IMG-02: non-destructive crop for a page-level or nested instance. The image
/// object and the original clip are untouched; the target draw is wrapped in a
/// clip expressed in the draw's own content space, inside the copied form.
public struct CropImageInstanceCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let placementIndex: Int
  public let unitRect: [Double]

  public init(pageID: PDFObjectID, placementIndex: Int, unitRect: [Double]) {
    self.pageID = pageID
    self.placementIndex = placementIndex
    self.unitRect = unitRect
  }

  public var name: String { "Crop Image Nondestructively" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolved(in: graph)
  }

  private func resolved(in graph: PDFGraph) throws -> (path: ImageInstancePath, clip: String) {
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: pageID, placementIndex: placementIndex, in: graph)
    guard path.refusal == nil else {
      throw PDFError(.unsupported, path.refusal ?? "This image instance cannot be cropped safely")
    }
    return (path, try clipPath(path: path))
  }

  private func clipPath(path: ImageInstancePath) throws -> String {
    guard unitRect.count == 4, unitRect.allSatisfy(\.isFinite) else {
      throw PDFError(.malformed, "The crop rectangle is invalid")
    }
    let (u0, v0, u1, v1) = (unitRect[0], unitRect[1], unitRect[2], unitRect[3])
    guard u0 >= 0, v0 >= 0, u1 <= 1, v1 <= 1, u1 > u0, v1 > v0 else {
      throw PDFError(.malformed, "The crop rectangle must be a non-empty sub-rectangle of 0...1")
    }
    guard u0 > 0 || v0 > 0 || u1 < 1 || v1 < 1 else {
      throw PDFError(.malformed, "The crop rectangle covers the whole image")
    }
    let matrix = path.localMatrix
    guard matrix.count == 6, matrix.allSatisfy(\.isFinite) else {
      throw PDFError(.malformed, "The image placement has no usable local matrix")
    }
    func map(_ u: Double, _ v: Double) -> [Double] {
      [
        matrix[0] * u + matrix[2] * v + matrix[4],
        matrix[1] * u + matrix[3] * v + matrix[5],
      ]
    }
    let p00 = map(u0, v0), p10 = map(u1, v0), p11 = map(u1, v1), p01 = map(u0, v1)
    func token(_ value: Double) -> String { ImageInventory.numberToken(value) }
    let axisAligned =
      (abs(p00[1] - p10[1]) < 1e-9 && abs(p10[0] - p11[0]) < 1e-9
        && abs(p11[1] - p01[1]) < 1e-9 && abs(p01[0] - p00[0]) < 1e-9)
      || (abs(p00[0] - p10[0]) < 1e-9 && abs(p10[1] - p11[1]) < 1e-9
        && abs(p11[0] - p01[0]) < 1e-9 && abs(p01[1] - p00[1]) < 1e-9)
    if axisAligned {
      let xs = [p00[0], p10[0], p11[0], p01[0]]
      let ys = [p00[1], p10[1], p11[1], p01[1]]
      let x = xs.min()!, y = ys.min()!
      let width = xs.max()! - x, height = ys.max()! - y
      if width > 0, height > 0 {
        return "\(token(x)) \(token(y)) \(token(width)) \(token(height)) re"
      }
    }
    return "\(token(p00[0])) \(token(p00[1])) m "
      + "\(token(p10[0])) \(token(p10[1])) l "
      + "\(token(p11[0])) \(token(p11[1])) l "
      + "\(token(p01[0])) \(token(p01[1])) l h"
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let (path, clip) = try resolved(in: graph)
    var isolated = try ImageInstanceIsolation.isolate(path, in: graph)
    let index = isolated.targetInstructionIndex
    let prefix = Array("q\n\(clip) W n\n".utf8)
    let suffix = Array("\nQ".utf8)
    if isolated.targetContentIsPage {
      let content = try PageContent.load(pageID: pageID, in: isolated.graph)
      guard index >= 2, index + 1 < content.instructions.count,
        content.instructions[index - 2].operatorName == "q",
        content.instructions[index + 1].operatorName == "Q"
      else {
        throw PDFError(.malformed, "The image draw lost its clipping block")
      }
      let open = content.instructions[index - 2].span.lowerBound
      let close = content.instructions[index + 1].span.upperBound
      isolated.graph = try content.replacing(
        ranges: [(open..<open, prefix), (close..<close, suffix)],
        in: isolated.graph)
    } else {
      guard let formID = isolated.targetFormID,
        case .stream(var stream)? = isolated.graph.objects[formID]
      else {
        throw PDFError(.malformed, "The isolated form XObject is missing")
      }
      var bytes = [UInt8](stream.bytes)
      let instructions = try ContentParser.instructions(in: bytes)
      guard index >= 2, index + 1 < instructions.count,
        instructions[index - 2].operatorName == "q",
        instructions[index + 1].operatorName == "Q"
      else {
        throw PDFError(.malformed, "The image draw lost its clipping block")
      }
      let open = instructions[index - 2].span.lowerBound
      let close = instructions[index + 1].span.upperBound
      bytes.replaceSubrange(close..<close, with: suffix)
      bytes.replaceSubrange(open..<open, with: prefix)
      stream.bytes = Data(bytes)
      stream.dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
      isolated.graph.objects[formID] = .stream(stream)
    }
    try ImageOCRRelations.invalidateGeneratedLayer(pageID: pageID, in: &isolated.graph)
    return isolated.graph
  }
}
