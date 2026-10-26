import Foundation
import PDFCore

/// IMG-07: editable vector objects inside an explicit page-content profile.
///
/// A selectable vector object is one ordinary page-level path painted by a
/// single PDF paint operator (S, s, f, F, f*, B, B*, b, b*) whose path
/// operators are m, l, c, v, y, re and h.
///
/// Style edits write a new solid color/line width/dash immediately before the
/// paint operator, so they override only that object's paint and never edit
/// shared graphics state used by earlier paths. Transform edits rewrite only
/// that path's own coordinate operands. In both cases every other byte of the
/// page — gradients, tiling patterns, clipping paths, transparency groups,
/// images, other vector paths — stays byte-identical, and the path remains
/// vector content (it is never rasterized).
///
/// Outside the profile, with explicit refusals: gradient shading (sh), tiling
/// pattern paint (/Pattern cs + scn), reusable form XObjects and images (Do),
/// inline images, and paths painted under rotated/skewed page transforms for
/// transform edits. Nested form content is never inventoried here.
public enum VectorPaintKind: String, Sendable, Equatable {
  case fill
  case stroke
  case fillStroke

  public var displayName: String {
    switch self {
    case .fill: return "Fill"
    case .stroke: return "Stroke"
    case .fillStroke: return "Fill + stroke"
    }
  }

  public var hasFill: Bool { self != .stroke }
  public var hasStroke: Bool { self != .fill }
}

/// A requested style change for one vector object. Nil components keep the
/// object's existing paint. Colors are DeviceRGB 0...1.
public struct VectorObjectStyle: Sendable, Equatable {
  public var fillColor: [Double]?
  public var strokeColor: [Double]?
  public var lineWidth: Double?
  public var dash: [Double]?

  public init(
    fillColor: [Double]? = nil, strokeColor: [Double]? = nil, lineWidth: Double? = nil,
    dash: [Double]? = nil
  ) {
    self.fillColor = fillColor
    self.strokeColor = strokeColor
    self.lineWidth = lineWidth
    self.dash = dash
  }

  public var isEmpty: Bool {
    fillColor == nil && strokeColor == nil && lineWidth == nil && dash == nil
  }
}

/// The effective paint state observed at the object's paint operator. Fields
/// are nil when the value comes from a color space this profile does not read
/// as DeviceRGB/gray/CMYK.
public struct VectorObjectStyleSnapshot: Sendable, Equatable {
  public let fillColor: [Double]?
  public let strokeColor: [Double]?
  public let lineWidth: Double
  public let dash: [Double]
  public let patternFill: Bool
  public let patternStroke: Bool
  public let selfClipping: Bool
  public let inheritedClip: Bool
  public let inheritedTransparencyState: Bool
  public let notes: [String]

  public init(
    fillColor: [Double]?, strokeColor: [Double]?, lineWidth: Double, dash: [Double],
    patternFill: Bool, patternStroke: Bool, selfClipping: Bool, inheritedClip: Bool,
    inheritedTransparencyState: Bool, notes: [String]
  ) {
    self.fillColor = fillColor
    self.strokeColor = strokeColor
    self.lineWidth = lineWidth
    self.dash = dash
    self.patternFill = patternFill
    self.patternStroke = patternStroke
    self.selfClipping = selfClipping
    self.inheritedClip = inheritedClip
    self.inheritedTransparencyState = inheritedTransparencyState
    self.notes = notes
  }
}

/// Stable identity for one painted path inside one page revision. The
/// fingerprint covers the exact path bytes so a stale selection refuses.
public struct VectorObjectID: Sendable, Equatable, Hashable {
  public let pageID: PDFObjectID
  public let streamID: PDFObjectID
  public let paintInstructionIndex: Int
  public let paintOperator: String
  public let fingerprint: UInt64

  public init(
    pageID: PDFObjectID, streamID: PDFObjectID, paintInstructionIndex: Int,
    paintOperator: String, fingerprint: UInt64
  ) {
    self.pageID = pageID
    self.streamID = streamID
    self.paintInstructionIndex = paintInstructionIndex
    self.paintOperator = paintOperator
    self.fingerprint = fingerprint
  }

  public var identity: String {
    "page:\(pageID.number):\(pageID.generation):stream:\(streamID.number):"
      + "\(paintInstructionIndex):\(paintOperator):\(fingerprint)"
  }
}

/// How the page-space transform at the paint operator maps this path. Transform
/// edits need an axis-aligned positive transform to map page-space intent back
/// into path coordinates without approximating rotation.
public enum VectorTransformProfile: Sendable, Equatable {
  case identity
  case axisAligned(scaleX: Double, scaleY: Double, translateX: Double, translateY: Double)
  case unsupported(String)

  public var isTransformable: Bool {
    switch self {
    case .identity, .axisAligned: return true
    case .unsupported: return false
    }
  }

  public var isUniform: Bool {
    switch self {
    case .identity: return true
    case .axisAligned(let scaleX, let scaleY, _, _):
      return abs(scaleX - scaleY) <= 1e-6 * Swift.max(1, abs(scaleX))
    case .unsupported: return false
    }
  }

  public var refusalReason: String? {
    if case .unsupported(let reason) = self { return reason }
    return nil
  }
}

/// One selectable vector object on a page.
public struct SelectableVectorObject: Sendable, Equatable {
  public let id: VectorObjectID
  public let pageID: PDFObjectID
  /// Conservative page-space bounds (curve control points included).
  public let bounds: [Double]
  public let paintKind: VectorPaintKind
  public let style: VectorObjectStyleSnapshot
  public let pathInstructionIndices: [Int]
  public let transformProfile: VectorTransformProfile
  public let styleEditingSupported: Bool
  public let transformEditingSupported: Bool
  public let refusal: String?

  public init(
    id: VectorObjectID, pageID: PDFObjectID, bounds: [Double], paintKind: VectorPaintKind,
    style: VectorObjectStyleSnapshot, pathInstructionIndices: [Int],
    transformProfile: VectorTransformProfile, styleEditingSupported: Bool,
    transformEditingSupported: Bool, refusal: String?
  ) {
    self.id = id
    self.pageID = pageID
    self.bounds = bounds
    self.paintKind = paintKind
    self.style = style
    self.pathInstructionIndices = pathInstructionIndices
    self.transformProfile = transformProfile
    self.styleEditingSupported = styleEditingSupported
    self.transformEditingSupported = transformEditingSupported
    self.refusal = refusal
  }

  public var summary: String {
    "\(paintKind.displayName) path at "
      + bounds.map { String(format: "%.0f", $0) }.joined(separator: ",")
  }
}

/// Visible paint the vector profile deliberately refuses, for point-of-use
/// explanations. Bounds are nil when the paint does not define an editable
/// region (for example a page-level gradient shading).
public struct VectorPaintRefusal: Sendable, Equatable {
  public let instructionIndex: Int
  public let reason: String
  public let bounds: [Double]?

  public init(instructionIndex: Int, reason: String, bounds: [Double]?) {
    self.instructionIndex = instructionIndex
    self.reason = reason
    self.bounds = bounds
  }
}

/// Page-level vector object inventory.
public enum VectorObjectInventory {
  /// All selectable vector objects on one page, in paint order.
  public static func selectable(pageID: PDFObjectID, in graph: PDFGraph) throws
    -> [SelectableVectorObject]
  {
    try VectorPageScan(pageID: pageID, graph: graph).run().objects
  }

  /// Visible vector paint outside the editable profile.
  public static func refusals(pageID: PDFObjectID, in graph: PDFGraph) throws
    -> [VectorPaintRefusal]
  {
    try VectorPageScan(pageID: pageID, graph: graph).run().refusals
  }
}

/// IMG-07 style edit: insert solid DeviceRGB color, line width and/or dash
/// state immediately before the object's paint operator.
public struct SetVectorObjectStyleCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: VectorObjectID
  public let style: VectorObjectStyle

  public init(objectID: VectorObjectID, style: VectorObjectStyle) {
    self.objectID = objectID
    self.style = style
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [objectID.pageID] }
  public var name: String { "Set Vector Object Style" }

  public func validate(in graph: PDFGraph) throws {
    guard !style.isEmpty else {
      throw PDFError(.malformed, "No vector style change was requested")
    }
    try validateColors()
    if let width = style.lineWidth {
      guard width.isFinite, width >= 0, width <= 100 else {
        throw PDFError(.malformed, "The line width is outside the supported range")
      }
    }
    if let dash = style.dash {
      guard dash.count <= 64, dash.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000 })
      else {
        throw PDFError(.malformed, "The dash pattern is outside the supported range")
      }
    }
    let resolved = try VectorObjectSupport.resolve(objectID, in: graph)
    if style.fillColor != nil, !resolved.object.paintKind.hasFill {
      throw PDFError(.malformed, "This path has no fill to style")
    }
    if style.strokeColor != nil || style.lineWidth != nil || style.dash != nil,
      !resolved.object.paintKind.hasStroke
    {
      throw PDFError(.malformed, "This path has no stroke to style")
    }
    if style.lineWidth != nil || style.dash != nil,
      !resolved.object.transformProfile.isUniform
    {
      throw PDFError(
        .unsupported,
        "Line width and dash editing need a uniform page transform; this path is "
          + "painted under a non-uniform or rotated transform.")
    }
    _ = try VectorObjectSupport.insertionRange(for: resolved)
  }

  private func validateColors() throws {
    for color in [style.fillColor, style.strokeColor].compactMap({ $0 }) {
      guard color.count == 3, color.allSatisfy({ $0.isFinite && (0...1).contains($0) })
      else {
        throw PDFError(.malformed, "Vector colors must be finite DeviceRGB 0...1 components")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    let resolved = try VectorObjectSupport.resolve(objectID, in: graph)
    let location = try VectorObjectSupport.insertionRange(for: resolved)
    var bytes: [UInt8] = []
    if let fill = style.fillColor {
      bytes += Array((token(fill[0]) + " " + token(fill[1]) + " " + token(fill[2]) + " rg\n").utf8)
    }
    if let stroke = style.strokeColor {
      bytes += Array(
        (token(stroke[0]) + " " + token(stroke[1]) + " " + token(stroke[2]) + " RG\n").utf8)
    }
    if let width = style.lineWidth {
      bytes += Array((token(width) + " w\n").utf8)
    }
    if let dash = style.dash {
      let pattern = dash.map(token).joined(separator: " ")
      bytes += Array(("[\(pattern)] 0 d\n").utf8)
    }
    guard !bytes.isEmpty else {
      throw PDFError(.malformed, "No vector style bytes were produced")
    }
    let content = try PageContent.load(pageID: objectID.pageID, in: graph)
    return try content.replacing(range: location..<location, with: bytes, in: graph)
  }

  private func token(_ value: Double) -> String {
    ImageInventory.numberToken(value)
  }
}

/// IMG-07 transform edit: move and/or uniformly scale one vector object inside
/// its existing page transform. Only this path's coordinate operands change.
public struct TransformVectorObjectCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: VectorObjectID
  public let translateX: Double
  public let translateY: Double
  /// Uniform scale factor about (anchorX, anchorY) in page space; 1 moves only.
  public let scale: Double
  public let anchorX: Double
  public let anchorY: Double

  public init(
    objectID: VectorObjectID, translateX: Double, translateY: Double, scale: Double = 1,
    anchorX: Double = 0, anchorY: Double = 0
  ) {
    self.objectID = objectID
    self.translateX = translateX
    self.translateY = translateY
    self.scale = scale
    self.anchorX = anchorX
    self.anchorY = anchorY
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [objectID.pageID] }
  public var name: String { scale == 1 ? "Move Vector Object" : "Scale Vector Object" }

  public func validate(in graph: PDFGraph) throws {
    guard translateX.isFinite, translateY.isFinite, scale.isFinite, scale > 0,
      anchorX.isFinite, anchorY.isFinite
    else {
      throw PDFError(.malformed, "The vector transform is not finite")
    }
    guard abs(translateX) > 1e-9 || abs(translateY) > 1e-9 || abs(scale - 1) > 1e-9 else {
      throw PDFError(.malformed, "The vector transform changes nothing")
    }
    let resolved = try VectorObjectSupport.resolve(objectID, in: graph)
    guard resolved.object.transformEditingSupported else {
      throw PDFError(
        .unsupported,
        resolved.object.refusal ?? "This vector object cannot be transformed in this profile")
    }
    if scale != 1, !resolved.object.transformProfile.isUniform {
      throw PDFError(
        .unsupported,
        "Scaling a vector object needs a uniform page transform; this path is painted "
          + "under a non-uniform transform.")
    }
    _ = try VectorObjectSupport.transformEdits(
      resolved, translateX: translateX, translateY: translateY, scale: scale,
      anchorX: anchorX, anchorY: anchorY)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    let resolved = try VectorObjectSupport.resolve(objectID, in: graph)
    let edits = try VectorObjectSupport.transformEdits(
      resolved, translateX: translateX, translateY: translateY, scale: scale,
      anchorX: anchorX, anchorY: anchorY)
    let content = try PageContent.load(pageID: objectID.pageID, in: graph)
    return try content.replacing(ranges: edits, in: graph)
  }
}

// MARK: - Internal scan and command support

/// One resolved object ready for command validation/application.
struct ResolvedVectorObject {
  let object: SelectableVectorObject
  let content: PageContent
  let pathInstructions: [ContentInstruction]
  let paintInstruction: ContentInstruction
  let transform: [Double]
}

enum VectorObjectSupport {
  static func resolve(_ id: VectorObjectID, in graph: PDFGraph) throws
    -> ResolvedVectorObject
  {
    let scan = try VectorPageScan(pageID: id.pageID, graph: graph).run()
    guard let object = scan.objects.first(where: { $0.id == id }),
      let transform = scan.transforms[id.identity]
    else {
      throw PDFError(
        .unsupported,
        "The vector object changed since it was selected; select it again before "
          + "editing. No content was changed.")
    }
    let content = try PageContent.load(pageID: id.pageID, in: graph)
    guard id.paintInstructionIndex < content.instructions.count,
      content.instructions[id.paintInstructionIndex].operatorName == id.paintOperator
    else {
      throw PDFError(.malformed, "The vector paint operator moved unexpectedly")
    }
    var pathInstructions: [ContentInstruction] = []
    for index in object.pathInstructionIndices {
      guard index < content.instructions.count else {
        throw PDFError(.malformed, "The vector path moved unexpectedly")
      }
      pathInstructions.append(content.instructions[index])
    }
    return ResolvedVectorObject(
      object: object, content: content, pathInstructions: pathInstructions,
      paintInstruction: content.instructions[id.paintInstructionIndex], transform: transform)
  }

  /// Empty range immediately before the paint operator: inserting color/width/
  /// dash state there affects only this path's paint.
  static func insertionRange(for resolved: ResolvedVectorObject) throws -> Int {
    let location = resolved.paintInstruction.span.lowerBound
    guard location >= 0, location <= resolved.content.bytes.count else {
      throw PDFError(.malformed, "The vector paint operator lost its position")
    }
    guard resolved.content.segmentIndex(for: location..<location) != nil else {
      throw PDFError(.malformed, "The vector paint operator is outside the page content")
    }
    return location
  }

  static func transformEdits(
    _ resolved: ResolvedVectorObject, translateX: Double, translateY: Double, scale: Double,
    anchorX: Double, anchorY: Double
  ) throws -> [(range: Range<Int>, replacement: [UInt8])] {
    guard let inverse = invert(resolved.transform) else {
      throw PDFError(.unsupported, "The page transform at this path is singular")
    }
    let ctm = resolved.transform
    func mapped(_ localX: Double, _ localY: Double) -> (Double, Double)? {
      let pageX = ctm[0] * localX + ctm[2] * localY + ctm[4]
      let pageY = ctm[1] * localX + ctm[3] * localY + ctm[5]
      let targetX = anchorX + (pageX - anchorX) * scale + translateX
      let targetY = anchorY + (pageY - anchorY) * scale + translateY
      let localX2 = inverse[0] * targetX + inverse[2] * targetY + inverse[4]
      let localY2 = inverse[1] * targetX + inverse[3] * targetY + inverse[5]
      guard localX2.isFinite, localY2.isFinite else { return nil }
      return (localX2, localY2)
    }
    var edits: [(range: Range<Int>, replacement: [UInt8])] = []
    for instruction in resolved.pathInstructions {
      let operands = instruction.operands
      switch instruction.operatorName {
      case "m", "l":
        try rewritePairs(operands, pairCount: 1, mapped: mapped, into: &edits)
      case "c":
        try rewritePairs(operands, pairCount: 3, mapped: mapped, into: &edits)
      case "v", "y":
        try rewritePairs(operands, pairCount: 2, mapped: mapped, into: &edits)
      case "re":
        guard operands.count == 4 else {
          throw PDFError(.malformed, "The vector rectangle has malformed operands")
        }
        let values = try numbers(operands)
        guard let origin = mapped(values[0], values[1]),
          let corner = mapped(values[0] + values[2], values[1] + values[3])
        else {
          throw PDFError(.unsupported, "The vector rectangle cannot be transformed")
        }
        edits.append((operands[0].span, bytes(mapped: origin.0)))
        edits.append((operands[1].span, bytes(mapped: origin.1)))
        if scale != 1 {
          let width = corner.0 - origin.0
          let height = corner.1 - origin.1
          guard width.isFinite, height.isFinite, width >= 0, height >= 0 else {
            throw PDFError(.unsupported, "The scaled vector rectangle is degenerate")
          }
          edits.append((operands[2].span, bytes(mapped: width)))
          edits.append((operands[3].span, bytes(mapped: height)))
        }
      case "h":
        continue
      default:
        throw PDFError(
          .unsupported, "The vector path uses an operator this profile cannot rewrite")
      }
    }
    guard !edits.isEmpty else {
      throw PDFError(.malformed, "The vector transform produced no coordinate edits")
    }
    return edits
  }

  private static func rewritePairs(
    _ operands: [ContentOperand], pairCount: Int,
    mapped: (Double, Double) -> (Double, Double)?,
    into edits: inout [(range: Range<Int>, replacement: [UInt8])]
  ) throws {
    guard operands.count == pairCount * 2 else {
      throw PDFError(.malformed, "The vector path operand count is malformed")
    }
    let values = try numbers(operands)
    for pair in 0..<pairCount {
      let index = pair * 2
      guard let transformed = mapped(values[index], values[index + 1]) else {
        throw PDFError(.unsupported, "The vector path coordinate cannot be transformed")
      }
      edits.append((operands[index].span, bytes(mapped: transformed.0)))
      edits.append((operands[index + 1].span, bytes(mapped: transformed.1)))
    }
  }

  private static func numbers(_ operands: [ContentOperand]) throws -> [Double] {
    let values = operands.compactMap { number($0.value) }
    guard values.count == operands.count else {
      throw PDFError(.malformed, "The vector path has a non-numeric coordinate")
    }
    return values
  }

  static func number(_ value: PDFValue) -> Double? {
    switch value {
    case .real(let number): return number
    case .integer(let number): return Double(number)
    default: return nil
    }
  }

  private static func bytes(mapped value: Double) -> [UInt8] {
    Array(ImageInventory.numberToken(value).utf8)
  }

  private static func invert(_ matrix: [Double]) -> [Double]? {
    guard matrix.count == 6 else { return nil }
    let determinant = matrix[0] * matrix[3] - matrix[1] * matrix[2]
    guard abs(determinant) > 1e-12, determinant.isFinite else { return nil }
    let a = matrix[3] / determinant
    let b = -matrix[1] / determinant
    let c = -matrix[2] / determinant
    let d = matrix[0] / determinant
    let e = (matrix[2] * matrix[5] - matrix[3] * matrix[4]) / determinant
    let f = (matrix[1] * matrix[4] - matrix[0] * matrix[5]) / determinant
    let result = [a, b, c, d, e, f]
    return result.allSatisfy(\.isFinite) ? result : nil
  }
}

/// One page-level content scan with graphics-state tracking.
struct VectorPageScan {
  let pageID: PDFObjectID
  let graph: PDFGraph

  struct Result {
    let objects: [SelectableVectorObject]
    let refusals: [VectorPaintRefusal]
    let transforms: [String: [Double]]
  }

  func run() throws -> Result {
    let content = try PageContent.load(pageID: pageID, in: graph)
    var state = GraphicsState()
    var stack: [GraphicsState] = []
    var pending: [Int] = []
    var pendingSelfClipping = false
    var objects: [SelectableVectorObject] = []
    var refusals: [VectorPaintRefusal] = []
    var transforms: [String: [Double]] = [:]

    func resetPath() {
      pending.removeAll()
      pendingSelfClipping = false
    }

    for (index, instruction) in content.instructions.enumerated() {
      switch instruction.operatorName {
      case "q":
        stack.append(state)
      case "Q":
        if let restored = stack.popLast() { state = restored }
      case "cm":
        if instruction.operands.count == 6 {
          let values = instruction.operands.compactMap { VectorObjectSupport.number($0.value) }
          if values.count == 6 { state.ctm = concat(state.ctm, values) }
        }
      case "g", "rg", "k":
        state.fill = colorValue(instruction)
        state.patternFill = false
      case "G", "RG", "K":
        state.stroke = colorValue(instruction)
        state.patternStroke = false
      case "cs":
        state.fillSpace = colorSpaceName(instruction)
        state.patternFill = state.fillSpace?.contains("Pattern") == true
      case "CS":
        state.strokeSpace = colorSpaceName(instruction)
        state.patternStroke = state.strokeSpace?.contains("Pattern") == true
      case "scn", "sc":
        if state.fillSpace?.contains("Pattern") == true { state.patternFill = true }
      case "SCN", "SC":
        if state.strokeSpace?.contains("Pattern") == true { state.patternStroke = true }
      case "w":
        if let width = instruction.operands.first.flatMap({
          VectorObjectSupport.number($0.value)
        }) {
          state.lineWidth = width
        }
      case "d":
        if instruction.operands.count >= 1, case .array(let values) = instruction.operands[0].value
        {
          state.dash = values.compactMap { VectorObjectSupport.number($0) }
        }
      case "gs":
        state.transparencyState = true
      case "m", "l", "c", "v", "y", "re":
        pending.append(index)
        state.pathActive = true
      case "h":
        if state.pathActive { pending.append(index) }
      case "W", "W*":
        pendingSelfClipping = true
      case "n":
        if pendingSelfClipping { state.clipActive = true }
        resetPath()
        state.pathActive = false
      case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
        let kind = paintKind(for: instruction.operatorName)
        if !pending.isEmpty {
          let path = pending.map { content.instructions[$0] }
          if state.patternFill && kind.hasFill {
            refusals.append(
              VectorPaintRefusal(
                instructionIndex: index,
                reason:
                  "This path is filled with a tiling pattern. The vector profile "
                  + "preserves patterns for unrelated paint but does not edit pattern "
                  + "paint; nothing was changed.",
                bounds: pathBounds(instructions: path, transform: state.ctm)))
          } else if state.patternStroke && kind.hasStroke {
            refusals.append(
              VectorPaintRefusal(
                instructionIndex: index,
                reason:
                  "This path is stroked with a tiling pattern. The vector profile does "
                  + "not edit pattern paint; nothing was changed.",
                bounds: pathBounds(instructions: path, transform: state.ctm)))
          } else if let object = makeObject(
            index: index, instruction: instruction, state: state, pending: pending,
            selfClipping: pendingSelfClipping, content: content)
          {
            objects.append(object)
            transforms[object.id.identity] = state.ctm
          }
        }
        if pendingSelfClipping { state.clipActive = true }
        resetPath()
        state.pathActive = false
      case "sh":
        refusals.append(
          VectorPaintRefusal(
            instructionIndex: index,
            reason:
              "Gradient shading is outside the editable vector profile; shading "
              + "resources and their functions are preserved untouched.",
            bounds: nil))
      case "Do":
        refusals.append(
          VectorPaintRefusal(
            instructionIndex: index,
            reason:
              "Reusable form XObjects and images are outside the editable vector "
              + "profile; their content is not rewritten by a vector edit.",
            bounds: nil))
      case "BI":
        refusals.append(
          VectorPaintRefusal(
            instructionIndex: index,
            reason:
              "Inline images are outside the editable vector profile; their payload "
              + "is preserved untouched.",
            bounds: nil))
      default:
        continue
      }
    }
    return Result(objects: objects, refusals: refusals, transforms: transforms)
  }

  private func makeObject(
    index: Int, instruction: ContentInstruction, state: GraphicsState, pending: [Int],
    selfClipping: Bool, content: PageContent
  ) -> SelectableVectorObject? {
    guard let firstSpan = pending.first.map({ content.instructions[$0].span }),
      let streamIndex = content.segmentIndex(for: firstSpan),
      content.segmentIndex(for: instruction.span) == streamIndex
    else { return nil }
    let streamID = content.segments[streamIndex].objectID
    let kind = paintKind(for: instruction.operatorName)
    let pathInstructions = pending.map { content.instructions[$0] }
    guard let bounds = pathBounds(instructions: pathInstructions, transform: state.ctm)
    else { return nil }
    let expandedBounds = expandedForStroke(bounds: bounds, state: state, kind: kind)
    let profile = transformProfile(state.ctm)
    var notes: [String] = []
    if selfClipping { notes.append("The path also defines its own clip region.") }
    if state.clipActive {
      notes.append("An enclosing clip is active; it is preserved untouched.")
    }
    if state.transparencyState {
      notes.append("An enclosing ExtGState (for example transparency) is preserved untouched.")
    }
    if state.patternFill && kind.hasFill {
      notes.append("Fill uses a tiling pattern; a style edit would replace it with a solid color.")
    }
    if state.patternStroke && kind.hasStroke {
      notes.append(
        "Stroke uses a tiling pattern; a style edit would replace it with a solid color.")
    }
    let style = VectorObjectStyleSnapshot(
      fillColor: state.fill, strokeColor: state.stroke, lineWidth: state.lineWidth,
      dash: state.dash, patternFill: state.patternFill, patternStroke: state.patternStroke,
      selfClipping: selfClipping, inheritedClip: state.clipActive,
      inheritedTransparencyState: state.transparencyState, notes: notes)
    let transformable = profile.isTransformable
    let id = VectorObjectID(
      pageID: pageID, streamID: streamID, paintInstructionIndex: index,
      paintOperator: instruction.operatorName,
      fingerprint: fingerprint(
        pathInstructions: pathInstructions, paint: instruction, content: content))
    return SelectableVectorObject(
      id: id, pageID: pageID, bounds: expandedBounds, paintKind: kind, style: style,
      pathInstructionIndices: pending, transformProfile: profile,
      styleEditingSupported: true, transformEditingSupported: transformable,
      refusal: transformable ? nil : profile.refusalReason)
  }

  private func fingerprint(
    pathInstructions: [ContentInstruction], paint: ContentInstruction, content: PageContent
  ) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ range: Range<Int>) {
      guard range.lowerBound >= 0, range.upperBound <= content.bytes.count else { return }
      for byte in content.bytes[range] {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
      }
    }
    for instruction in pathInstructions {
      mix(instruction.span)
      for operand in instruction.operands { mix(operand.span) }
    }
    mix(paint.span)
    for operand in paint.operands { mix(operand.span) }
    return hash
  }

  private func paintKind(for operatorName: String) -> VectorPaintKind {
    switch operatorName {
    case "S", "s": return .stroke
    case "f", "F", "f*": return .fill
    default: return .fillStroke
    }
  }

  private func transformProfile(_ ctm: [Double]) -> VectorTransformProfile {
    guard ctm.count == 6, ctm.allSatisfy(\.isFinite) else {
      return .unsupported("The page transform at this path is not finite")
    }
    if abs(ctm[0] - 1) < 1e-9, abs(ctm[1]) < 1e-9, abs(ctm[2]) < 1e-9,
      abs(ctm[3] - 1) < 1e-9, abs(ctm[4]) < 1e-9, abs(ctm[5]) < 1e-9
    {
      return .identity
    }
    guard abs(ctm[1]) < 1e-9, abs(ctm[2]) < 1e-9, ctm[0] > 0, ctm[3] > 0 else {
      return .unsupported(
        "This path is painted under a rotated or skewed page transform; vector "
          + "transform edits support axis-aligned transforms only.")
    }
    return .axisAligned(
      scaleX: ctm[0], scaleY: ctm[3], translateX: ctm[4], translateY: ctm[5])
  }

  private func pathBounds(instructions: [ContentInstruction], transform ctm: [Double])
    -> [Double]?
  {
    var points: [(Double, Double)] = []
    for instruction in instructions {
      let values = instruction.operands.compactMap { VectorObjectSupport.number($0.value) }
      switch instruction.operatorName {
      case "m", "l":
        if values.count == 2 { points.append((values[0], values[1])) }
      case "c":
        if values.count == 6 {
          points.append((values[0], values[1]))
          points.append((values[2], values[3]))
          points.append((values[4], values[5]))
        }
      case "v", "y":
        if values.count == 4 {
          points.append((values[0], values[1]))
          points.append((values[2], values[3]))
        }
      case "re":
        if values.count == 4 {
          points.append((values[0], values[1]))
          points.append((values[0] + values[2], values[1]))
          points.append((values[0], values[1] + values[3]))
          points.append((values[0] + values[2], values[1] + values[3]))
        }
      default:
        continue
      }
    }
    guard !points.isEmpty else { return nil }
    let mapped = points.map { point -> (Double, Double) in
      (
        ctm[0] * point.0 + ctm[2] * point.1 + ctm[4],
        ctm[1] * point.0 + ctm[3] * point.1 + ctm[5]
      )
    }
    let xs = mapped.map(\.0)
    let ys = mapped.map(\.1)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
      minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite
    else { return nil }
    let bounds = [minX, minY, maxX, maxY]
    guard bounds[2] > bounds[0] || bounds[3] > bounds[1] else { return nil }
    return bounds
  }

  private func expandedForStroke(
    bounds: [Double], state: GraphicsState, kind: VectorPaintKind
  ) -> [Double] {
    guard kind.hasStroke, state.lineWidth > 0 else { return bounds }
    let scale = max(abs(state.ctm[0]), abs(state.ctm[3]), 1e-9)
    let pad = state.lineWidth * scale / 2
    return [bounds[0] - pad, bounds[1] - pad, bounds[2] + pad, bounds[3] + pad]
  }

  private func colorValue(_ instruction: ContentInstruction) -> [Double]? {
    let values = instruction.operands.compactMap { VectorObjectSupport.number($0.value) }
    guard values.count == instruction.operands.count else { return nil }
    switch instruction.operatorName {
    case "g", "G":
      guard values.count == 1 else { return nil }
      return [values[0], values[0], values[0]]
    case "rg", "RG":
      return values.count == 3 ? values : nil
    case "k", "K":
      guard values.count == 4 else { return nil }
      let c = values[0], m = values[1], y = values[2], k = values[3]
      return [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)]
    default:
      return nil
    }
  }

  private func colorSpaceName(_ instruction: ContentInstruction) -> String? {
    guard let first = instruction.operands.first, case .name(let name) = first.value else {
      return nil
    }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  private func concat(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
    [
      lhs[0] * rhs[0] + lhs[2] * rhs[1],
      lhs[1] * rhs[0] + lhs[3] * rhs[1],
      lhs[0] * rhs[2] + lhs[2] * rhs[3],
      lhs[1] * rhs[2] + lhs[3] * rhs[3],
      lhs[0] * rhs[4] + lhs[2] * rhs[5] + lhs[4],
      lhs[1] * rhs[4] + lhs[3] * rhs[5] + lhs[5],
    ]
  }

  private struct GraphicsState {
    var ctm: [Double] = [1, 0, 0, 1, 0, 0]
    var fill: [Double]?
    var stroke: [Double]?
    var lineWidth: Double = 1
    var dash: [Double] = []
    var fillSpace: String?
    var strokeSpace: String?
    var patternFill = false
    var patternStroke = false
    var transparencyState = false
    var pathActive = false
    var clipActive = false
  }
}
