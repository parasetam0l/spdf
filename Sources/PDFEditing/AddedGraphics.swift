import Foundation
import PDFCore

/// P21-009: grouping of app-created objects with stable identity.
///
/// App-created content is appended as page content streams (one stream object
/// per insertion). A group names a set of those stream objects under a stable
/// string ID persisted in the catalog (`/SPDFGroups`), so the membership
/// survives save/reopen and undo works through the ordinary transaction
/// history. Grouping never touches the grouped paint itself.
public struct AddedGroup: Sendable, Equatable {
  public let id: String
  public let members: [PDFObjectID]
  public let label: String?

  public init(id: String, members: [PDFObjectID], label: String? = nil) {
    self.id = id
    self.members = members
    self.label = label
  }
}

public enum AddedGraphicsGroups {
  static let catalogKey = PDFName("SPDFGroups")

  public static func list(in graph: PDFGraph) throws -> [AddedGroup] {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "Document catalog is missing")
    }
    guard let entry = catalog[catalogKey] else { return [] }
    guard case .array(let items) = entry else {
      throw PDFError(.malformed, "Added-graphics groups are malformed")
    }
    var result: [AddedGroup] = []
    for item in items {
      guard case .dictionary(let dictionary) = item,
        case .string(let idData)? = dictionary[PDFName("ID")],
        let id = String(data: idData, encoding: .utf8), !id.isEmpty,
        case .array(let members)? = dictionary[PDFName("Members")]
      else {
        throw PDFError(.malformed, "Added-graphics groups are malformed")
      }
      var memberIDs: [PDFObjectID] = []
      for member in members {
        guard case .reference(let streamID) = member else {
          throw PDFError(.malformed, "Added-graphics group members must be references")
        }
        memberIDs.append(streamID)
      }
      let label: String?
      if case .string(let labelData)? = dictionary[PDFName("Label")] {
        label = String(data: labelData, encoding: .utf8)
      } else {
        label = nil
      }
      result.append(AddedGroup(id: id, members: memberIDs, label: label))
    }
    return result
  }

  static func write(_ groups: [AddedGroup], in graph: inout PDFGraph) throws {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "Document catalog is missing")
    }
    var seen: Set<String> = []
    var items: [PDFValue] = []
    for group in groups {
      guard !group.id.isEmpty, group.id.utf8.count <= 200, seen.insert(group.id).inserted else {
        throw PDFError(.malformed, "Added-graphics group IDs must be unique and non-empty")
      }
      var dictionary: [PDFName: PDFValue] = [
        PDFName("ID"): .string(Data(group.id.utf8)),
        PDFName("Members"): .array(group.members.map { .reference($0) }),
      ]
      if let label = group.label {
        guard label.utf8.count <= 500 else {
          throw PDFError(.limitExceeded, "Added-graphics group label is too long")
        }
        dictionary[PDFName("Label")] = .string(Data(label.utf8))
      }
      items.append(.dictionary(dictionary))
    }
    catalog[catalogKey] = .array(items)
    graph.objects[catalogID] = .dictionary(catalog)
  }

  static func validateMembers(_ members: [PDFObjectID], in graph: PDFGraph) throws {
    guard !members.isEmpty, members.count <= 1_000 else {
      throw PDFError(.malformed, "An added-graphics group needs 1...1000 members")
    }
    guard Set(members).count == members.count else {
      throw PDFError(.malformed, "An added-graphics group lists a member twice")
    }
    for member in members {
      guard case .stream = graph.objects[member] else {
        throw PDFError(.malformed, "Added-graphics group members must be content streams")
      }
    }
  }
}

/// P21-009: create a named group over existing app-created content streams.
public struct CreateAddedGroupCommand: PDFEditCommand, Equatable, Sendable {
  public let members: [PDFObjectID]
  public let label: String?
  public let groupID: String

  public init(members: [PDFObjectID], label: String? = nil, groupID: String = UUID().uuidString) {
    self.members = members
    self.label = label
    self.groupID = groupID
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    AddedGraphics.ownerPages(of: members, in: graph)
  }
  public var name: String { "Group Graphics" }

  public func validate(in graph: PDFGraph) throws {
    try AddedGraphicsGroups.validateMembers(members, in: graph)
    guard !groupID.isEmpty, groupID.utf8.count <= 200 else {
      throw PDFError(.malformed, "The group ID is empty or too long")
    }
    let existing = try AddedGraphicsGroups.list(in: graph)
    guard !existing.contains(where: { $0.id == groupID }) else {
      throw PDFError(.malformed, "An added-graphics group with this ID already exists")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var groups = try AddedGraphicsGroups.list(in: graph)
    groups.append(AddedGroup(id: groupID, members: members, label: label))
    try AddedGraphicsGroups.write(groups, in: &graph)
    return graph
  }
}

/// P21-009: replace one group's membership (add/remove members).
public struct UpdateAddedGroupCommand: PDFEditCommand, Equatable, Sendable {
  public let groupID: String
  public let members: [PDFObjectID]

  public init(groupID: String, members: [PDFObjectID]) {
    self.groupID = groupID
    self.members = members
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    AddedGraphics.ownerPages(of: members, in: graph)
  }
  public var name: String { "Update Graphics Group" }

  public func validate(in graph: PDFGraph) throws {
    try AddedGraphicsGroups.validateMembers(members, in: graph)
    let existing = try AddedGraphicsGroups.list(in: graph)
    guard existing.contains(where: { $0.id == groupID }) else {
      throw PDFError(.malformed, "The added-graphics group does not exist")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var groups = try AddedGraphicsGroups.list(in: graph)
    guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
      throw PDFError(.malformed, "The added-graphics group does not exist")
    }
    groups[index] = AddedGroup(id: groupID, members: members, label: groups[index].label)
    try AddedGraphicsGroups.write(groups, in: &graph)
    return graph
  }
}

/// P21-009: delete a group. The grouped paint stays on the pages; only the
/// membership record is removed.
public struct DeleteAddedGroupCommand: PDFEditCommand, Equatable, Sendable {
  public let groupID: String

  public init(groupID: String) {
    self.groupID = groupID
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }
  public var name: String { "Ungroup Graphics" }

  public func validate(in graph: PDFGraph) throws {
    let existing = try AddedGraphicsGroups.list(in: graph)
    guard existing.contains(where: { $0.id == groupID }) else {
      throw PDFError(.malformed, "The added-graphics group does not exist")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let groups = try AddedGraphicsGroups.list(in: graph).filter { $0.id != groupID }
    try AddedGraphicsGroups.write(groups, in: &graph)
    return graph
  }
}

/// P21-010: move/resize/rotate for supported app-created graphics.
///
/// Supported subset (anything else refuses with an explicit reason):
/// image stamps (the `q … cm … Do … Q` blocks `AddImageStampCommand` and
/// `PlaceImageCommand` append) and rectangles (single-`re` shape blocks).
/// Text blocks, ellipses, polygons, and freeform paths refuse: their
/// multi-operator geometry has no single-operand transform in this profile.
public enum AddedGraphicKind: String, Sendable, Equatable {
  case imageStamp
  case rectangle
  case unsupported
}

/// P12-017: one app-created graphic on a page that the workspace can
/// select, with its page-space bounds for handles and hit testing.
public struct SelectableGraphic: Sendable, Equatable {
  public let streamID: PDFObjectID
  public let kind: AddedGraphicKind
  /// Axis-aligned page-space bounds ([x0, y0, x1, y1]).
  public let bounds: [Double]

  public init(streamID: PDFObjectID, kind: AddedGraphicKind, bounds: [Double]) {
    self.streamID = streamID
    self.kind = kind
    self.bounds = bounds
  }
}

public enum AddedGraphics {
  /// Whether the stream was appended by the app (see `AddedContent.append`).
  /// Native document streams are never app-created, even when their
  /// operators resemble an image stamp or rectangle.
  public static func isAppCreated(streamID: PDFObjectID, in graph: PDFGraph) -> Bool {
    guard case .stream(let stream)? = graph.objects[streamID] else { return false }
    return stream.dictionary[PDFName("SPDFAdded")] == .boolean(true)
  }

  /// Provenance gate for graphic mutation: only app-appended streams may be
  /// moved, resized, or rotated. Native document streams share operator
  /// shapes but live in unknown transform contexts, so rewriting their
  /// matrices would corrupt the page instead of moving the picture.
  public static func requireAppCreated(streamID: PDFObjectID, in graph: PDFGraph) throws {
    guard isAppCreated(streamID: streamID, in: graph) else {
      throw PDFError(
        .unsupported,
        "Only graphics added by sPDF can be moved or reshaped; document images use the explicit image operations")
    }
  }

  /// Classify an appended content stream by its operators.
  public static func kindOf(streamID: PDFObjectID, in graph: PDFGraph) throws -> AddedGraphicKind {
    let instructions = try decodedInstructions(streamID: streamID, in: graph)
    let operators = Set(instructions.map(\.operatorName))
    if operators.contains("Do"), operators.contains("cm") {
      return .imageStamp
    }
    if operators.contains("re"), !operators.contains("Tj"), !operators.contains("TJ"),
      !operators.contains("Do")
    {
      return .rectangle
    }
    return .unsupported
  }

  /// Axis-aligned bounds for image stamps and rectangles; nil otherwise.
  public static func boundsOf(streamID: PDFObjectID, in graph: PDFGraph) throws -> [Double]? {
    let instructions = try decodedInstructions(streamID: streamID, in: graph)
    switch try kindOf(streamID: streamID, in: graph) {
    case .imageStamp:
      guard let cm = instructions.last(where: { $0.operatorName == "cm" }),
        cm.operands.count == 6
      else { return nil }
      let values = cm.operands.compactMap { ImageInventory.number(of: $0.value) }
      guard values.count == 6 else { return nil }
      return ImageInventory.bounds(of: values)
    case .rectangle:
      guard let re = instructions.first(where: { $0.operatorName == "re" }),
        re.operands.count == 4
      else { return nil }
      let values = re.operands.compactMap { ImageInventory.number(of: $0.value) }
      guard values.count == 4 else { return nil }
      return [values[0], values[1], values[0] + values[2], values[1] + values[3]]
    case .unsupported:
      return nil
    }
  }

  /// P12-017: every app-created graphic on a page that selection can
  /// address, in content order. Unsupported kinds (text, ellipses, paths),
  /// boundless streams, and native document streams (no provenance marker)
  /// are skipped, never fabricated — moving those would rewrite matrices in
  /// an unknown transform context and corrupt the page.
  public static func selectable(
    pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> [SelectableGraphic] {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let references: [PDFObjectID]
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      references = [id]
    case .array(let values)?:
      references = values.compactMap {
        if case .reference(let id) = $0 { return id }
        return nil
      }
    default:
      return []
    }
    var result: [SelectableGraphic] = []
    for streamID in references {
      guard isAppCreated(streamID: streamID, in: graph),
        let kind = try? kindOf(streamID: streamID, in: graph),
        kind != .unsupported,
        let bounds = try? boundsOf(streamID: streamID, in: graph),
        bounds.count == 4, bounds[2] > bounds[0], bounds[3] > bounds[1]
      else { continue }
      result.append(SelectableGraphic(streamID: streamID, kind: kind, bounds: bounds))
    }
    return result
  }

  /// Pages whose `/Contents` reference the stream (for change reporting).
  public static func ownerPages(of members: [PDFObjectID], in graph: PDFGraph) -> [PDFObjectID] {
    guard let pages = try? PDFPageTree.pageIDs(in: graph) else { return [] }
    var result: [PDFObjectID] = []
    for pageID in pages {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      let refs: [PDFObjectID]
      switch page[PDFName("Contents")] {
      case .reference(let id)?:
        refs = [id]
      case .array(let values)?:
        refs = values.compactMap { if case .reference(let id) = $0 { return id } else { return nil } }
      default:
        refs = []
      }
      if members.contains(where: { refs.contains($0) }) { result.append(pageID) }
    }
    return result
  }

  static func decodedInstructions(streamID: PDFObjectID, in graph: PDFGraph) throws
    -> [ContentInstruction]
  {
    guard case .stream(let stream)? = graph.objects[streamID] else {
      throw PDFError(.malformed, "The app-created graphic is missing")
    }
    let filters = try PDFFilters.filterNames(in: stream.dictionary)
    let decoded: [UInt8]
    if filters.isEmpty {
      decoded = [UInt8](stream.bytes)
    } else if filters == [PDFName("FlateDecode")] {
      decoded = [UInt8](try PDFFilters.decoded(stream))
    } else {
      throw PDFError(.unsupported, "This app-created graphic uses an unsupported filter")
    }
    return try ContentParser.instructions(in: decoded)
  }

  /// Rewrite operand spans inside one appended stream, preserving its filter.
  static func rewriteOperands(
    streamID: PDFObjectID, edits: [(range: Range<Int>, replacement: [UInt8])],
    in graph: inout PDFGraph
  ) throws {
    guard case .stream(let stream)? = graph.objects[streamID] else {
      throw PDFError(.malformed, "The app-created graphic is missing")
    }
    let filters = try PDFFilters.filterNames(in: stream.dictionary)
    var decoded: [UInt8]
    if filters.isEmpty {
      decoded = [UInt8](stream.bytes)
    } else if filters == [PDFName("FlateDecode")] {
      decoded = [UInt8](try PDFFilters.decoded(stream))
    } else {
      throw PDFError(.unsupported, "This app-created graphic uses an unsupported filter")
    }
    for (range, _) in edits {
      guard range.lowerBound >= 0, range.upperBound <= decoded.count else {
        throw PDFError(.malformed, "The app-created graphic changed under the edit")
      }
    }
    for (range, replacement) in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      decoded.replaceSubrange(range, with: replacement)
    }
    var dictionary = stream.dictionary
    let bytes: Data
    if filters == [PDFName("FlateDecode")] {
      bytes = try PDFFilters.encodeFlate(Data(decoded))
      dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
      dictionary.removeValue(forKey: PDFName("DecodeParms"))
      dictionary.removeValue(forKey: PDFName("DP"))
    } else {
      bytes = Data(decoded)
      dictionary.removeValue(forKey: PDFName("Filter"))
      dictionary.removeValue(forKey: PDFName("DecodeParms"))
      dictionary.removeValue(forKey: PDFName("DP"))
    }
    dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
    graph.objects[streamID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))
  }

  static func numbers(of operands: [ContentOperand]) throws -> [Double] {
    let values = operands.compactMap { ImageInventory.number(of: $0.value) }
    guard values.count == operands.count else {
      throw PDFError(.malformed, "The app-created graphic has non-numeric geometry")
    }
    return values
  }
}

/// P21-010: translate an image stamp or rectangle by `(dx, dy)`.
public struct MoveAddedGraphicCommand: PDFEditCommand, Equatable, Sendable {
  public let streamID: PDFObjectID
  public let dx: Double
  public let dy: Double

  public init(streamID: PDFObjectID, dx: Double, dy: Double) {
    self.streamID = streamID
    self.dx = dx
    self.dy = dy
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    AddedGraphics.ownerPages(of: [streamID], in: graph)
  }
  public var name: String { "Move Graphic" }

  public func validate(in graph: PDFGraph) throws {
    guard dx.isFinite, dy.isFinite else {
      throw PDFError(.malformed, "The graphic offset is not finite")
    }
    try AddedGraphics.requireAppCreated(streamID: streamID, in: graph)
    _ = try edits(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let edits = try edits(in: graph)
    var graph = graph
    try AddedGraphics.rewriteOperands(streamID: streamID, edits: edits, in: &graph)
    return graph
  }

  private func edits(in graph: PDFGraph) throws -> [(range: Range<Int>, replacement: [UInt8])] {
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
    switch try AddedGraphics.kindOf(streamID: streamID, in: graph) {
    case .imageStamp:
      guard let cm = instructions.last(where: { $0.operatorName == "cm" }),
        cm.operands.count == 6
      else {
        throw PDFError(.malformed, "The image stamp lost its placement matrix")
      }
      let values = try AddedGraphics.numbers(of: cm.operands)
      let e = Array(ImageInventory.numberToken(values[4] + dx).utf8)
      let f = Array(ImageInventory.numberToken(values[5] + dy).utf8)
      return [(cm.operands[4].span, e), (cm.operands[5].span, f)]
    case .rectangle:
      guard let re = instructions.first(where: { $0.operatorName == "re" }),
        re.operands.count == 4
      else {
        throw PDFError(.malformed, "The rectangle lost its geometry")
      }
      let values = try AddedGraphics.numbers(of: re.operands)
      let x = Array(ImageInventory.numberToken(values[0] + dx).utf8)
      let y = Array(ImageInventory.numberToken(values[1] + dy).utf8)
      return [(re.operands[0].span, x), (re.operands[1].span, y)]
    case .unsupported:
      throw PDFError(
        .unsupported,
        "Only image stamps and rectangles move in this profile; text, ellipses, and paths refuse")
    }
  }
}

/// P21-010: scale an image stamp or rectangle about its own origin.
public struct ScaleAddedGraphicCommand: PDFEditCommand, Equatable, Sendable {
  public let streamID: PDFObjectID
  public let scaleX: Double
  public let scaleY: Double

  public init(streamID: PDFObjectID, scaleX: Double, scaleY: Double) {
    self.streamID = streamID
    self.scaleX = scaleX
    self.scaleY = scaleY
  }

  public init(streamID: PDFObjectID, uniformScale: Double) {
    self.init(streamID: streamID, scaleX: uniformScale, scaleY: uniformScale)
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    AddedGraphics.ownerPages(of: [streamID], in: graph)
  }
  public var name: String { "Resize Graphic" }

  public func validate(in graph: PDFGraph) throws {
    guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
      throw PDFError(.malformed, "Graphic scale factors must be positive finite numbers")
    }
    try AddedGraphics.requireAppCreated(streamID: streamID, in: graph)
    _ = try edits(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let edits = try edits(in: graph)
    var graph = graph
    try AddedGraphics.rewriteOperands(streamID: streamID, edits: edits, in: &graph)
    return graph
  }

  private func edits(in graph: PDFGraph) throws -> [(range: Range<Int>, replacement: [UInt8])] {
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
    switch try AddedGraphics.kindOf(streamID: streamID, in: graph) {
    case .imageStamp:
      guard let cm = instructions.last(where: { $0.operatorName == "cm" }),
        cm.operands.count == 6
      else {
        throw PDFError(.malformed, "The image stamp lost its placement matrix")
      }
      let values = try AddedGraphics.numbers(of: cm.operands)
      return [
        (cm.operands[0].span, Array(ImageInventory.numberToken(values[0] * scaleX).utf8)),
        (cm.operands[3].span, Array(ImageInventory.numberToken(values[3] * scaleY).utf8)),
      ]
    case .rectangle:
      guard let re = instructions.first(where: { $0.operatorName == "re" }),
        re.operands.count == 4
      else {
        throw PDFError(.malformed, "The rectangle lost its geometry")
      }
      let values = try AddedGraphics.numbers(of: re.operands)
      return [
        (re.operands[2].span, Array(ImageInventory.numberToken(values[2] * scaleX).utf8)),
        (re.operands[3].span, Array(ImageInventory.numberToken(values[3] * scaleY).utf8)),
      ]
    case .unsupported:
      throw PDFError(
        .unsupported,
        "Only image stamps and rectangles resize in this profile; text, ellipses, and paths refuse")
    }
  }
}

/// P21-010: rotate an image stamp or rectangle in 90-degree steps.
/// Image stamps rotate like placed images (linear part about the origin);
/// rectangles rotate about their own center, swapping extent for quarter turns.
public struct RotateAddedGraphicCommand: PDFEditCommand, Equatable, Sendable {
  public let streamID: PDFObjectID
  public let degrees: Int

  public init(streamID: PDFObjectID, degrees: Int) {
    self.streamID = streamID
    self.degrees = degrees
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    AddedGraphics.ownerPages(of: [streamID], in: graph)
  }
  public var name: String { "Rotate Graphic" }

  public func validate(in graph: PDFGraph) throws {
    guard degrees % 90 == 0 else {
      throw PDFError(.malformed, "Graphic rotation must be a multiple of 90 degrees")
    }
    try AddedGraphics.requireAppCreated(streamID: streamID, in: graph)
    _ = try edits(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let edits = try edits(in: graph)
    var graph = graph
    try AddedGraphics.rewriteOperands(streamID: streamID, edits: edits, in: &graph)
    return graph
  }

  private func edits(in graph: PDFGraph) throws -> [(range: Range<Int>, replacement: [UInt8])] {
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
    switch try AddedGraphics.kindOf(streamID: streamID, in: graph) {
    case .imageStamp:
      guard let cm = instructions.last(where: { $0.operatorName == "cm" }),
        cm.operands.count == 6
      else {
        throw PDFError(.malformed, "The image stamp lost its placement matrix")
      }
      let values = try AddedGraphics.numbers(of: cm.operands)
      let rotation: [Double]
      switch ((degrees % 360) + 360) % 360 {
      case 0: rotation = [1, 0, 0, 1, 0, 0]
      case 90: rotation = [0, 1, -1, 0, 0, 0]
      case 180: rotation = [-1, 0, 0, -1, 0, 0]
      default: rotation = [0, -1, 1, 0, 0, 0]
      }
      let local = [values[0], values[1], values[2], values[3], 0, 0]
      let rotated = ImageInventory.concat(rotation, local)
      let result = [
        rotated[0], rotated[1], rotated[2], rotated[3],
        rotated[4] + values[4], rotated[5] + values[5],
      ]
      return zip(cm.operands, result).map {
        ($0.0.span, Array(ImageInventory.numberToken($0.1).utf8))
      }
    case .rectangle:
      guard let re = instructions.first(where: { $0.operatorName == "re" }),
        re.operands.count == 4
      else {
        throw PDFError(.malformed, "The rectangle lost its geometry")
      }
      let values = try AddedGraphics.numbers(of: re.operands)
      let (x, y, w, h) = (values[0], values[1], values[2], values[3])
      let center = [x + w / 2, y + h / 2]
      let result: [Double]
      switch ((degrees % 360) + 360) % 360 {
      case 90, 270:
        result = [center[0] - h / 2, center[1] - w / 2, h, w]
      default:
        result = [x, y, w, h]
      }
      return zip(re.operands, result).map {
        ($0.0.span, Array(ImageInventory.numberToken($0.1).utf8))
      }
    case .unsupported:
      throw PDFError(
        .unsupported,
        "Only image stamps and rectangles rotate in this profile; text, ellipses, and paths refuse")
    }
  }
}
