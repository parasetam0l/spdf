import CoreGraphics
import Foundation
import PDFCore

/// IMG-04/IMG-05: the explicit page-content profile for mixed object
/// selection and arrangement.
///
/// The profile deliberately keeps identity and eligibility narrow:
///
/// * sPDF-authored content streams ("SPDFAdded") that paint a text box
///   ("SPDFTextBox" metadata), an older text object (text operators without
///   box metadata), an image stamp or a rectangle. These carry a stable stream
///   object identity, can be moved without touching unrelated paint, and are
///   safe to duplicate, delete, reorder and group.
/// * Directly drawable document image placements (q ... cm ... Do ... Q with an
///   axis-aligned page matrix and supported rectangular clipping). These can
///   be selected, moved and (when the enclosing transform is a plain positive
///   scale) resized through the existing image commands, but are never
///   deleted, duplicated, reordered or grouped here because that would rewrite
///   original page paint or shared resources.
///
/// Page marks ("SPDFMark" streams), form widgets, annotations, native page
/// text, nested form-XObject content, rotated/skewed image placements and
/// unsupported vector shapes are outside the profile and are refused with a
/// reason instead of approximated.
public enum PageObjectKind: String, Sendable, Equatable, CaseIterable, Hashable {
  /// An sPDF-authored text box with "SPDFTextBox" geometry metadata.
  case authoredTextBox
  /// An sPDF-authored text stream without box metadata (older Add Text
  /// objects and mark-free text insertions). Move-only.
  case addedText
  /// An sPDF-authored image stamp (q ... cm /Im Do Q).
  case imageStamp
  /// An sPDF-authored rectangle ("re" plus a paint operator).
  case rectangle
  /// A directly drawable image placement that already exists in the PDF.
  case documentImage

  public var displayName: String {
    switch self {
    case .authoredTextBox: return "Text box"
    case .addedText: return "Text object"
    case .imageStamp: return "Image stamp"
    case .rectangle: return "Rectangle"
    case .documentImage: return "Document image"
    }
  }

  /// App-authored streams are the only objects with an identity this profile
  /// may detach, clone or reorder.
  public var isAppAuthored: Bool { self != .documentImage }
}

/// How an object may participate in a group resize.
public enum PageObjectResizeRule: String, Sendable, Equatable {
  /// Independent X and Y scaling is supported.
  case free
  /// Only uniform scaling is supported (text keeps its font size ratio).
  case uniformOnly
  /// The object supports moving but not resizing in this profile.
  case never
}

/// One arrangement operation with its declared eligibility.
public enum PageObjectCapability: String, Sendable, Equatable, CaseIterable {
  case move
  case resize
  case delete
  case duplicate
  case reorder
  case group
}

/// One page object the mixed-selection canvas may address. Page-space bounds
/// are [x0, y0, x1, y1]; hitBounds is the narrower visible region for a
/// clipped document image (nil means bounds is already the hit region).
public struct PageObjectRef: Sendable, Equatable, Hashable {
  public let pageID: PDFObjectID
  public let kind: PageObjectKind
  /// Stable content-stream identity for app-authored objects.
  public let streamID: PDFObjectID?
  /// Position of the stream in the page /Contents array (paint order).
  public let streamIndex: Int?
  /// Placement index for a document image, resolved against the current graph.
  public let imagePlacementIndex: Int?
  public let bounds: [Double]
  public let hitBounds: [Double]?
  /// Monotonic paint rank; larger paints later. Streams use their /Contents
  /// position, document images their enclosing segment position plus their
  /// instruction offset inside it.
  public let paintRank: Double
  /// Resize eligibility for this instance (instance-specific for document
  /// images whose enclosing transform cannot be rewritten safely).
  public let resizeRule: PageObjectResizeRule
  /// Set when this object belongs to a persisted sPDF object group.
  public let groupID: String?

  public init(
    pageID: PDFObjectID, kind: PageObjectKind, streamID: PDFObjectID? = nil,
    streamIndex: Int? = nil, imagePlacementIndex: Int? = nil, bounds: [Double],
    hitBounds: [Double]? = nil, paintRank: Double = 0,
    resizeRule: PageObjectResizeRule? = nil, groupID: String? = nil
  ) {
    self.pageID = pageID
    self.kind = kind
    self.streamID = streamID
    self.streamIndex = streamIndex
    self.imagePlacementIndex = imagePlacementIndex
    self.bounds = bounds
    self.hitBounds = hitBounds
    self.paintRank = paintRank
    self.resizeRule =
      resizeRule
      ?? (kind == .authoredTextBox
        ? .uniformOnly
        : (kind == .addedText ? .never : .free))
    self.groupID = groupID
  }

  /// Stable identity inside one page/graph revision.
  public var identity: String {
    if let streamID {
      return "stream:\(pageID.number):\(pageID.generation):\(streamID.number):"
        + "\(streamID.generation):\(kind.rawValue)"
    }
    return "placement:\(pageID.number):\(pageID.generation):"
      + "\(imagePlacementIndex ?? -1):\(kind.rawValue)"
  }

  /// The region pointer hits and marquee selection tests.
  public var hitRect: [Double] { hitBounds ?? bounds }

  public func supports(_ capability: PageObjectCapability) -> Bool {
    switch capability {
    case .move: return true
    case .resize: return resizeRule != .never
    case .delete, .duplicate, .reorder, .group: return kind.isAppAuthored
    }
  }

  public func contains(point: [Double]) -> Bool {
    let rect = hitRect
    guard rect.count == 4, point.count == 2, point.allSatisfy(\.isFinite) else { return false }
    return point[0] >= rect[0] && point[0] <= rect[2]
      && point[1] >= rect[1] && point[1] <= rect[3]
  }
}

/// One transform mapping a member's rectangle under a group resize: the
/// member moves by dx/dy and then scales about its own bottom-left corner.
public struct PageObjectTransform: Sendable, Equatable {
  public let dx: Double
  public let dy: Double
  public let scaleX: Double
  public let scaleY: Double

  public init(dx: Double, dy: Double, scaleX: Double, scaleY: Double) {
    self.dx = dx
    self.dy = dy
    self.scaleX = scaleX
    self.scaleY = scaleY
  }

  public var isIdentity: Bool {
    abs(dx) < 1e-9 && abs(dy) < 1e-9 && abs(scaleX - 1) < 1e-9
      && abs(scaleY - 1) < 1e-9
  }
}

/// Rectangle math shared by the selection and arrangement layers.
public enum PageObjectRects {
  public static func valid(_ rect: [Double]) -> Bool {
    rect.count == 4 && rect.allSatisfy(\.isFinite) && rect[2] > rect[0] && rect[3] > rect[1]
  }

  public static func union(_ rects: [[Double]]) -> [Double]? {
    var result: [Double]? = nil
    for rect in rects {
      guard valid(rect) else { continue }
      guard var current = result else {
        result = rect
        continue
      }
      current = [
        Swift.min(current[0], rect[0]), Swift.min(current[1], rect[1]),
        Swift.max(current[2], rect[2]), Swift.max(current[3], rect[3]),
      ]
      result = current
    }
    return result
  }

  public static func intersects(_ a: [Double], _ b: [Double]) -> Bool {
    guard valid(a), valid(b) else { return false }
    return a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3]
  }

  public static func contains(_ outer: [Double], _ inner: [Double]) -> Bool {
    guard valid(outer), valid(inner) else { return false }
    return inner[0] >= outer[0] && inner[1] >= outer[1] && inner[2] <= outer[2]
      && inner[3] <= outer[3]
  }

  /// IMG-04 math: one group transform applied to a member. Scaling each
  /// member about its own origin loses the spacing between members, so the
  /// mapping includes the translation that preserves the group relationship.
  public static func mapping(member: [Double], from group: [Double], to destination: [Double])
    -> PageObjectTransform?
  {
    guard valid(member), valid(group), valid(destination) else { return nil }
    let scaleX = (destination[2] - destination[0]) / (group[2] - group[0])
    let scaleY = (destination[3] - destination[1]) / (group[3] - group[1])
    let dx = destination[0] + (member[0] - group[0]) * scaleX - member[0]
    let dy = destination[1] + (member[1] - group[1]) * scaleY - member[1]
    guard scaleX.isFinite, scaleY.isFinite, dx.isFinite, dy.isFinite,
      scaleX > 0, scaleY > 0
    else { return nil }
    return PageObjectTransform(dx: dx, dy: dy, scaleX: scaleX, scaleY: scaleY)
  }
}

/// A validated mixed selection on one page: at least one member, one page,
/// unique identities, valid page-space bounds.
public struct PageObjectSelection: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let members: [PageObjectRef]

  public init(pageID: PDFObjectID, members: [PageObjectRef]) throws {
    guard !members.isEmpty else {
      throw PDFError(.malformed, "Select at least one page object")
    }
    guard members.allSatisfy({ $0.pageID == pageID }) else {
      throw PDFError(.unsupported, "A mixed selection must stay on one page")
    }
    var seen = Set<String>()
    for member in members {
      guard PageObjectRects.valid(member.bounds) else {
        throw PDFError(.malformed, "A selected object has invalid page bounds")
      }
      guard seen.insert(member.identity).inserted else {
        throw PDFError(.malformed, "A selected object appears twice")
      }
    }
    self.pageID = pageID
    self.members = members.sorted {
      $0.paintRank == $1.paintRank ? $0.identity < $1.identity : $0.paintRank < $1.paintRank
    }
  }

  /// Build a selection from already-resolved refs, inferring the page.
  public static func make(_ members: [PageObjectRef]) throws -> PageObjectSelection {
    guard let first = members.first else {
      throw PDFError(.malformed, "Select at least one page object")
    }
    return try PageObjectSelection(pageID: first.pageID, members: members)
  }

  public var count: Int { members.count }
  public var bounds: [Double]? { PageObjectRects.union(members.map(\.bounds)) }
  public var hitBounds: [Double]? { PageObjectRects.union(members.map(\.hitRect)) }
  public var kinds: Set<PageObjectKind> { Set(members.map(\.kind)) }
  public var isMixed: Bool { kinds.count > 1 }

  public func contains(_ ref: PageObjectRef) -> Bool {
    members.contains { $0.identity == ref.identity }
  }

  public func supports(_ capability: PageObjectCapability) -> Bool {
    switch capability {
    case .move:
      return true
    case .resize:
      return resizeRule != nil
    case .delete, .duplicate, .reorder, .group:
      return members.allSatisfy { $0.supports(capability) }
    }
  }

  /// Combined resize rule: nil when any member cannot resize at all.
  public var resizeRule: PageObjectResizeRule? {
    if members.contains(where: { $0.resizeRule == .never }) { return nil }
    if members.contains(where: { $0.resizeRule == .uniformOnly }) { return .uniformOnly }
    return .free
  }

  /// Actionable reason when the selection cannot perform a capability, or nil
  /// when it can.
  public func refusal(for capability: PageObjectCapability) -> String? {
    if capability == .resize {
      return resizeRule == nil
        ? "The selection includes a text object that supports moving only; "
          + "text objects cannot be resized in this profile."
        : nil
    }
    guard supports(capability) else {
      let blocked = members.filter { !$0.supports(capability) }.map(\.kind.displayName)
      let names = Array(Set(blocked)).sorted().joined(separator: ", ")
      switch capability {
      case .delete:
        return
          "The selection includes original page content (\(names)). Only objects "
          + "added by sPDF can be deleted here."
      case .duplicate:
        return
          "The selection includes original page content (\(names)). Only objects "
          + "added by sPDF can be duplicated here."
      case .reorder:
        return
          "The selection includes original page content (\(names)). Paint order can "
          + "only be changed for objects added by sPDF."
      case .group:
        return
          "The selection includes original page content (\(names)). Only objects "
          + "added by sPDF can be grouped."
      case .move, .resize:
        return "This selection cannot perform that action."
      }
    }
    return nil
  }

  /// Summary label for the inspector/dialog: "3 objects (2 text boxes, 1 image stamp)".
  public var label: String {
    guard count > 1 else { return members[0].kind.displayName }
    let counts = Dictionary(grouping: members.map(\.kind), by: { $0 }).mapValues(\.count)
    let parts = counts.keys.sorted { $0.rawValue < $1.rawValue }.map { kind -> String in
      let amount = counts[kind] ?? 0
      return "\(amount) \(kind.displayName.lowercased())\(amount == 1 ? "" : "s")"
    }
    return "\(count) objects (\(parts.joined(separator: ", ")))"
  }

  /// Shift-click composition: remove an already-selected object, otherwise add
  /// it. Returns nil when toggling leaves nothing selected.
  public func toggling(_ ref: PageObjectRef) throws -> PageObjectSelection? {
    guard ref.pageID == pageID else {
      throw PDFError(.unsupported, "A mixed selection must stay on one page")
    }
    if contains(ref) {
      let remaining = members.filter { $0.identity != ref.identity }
      guard !remaining.isEmpty else { return nil }
      return try PageObjectSelection(pageID: pageID, members: remaining)
    }
    return try PageObjectSelection(pageID: pageID, members: members + [ref])
  }
}

/// One visible object the profile deliberately refuses, with its page-space
/// bounds and an actionable reason. The canvas shows these for clicks that land
/// on content the mixed-selection profile cannot address.
public struct PageObjectRefusal: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let bounds: [Double]
  public let reason: String

  public init(pageID: PDFObjectID, bounds: [Double], reason: String) {
    self.pageID = pageID
    self.bounds = bounds
    self.reason = reason
  }
}

/// Marquee semantics.
public enum PageObjectMarqueeMode: String, Sendable, Equatable, CaseIterable {
  /// Any overlap selects (common rubber-band behavior).
  case intersecting
  /// The marquee must fully contain the object.
  case containing
}

/// IMG-04/IMG-05: the explicit page-content profile implementation.
public enum PageObjectSelectionProfile {
  /// Human-readable name used by dialogs and evidence.
  public static let name = "sPDF page-content objects"

  /// The declared profile and its boundary, shown in the arrange dialog.
  public static let declaredProfile =
    "Mixed selection covers text boxes and text objects added by sPDF, sPDF "
    + "image stamps and rectangles, and directly editable document image "
    + "placements on the same page. Page marks, forms, annotations, native page "
    + "text, nested form content, rotated or clipped image placements the canvas "
    + "cannot rewrite, and unsupported vector shapes stay outside this profile "
    + "and are refused with a reason."

  /// Every selectable object on one page in paint order (back to front).
  public static func selectable(pageID: PDFObjectID, in graph: PDFGraph) throws
    -> [PageObjectRef]
  {
    let references = try PageObjectContent.pageContents(pageID, in: graph)
    let groups = (try? AddedGraphicsGroups.list(in: graph)) ?? []
    var groupByMember: [PDFObjectID: String] = [:]
    for group in groups {
      for member in group.members { groupByMember[member] = group.id }
    }
    var result: [PageObjectRef] = []
    for (index, streamID) in references.enumerated() {
      guard let info = try PageObjectContent.streamInfo(streamID, in: graph) else { continue }
      guard let kind = info.kind else { continue }
      result.append(
        PageObjectRef(
          pageID: pageID, kind: kind, streamID: streamID, streamIndex: index,
          bounds: info.bounds,
          paintRank: Double(index),
          resizeRule: info.resizeRule,
          groupID: groupByMember[streamID]))
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    for (index, placement) in placements.enumerated() {
      guard let bounds = documentImageBounds(placement),
        !result.contains(where: { existing in
          existing.kind == .imageStamp && approximatelyEqual(existing.bounds, bounds)
        })
      else { continue }
      let segmentIndex = content.segmentIndex(
        for: content.instructions[placement.instructionIndex].span) ?? 0
      result.append(
        PageObjectRef(
          pageID: pageID, kind: .documentImage, imagePlacementIndex: index,
          bounds: bounds, hitBounds: placement.canvasVisibleBounds,
          paintRank: Double(segmentIndex) + Double(placement.instructionIndex) / 1_000_000,
          resizeRule: documentImageResizeRule(placement)))
    }
    return result.sorted {
      $0.paintRank == $1.paintRank ? $0.identity < $1.identity : $0.paintRank < $1.paintRank
    }
  }

  /// Topmost selectable object under a page point, or nil.
  public static func object(at point: [Double], pageID: PDFObjectID, in graph: PDFGraph)
    throws -> PageObjectRef?
  {
    let candidates = try selectable(pageID: pageID, in: graph)
    return candidates.reversed().first { $0.contains(point: point) }
  }

  /// Objects selected by a marquee rectangle.
  public static func marquee(
    pageID: PDFObjectID, rect: [Double], mode: PageObjectMarqueeMode = .intersecting,
    in graph: PDFGraph
  ) throws -> PageObjectSelection? {
    guard PageObjectRects.valid(rect) else { return nil }
    let candidates = try selectable(pageID: pageID, in: graph)
    let hits = candidates.filter { candidate in
      switch mode {
      case .intersecting: return PageObjectRects.intersects(candidate.hitRect, rect)
      case .containing: return PageObjectRects.contains(rect, candidate.hitRect)
      }
    }
    guard !hits.isEmpty else { return nil }
    return try PageObjectSelection(pageID: pageID, members: hits)
  }

  /// Objects the profile refuses on this page, for point-of-use explanations.
  public static func refusals(pageID: PDFObjectID, in graph: PDFGraph) throws
    -> [PageObjectRefusal]
  {
    var result: [PageObjectRefusal] = []
    let references = try PageObjectContent.pageContents(pageID, in: graph)
    for streamID in references {
      guard
        let dictionary = PageObjectContent.streamDictionary(streamID, in: graph),
        dictionary[PDFName("SPDFAdded")] == .boolean(true),
        dictionary[PDFName("SPDFMark")] == nil
      else { continue }
      guard let instructions = try? AddedGraphics.decodedInstructions(
        streamID: streamID, in: graph)
      else { continue }
      if instructions.contains(where: { $0.operatorName == "Tj" || $0.operatorName == "TJ" }) {
        continue
      }
      if PageObjectContent.isImageStamp(instructions)
        || PageObjectContent.isRectangle(instructions)
      {
        continue
      }
      if let bounds = PageObjectContent.pathBounds(instructions),
        PageObjectRects.valid(bounds)
      {
        result.append(
          PageObjectRefusal(
            pageID: pageID, bounds: bounds,
            reason:
              "This sPDF vector shape is outside the mixed-selection profile "
              + "(only image stamps and rectangles transform); the PDF is unchanged."))
      }
    }
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    for placement in placements {
      guard documentImageBounds(placement) == nil,
        PageObjectRects.valid(placement.bounds)
      else { continue }
      let reason: String
      if placement.depth > 0 {
        reason =
          "This image is drawn inside a reusable form; mixed selection refuses it "
          + "because its shared transform cannot be rewritten safely."
      } else if !placement.hasSupportedClipping {
        reason =
          "This image uses a clipping path the canvas cannot hit-test exactly; "
          + "mixed selection refuses it instead of guessing its visible region."
      } else if !placement.isDirectlyEditable {
        reason =
          "This image is not drawn in the supported q...cm...Do...Q pattern; mixed "
          + "selection cannot rewrite its placement."
      } else {
        reason =
          "This image has a rotated or skewed placement; mixed selection supports "
          + "axis-aligned placements only."
      }
      result.append(PageObjectRefusal(pageID: pageID, bounds: placement.bounds, reason: reason))
    }
    return result
  }

  /// Membership of the persisted sPDF object group that contains streamID.
  public static func groupMembers(streamID: PDFObjectID, in graph: PDFGraph) throws
    -> [PDFObjectID]
  {
    for group in try AddedGraphicsGroups.list(in: graph) where group.members.contains(streamID) {
      return group.members
    }
    return []
  }

  /// Expand a selection so a click on one member of a persisted group selects
  /// the whole group. Document images are never group members.
  public static func expandingGroups(_ selection: PageObjectSelection, in graph: PDFGraph)
    throws -> PageObjectSelection
  {
    let groups = try AddedGraphicsGroups.list(in: graph)
    let selectedStreams = Set(selection.members.compactMap(\.streamID))
    var memberStreams = selectedStreams
    for group in groups where !selectedStreams.isDisjoint(with: Set(group.members)) {
      memberStreams.formUnion(group.members)
    }
    guard memberStreams != selectedStreams else { return selection }
    let selectable = try selectable(pageID: selection.pageID, in: graph)
    var combined = selection.members
    var seen = Set(combined.map(\.identity))
    for candidate in selectable {
      guard let streamID = candidate.streamID, memberStreams.contains(streamID) else { continue }
      if seen.insert(candidate.identity).inserted { combined.append(candidate) }
    }
    return try PageObjectSelection(pageID: selection.pageID, members: combined)
  }

  // MARK: - Internal geometry/classification

  private static func documentImageBounds(_ placement: ImagePlacement) -> [Double]? {
    guard placement.depth == 0, placement.isDirectlyEditable,
      placement.hasSupportedClipping,
      placement.matrix.count == 6, placement.matrix.allSatisfy(\.isFinite),
      placement.matrix[0] > 0, placement.matrix[3] > 0,
      abs(placement.matrix[1]) < 1e-9, abs(placement.matrix[2]) < 1e-9,
      PageObjectRects.valid(placement.bounds),
      let visible = placement.canvasVisibleBounds, PageObjectRects.valid(visible)
    else { return nil }
    return placement.bounds
  }

  private static func documentImageResizeRule(_ placement: ImagePlacement) -> PageObjectResizeRule {
    guard placement.localMatrix.count == 6, placement.outerMatrix.count == 6,
      placement.localMatrix.allSatisfy(\.isFinite), placement.outerMatrix.allSatisfy(\.isFinite),
      abs(placement.localMatrix[1]) < 1e-9, abs(placement.localMatrix[2]) < 1e-9,
      abs(placement.outerMatrix[1]) < 1e-9, abs(placement.outerMatrix[2]) < 1e-9,
      placement.localMatrix[0] > 0, placement.localMatrix[3] > 0,
      placement.outerMatrix[0] > 0, placement.outerMatrix[3] > 0
    else { return .never }
    return .free
  }

  private static func approximatelyEqual(_ lhs: [Double], _ rhs: [Double]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.01 }
  }
}

/// Internal decoding shared by selection and the transform commands.
enum PageObjectContent {
  struct StreamInfo {
    let kind: PageObjectKind?
    let bounds: [Double]
    let resizeRule: PageObjectResizeRule
  }

  static func pageContents(_ pageID: PDFObjectID, in graph: PDFGraph) throws -> [PDFObjectID] {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      return [id]
    case .array(let values)?:
      return try values.map { value in
        guard case .reference(let id) = value else {
          throw PDFError(.malformed, "Page content array member is not a reference")
        }
        return id
      }
    case nil, .null?:
      return []
    default:
      throw PDFError(.malformed, "Page contents entry is not a stream reference")
    }
  }

  static func streamDictionary(_ streamID: PDFObjectID, in graph: PDFGraph)
    -> [PDFName: PDFValue]?
  {
    guard case .stream(let stream)? = graph.objects[streamID] else { return nil }
    return stream.dictionary
  }

  static func isAppAuthored(streamID: PDFObjectID, in graph: PDFGraph) -> Bool {
    streamDictionary(streamID, in: graph)?[PDFName("SPDFAdded")] == .boolean(true)
  }

  static func isPageMark(streamID: PDFObjectID, in graph: PDFGraph) -> Bool {
    streamDictionary(streamID, in: graph)?[PDFName("SPDFMark")] != nil
  }

  static func streamInfo(_ streamID: PDFObjectID, in graph: PDFGraph) throws -> StreamInfo? {
    guard let dictionary = streamDictionary(streamID, in: graph),
      dictionary[PDFName("SPDFAdded")] == .boolean(true),
      dictionary[PDFName("SPDFMark")] == nil
    else { return nil }
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: graph)
    if instructions.contains(where: { $0.operatorName == "Tj" || $0.operatorName == "TJ" }) {
      if let box = textBoxGeometry(dictionary),
        let bounds = textBoxBounds(box: box, dictionary: dictionary, instructions: instructions)
      {
        return StreamInfo(kind: .authoredTextBox, bounds: bounds, resizeRule: .uniformOnly)
      }
      guard let bounds = textObjectBounds(instructions) else {
        return StreamInfo(kind: nil, bounds: [0, 0, 0, 0], resizeRule: .never)
      }
      return StreamInfo(kind: .addedText, bounds: bounds, resizeRule: .never)
    }
    if isImageStamp(instructions) {
      guard let values = lastMatrixOperands(instructions) else {
        return StreamInfo(kind: nil, bounds: [0, 0, 0, 0], resizeRule: .never)
      }
      let bounds = ImageInventory.bounds(of: values)
      guard PageObjectRects.valid(bounds) else {
        return StreamInfo(kind: nil, bounds: [0, 0, 0, 0], resizeRule: .never)
      }
      return StreamInfo(kind: .imageStamp, bounds: bounds, resizeRule: .free)
    }
    if isRectangle(instructions) {
      guard let rect = firstRectangle(instructions) else {
        return StreamInfo(kind: nil, bounds: [0, 0, 0, 0], resizeRule: .never)
      }
      let bounds = [rect[0], rect[1], rect[0] + rect[2], rect[1] + rect[3]]
      guard PageObjectRects.valid(bounds) else {
        return StreamInfo(kind: nil, bounds: [0, 0, 0, 0], resizeRule: .never)
      }
      return StreamInfo(kind: .rectangle, bounds: bounds, resizeRule: .free)
    }
    return StreamInfo(kind: nil, bounds: [0, 0, 0, 0], resizeRule: .never)
  }

  static func isImageStamp(_ instructions: [ContentInstruction]) -> Bool {
    instructions.contains { $0.operatorName == "Do" }
      && instructions.contains { $0.operatorName == "cm" }
  }

  static func isRectangle(_ instructions: [ContentInstruction]) -> Bool {
    guard !isImageStamp(instructions),
      !instructions.contains(where: { $0.operatorName == "Tj" || $0.operatorName == "TJ" })
    else { return false }
    return instructions.contains { $0.operatorName == "re" }
  }

  static func lastMatrixOperands(_ instructions: [ContentInstruction]) -> [Double]? {
    guard let cm = instructions.last(where: { $0.operatorName == "cm" }),
      cm.operands.count == 6
    else { return nil }
    let values = cm.operands.compactMap { geometryNumber($0.value) }
    return values.count == 6 ? values : nil
  }

  static func firstRectangle(_ instructions: [ContentInstruction]) -> [Double]? {
    guard let re = instructions.first(where: { $0.operatorName == "re" }),
      re.operands.count == 4
    else { return nil }
    let values = re.operands.compactMap { geometryNumber($0.value) }
    return values.count == 4 ? values : nil
  }

  static func geometryNumber(_ value: PDFValue) -> Double? {
    switch value {
    case .real(let number): return number
    case .integer(let number): return Double(number)
    default: return nil
    }
  }

  /// The declared box geometry plus the exact per-line baselines and x starts.
  struct TextBoxGeometry {
    let box: PageTextBox
    let lines: [(x: Double, y: Double)]
  }

  static func textBoxGeometry(_ dictionary: [PDFName: PDFValue]) -> TextBoxGeometry? {
    guard dictionary[PDFName("SPDFTextVersion")] == .integer(1),
      case .array(let geometry)? = dictionary[PDFName("SPDFTextBox")],
      geometry.count == 5,
      let x = geometryNumber(geometry[0]),
      let baseline = geometryNumber(geometry[1]),
      let width = geometryNumber(geometry[2]),
      let spacing = geometryNumber(geometry[3]),
      case .boolean(let wraps) = geometry[4],
      x.isFinite, baseline.isFinite, width.isFinite, spacing.isFinite,
      (24...2_000).contains(width), spacing > 0, spacing <= 1_000,
      abs(x) <= 1_000_000, abs(baseline) <= 1_000_000
    else { return nil }
    let box = PageTextBox(
      x: x, firstBaseline: baseline, width: width, lineSpacing: spacing, wraps: wraps)
    var lines: [(x: Double, y: Double)] = []
    if case .array(let records)? = dictionary[PDFName("SPDFTextLines")],
      records.count <= 4_000
    {
      for record in records {
        guard case .array(let fields) = record, (4...6).contains(fields.count),
          let lineX = geometryNumber(fields[2]), let lineY = geometryNumber(fields[3]),
          lineX.isFinite, lineY.isFinite
        else {
          lines.removeAll()
          break
        }
        lines.append((lineX, lineY))
      }
    }
    if lines.isEmpty { lines = [(x, baseline)] }
    return TextBoxGeometry(box: box, lines: lines)
  }

  static func textBoxBounds(
    box: TextBoxGeometry, dictionary: [PDFName: PDFValue],
    instructions: [ContentInstruction]
  ) -> [Double]? {
    _ = dictionary
    let size = textSize(instructions: instructions) ?? 12
    let baselines = box.lines.map(\.y)
    guard let minBaseline = baselines.min(), let maxBaseline = baselines.max() else {
      return nil
    }
    let minX = Swift.min(box.box.x, box.lines.map(\.x).min() ?? box.box.x)
    var maxX = box.box.x + box.box.width
    if let painted = textObjectBounds(instructions), painted[2] > maxX {
      maxX = painted[2]
    }
    let bounds = [minX, minBaseline - size * 0.25, maxX, maxBaseline + size * 0.85]
    return PageObjectRects.valid(bounds) ? bounds : nil
  }

  /// Bounds for a text stream without box metadata. Widths are conservative
  /// estimates from the emitted string bytes at the active font size; the
  /// profile only moves these objects, so bounds are used for hit-testing and
  /// alignment, never for rewriting content.
  static func textObjectBounds(_ instructions: [ContentInstruction]) -> [Double]? {
    var rects: [[Double]] = []
    var size: Double = 12
    var x: Double = 0
    var y: Double = 0
    for instruction in instructions {
      switch instruction.operatorName {
      case "Tf":
        if instruction.operands.count >= 2,
          let value = geometryNumber(instruction.operands[1].value), value > 0, value.isFinite
        {
          size = value
        }
      case "Tm":
        if instruction.operands.count == 6,
          let e = geometryNumber(instruction.operands[4].value),
          let f = geometryNumber(instruction.operands[5].value)
        {
          x = e
          y = f
        }
      case "Tj", "TJ":
        let bytes = stringByteCount(instruction.operands)
        guard bytes > 0 else { continue }
        let width = Double(bytes) * size * 0.5
        rects.append([x, y - size * 0.25, x + width, y + size * 0.85])
      case "re":
        let values = instruction.operands.compactMap { geometryNumber($0.value) }
        if values.count == 4 {
          rects.append([values[0], values[1], values[0] + values[2], values[1] + values[3]])
        }
      default:
        continue
      }
    }
    return PageObjectRects.union(rects)
  }

  static func pathBounds(_ instructions: [ContentInstruction]) -> [Double]? {
    var points: [[Double]] = []
    for instruction in instructions {
      let values = instruction.operands.compactMap { geometryNumber($0.value) }
      switch instruction.operatorName {
      case "m", "l":
        if values.count >= 2 { points.append([values[0], values[1]]) }
      case "c":
        if values.count >= 6 {
          points.append([values[0], values[1]])
          points.append([values[2], values[3]])
          points.append([values[4], values[5]])
        }
      case "v", "y":
        if values.count >= 4 {
          points.append([values[0], values[1]])
          points.append([values[2], values[3]])
        }
      case "re":
        if values.count >= 4 {
          points.append([values[0], values[1]])
          points.append([values[0] + values[2], values[1] + values[3]])
        }
      default:
        continue
      }
    }
    guard !points.isEmpty else { return nil }
    let xs = points.map { $0[0] }
    let ys = points.map { $0[1] }
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
    else { return nil }
    let bounds = [minX, minY, maxX, maxY]
    return PageObjectRects.valid(bounds) ? bounds : nil
  }

  static func textSize(instructions: [ContentInstruction]) -> Double? {
    var size: Double?
    for instruction in instructions where instruction.operatorName == "Tf" {
      guard instruction.operands.count >= 2,
        let value = geometryNumber(instruction.operands[1].value), value > 0, value.isFinite
      else { continue }
      size = value
    }
    return size
  }

  static func stringByteCount(_ operands: [ContentOperand]) -> Int {
    var total = 0
    for operand in operands {
      switch operand.value {
      case .string(let data):
        total += data.count
      case .array(let values):
        for value in values {
          if case .string(let data) = value { total += data.count }
        }
      default:
        continue
      }
    }
    return total
  }
}
