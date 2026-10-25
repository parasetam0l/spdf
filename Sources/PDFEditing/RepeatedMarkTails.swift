import Foundation
import PDFCore

/// PAG-06: one applied repeated-mark set found in the page content.
public struct RepeatedMarkGroup: Sendable, Equatable {
  public let groupID: String
  public let label: String
  public let pageIDs: [PDFObjectID]
  /// PAG-06/PAG-07: the editable settings stored with the set, or nil for
  /// marks written before settings were recorded or with a custom font.
  public let spec: RepeatedMarkSpec?

  public init(
    groupID: String, label: String, pageIDs: [PDFObjectID],
    spec: RepeatedMarkSpec? = nil
  ) {
    self.groupID = groupID
    self.label = label
    self.pageIDs = pageIDs
    self.spec = spec
  }

  /// PAG-06: whether this set can be updated in place. Sets authored with a
  /// caller-supplied font stay removable but not editable, because the font
  /// program is not part of the settings record.
  public var isEditable: Bool {
    guard let spec else { return false }
    return !spec.usesCustomFont
  }

  /// PAG-07: the marks of this set on one page.
  public var pageCount: Int { pageIDs.count }
}

/// PAG-06/PAG-07: discover the sPDF-authored mark sets that can be verified,
/// updated in place or removed as a unit.
public enum RepeatedMarkInventory {
  public static func groups(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> [RepeatedMarkGroup] {
    var order: [String] = []
    var labels: [String: String] = [:]
    var specs: [String: RepeatedMarkSpec] = [:]
    var pages: [String: [PDFObjectID]] = [:]
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      for reference in contentReferences(page[PDFName("Contents")]) {
        guard case .reference(let streamID) = reference,
          case .stream(let stream)? = graph.objects[streamID],
          case .string(let groupData)? = stream.dictionary[PDFName("SPDFMark")]
        else { continue }
        let groupID = String(decoding: groupData, as: UTF8.self)
        if labels[groupID] == nil {
          order.append(groupID)
          if case .string(let labelData)? = stream.dictionary[PDFName("SPDFMarkLabel")] {
            labels[groupID] = String(decoding: labelData, as: UTF8.self)
          } else {
            labels[groupID] = "Page mark"
          }
          if case .string(let specData)? = stream.dictionary[RepeatedMarkSpec.streamKey] {
            specs[groupID] = RepeatedMarkSpec.decode(specData)
          }
        }
        if pages[groupID]?.last != pageID {
          pages[groupID, default: []].append(pageID)
        }
      }
    }
    return order.map { groupID in
      let spec = specs[groupID]
      let label = spec?.displayLabel ?? labels[groupID] ?? "Page mark"
      return RepeatedMarkGroup(
        groupID: groupID, label: label, pageIDs: pages[groupID] ?? [], spec: spec)
    }
  }

  /// PAG-06: the content streams of one set on one page, in paint order.
  public static func streamIDs(
    groupID: String, pageID: PDFObjectID, in graph: PDFGraph
  ) -> [PDFObjectID] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    var result: [PDFObjectID] = []
    for reference in contentReferences(page[PDFName("Contents")]) {
      guard case .reference(let streamID) = reference,
        case .stream(let stream)? = graph.objects[streamID],
        case .string(let group)? = stream.dictionary[PDFName("SPDFMark")],
        String(decoding: group, as: UTF8.self) == groupID
      else { continue }
      result.append(streamID)
    }
    return result
  }

  static func contentReferences(_ value: PDFValue?) -> [PDFValue] {
    if case .reference(let reference)? = value { return [.reference(reference)] }
    if case .array(let items)? = value { return items }
    return []
  }
}

/// PAG-06/PAG-07: verification result for one page of an applied mark set.
public struct RepeatedMarkPageVerification: Sendable, Equatable {
  public let pageID: PDFObjectID
  /// 1-based position of the page inside the document page list.
  public let pageNumber: Int
  public let expectedText: String?
  public let visibleText: String?
  public let streamCount: Int
  public let issues: [String]

  public var isMatched: Bool {
    issues.isEmpty && expectedText != nil && visibleText != nil
  }

  public init(
    pageID: PDFObjectID, pageNumber: Int, expectedText: String?,
    visibleText: String?, streamCount: Int, issues: [String]
  ) {
    self.pageID = pageID
    self.pageNumber = pageNumber
    self.expectedText = expectedText
    self.visibleText = visibleText
    self.streamCount = streamCount
    self.issues = issues
  }
}

/// PAG-07: an applied mark set verified against its stored settings.
public struct RepeatedMarkVerification: Sendable, Equatable {
  public let groupID: String
  public let label: String
  public let pages: [RepeatedMarkPageVerification]
  public let issues: [String]

  public var isVerified: Bool {
    issues.isEmpty && !pages.isEmpty && pages.allSatisfy(\.isMatched)
  }

  public var firstText: String? { pages.compactMap(\.expectedText).first }
  public var lastText: String? { pages.compactMap(\.expectedText).last }

  public var summary: String {
    let pageWord = pages.count == 1 ? "page" : "pages"
    var lines = [
      "\(label) - \(pages.count) \(pageWord)"
        + (isVerified ? ": verified" : ": needs attention")
    ]
    if let first = firstText, let last = lastText, first != last {
      lines.append("  applied text: \(first) - \(last)")
    } else if let first = firstText {
      lines.append("  applied text: \(first)")
    }
    for issue in issues { lines.append("  ! \(issue)") }
    for page in pages where !page.isMatched {
      for issue in page.issues { lines.append("  page \(page.pageNumber): \(issue)") }
    }
    return lines.joined(separator: "\n")
  }

  public init(
    groupID: String, label: String, pages: [RepeatedMarkPageVerification],
    issues: [String]
  ) {
    self.groupID = groupID
    self.label = label
    self.pages = pages
    self.issues = issues
  }
}

/// PAG-06/PAG-07: verify that an applied set still paints the text its stored
/// settings ask for, exactly once per recorded page. Verification reads the
/// saved page content through the normal text layout, so it also catches marks
/// that were stacked by an older build or removed outside sPDF.
public enum RepeatedMarkVerifier {
  public static func verify(
    _ group: RepeatedMarkGroup, in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> RepeatedMarkVerification {
    var issues: [String] = []
    var pages: [RepeatedMarkPageVerification] = []
    let pageNumbers = Dictionary(
      uniqueKeysWithValues: pageIDs.enumerated().map { ($0.element, $0.offset + 1) })
    if let spec = group.spec, spec.usesCustomFont {
      issues.append(
        "This set was created with a custom embedded font; it can be removed but not "
          + "verified or edited in place.")
    }
    if group.spec == nil {
      issues.append(
        "This set was saved without editable settings; its sequence can be inspected "
          + "only from the painted page content.")
    }
    for (index, pageID) in group.pageIDs.enumerated() {
      let expected = group.spec?.expectedText(
        pageIndex: index, pageCount: group.pageIDs.count)
      let streams = RepeatedMarkInventory.streamIDs(
        groupID: group.groupID, pageID: pageID, in: graph)
      var pageIssues: [String] = []
      if streams.isEmpty {
        pageIssues.append("the mark stream is missing")
      } else if streams.count > 1 {
        pageIssues.append("the mark is applied \(streams.count) times on this page")
      }
      var visible: String?
      if let expected, !expected.isEmpty {
        let normalizedExpected = normalize(expected)
        let layout = try? PageTextLayout.build(pageID: pageID, in: graph)
        let painted = layout.map { layout in
          normalize(layout.clusters.map(\.text).joined())
        } ?? ""
        if let layout {
          if painted.contains(normalizedExpected) {
            // Recover the painted line so the report names the actual text.
            visible = layout.lines.map { layout.text(in: $0) }
              .first { normalize($0).contains(normalizedExpected) }
              ?? expected
          } else {
            pageIssues.append("expected \"\(expected)\" but the saved page does not show it")
          }
        } else {
          pageIssues.append("the saved page text could not be read")
        }
      } else if !streams.isEmpty {
        visible = nil
      }
      pages.append(
        RepeatedMarkPageVerification(
          pageID: pageID, pageNumber: pageNumbers[pageID] ?? index + 1,
          expectedText: expected, visibleText: visible, streamCount: streams.count,
          issues: pageIssues))
    }
    if let spec = group.spec, spec.kind == .bates, !pages.isEmpty,
      pages.allSatisfy({ $0.isMatched })
    {
      // The stored settings produce contiguous numbers already; flag a gap
      // only when the painted text does not match the requested width.
      let numbers = (0..<pages.count).map { spec.start + $0 }
      if let last = numbers.last, String(last).count > spec.digits {
        issues.append(
          "The last number \(last) is wider than the requested \(spec.digits) digits.")
      }
    }
    return RepeatedMarkVerification(
      groupID: group.groupID, label: group.label, pages: pages, issues: issues)
  }

  static func normalize(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
  }
}

/// PAG-06: replace one applied mark set in place. The previous streams of the
/// set are removed from every scanned page and the new paint is appended with
/// the same group identity, so the action never stacks duplicate marks and
/// unrelated content and other mark sets stay intact. One transaction means
/// one undo step.
public struct UpdateRepeatedMarkCommand: PDFEditCommand, Equatable, Sendable {
  public let groupID: String
  /// Pages scanned for the previous set of this group (normally every page).
  public let allPageIDs: [PDFObjectID]
  /// New pages in sequence order.
  public let pageIDs: [PDFObjectID]
  public let mark: RepeatedMark
  public let margin: Double
  public let placement: RepeatedMarkPlacement?
  public let customFont: CustomTextFont?

  public init(
    groupID: String, allPageIDs: [PDFObjectID], pageIDs: [PDFObjectID],
    mark: RepeatedMark, margin: Double = 36,
    placement: RepeatedMarkPlacement? = nil, customFont: CustomTextFont? = nil
  ) {
    self.groupID = groupID
    self.allPageIDs = allPageIDs
    self.pageIDs = pageIDs
    self.mark = mark
    self.margin = margin
    self.placement = placement
    self.customFont = customFont
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    var pages = allPageIDs
    for pageID in pageIDs where !pages.contains(pageID) { pages.append(pageID) }
    return pages
  }
  public var name: String { "Update Page Mark" }

  public func validate(in graph: PDFGraph) throws {
    guard !groupID.isEmpty else {
      throw PDFError(.malformed, "The page mark identity is missing")
    }
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected")
    }
    guard !matchedStreamIDs(in: graph).isEmpty else {
      throw PDFError(.unsupported, "This page mark is no longer present")
    }
    let add = replacementCommand
    try add.validate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    // Remove the previous set from every scanned page, including pages that
    // leave the set, and drop the now-unreferenced content streams so repeated
    // updates do not accumulate hidden paint.
    var removedStreams: [PDFObjectID] = []
    for pageID in allPageIDs {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      let references = RepeatedMarkInventory.contentReferences(page[PDFName("Contents")])
      var kept: [PDFValue] = []
      var pageRemoved = false
      for reference in references {
        if case .reference(let streamID) = reference,
          case .stream(let stream)? = graph.objects[streamID],
          case .string(let group)? = stream.dictionary[PDFName("SPDFMark")],
          String(decoding: group, as: UTF8.self) == groupID
        {
          removedStreams.append(streamID)
          pageRemoved = true
        } else {
          kept.append(reference)
        }
      }
      guard pageRemoved else { continue }
      switch kept.count {
      case 0: page[PDFName("Contents")] = nil
      case 1: page[PDFName("Contents")] = kept[0]
      default: page[PDFName("Contents")] = .array(kept)
      }
      graph.objects[pageID] = .dictionary(page)
    }
    for streamID in removedStreams {
      if !isReferenced(streamID, byAnyOf: allPageIDs, in: graph) {
        graph.objects[streamID] = nil
      }
    }
    return try replacementCommand.apply(to: graph)
  }

  var replacementCommand: AddRepeatedMarkCommand {
    AddRepeatedMarkCommand(
      pageIDs: pageIDs, mark: mark, margin: margin, customFont: customFont,
      groupID: groupID, placement: placement)
  }

  private func matchedStreamIDs(in graph: PDFGraph) -> [PDFObjectID] {
    var result: [PDFObjectID] = []
    for pageID in allPageIDs {
      result.append(
        contentsOf: RepeatedMarkInventory.streamIDs(
          groupID: groupID, pageID: pageID, in: graph))
    }
    return result
  }

  private func isReferenced(
    _ streamID: PDFObjectID, byAnyOf pageIDs: [PDFObjectID], in graph: PDFGraph
  ) -> Bool {
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      for reference in RepeatedMarkInventory.contentReferences(page[PDFName("Contents")]) {
        if case .reference(let id) = reference, id == streamID { return true }
      }
    }
    return false
  }
}

/// PAG-06: remove every content stream belonging to one mark set. Unrelated
/// content and other mark sets are untouched; the action is one undo step.
public struct RemoveRepeatedMarkCommand: PDFEditCommand, Equatable, Sendable {
  public let groupID: String
  public let pageIDs: [PDFObjectID]

  public init(groupID: String, pageIDs: [PDFObjectID]) {
    self.groupID = groupID
    self.pageIDs = pageIDs
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Remove Page Mark" }

  public func validate(in graph: PDFGraph) throws {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected")
    }
    guard !matchedStreams(in: graph).isEmpty else {
      throw PDFError(.unsupported, "This page mark is no longer present")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    for pageID in pageIDs {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      let references = RepeatedMarkInventory.contentReferences(page[PDFName("Contents")])
      let kept = references.filter { reference in
        guard case .reference(let streamID) = reference,
          case .stream(let stream)? = graph.objects[streamID],
          case .string(let group)? = stream.dictionary[PDFName("SPDFMark")]
        else { return true }
        return String(decoding: group, as: UTF8.self) != groupID
      }
      guard kept.count != references.count else { continue }
      switch kept.count {
      case 0: page[PDFName("Contents")] = nil
      case 1: page[PDFName("Contents")] = kept[0]
      default: page[PDFName("Contents")] = .array(kept)
      }
      graph.objects[pageID] = .dictionary(page)
    }
    return graph
  }

  private func matchedStreams(in graph: PDFGraph) -> [PDFObjectID] {
    var result: [PDFObjectID] = []
    for pageID in pageIDs {
      result.append(
        contentsOf: RepeatedMarkInventory.streamIDs(
          groupID: groupID, pageID: pageID, in: graph))
    }
    return result
  }
}
