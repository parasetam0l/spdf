import AppKit
import PDFCore
import PDFEditing

/// PAG-06/PAG-07: the values collected by the Page Marks dialog.
struct PageMarkRequest {
  let mark: RepeatedMark
  /// Zero-based document page indices in sequence order.
  let pageIndices: [Int]
  let margin: Double
  let placement: RepeatedMarkPlacement
  /// The applied set being replaced, or nil when a new set is added.
  let existingGroup: RepeatedMarkGroup?
}

/// PAG-06/PAG-07: one dialog for adding a page mark set, updating an applied
/// set in place, or verifying the sets already applied.
///
/// The document owns the commit and its single undo step; this editor only
/// collects, validates and previews the request. Existing sets are prefilled
/// from their stored settings, so an update replaces the old paint instead of
/// stacking a duplicate mark.
@MainActor
enum PageMarkEditor {
  static func request(
    groups: [RepeatedMarkGroup], pageIDs: [PDFObjectID], graph: PDFGraph
  ) -> PageMarkRequest? {
    let pageCount = pageIDs.count
    guard pageCount > 0 else { return nil }
    let editable = groups.filter(\.isEditable)
    var editing: RepeatedMarkGroup?
    if !groups.isEmpty {
      let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
      selector.addItem(withTitle: "Add a new mark set")
      for group in editable {
        let pageWord = group.pageIDs.count == 1 ? "page" : "pages"
        selector.addItem(
          withTitle: "Edit \(group.label) - \(group.pageIDs.count) \(pageWord)")
      }
      let verifyIndex = selector.numberOfItems
      selector.addItem(withTitle: "Verify the applied mark sets...")
      let choice = NSAlert()
      choice.messageText = "Page Marks"
      choice.informativeText = editable.isEmpty
        ? "This document has \(groups.count) applied sPDF mark set(s). Sets saved by an "
          + "older version, or authored with a custom embedded font, can be verified or "
          + "removed but not edited. Use Page > Remove Page Mark to remove one."
        : "Edit an applied mark set in place without stacking a second mark, add a new set, "
          + "or verify what the applied sets paint. Every change is one undo step."
      choice.accessoryView = selector
      choice.addButton(withTitle: "Continue")
      choice.addButton(withTitle: "Cancel")
      guard choice.runModal() == .alertFirstButtonReturn else { return nil }
      let selected = selector.indexOfSelectedItem
      if selected == verifyIndex {
        showVerification(groups: groups, pageIDs: pageIDs, graph: graph)
        return nil
      }
      if selected > 0, selected - 1 < editable.count {
        editing = editable[selected - 1]
      }
    }

    let spec = editing?.spec
    let kinds = RepeatedMarkSpec.Kind.allCases
    let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    typePopup.addItems(withTitles: kinds.map(\.displayName))
    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
    let suffixField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
    let familyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    familyPopup.addItems(withTitles: ["Helvetica", "Times", "Courier"])
    let sizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    let opacityField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    let angleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    let colorPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    colorPopup.addItems(withTitles: ["Gray", "Black", "Red", "Blue"])
    let boldCheckbox = NSButton(
      checkboxWithTitle: "Bold", target: nil, action: nil)
    let pageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
    let marginField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    let placementPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    placementPopup.addItems(withTitles: RepeatedMarkPlacement.allCases.map(\.displayName))
    let startField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    let digitsField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))

    let colors: [[Double]] = [
      [0.35, 0.35, 0.35], [0, 0, 0], [0.7, 0, 0], [0, 0.2, 0.7],
    ]
    let defaultStyle = AddedTextStyle(
      size: 48, color: colors[0], alignment: .center, opacity: 0.2)
    let style = spec?.makeMark().style ?? defaultStyle
    let pageNumbersByName = Dictionary(
      uniqueKeysWithValues: pageIDs.enumerated().map { ($0.element, $0.offset + 1) })
    var pageNumbers: [Int] = []
    if let editing {
      pageNumbers = editing.pageIDs.compactMap { pageNumbersByName[$0] }.sorted()
    }
    if pageNumbers.isEmpty {
      pageNumbers = Array(1...pageCount)
    }

    typePopup.selectItem(
      at: kinds.firstIndex(of: spec?.kind ?? .watermark) ?? 0)
    textField.stringValue = spec?.text ?? "CONFIDENTIAL"
    suffixField.stringValue = spec?.suffix ?? ""
    familyPopup.selectItem(
      at: ["helvetica", "times", "courier"].firstIndex(of: style.family.rawValue) ?? 0)
    sizeField.stringValue = numberText(spec?.size ?? style.size)
    opacityField.stringValue = numberText(spec?.opacity ?? style.opacity)
    angleField.stringValue = numberText(spec?.angle ?? 45)
    colorPopup.selectItem(at: colorIndex(for: style.color, colors: colors))
    boldCheckbox.state = style.bold ? .on : .off
    pageField.stringValue = BatesBatchPlanner.formatPageList(pageNumbers)
    marginField.stringValue = numberText(spec?.margin ?? 36)
    placementPopup.selectItem(
      at: RepeatedMarkPlacement.allCases.firstIndex(
        of: spec?.placement ?? .bottomCenter) ?? 4)
    startField.stringValue = String(spec?.start ?? 1)
    digitsField.stringValue = String(spec?.digits ?? 6)

    let rows: [[NSView]] = [
      [NSTextField(labelWithString: "Type:"), typePopup],
      [NSTextField(labelWithString: "Text / prefix:"), textField],
      [NSTextField(labelWithString: "Bates suffix:"), suffixField],
      [NSTextField(labelWithString: "Font:"), familyPopup],
      [NSTextField(labelWithString: "Size:"), sizeField],
      [NSTextField(labelWithString: "Opacity:"), opacityField],
      [NSTextField(labelWithString: "Angle:"), angleField],
      [NSTextField(labelWithString: "Color:"), colorPopup],
      [NSGridCell.emptyContentView, boldCheckbox],
      [NSTextField(labelWithString: "Pages:"), pageField],
      [NSTextField(labelWithString: "Margin:"), marginField],
      [NSTextField(labelWithString: "Placement:"), placementPopup],
      [NSTextField(labelWithString: "Bates start:"), startField],
      [NSTextField(labelWithString: "Bates digits:"), digitsField],
    ]
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 460, height: 390)
    let dialog = NSAlert()
    dialog.messageText = editing == nil ? "Add Page Mark" : "Edit Page Mark"
    var information =
      "Headers, footers, page numbers and Bates marks use the margin and placement; "
      + "watermarks are centered and rotate by the angle. Page numbers support {page} "
      + "and {pages}; Bates numbers are prefix + zero-padded number + suffix. "
      + "Excluded pages get no mark. One undo step covers every selected page."
    if let editing {
      let verification = RepeatedMarkVerifier.verify(
        editing, in: graph, pageIDs: pageIDs)
      information += "\n\nCurrent set: "
        + verification.summary.replacingOccurrences(of: "\n", with: " | ")
    }
    dialog.informativeText = information
    dialog.accessoryView = grid
    dialog.addButton(withTitle: "Preview")
    dialog.addButton(withTitle: "Cancel")
    guard dialog.runModal() == .alertFirstButtonReturn else { return nil }

    let kind = kinds[max(0, min(typePopup.indexOfSelectedItem, kinds.count - 1))]
    let family: AddedTextStyle.Family = [
      AddedTextStyle.Family.helvetica, .times, .courier,
    ][max(0, min(familyPopup.indexOfSelectedItem, 2))]
    let placement = RepeatedMarkPlacement.allCases[
      max(0, min(placementPopup.indexOfSelectedItem, RepeatedMarkPlacement.allCases.count - 1))]
    let size = Double(sizeField.stringValue) ?? style.size
    let opacity = Double(opacityField.stringValue) ?? style.opacity
    let angle = Double(angleField.stringValue) ?? 45
    let margin = max(0, Double(marginField.stringValue) ?? 36)
    let start = Int(startField.stringValue) ?? 1
    let digits = Int(digitsField.stringValue) ?? 6
    let offset = spec?.offset ?? 0
    let alignment: TextParagraphCandidate.Alignment =
      kind == .watermark ? .center : placement.alignment
    let markStyle = AddedTextStyle(
      family: family, bold: boldCheckbox.state == .on, size: size,
      color: colors[max(0, min(colorPopup.indexOfSelectedItem, colors.count - 1))],
      alignment: alignment, opacity: min(1, max(0, opacity)))
    let rawText = textField.stringValue
    let suffix = suffixField.stringValue
    let mark: RepeatedMark
    switch kind {
    case .watermark:
      let text = rawText.isEmpty ? "CONFIDENTIAL" : rawText
      mark = .watermark(text: text, style: markStyle, angle: angle)
    case .header:
      mark = .header(text: rawText, style: markStyle)
    case .footer:
      mark = .footer(text: rawText, style: markStyle)
    case .pageNumber:
      let text = rawText.contains("{page}") ? rawText : "Page {page} of {pages}"
      mark = .pageNumber(text: text, style: markStyle, offset: offset)
    case .bates:
      guard (1...12).contains(digits) else {
        NSSound.beep()
        return nil
      }
      mark = .bates(
        prefix: rawText, suffix: suffix, start: start, digits: digits,
        style: markStyle)
    }
    let indices = PageRange.parse(pageField.stringValue, pageCount: pageCount)
    guard !indices.isEmpty else {
      NSSound.beep()
      return nil
    }
    let command = AddRepeatedMarkCommand(
      pageIDs: indices.map { pageIDs[$0] }, mark: mark, margin: margin,
      placement: placement)
    let plan: RepeatedMarkPlan
    do {
      plan = try command.plan(in: graph)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Page Mark Cannot Be Applied"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return nil
    }
    let preview = NSAlert()
    preview.messageText = "Preview: \(kind.displayName)"
    var detail = plan.summary
    if let editing {
      detail += "\nReplacing: \(editing.label)"
    }
    for page in plan.pages.prefix(6) {
      detail += "\nPage \(page.pageIndex + 1): \(page.text)"
    }
    if plan.pages.count > 6 { detail += "\n..." }
    preview.informativeText = detail
    preview.addButton(withTitle: "Apply")
    preview.addButton(withTitle: "Cancel")
    guard preview.runModal() == .alertFirstButtonReturn else { return nil }
    return PageMarkRequest(
      mark: mark, pageIndices: indices, margin: margin, placement: placement,
      existingGroup: editing)
  }

  /// PAG-07: show what every applied set paints and whether it verifies.
  static func showVerification(
    groups: [RepeatedMarkGroup], pageIDs: [PDFObjectID], graph: PDFGraph
  ) {
    var lines: [String] = []
    for group in groups {
      let verification = RepeatedMarkVerifier.verify(
        group, in: graph, pageIDs: pageIDs)
      lines.append(verification.summary)
      lines.append("")
      if lines.count >= 40 { break }
    }
    let alert = NSAlert()
    alert.messageText = "Verify Page Marks"
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  static func numberText(_ value: Double) -> String {
    if value == value.rounded() { return String(Int(value)) }
    return String(format: "%g", value)
  }

  static func colorIndex(for color: [Double], colors: [[Double]]) -> Int {
    guard color.count == 3 else { return 0 }
    var best = 0
    var bestDistance = Double.infinity
    for (index, candidate) in colors.enumerated() {
      let distance = zip(color, candidate).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }
}
