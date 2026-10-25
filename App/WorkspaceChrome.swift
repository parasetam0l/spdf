import AppKit
import Combine
import MacServices
import PDFEditing
import SwiftUI

@MainActor
final class WorkspaceDocumentState: ObservableObject {
  @Published var hasChanges = false
  @Published var canUndo = false
  @Published var canRedo = false
  nonisolated init() {}
}

struct WorkspaceToolStyle: ButtonStyle {
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: selected ? .semibold : .medium))
      .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.8))
      .padding(.horizontal, 9)
      .frame(height: 32)
      .background(
        selected
          ? Color.accentColor.opacity(0.12)
          : Color.primary.opacity(configuration.isPressed ? 0.07 : 0),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .contentShape(RoundedRectangle(cornerRadius: 5))
  }
}

/// A numeric property must not write merely because it appears or receives
/// focus. Mixed values start blank; only changes to the draft apply a value.
private struct WorkspacePointField: View {
  let label: String
  @Binding var value: Double
  var mixed = false
  var commitOnEnd = false
  @State private var draft = ""
  @State private var displayed = ""
  @FocusState private var focused: Bool

  private var formatter: NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = .current
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = 3
    return formatter
  }

  var body: some View {
    TextField(mixed ? "Mixed" : label, text: $draft)
      .focused($focused)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel(label)
      .onAppear { refresh() }
      .onChange(of: value) { _, _ in if !focused || (commitOnEnd && draft == displayed) { refresh() } }
      .onChange(of: mixed) { _, _ in if !focused || (commitOnEnd && draft == displayed) { refresh() } }
      .onChange(of: draft) { _, text in
        guard focused, text != displayed else { return }
        if !commitOnEnd { applyDraft(); displayed = text }
      }
      .onChange(of: focused) { _, active in
        if !active { if commitOnEnd { applyDraft() }; refresh() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { _ in
        // Save/Quit end the native field editor synchronously. FocusState's
        // later view update must not commit the number after the PDF write.
        if commitOnEnd { applyDraft(); refresh() }
      }
      .onSubmit { if commitOnEnd { applyDraft() }; refresh() }
  }

  private func applyDraft() {
    guard draft != displayed else { return }
    let normalized = draft.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: formatter.decimalSeparator, with: ".")
    if let number = Double(normalized), number.isFinite { value = number }
  }

  private func refresh() {
    displayed = mixed ? "" : formatter.string(from: NSNumber(value: value)) ?? ""
    draft = displayed
  }
}

struct WorkspaceTextInspector: View {
  @ObservedObject var viewer: PDFViewingSession
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Text").font(.system(size: 13, weight: .semibold))
        Spacer()
        if viewer.isEditingPageText {
          Text(viewer.isTypingPageText ? "Editing" : "Selected")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let refusal = viewer.textEditRefusal {
            VStack(alignment: .leading, spacing: 8) {
              Label("Inline text editing unavailable", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
              Text(refusal).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              if viewer.allowsContentEditing {
                Button("Add Text") { _ = viewer.activateTool(.addText) }
                  .buttonStyle(.bordered)
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Inline text editing unavailable")
            .accessibilityValue(refusal)
            Divider()
          }
          if viewer.isEditingPageText || viewer.activeTool == .addText {
            VStack(alignment: .leading, spacing: 10) {
              sectionTitle("TYPE")
              VStack(alignment: .leading, spacing: 5) {
                Text("Font").font(.caption).foregroundStyle(.secondary)
                if viewer.canFormatPageText || !viewer.isEditingPageText {
                  fontMenu
                  HStack(spacing: 8) {
                    traitButton("Bold", symbol: "bold", field: "bold", selected: face.isBold) {
                      apply(.bold(viewer.pageTextMixedFormatting.contains("bold") || !face.isBold))
                    }
                    traitButton("Italic", symbol: "italic", field: "italic", selected: face.isItalic) {
                      apply(.italic(viewer.pageTextMixedFormatting.contains("italic") || !face.isItalic))
                    }
                    Spacer()
                  }
                  .disabled(viewer.isEditingPageText && !viewer.canChangePageTextTraits)
                  if viewer.isEditingPageText {
                    Text(viewer.pageTextSelectionScope).font(.caption).foregroundStyle(.secondary)
                  }
                } else {
                  Text(viewer.pageTextStyle.fontFamily).font(.system(size: 12, weight: .medium))
                    .help("This block retains its source font. Character formatting is unavailable for this PDF text.")
                }
              }
              HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                  Text(viewer.pageTextMixedFormatting.contains("size") ? "Size · Mixed" : "Size")
                    .font(.caption).foregroundStyle(.secondary)
                  HStack(spacing: 4) {
                    WorkspacePointField(label: "Text size", value: size,
                      mixed: viewer.pageTextMixedFormatting.contains("size"))
                    Text("pt").foregroundStyle(.secondary).font(.caption)
                  }
                }
                VStack(alignment: .leading, spacing: 5) {
                  Text(viewer.pageTextMixedFormatting.contains("color") ? "Color · Mixed" : "Color")
                    .font(.caption).foregroundStyle(.secondary)
                  colorMenu
                }
              }
              if viewer.pageTextOverflow != nil {
                WorkspacePageTextOverflowView(viewer: viewer)
              } else if let issue = viewer.pageTextFormattingIssue {
                Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
              }
              if viewer.pageTextWidthApplier != nil {
                HStack {
                  Text("Width").font(.caption).foregroundStyle(.secondary)
                  WorkspacePointField(label: "Paragraph width", value: Binding(
                    get: { viewer.pageTextWidth },
                    set: { viewer.pageTextWidthApplier?($0) }))
                  Text("pt").font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            if viewer.isEditingPageText, viewer.canFormatPageText {
              Divider()
              WorkspaceParagraphControls(viewer: viewer)
            }
            if viewer.isEditingPageText {
              Divider()
              VStack(alignment: .leading, spacing: 10) {
                sectionTitle("POSITION")
                HStack(spacing: 10) {
                  positionField("X", index: 0)
                  positionField("Y", index: 1)
                }
                Text("Points from the page’s bottom-left corner.")
                  .font(.system(size: 10)).foregroundStyle(.tertiary)
                WorkspaceAlignmentControls { viewer.pageTextAlignmentApplier?($0) }
              }
              Divider()
              VStack(spacing: 8) {
                if !viewer.isTypingPageText {
                  Button {
                    viewer.pageTextBeginTyping?()
                  } label: {
                    Label("Edit Text", systemImage: "character.cursor.ibeam")
                      .frame(maxWidth: .infinity)
                  }
                  .buttonStyle(.bordered)
                }
                Button {
                  _ = viewer.pendingEditFinisher?()
                } label: {
                  HStack {
                    Text("Done")
                    Spacer()
                    Text("⌘↩").foregroundStyle(.white.opacity(0.7))
                  }
                  .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel", action: { viewer.pageTextCancel?() })
                  .buttonStyle(.borderless).foregroundStyle(.secondary)
              }
            }
          } else {
            VStack(alignment: .leading, spacing: 12) {
              Image(systemName: "cursorarrow.and.square.on.square.dashed")
                .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
              Text("Select a text block")
                .font(.system(size: 13, weight: .medium))
              Text("Click text to select it. Drag to move it, or double-click to start typing.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          if viewer.activeTool == .addText && !viewer.isEditingPageText {
            Text("Click the page to start a text block. Press Return for another line.")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
      if viewer.isEditingPageText {
        Text(
          viewer.isTypingPageText
            ? "Select characters to replace them.\nDrag the grip to move the block."
            : "Drag the block to move it.\nDouble-click to edit its text."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .lineSpacing(3)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .frame(width: 224)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Text properties")
  }

  private var size: Binding<Double> {
    Binding(
      get: { viewer.pageTextStyle.fontSize },
      set: { value in
        guard value.isFinite, (2...144).contains(value) else { return }
        apply(.size(value))
      })
  }

  private var face: StandardTextFont {
    StandardTextFont(rawValue: viewer.pageTextStyle.fontFamily) ?? .helvetica
  }
  private var fontMenu: some View {
    Menu {
      Button("Helvetica") { apply(.family(.helvetica)) }
      Button("Times") { apply(.family(.times)) }
      Button("Courier") { apply(.family(.courier)) }
      if !viewer.pageTextAvailableSourceFonts.isEmpty {
        Divider()
        Section("Embedded in this paragraph") {
          ForEach(Array(viewer.pageTextAvailableSourceFonts.enumerated()), id: \.offset) { item in
            Button(item.element.name) { apply(.sourceFont(item.element)) }
          }
        }
      }
      if !viewer.pageTextAvailableLicensedFonts.isEmpty {
        Divider()
        Section("Licensed fonts installed in this app") {
          ForEach(Array(viewer.pageTextAvailableLicensedFonts.enumerated()), id: \.offset) { item in
            Button(item.element.faceName) { apply(.licensedFont(item.element)) }
          }
        }
      }
    } label: {
      HStack {
        Text(viewer.pageTextMixedFormatting.contains("family") ? "Mixed fonts"
          : StandardTextFont(rawValue: viewer.pageTextStyle.fontFamily) == nil
            ? viewer.pageTextStyle.fontFamily : face.family.rawValue.capitalized)
        Spacer()
      }
      .font(.system(size: 12)).frame(maxWidth: .infinity)
    }
    .menuStyle(.borderedButton).accessibilityLabel("Font family")
    .help("Standard PDF fonts, fonts embedded in this paragraph, and fonts installed after license acceptance. Missing characters are refused.")
  }
  private func traitButton(_ title: String, symbol: String, field: String, selected: Bool,
    action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: viewer.pageTextMixedFormatting.contains(field) ? "minus" : symbol)
        .frame(width: 30, height: 26)
    }
    .buttonStyle(.bordered)
    .tint(selected ? .accentColor : .secondary)
    .accessibilityLabel(title)
    .accessibilityValue(viewer.pageTextMixedFormatting.contains(field) ? "Mixed" : selected ? "On" : "Off")
    .help(title == "Bold" ? "Bold (⌘B)" : "Italic (⌘I)")
  }
  private func apply(_ change: PageTextFormatChange) {
    if let apply = viewer.pageTextFormattingApplier { apply(change); return }
    var style = viewer.pageTextStyle
    var font = face
    switch change {
    case .family(let family): font = .face(family: family, bold: font.isBold, italic: font.isItalic)
    case .sourceFont(_): return
    case .licensedFont(_): return
    case .bold(let enabled): font = .face(family: font.family, bold: enabled, italic: font.isItalic)
    case .italic(let enabled): font = .face(family: font.family, bold: font.isBold, italic: enabled)
    case .size(let size): style.fontSize = size
    case .color(let color): style.color = color
    }
    style.fontFamily = font.rawValue
    viewer.pageTextStyle = style
    viewer.pageTextStyleApplier?(style)
  }
  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
  }
  private func positionField(_ label: String, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      WorkspacePointField(label: "Text position \(label)", value: Binding(
          get: { viewer.pageTextPosition[index] },
          set: { value in
            guard value.isFinite else { return }
            var point = viewer.pageTextPosition
            point[index] = value
            viewer.pageTextPositionApplier?(point[0], point[1])
          }))
    }
  }
  private var colorMenu: some View {
    Menu {
      Button("Black") { color([0, 0, 0]) }
      Button("Gray") { color([0.35, 0.35, 0.35]) }
      Button("Red") { color([0.8, 0.12, 0.12]) }
      Button("Blue") { color([0.08, 0.25, 0.8]) }
      Button("Green") { color([0.05, 0.45, 0.2]) }
      Divider()
      Button("Custom Color…") { PageTextColorPanelController.shared.show(for: viewer) }
    } label: {
      HStack(spacing: 6) {
        Image(nsImage: swatch).renderingMode(.original).frame(width: 24, height: 16)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
      }
      .frame(height: 21)
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Text color")
  }
  private var swatch: NSImage {
    let rgb = viewer.pageTextStyle.color
    return NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
      let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
      NSColor(
        srgbRed: rgb[0], green: rgb[1], blue: rgb[2],
        alpha: viewer.pageTextStyle.opacity
      ).setFill()
      path.fill()
      NSColor.separatorColor.setStroke()
      path.lineWidth = 1
      path.stroke()
      return true
    }
  }
  private func color(_ rgb: [Double]) {
    apply(.color(rgb))
  }
}

struct WorkspaceParagraphControls: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("PARAGRAPH")
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        ForEach(PageTextParagraphAlignment.allCases, id: \.self) { alignment in
          Button {
            updateParagraph { $0.alignment = alignment }
          } label: {
            Image(systemName: alignment.symbol).frame(width: 26, height: 24)
          }
          .buttonStyle(.bordered)
          .tint(
            viewer.pageTextParagraphStyle.alignment == alignment
              ? .accentColor : .secondary)
          .accessibilityLabel("\(alignment.title) paragraph alignment")
          .accessibilityValue(
            viewer.pageTextParagraphStyle.alignment == alignment ? "Selected" : "Not selected")
        }
        Spacer()
      }
      HStack(spacing: 8) {
        field("Leading", keyPath: \.leading, label: "Paragraph leading")
        field("Before", keyPath: \.spacingBefore, label: "Space before paragraph")
        field("After", keyPath: \.spacingAfter, label: "Space after paragraph")
      }
      HStack(spacing: 8) {
        field("Left", keyPath: \.leftIndent, label: "Left paragraph indent")
        field("Right", keyPath: \.rightIndent, label: "Right paragraph indent")
        field("First line", keyPath: \.firstLineIndent, label: "First-line indent")
      }
      Text("Leading 0 keeps the source line height. First-line indent can be negative for a hanging indent.")
        .font(.system(size: 9)).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func field(
    _ title: String, keyPath: WritableKeyPath<PageTextParagraphStyle, Double>,
    label: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
      WorkspacePointField(
        label: label,
        value: Binding(
          get: { viewer.pageTextParagraphStyle[keyPath: keyPath] },
          set: { value in
            guard value.isFinite else { return }
            updateParagraph { $0[keyPath: keyPath] = value }
          }))
    }
  }

  private func updateParagraph(_ mutate: (inout PageTextParagraphStyle) -> Void) {
    var style = viewer.pageTextParagraphStyle
    mutate(&style)
    guard style.isValid else { return }
    viewer.pageTextParagraphStyle = style
    viewer.pageTextParagraphStyleApplier?(style)
  }
}

/// TXT-06: explain why the draft cannot be committed and offer only the
/// corrections that preserve the draft and any source clipping boundary.
struct WorkspacePageTextOverflowView: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    if let overflow = viewer.pageTextOverflow {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(overflow.cause.title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.red)
        Text(overflow.message)
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
        if overflow.canFitText || overflow.canWidenBox || overflow.canMoveInsideBoundary {
          HStack(spacing: 6) {
            if overflow.canFitText, let fit = viewer.pageTextFitOverflow {
              Button("Fit text") { _ = fit() }
                .buttonStyle(.bordered)
                .help("Reduce every text run proportionally until the draft fits. All characters stay in the draft.")
                .accessibilityLabel("Fit overflowing text")
            }
            if overflow.canWidenBox, let widen = viewer.pageTextWidenOverflowBox {
              Button("Widen box") { _ = widen() }
                .buttonStyle(.bordered)
                .help("Increase the wrapping width, bounded by the source clipping area.")
                .accessibilityLabel("Widen overflowing text box")
            }
            if overflow.canMoveInsideBoundary, let move = viewer.pageTextMoveOverflowInside {
              Button("Move inside") { _ = move() }
                .buttonStyle(.bordered)
                .help("Shift the paragraph until its box lies inside the dashed clipping boundary.")
                .accessibilityLabel("Move text inside boundary")
            }
          }
        } else {
          Text(overflow.cause == .taggedLayout
            ? "The draft remains open. Tagged layout cannot be resized automatically; Cancel discards the draft."
            : "The draft remains open. This layout cannot be corrected automatically; Cancel discards the draft.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(8)
      .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
    }
  }
}

struct WorkspaceAlignmentControls: View {
  var align: (PageObjectAlignment) -> Void
  private let symbols = ["align.horizontal.left", "align.horizontal.center", "align.horizontal.right",
    "align.vertical.top", "align.vertical.center", "align.vertical.bottom"]
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Align to page").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 4) {
        ForEach(Array(PageObjectAlignment.allCases.enumerated()), id: \.element) { index, alignment in
          Button { align(alignment) } label: {
            Image(systemName: symbols[index]).frame(width: 23, height: 24)
          }
          .buttonStyle(.borderless)
          .help("Align \(alignment.rawValue) to page")
          .accessibilityLabel("Align \(alignment.rawValue) to page")
        }
      }
    }
  }
}

struct WorkspaceTextSelectionInspector: View {
  @ObservedObject var viewer: PDFViewingSession
  var onEditText: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Text selection").font(.system(size: 13, weight: .semibold)).padding(16)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let details = viewer.selectionDetails {
            LabeledContent("Page") { Text("\(details.pageNumber)") }
            VStack(alignment: .leading, spacing: 5) {
              Text("Selected text").font(.caption).foregroundStyle(.secondary)
              Text(details.text).font(.system(size: 12)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let bounds = details.bounds, bounds.count == 4 {
              LabeledContent("Bounds") {
                Text("\(Int(bounds[0])), \(Int(bounds[1])) – \(Int(bounds[2])), \(Int(bounds[3])) pt")
                  .textSelection(.enabled)
              }
            }
            Button(action: onEditText) {
              Label("Edit Text", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewer.allowsContentEditing || viewer.isLocked)
            if let restriction = viewer.editingRestrictionNotice {
              Text(restriction).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
              Text("PDF text selection is read-only. Choose Edit PDF to select and edit a supported text block.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          } else {
            Text("Select text on the page to inspect it here.")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .frame(width: 224)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Text selection properties")
  }
}

struct WorkspaceGraphicInspector: View {
  @ObservedObject var viewer: PDFViewingSession
  @State private var constrain = true
  private var editable: Bool { viewer.activeTool == .imageEdit && viewer.allowsContentEditing && !viewer.isLocked }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(viewer.selectedGraphics.count > 1 ? "Objects" : "Image")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        if viewer.selectedGraphics.count > 1 {
          Text("\(viewer.selectedGraphics.count) selected").font(.caption).foregroundStyle(.secondary)
        }
      }.padding(16)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Button { viewer.onInsertImage?() } label: {
            Label("Insert Image…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
          }.buttonStyle(.bordered).disabled(!editable)
          if let bounds = viewer.selectedGraphicBounds {
            if let restriction = viewer.editingRestrictionNotice, !viewer.allowsContentEditing {
              Label {
                Text(restriction).fixedSize(horizontal: false, vertical: true)
              } icon: {
                Image(systemName: "exclamationmark.lock.fill")
              }
              .font(.system(size: 11)).foregroundStyle(.secondary)
              .accessibilityLabel("Editing unavailable")
            }
            if !editable {
              Button { _ = viewer.activateTool(.imageEdit) } label: {
                Label("Edit Images", systemImage: "photo")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .disabled(!viewer.allowsContentEditing || viewer.isLocked)
            }
            VStack(alignment: .leading, spacing: 10) {
              Text("POSITION & SIZE").font(.system(size: 10, weight: .semibold))
                .tracking(0.7).foregroundStyle(.secondary)
              HStack(spacing: 10) {
                field("X", value: bounds.minX, component: 0)
                field("Y", value: bounds.minY, component: 1)
              }
              HStack(spacing: 10) {
                field("Width", value: bounds.width, component: 2)
                field("Height", value: bounds.height, component: 3)
              }
              Toggle("Keep proportions", isOn: $constrain).font(.caption).toggleStyle(.checkbox)
              Text("Points from the page’s bottom-left corner.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
              WorkspaceAlignmentControls { viewer.alignGraphics($0) }
            }.disabled(!editable)
            Divider()
            if viewer.selectedGraphics.count == 1, let target = viewer.selectedGraphics.first {
              Button { viewer.onRotateGraphic?(target) } label: {
                Label("Rotate 90°", systemImage: "rotate.right").frame(maxWidth: .infinity)
              }.buttonStyle(.bordered).disabled(!editable)
            }
            Button(role: .destructive) { viewer.deleteSelectedGraphics() } label: {
              Label("Delete Selection", systemImage: "trash").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(!editable || !viewer.canDeleteSelectedGraphics)
          } else if let refusal = viewer.graphicEditRefusal {
            VStack(alignment: .leading, spacing: 8) {
              Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .light)).foregroundStyle(.orange)
                .accessibilityHidden(true)
              Text("Image editing unavailable")
                .font(.system(size: 13, weight: .medium))
              Text(refusal).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Image editing unavailable")
            .accessibilityValue(refusal)
          } else if let restriction = viewer.editingRestrictionNotice, !viewer.allowsContentEditing {
            VStack(alignment: .leading, spacing: 8) {
              Image(systemName: "exclamationmark.lock.fill")
                .font(.system(size: 24, weight: .light)).foregroundStyle(.orange)
                .accessibilityHidden(true)
              Text("Editing unavailable").font(.system(size: 13, weight: .medium))
              Text(restriction).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Editing unavailable")
            .accessibilityValue(restriction)
          } else {
            VStack(alignment: .leading, spacing: 10) {
              Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
              Text("Place an image on the page").font(.system(size: 13, weight: .medium))
              Text("Insert an image, then drag it to move or resize it. Shift-click to select several objects.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
              Text("For supported existing images, choose Images and drag the selection or handles. Right-click for rotate, scale or replace.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
          }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
      if viewer.selectedGraphicBounds != nil {
        Text(editable ? "Arrow keys move 1 pt; Shift moves 10 pt.\nEscape cancels a drag or clears selection."
          : "Choose Images to move or resize this selection.")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(16)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor)).frame(width: 224)
    .accessibilityElement(children: .contain).accessibilityLabel("Image properties")
  }

  private func field(_ label: String, value: Double, component: Int) -> some View {
    let identities = viewer.selectedGraphics.map(\.streamID)
    return VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      WorkspacePointField(label: "Object \(label)", value: Binding(get: {
        guard identities == viewer.selectedGraphics.map(\.streamID),
          let current = viewer.selectedGraphicBounds else { return value }
        return [current.minX, current.minY, current.width, current.height][component]
      }, set: { number in
        guard identities == viewer.selectedGraphics.map(\.streamID), number.isFinite,
          var bounds = viewer.selectedGraphicBounds else { return }
        switch component {
        case 0: bounds.origin.x = number
        case 1: bounds.origin.y = number
        case 2:
          guard number >= 1, number <= 20_000 else { return }
          if constrain { bounds.size.height *= number / bounds.width }
          bounds.size.width = number
        default:
          guard number >= 1, number <= 20_000 else { return }
          if constrain { bounds.size.width *= number / bounds.height }
          bounds.size.height = number
        }
        viewer.setGraphicBounds(bounds)
      }), commitOnEnd: true)
    }
  }
}

struct WorkspaceWelcomeView: View {
  private var recent: [URL] { Array(NSDocumentController.shared.recentDocumentURLs.prefix(5)) }
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 9) {
          Image(systemName: "doc.text.fill").font(.system(size: 22)).foregroundStyle(
            Color.accentColor)
          Text("sPDF").font(.system(size: 19, weight: .semibold, design: .rounded))
        }
        Spacer()
        Text("Make it\nyour document.")
          .font(.system(size: 30, weight: .semibold)).tracking(-0.6)
          .fixedSize(horizontal: false, vertical: true)
        Text("Edit text, review changes,\nand put your pages in order.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .lineSpacing(3).padding(.top, 12)
        VStack(spacing: 10) {
          Button {
            NSDocumentController.shared.openDocument(nil)
          } label: {
            HStack {
              Label("Open PDF…", systemImage: "folder")
              Spacer()
              Text("⌘O").opacity(0.6)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 3)
          }
          .buttonStyle(.borderedProminent).keyboardShortcut("o")
          Button {
            NSDocumentController.shared.newDocument(nil)
          } label: {
            HStack {
              Label("New PDF", systemImage: "doc.badge.plus")
              Spacer()
              Text("⌘N").opacity(0.5)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 3)
          }
          .buttonStyle(.bordered).keyboardShortcut("n")
        }
        .padding(.top, 28)
        Spacer()
      }
      .padding(36).frame(width: 322)
      .frame(maxHeight: .infinity)
      .background(Color(nsColor: .controlBackgroundColor))
      Divider()
      VStack(alignment: .leading, spacing: 18) {
        Text("Recent documents").font(.system(size: 13, weight: .semibold))
        if recent.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Your next document starts here.").font(.system(size: 12, weight: .medium))
            Text("Open a PDF or create a blank page. Recent files will appear here.")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }.padding(.top, 12)
        } else {
          VStack(spacing: 4) {
            ForEach(recent, id: \.self) { url in
              Button {
                open(url)
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: "doc.text").font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(url.deletingPathExtension().lastPathComponent).font(
                      .system(size: 12, weight: .medium)
                    ).lineLimit(1)
                    Text(url.deletingLastPathComponent().lastPathComponent).font(.system(size: 10))
                      .foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(
                    .tertiary)
                }
                .padding(9).contentShape(RoundedRectangle(cornerRadius: 6))
              }
              .buttonStyle(.plain).help(url.path)
            }
          }
        }
        Spacer()
        Text("⌘N  New PDF     ⌘O  Open PDF")
          .font(.system(size: 10)).foregroundStyle(.tertiary)
      }
      .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func open(_ url: URL) {
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
      if let error { NSApp.presentError(error) }
    }
  }
}

/// SwiftUI's split view otherwise assigns the sidebar its maximum width.
/// Set its initial width once and let AppKit keep it steady during resizing.
struct WorkspaceNavigationSizer: NSViewRepresentable {
  let viewer: PDFViewingSession
  func makeNSView(context: Context) -> Probe {
    let view = Probe()
    view.viewer = viewer
    return view
  }
  func updateNSView(_ nsView: Probe, context: Context) {}
  @MainActor final class Probe: NSView {
    weak var viewer: PDFViewingSession?
    private var configured = false
    private var resizeUpdates: AnyCancellable?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in self?.configure() }
    }
    private func configure() {
      guard !configured, window != nil, let viewer else { return }
      var ancestor = superview
      while let parent = ancestor {
        if let split = parent as? NSSplitView, split.isVertical, split.subviews.count >= 2 {
          configured = true
          let desired = viewer.sidebarWidth > 0 ? min(260, max(170, viewer.sidebarWidth)) : 200
          if let controller = split.delegate as? NSSplitViewController {
            controller.splitViewItems.first?.holdingPriority = .defaultHigh
          }
          split.setPosition(desired, ofDividerAt: 0)
          viewer.sidebarWidth = Double(split.subviews[0].frame.width)
          resizeUpdates = NotificationCenter.default.publisher(
            for: NSSplitView.didResizeSubviewsNotification, object: split
          )
          .receive(on: DispatchQueue.main)
          .sink { [weak self, weak split] _ in
            MainActor.assumeIsolated {
              guard let self, let split, let width = split.subviews.first?.frame.width,
                width >= 170,
                self.viewer?.sidebarWidth != Double(width)
              else { return }
              self.viewer?.sidebarWidth = Double(width)
            }
          }
          return
        }
        ancestor = parent.superview
      }
    }
  }
}

struct WorkspacePanelEmptyState: View {
  let title: String
  let symbol: String
  let detail: String
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(.tertiary)
      Text(title).font(.system(size: 12, weight: .medium))
      Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
