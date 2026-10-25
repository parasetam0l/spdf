import Foundation
import PDFCore

/// IMG-05: object-relative alignment directions. The App's page-alignment enum
/// lives in MacServices and keeps its own meaning (align a single object to the
/// page); this enum is specifically relative arrangement of a mixed selection.
public enum PageObjectArrangeAlignment: String, Sendable, Equatable, CaseIterable {
  case left
  case center
  case right
  case top
  case middle
  case bottom

  public var displayName: String {
    switch self {
    case .left: return "Align Left"
    case .center: return "Align Center"
    case .right: return "Align Right"
    case .top: return "Align Top"
    case .middle: return "Align Middle"
    case .bottom: return "Align Bottom"
    }
  }
}

/// IMG-05: the axis a distribution equalizes.
public enum PageObjectDistributeAxis: String, Sendable, Equatable, CaseIterable {
  case horizontal
  case vertical

  public var displayName: String {
    switch self {
    case .horizontal: return "Distribute Horizontally"
    case .vertical: return "Distribute Vertically"
    }
  }
}

/// What an alignment is relative to.
public enum PageObjectArrangementReference: String, Sendable, Equatable, CaseIterable {
  /// The selection's own bounding box (object-relative arrangement).
  case selection
  /// The page's media box.
  case page

  public var displayName: String {
    switch self {
    case .selection: return "Selection"
    case .page: return "Page"
    }
  }
}

/// The pure math IMG-05 needs. Kept separate from the commands so the dialog
/// can preview offsets and tests can check the arithmetic without a graph.
public enum PageObjectArrangementMath {
  /// Equal-gap distribution: the first and last objects in sort order keep
  /// their positions, and the spaces between adjacent objects become equal.
  /// Overlapping objects produce negative gaps and remain ordered; the
  /// result is still deterministic and finite.
  public static func distributionDeltas(rects: [[Double]], axis: PageObjectDistributeAxis)
    -> [[Double]]?
  {
    guard rects.count >= 3, rects.allSatisfy(PageObjectRects.valid) else { return nil }
    let indices = rects.indices.sorted { lhs, rhs in
      switch axis {
      case .horizontal:
        return rects[lhs][0] == rects[rhs][0]
          ? rects[lhs][1] < rects[rhs][1] : rects[lhs][0] < rects[rhs][0]
      case .vertical:
        return rects[lhs][1] == rects[rhs][1]
          ? rects[lhs][0] < rects[rhs][0] : rects[lhs][1] < rects[rhs][1]
      }
    }
    let first = rects[indices[0]]
    let last = rects[indices[rects.count - 1]]
    let minimum: Double
    let maximum: Double
    let totalExtent: Double
    switch axis {
    case .horizontal:
      minimum = first[0]
      maximum = last[2]
      totalExtent = indices.reduce(0) { $0 + (rects[$1][2] - rects[$1][0]) }
    case .vertical:
      minimum = first[1]
      maximum = last[3]
      totalExtent = indices.reduce(0) { $0 + (rects[$1][3] - rects[$1][1]) }
    }
    let span = maximum - minimum
    let gap = (span - totalExtent) / Double(rects.count - 1)
    guard gap.isFinite else { return nil }
    var deltas = Array(repeating: [0.0, 0.0], count: rects.count)
    var cursor = minimum
    for index in indices {
      switch axis {
      case .horizontal:
        deltas[index] = [cursor - rects[index][0], 0]
        cursor += (rects[index][2] - rects[index][0]) + gap
      case .vertical:
        deltas[index] = [0, cursor - rects[index][1]]
        cursor += (rects[index][3] - rects[index][1]) + gap
      }
    }
    let finite = deltas.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }
    return finite ? deltas : nil
  }

  /// Per-member translation that aligns every object to one reference edge.
  public static func alignmentDeltas(
    rects: [[Double]], alignment: PageObjectArrangeAlignment, reference: [Double]
  ) -> [[Double]]? {
    guard PageObjectRects.valid(reference), rects.allSatisfy(PageObjectRects.valid) else {
      return nil
    }
    var deltas: [[Double]] = []
    for rect in rects {
      switch alignment {
      case .left:
        deltas.append([reference[0] - rect[0], 0])
      case .center:
        deltas.append([(reference[0] + reference[2]) / 2 - (rect[0] + rect[2]) / 2, 0])
      case .right:
        deltas.append([reference[2] - rect[2], 0])
      case .top:
        deltas.append([0, reference[3] - rect[3]])
      case .middle:
        deltas.append([0, (reference[1] + reference[3]) / 2 - (rect[1] + rect[3]) / 2])
      case .bottom:
        deltas.append([0, reference[1] - rect[1]])
      }
    }
    let finite = deltas.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }
    return finite ? deltas : nil
  }
}

/// IMG-04/IMG-05: turns arrangement intent into the exact command list the App
/// commits as one transaction (one Undo, one viewer reload).
public enum PageObjectArrangement {
  /// Move every selected object by the same page-space offset.
  public static func moveCommands(
    _ selection: PageObjectSelection, dx: Double, dy: Double, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 0.001 else {
      throw PDFError(.malformed, "The move offset is not a usable position")
    }
    return try transformCommands(
      selection,
      transforms: Array(
        repeating: PageObjectTransform(dx: dx, dy: dy, scaleX: 1, scaleY: 1),
        count: selection.members.count),
      in: graph)
  }

  /// Apply one mapping per member (aligned with selection.members order).
  public static func transformCommands(
    _ selection: PageObjectSelection, transforms: [PageObjectTransform], in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    guard transforms.count == selection.members.count else {
      throw PDFError(.malformed, "Every selected object needs exactly one transform")
    }
    if let refusal = selection.refusal(for: .resize) {
      let anyScaling = transforms.contains {
        abs($0.scaleX - 1) > 1e-9 || abs($0.scaleY - 1) > 1e-9
      }
      if anyScaling { throw PDFError(.unsupported, refusal) }
    }
    if let rule = selection.resizeRule, rule == .uniformOnly {
      let uniform = transforms.allSatisfy {
        abs($0.scaleX - $0.scaleY) <= 1e-6 * Swift.max(1, abs($0.scaleX))
      }
      guard uniform else {
        throw PDFError(
          .unsupported,
          "The selection includes a text box; mixed resize must stay uniform so "
            + "font sizes and line advances scale together.")
      }
    }
    var result: [any PDFEditCommand] = []
    for (member, transform) in zip(selection.members, transforms) {
      result.append(contentsOf: try memberCommands(member, transform: transform, in: graph))
    }
    guard !result.isEmpty else {
      throw PDFError(.malformed, "The arrangement produced no changes")
    }
    return result
  }

  private static func memberCommands(
    _ member: PageObjectRef, transform: PageObjectTransform, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    let scaling = abs(transform.scaleX - 1) > 1e-9 || abs(transform.scaleY - 1) > 1e-9
    let moving = abs(transform.dx) > 1e-9 || abs(transform.dy) > 1e-9
    switch member.kind {
    case .authoredTextBox, .addedText:
      guard let streamID = member.streamID else {
        throw PDFError(.malformed, "A text selection is missing its content stream")
      }
      if scaling {
        guard member.kind == .authoredTextBox else {
          throw PDFError(
            .unsupported,
            "Text objects without box geometry support moving only in this profile.")
        }
        guard abs(transform.scaleX - transform.scaleY) <= 1e-6 else {
          throw PDFError(
            .unsupported, "Text boxes resize uniformly only; text was not distorted")
        }
        let scale = (transform.scaleX + transform.scaleY) / 2
        return [
          TransformTextObjectCommand(
            resizing: streamID, scale: scale,
            anchorX: member.bounds[0], anchorY: member.bounds[1],
            targetMinX: member.bounds[0] + transform.dx,
            targetMinY: member.bounds[1] + transform.dy)
        ]
      }
      guard moving else { return [] }
      return [TransformTextObjectCommand(streamID: streamID, dx: transform.dx, dy: transform.dy)]
    case .imageStamp, .rectangle:
      guard let streamID = member.streamID else {
        throw PDFError(.malformed, "A graphic selection is missing its content stream")
      }
      var commands: [any PDFEditCommand] = []
      if moving {
        commands.append(MoveAddedGraphicCommand(streamID: streamID, dx: transform.dx, dy: transform.dy))
      }
      if scaling {
        commands.append(
          ScaleAddedGraphicCommand(
            streamID: streamID, scaleX: transform.scaleX, scaleY: transform.scaleY))
      }
      return commands
    case .documentImage:
      guard let placementIndex = member.imagePlacementIndex else {
        throw PDFError(.malformed, "An image selection is missing its placement index")
      }
      var commands: [any PDFEditCommand] = []
      if moving {
        commands.append(
          MoveImageCommand(
            pageID: member.pageID, placementIndex: placementIndex,
            dx: transform.dx, dy: transform.dy))
      }
      if scaling {
        commands.append(
          ScaleImageCommand(
            pageID: member.pageID, placementIndex: placementIndex,
            scaleX: transform.scaleX, scaleY: transform.scaleY))
      }
      return commands
    }
  }

  /// Map a group resize (selection bounds to a destination rect) onto every
  /// member and return the commands. Relationships between members are kept
  /// because each member gets its own mapped origin shift and scale.
  public static func resizeCommands(
    _ selection: PageObjectSelection, from group: [Double], to destination: [Double],
    in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    if let refusal = selection.refusal(for: .resize) {
      throw PDFError(.unsupported, refusal)
    }
    guard let rule = selection.resizeRule else {
      throw PDFError(.unsupported, "This selection cannot be resized in this profile")
    }
    var transforms: [PageObjectTransform] = []
    for member in selection.members {
      guard let transform = PageObjectRects.mapping(
        member: member.bounds, from: group, to: destination)
      else {
        throw PDFError(.unsupported, "This selection cannot be mapped onto the target bounds")
      }
      if rule == .uniformOnly,
        abs(transform.scaleX - transform.scaleY) > 1e-6 * Swift.max(1, abs(transform.scaleX))
      {
        throw PDFError(
          .unsupported,
          "The selection includes a text box; mixed resize must stay uniform so font "
            + "sizes and line advances scale together.")
      }
      transforms.append(transform)
    }
    return try transformCommands(selection, transforms: transforms, in: graph)
  }

  /// IMG-05: align every selected object to the selection bounds or the page.
  public static func alignCommands(
    _ selection: PageObjectSelection, alignment: PageObjectArrangeAlignment,
    reference: PageObjectArrangementReference = .selection, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    guard let bounds = referenceBounds(selection, reference: reference, in: graph) else {
      throw PDFError(.malformed, "The alignment reference has no usable page bounds")
    }
    guard
      let deltas = PageObjectArrangementMath.alignmentDeltas(
        rects: selection.members.map(\.bounds), alignment: alignment, reference: bounds)
    else {
      throw PDFError(.malformed, "The selected bounds cannot be aligned")
    }
    let transforms = deltas.map {
      PageObjectTransform(dx: $0[0], dy: $0[1], scaleX: 1, scaleY: 1)
    }
    return try transformCommands(selection, transforms: transforms, in: graph)
  }

  /// IMG-05: equal-gap distribution along one axis. At least three objects are
  /// required because two objects have no interior spacing to distribute.
  public static func distributeCommands(
    _ selection: PageObjectSelection, axis: PageObjectDistributeAxis, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    guard selection.count >= 3 else {
      throw PDFError(.unsupported, "Distribute needs at least three selected objects")
    }
    guard
      let deltas = PageObjectArrangementMath.distributionDeltas(
        rects: selection.members.map(\.bounds), axis: axis)
    else {
      throw PDFError(.malformed, "The selected bounds cannot be distributed")
    }
    let transforms = deltas.map {
      PageObjectTransform(dx: $0[0], dy: $0[1], scaleX: 1, scaleY: 1)
    }
    return try transformCommands(selection, transforms: transforms, in: graph)
  }

  public static func deleteCommands(
    _ selection: PageObjectSelection, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    if let refusal = selection.refusal(for: .delete) {
      throw PDFError(.unsupported, refusal)
    }
    let streamIDs = selection.members.compactMap(\.streamID)
    guard streamIDs.count == selection.members.count else {
      throw PDFError(.unsupported, "Only stream-backed objects can be deleted here")
    }
    let commands: [any PDFEditCommand] = [
      DeletePageObjectStreamsCommand(pageID: selection.pageID, streamIDs: streamIDs)
    ]
    for command in commands { try command.validate(in: graph) }
    return commands
  }

  public static func duplicateCommands(
    _ selection: PageObjectSelection, offsetX: Double = 14, offsetY: Double = -14,
    in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    if let refusal = selection.refusal(for: .duplicate) {
      throw PDFError(.unsupported, refusal)
    }
    let streamIDs = selection.members.compactMap(\.streamID)
    guard streamIDs.count == selection.members.count else {
      throw PDFError(.unsupported, "Only stream-backed objects can be duplicated here")
    }
    let command = DuplicatePageObjectStreamsCommand(
      pageID: selection.pageID, streamIDs: streamIDs, dx: offsetX, dy: offsetY)
    try command.validate(in: graph)
    return [command]
  }

  public static func reorderCommands(
    _ selection: PageObjectSelection, destination: PageObjectStacking, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    if let refusal = selection.refusal(for: .reorder) {
      throw PDFError(.unsupported, refusal)
    }
    let streamIDs = selection.members.compactMap(\.streamID)
    guard streamIDs.count == selection.members.count else {
      throw PDFError(.unsupported, "Only stream-backed objects can change paint order")
    }
    let command = ReorderPageObjectStreamsCommand(
      pageID: selection.pageID, streamIDs: streamIDs, destination: destination)
    try command.validate(in: graph)
    return [command]
  }

  public static func groupCommands(
    _ selection: PageObjectSelection, label: String = "Group", groupID: String = UUID().uuidString,
    in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    [try PageObjectGrouping.groupCommand(selection, label: label, groupID: groupID, in: graph)]
  }

  public static func ungroupCommands(
    _ selection: PageObjectSelection, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    try PageObjectGrouping.ungroupCommands(selection, in: graph)
  }

  /// IMG-05: selects the arrangement reference bounds: the selection union or
  /// the page media box (a rotated page keeps its unrotated media box, which is
  /// the coordinate space page content lives in).
  private static func referenceBounds(
    _ selection: PageObjectSelection, reference: PageObjectArrangementReference,
    in graph: PDFGraph
  ) -> [Double]? {
    switch reference {
    case .selection:
      return selection.bounds
    case .page:
      guard case .dictionary(let page)? = graph.objects[selection.pageID] else {
        return selection.bounds
      }
      let media = DocumentInventoryBox.mediaBox(of: page, in: graph)
      return PageObjectRects.valid(media) ? media : selection.bounds
    }
  }
}

extension PageObjectRects {
  /// The CGRect form of a page-space rect, for callers that already use
  /// CoreGraphics (the App canvas and the resize mapping).
  public static func cgRect(_ rect: [Double]) -> CGRect? {
    guard valid(rect) else { return nil }
    return CGRect(x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1])
  }

  /// The page-space array form of a CGRect.
  public static func pageRect(_ rect: CGRect) -> [Double]? {
    let values = [
      Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY),
    ]
    return valid(values) ? values : nil
  }
}
