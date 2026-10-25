import Foundation
import PDFCore

/// IMG-04/IMG-05: transforms and structural edits for the declared
/// page-content profile. Every public command here validates the same
/// eligibility the selection profile exposes, so the App layer cannot mutate an
/// object the canvas would not have offered.
public enum PageObjectStacking: String, Sendable, Equatable, CaseIterable {
  case front
  case back
  case forward
  case backward

  public var displayName: String {
    switch self {
    case .front: return "Bring to Front"
    case .back: return "Send to Back"
    case .forward: return "Bring Forward"
    case .backward: return "Send Backward"
    }
  }
}

/// IMG-04: transform one sPDF-authored text object (move, or uniform resize
/// for an authored text box).
///
/// The command rewrites only the object's own appended content stream and its
/// box/line metadata. Every other content stream, resource, annotation and
/// page object stays byte-identical. The affine transform is
///
///     new = anchor + (old - anchor) * scale + translate
///
/// applied to text-show baselines, rectangle paint, character/word spacing and
/// rise. A move uses scale 1; a group resize passes the member's bottom-left
/// corner as anchor and the mapped origin shift as translate.
public struct TransformTextObjectCommand: PDFEditCommand, Equatable, Sendable {
  public let streamID: PDFObjectID
  public let scale: Double
  public let anchorX: Double
  public let anchorY: Double
  public let translateX: Double
  public let translateY: Double

  public init(
    streamID: PDFObjectID, scale: Double = 1, anchorX: Double = 0, anchorY: Double = 0,
    translateX: Double, translateY: Double
  ) {
    self.streamID = streamID
    self.scale = scale
    self.anchorX = anchorX
    self.anchorY = anchorY
    self.translateX = translateX
    self.translateY = translateY
  }

  /// Move an authored text object by (dx, dy).
  public init(streamID: PDFObjectID, dx: Double, dy: Double) {
    self.init(streamID: streamID, translateX: dx, translateY: dy)
  }

  /// Uniformly scale an authored text box about its bottom-left corner and
  /// then shift it so the mapped corner lands on (targetMinX, targetMinY).
  public init(
    resizing streamID: PDFObjectID, scale: Double, anchorX: Double, anchorY: Double,
    targetMinX: Double, targetMinY: Double
  ) {
    self.init(
      streamID: streamID, scale: scale, anchorX: anchorX, anchorY: anchorY,
      translateX: targetMinX - anchorX, translateY: targetMinY - anchorY)
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    AddedGraphics.ownerPages(of: [streamID], in: graph)
  }

  public var name: String { scale == 1 ? "Move Text Object" : "Resize Text Box" }

  public func validate(in graph: PDFGraph) throws {
    guard scale.isFinite, scale > 0, anchorX.isFinite, anchorY.isFinite,
      translateX.isFinite, translateY.isFinite
    else {
      throw PDFError(.malformed, "The text-object transform is not finite")
    }
    guard PageObjectContent.isAppAuthored(streamID: streamID, in: graph) else {
      throw PDFError(
        .unsupported,
        "Only text objects added by sPDF can be moved or resized here; original page "
          + "text is not rewritten by the mixed selection.")
    }
    guard !PageObjectContent.isPageMark(streamID: streamID, in: graph) else {
      throw PDFError(
        .unsupported, "Page marks are edited through the page-mark commands, not object selection")
    }
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
    guard instructions.contains(where: { $0.operatorName == "Tj" || $0.operatorName == "TJ" })
    else {
      throw PDFError(.unsupported, "The object does not paint text in this profile")
    }
    if scale != 1 {
      guard
        let dictionary = PageObjectContent.streamDictionary(streamID, in: graph),
        PageObjectContent.textBoxGeometry(dictionary) != nil
      else {
        throw PDFError(
          .unsupported,
          "Text objects without authored box geometry support moving only; they "
            + "cannot be resized in this profile.")
      }
    }
    _ = try PageObjectStreamEdit.transformEdit(
      instructions: instructions, scale: scale, anchorX: anchorX, anchorY: anchorY,
      translateX: translateX, translateY: translateY)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    try PageObjectStreamEdit.transform(
      streamID: streamID, scale: scale, anchorX: anchorX, anchorY: anchorY,
      translateX: translateX, translateY: translateY, in: &graph)
    return graph
  }
}

/// IMG-04: detach sPDF-authored streams from one page. The objects themselves
/// are left in the graph exactly like the existing added-graphics delete
/// command does, so shared resources and unrelated content are untouched.
public struct DeletePageObjectStreamsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let streamIDs: [PDFObjectID]

  public init(pageID: PDFObjectID, streamIDs: [PDFObjectID]) {
    self.pageID = pageID
    self.streamIDs = streamIDs
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Delete Page Objects" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !streamIDs.isEmpty, Set(streamIDs).count == streamIDs.count else {
      throw PDFError(.malformed, "Select at least one unique page object")
    }
    let references = Set(try PageObjectContent.pageContents(pageID, in: graph))
    guard streamIDs.allSatisfy({ references.contains($0) }) else {
      throw PDFError(.malformed, "A selected object is not painted on this page")
    }
    for streamID in streamIDs {
      guard try PageObjectContent.streamInfo(streamID, in: graph) != nil else {
        throw PDFError(
          .unsupported,
          "Only objects added by sPDF in the mixed-selection profile can be "
            + "deleted; original page paint is never detached here.")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let removed = Set(streamIDs)
    let remaining = try PageObjectContent.pageContents(pageID, in: graph).filter {
      !removed.contains($0)
    }
    page[PDFName("Contents")] = .array(remaining.map { PDFValue.reference($0) })
    graph.objects[pageID] = .dictionary(page)
    try PageObjectStreamEdit.pruneGroups(removing: removed, in: &graph)
    return graph
  }
}

/// IMG-04: duplicate sPDF-authored streams by cloning each stream object,
/// translating the clone by (dx, dy) and inserting it directly after its
/// original in paint order. The clones are new authored objects (new stream
/// identities), share page resources safely and start ungrouped.
public struct DuplicatePageObjectStreamsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let streamIDs: [PDFObjectID]
  public let dx: Double
  public let dy: Double

  public init(pageID: PDFObjectID, streamIDs: [PDFObjectID], dx: Double, dy: Double) {
    self.pageID = pageID
    self.streamIDs = streamIDs
    self.dx = dx
    self.dy = dy
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Duplicate Page Objects" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !streamIDs.isEmpty, Set(streamIDs).count == streamIDs.count else {
      throw PDFError(.malformed, "Select at least one unique page object")
    }
    guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 0.001 else {
      throw PDFError(.malformed, "The duplicate offset is not a usable position")
    }
    let references = try PageObjectContent.pageContents(pageID, in: graph)
    let owned = Set(references)
    for streamID in streamIDs {
      guard owned.contains(streamID) else {
        throw PDFError(.malformed, "A selected object is not painted on this page")
      }
      guard try PageObjectContent.streamInfo(streamID, in: graph) != nil else {
        throw PDFError(
          .unsupported,
          "Only objects added by sPDF in the mixed-selection profile can be "
            + "duplicated; original page paint is never cloned here.")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var references = try PageObjectContent.pageContents(pageID, in: graph)
    var insertions: [(after: PDFObjectID, clone: PDFObjectID)] = []
    for streamID in streamIDs {
      guard case .stream(let stream)? = graph.objects[streamID] else {
        throw PDFError(.malformed, "The selected content stream is missing")
      }
      let cloneID = AddedContent.nextObjectID(in: graph)
      graph.objects[cloneID] = .stream(
        PDFStream(dictionary: stream.dictionary, bytes: stream.bytes))
      try PageObjectStreamEdit.transform(
        streamID: cloneID, scale: 1, anchorX: 0, anchorY: 0,
        translateX: dx, translateY: dy, in: &graph)
      insertions.append((streamID, cloneID))
    }
    for insertion in insertions {
      guard let index = references.firstIndex(of: insertion.after) else {
        throw PDFError(.malformed, "The selected content stream left the page")
      }
      references.insert(insertion.clone, at: index + 1)
    }
    page[PDFName("Contents")] = .array(references.map { PDFValue.reference($0) })
    graph.objects[pageID] = .dictionary(page)
    return graph
  }
}

/// IMG-05: change paint order for sPDF-authored streams only. The page
/// /Contents array is the paint order; native streams keep their relative
/// positions, so unrelated page content does not move. Tagged content
/// (BDC/BMC/EMC) refuses rather than risk a structure-tree mismatch.
public struct ReorderPageObjectStreamsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let streamIDs: [PDFObjectID]
  public let destination: PageObjectStacking

  public init(pageID: PDFObjectID, streamIDs: [PDFObjectID], destination: PageObjectStacking) {
    self.pageID = pageID
    self.streamIDs = streamIDs
    self.destination = destination
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { destination.displayName }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !streamIDs.isEmpty, Set(streamIDs).count == streamIDs.count else {
      throw PDFError(.malformed, "Select at least one unique page object")
    }
    let references = try PageObjectContent.pageContents(pageID, in: graph)
    guard references.count > 1 else {
      throw PDFError(
        .unsupported,
        "This page has a single content stream, so paint order cannot change.")
    }
    let owned = Set(references)
    for streamID in streamIDs {
      guard owned.contains(streamID) else {
        throw PDFError(.malformed, "A selected object is not painted on this page")
      }
      guard try PageObjectContent.streamInfo(streamID, in: graph) != nil else {
        throw PDFError(
          .unsupported,
          "Only objects added by sPDF can change paint order; original page "
            + "content keeps its place.")
      }
      let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
      guard !instructions.contains(where: {
        $0.operatorName == "BDC" || $0.operatorName == "BMC" || $0.operatorName == "EMC"
      }) else {
        throw PDFError(
          .unsupported,
          "This stream carries marked content; reordering it could break the "
            + "structure tree, so the paint order was not changed.")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var references = try PageObjectContent.pageContents(pageID, in: graph)
    let selected = Set(streamIDs)
    switch destination {
    case .front:
      let moving = references.filter(selected.contains)
      references.removeAll(where: selected.contains)
      references.append(contentsOf: moving)
    case .back:
      let moving = references.filter(selected.contains)
      references.removeAll(where: selected.contains)
      references.insert(contentsOf: moving, at: 0)
    case .forward:
      var index = references.count - 2
      while index >= 0 {
        if selected.contains(references[index]), !selected.contains(references[index + 1]) {
          references.swapAt(index, index + 1)
        }
        index -= 1
      }
    case .backward:
      var index = 1
      while index < references.count {
        if selected.contains(references[index]), !selected.contains(references[index - 1]) {
          references.swapAt(index, index - 1)
        }
        index += 1
      }
    }
    page[PDFName("Contents")] = .array(references.map { PDFValue.reference($0) })
    graph.objects[pageID] = .dictionary(page)
    return graph
  }
}

/// IMG-05: grouping through the persisted sPDF group records. Membership only
/// names streams; the paint itself is untouched, so grouping/ungrouping never
/// moves or repaints anything. Only app-authored streams can join a group
/// (document images stay outside the profile).
public enum PageObjectGrouping {
  public static func groupCommand(
    _ selection: PageObjectSelection, label: String = "Group",
    groupID: String = UUID().uuidString, in graph: PDFGraph
  ) throws -> any PDFEditCommand {
    if let refusal = selection.refusal(for: .group) {
      throw PDFError(.unsupported, refusal)
    }
    let members = selection.members.compactMap(\.streamID)
    guard members.count == selection.members.count else {
      throw PDFError(.unsupported, "Only stream-backed objects can be grouped")
    }
    let command = CreateAddedGroupCommand(members: members, label: label, groupID: groupID)
    try command.validate(in: graph)
    return command
  }

  public static func ungroupCommands(
    _ selection: PageObjectSelection, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    if let refusal = selection.refusal(for: .group) {
      throw PDFError(.unsupported, refusal)
    }
    let streams = Set(selection.members.compactMap(\.streamID))
    var commands: [any PDFEditCommand] = []
    for group in try AddedGraphicsGroups.list(in: graph)
    where !streams.isDisjoint(with: Set(group.members)) {
      let command = DeleteAddedGroupCommand(groupID: group.id)
      try command.validate(in: graph)
      commands.append(command)
    }
    guard !commands.isEmpty else {
      throw PDFError(.unsupported, "The selection is not part of a grouped set")
    }
    return commands
  }
}

/// Internal stream rewriting. Every edit is an operand span replacement inside
/// the object's own appended stream, so unrelated objects stay byte-identical.
enum PageObjectStreamEdit {
  static func transform(
    streamID: PDFObjectID, scale: Double, anchorX: Double, anchorY: Double,
    translateX: Double, translateY: Double, in graph: inout PDFGraph
  ) throws {
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
    let edits = try transformEdit(
      instructions: instructions, scale: scale, anchorX: anchorX, anchorY: anchorY,
      translateX: translateX, translateY: translateY)
    try AddedGraphics.rewriteOperands(streamID: streamID, edits: edits, in: &graph)
    try updateMetadata(
      streamID: streamID, scale: scale, anchorX: anchorX, anchorY: anchorY,
      translateX: translateX, translateY: translateY, in: &graph)
  }

  static func transformEdit(
    instructions: [ContentInstruction], scale: Double, anchorX: Double, anchorY: Double,
    translateX: Double, translateY: Double
  ) throws -> [(range: Range<Int>, replacement: [UInt8])] {
    func mapped(_ value: Double, _ anchor: Double, _ translate: Double) -> Double {
      anchor + (value - anchor) * scale + translate
    }
    var edits: [(range: Range<Int>, replacement: [UInt8])] = []
    for instruction in instructions {
      switch instruction.operatorName {
      case "Tm":
        guard instruction.operands.count == 6,
          let values = numericOperands(instruction.operands)
        else {
          throw PDFError(.malformed, "The text object has a malformed text matrix")
        }
        edits.append(
          (instruction.operands[4].span, token(mapped(values[4], anchorX, translateX))))
        edits.append(
          (instruction.operands[5].span, token(mapped(values[5], anchorY, translateY))))
      case "Tf":
        guard instruction.operands.count >= 2,
          let value = PageObjectContent.geometryNumber(instruction.operands[1].value)
        else {
          throw PDFError(.malformed, "The text object has a malformed font size")
        }
        if scale != 1 {
          edits.append((instruction.operands[1].span, token(value * scale)))
        }
      case "Tc", "Tw", "Ts":
        guard let operand = instruction.operands.first,
          let value = PageObjectContent.geometryNumber(operand.value)
        else {
          throw PDFError(.malformed, "The text object has malformed text state")
        }
        if scale != 1 {
          edits.append((operand.span, token(value * scale)))
        }
      case "re":
        guard instruction.operands.count == 4,
          let values = numericOperands(instruction.operands)
        else {
          throw PDFError(.malformed, "The text object has a malformed rectangle")
        }
        edits.append(
          (instruction.operands[0].span, token(mapped(values[0], anchorX, translateX))))
        edits.append(
          (instruction.operands[1].span, token(mapped(values[1], anchorY, translateY))))
        if scale != 1 {
          edits.append((instruction.operands[2].span, token(values[2] * scale)))
          edits.append((instruction.operands[3].span, token(values[3] * scale)))
        }
      case "cm":
        // Image-stamp placements are handled by the existing added-graphic
        // commands; text streams never carry a placement matrix.
        continue
      default:
        continue
      }
    }
    guard !edits.isEmpty else {
      throw PDFError(.unsupported, "This object has no rewritable text geometry")
    }
    return edits
  }

  private static func numericOperands(_ operands: [ContentOperand]) -> [Double]? {
    let values = operands.compactMap { PageObjectContent.geometryNumber($0.value) }
    return values.count == operands.count ? values : nil
  }

  private static func token(_ value: Double) -> [UInt8] {
    guard value.isFinite else { return Array("0".utf8) }
    return Array(ImageInventory.numberToken(value).utf8)
  }

  /// Translate box and line metadata so reopening re-selects the transformed
  /// box at its painted position. Only sPDF-authored text boxes carry it.
  private static func updateMetadata(
    streamID: PDFObjectID, scale: Double, anchorX: Double, anchorY: Double,
    translateX: Double, translateY: Double, in graph: inout PDFGraph
  ) throws {
    guard case .stream(let stream)? = graph.objects[streamID],
      var dictionary = Optional(stream.dictionary),
      let box = dictionary[PDFName("SPDFTextBox")].flatMap(boxGeometry)
    else { return }
    func mapped(_ value: Double, _ anchor: Double, _ translate: Double) -> Double {
      anchor + (value - anchor) * scale + translate
    }
    var values = box.values
    values[0] = mapped(values[0], anchorX, translateX)
    values[1] = mapped(values[1], anchorY, translateY)
    if scale != 1 { values[2] *= scale }
    dictionary[PDFName("SPDFTextBox")] = .array([
      .real(values[0]), .real(values[1]), .real(values[2]), .real(values[3]),
      box.wraps,
    ])
    if case .array(let records)? = dictionary[PDFName("SPDFTextLines")] {
      var updatedRecords: [PDFValue] = []
      for record in records {
        guard case .array(var fields) = record, fields.count >= 4,
          let x = PageObjectContent.geometryNumber(fields[2]),
          let y = PageObjectContent.geometryNumber(fields[3])
        else {
          updatedRecords.append(record)
          continue
        }
        fields[2] = .real(mapped(x, anchorX, translateX))
        fields[3] = .real(mapped(y, anchorY, translateY))
        if scale != 1 {
          if fields.count >= 5, case .array(var style) = fields[4], style.count >= 5 {
            if let size = PageObjectContent.geometryNumber(style[1]) {
              style[1] = .real(size * scale)
            }
            if let spacing = PageObjectContent.geometryNumber(style[4]) {
              style[4] = .real(spacing * scale)
            }
            fields[4] = .array(style)
          }
          if fields.count >= 6, case .array(var styles) = fields[5] {
            for index in styles.indices {
              guard case .array(var values) = styles[index], values.count == 5 else { continue }
              if let rise = PageObjectContent.geometryNumber(values[2]) {
                values[2] = .real(rise * scale)
              }
              if let wordSpacing = PageObjectContent.geometryNumber(values[3]) {
                values[3] = .real(wordSpacing * scale)
              }
              if case .real(let width) = values[4] {
                values[4] = .real(width * scale)
              }
              styles[index] = .array(values)
            }
            fields[5] = .array(styles)
          }
        }
        updatedRecords.append(.array(fields))
      }
      dictionary[PDFName("SPDFTextLines")] = .array(updatedRecords)
    }
    graph.objects[streamID] = .stream(
      PDFStream(dictionary: dictionary, bytes: stream.bytes))
  }

  private static func boxGeometry(_ value: PDFValue) -> (values: [Double], wraps: PDFValue)? {
    guard case .array(let values) = value, values.count == 5,
      let x = PageObjectContent.geometryNumber(values[0]),
      let baseline = PageObjectContent.geometryNumber(values[1]),
      let width = PageObjectContent.geometryNumber(values[2]),
      let spacing = PageObjectContent.geometryNumber(values[3]),
      case .boolean = values[4]
    else { return nil }
    return ([x, baseline, width, spacing], values[4])
  }

  /// A deleted object can no longer belong to a persisted group.
  static func pruneGroups(removing removed: Set<PDFObjectID>, in graph: inout PDFGraph) throws {
    let groups = try AddedGraphicsGroups.list(in: graph)
    guard !groups.isEmpty else { return }
    let pruned = groups.compactMap { group -> AddedGroup? in
      let members = group.members.filter { !removed.contains($0) }
      return members.isEmpty ? nil : AddedGroup(id: group.id, members: members, label: group.label)
    }
    try AddedGraphicsGroups.write(pruned, in: &graph)
  }
}
