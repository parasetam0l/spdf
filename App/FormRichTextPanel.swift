import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// FRM-05: the rich text field editor. Selections in the field text receive
// bold/italic/size/color runs; one embedded TrueType program can become the
// field base font. Commit writes /V, a coherent /RV RTF mirror and every widget
// appearance as ONE undoable transaction.

@MainActor
final class FormRichTextPanelModel: ObservableObject {
  struct FieldRow: Identifiable, Equatable {
    let id: String
    let name: String
    let valuePreview: String
    let rich: Bool
  }

  @Published var statusText = "Choose a text field, then style a selection."
  @Published var errorText: String?
  @Published var fieldRows: [FieldRow] = []
  @Published var selectedFieldName = ""
  @Published var editorText = ""
  @Published var selectionLabel = "No selection (styles apply to the whole field)"
  @Published var richSummary = ""
  @Published var fitNote = ""
  @Published var bold = false
  @Published var italic = false
  @Published var fontSize = 12.0
  @Published var color = Color.black
  @Published var embeddedFontLabel = "Field default font"
  @Published var embeddedFontNote = ""
  @Published var canCommit = false

  private weak var document: SPDFDocument?
  private var value: FormRichTextValue?
  private var selectedRange = NSRange(location: 0, length: 0)

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  func refresh() {
    guard let document else { return }
    fieldRows = document.formRichTextFieldRows()
    if !fieldRows.contains(where: { $0.name == selectedFieldName }) {
      selectedFieldName = fieldRows.first?.name ?? ""
    }
    loadSelectedField()
  }

  private func loadSelectedField() {
    guard let document, !selectedFieldName.isEmpty else {
      value = nil
      editorText = ""
      canCommit = false
      embeddedFontLabel = "Field default font"
      embeddedFontNote = ""
      return
    }
    guard let loaded = document.formRichTextFieldValue(name: selectedFieldName) else {
      errorText = "The selected field could not be read."
      return
    }
    value = loaded.value
    editorText = loaded.value.plainText
    bold = loaded.value.baseStyle.bold
    italic = loaded.value.baseStyle.italic
    fontSize = loaded.value.baseStyle.fontSize
    color = Self.color(from: loaded.value.baseStyle.color)
    switch loaded.value.baseStyle.font {
    case .embedded(let source)?:
      embeddedFontLabel = "Embedded: " + source.faceName
      embeddedFontNote = "The field base font is an embedded TrueType subset."
    case .standard(let face)?:
      embeddedFontLabel = "Standard face: " + face.rawValue
      embeddedFontNote = ""
    case nil:
      embeddedFontLabel = "Field default font"
      embeddedFontNote = loaded.inheritedFontNote
    }
    richSummary = Self.summary(loaded.value)
    canCommit = true
    updateFitNote()
  }

  func selectField(_ name: String) {
    guard name != selectedFieldName else { return }
    selectedFieldName = name
    errorText = nil
    loadSelectedField()
  }

  func selectionChanged(_ range: NSRange) {
    selectedRange = range
    guard let value, range.length > 0,
      range.location + range.length <= value.utf16Length
    else {
      selectionLabel = "No selection (styles apply to the whole field)"
      return
    }
    let style = value.style(atUTF16Offset: range.location)
    bold = style.bold
    italic = style.italic
    fontSize = style.fontSize
    color = Self.color(from: style.color)
    selectionLabel = "Selection: " + String(range.length) + " character(s)"
  }

  func editorTextChanged(_ text: String) {
    guard var value else { return }
    value.plainText = text
    value.runs = value.runs.filter {
      $0.location + $0.length <= (text as NSString).length
    }
    self.value = value
    richSummary = Self.summary(value)
    updateFitNote()
  }

  func applySelectionStyle() {
    guard let document, var value, !selectedFieldName.isEmpty else { return }
    errorText = nil
    let style = FormRichTextStyle(
      bold: bold, italic: italic, fontSize: fontSize, color: Self.components(from: color))
    do {
      if selectedRange.length > 0 {
        value = try value.applying(style: style, to: selectedRange)
      } else {
        value.baseStyle = style
      }
      self.value = value
      richSummary = Self.summary(value)
      _ = document
      updateFitNote()
      statusText = selectedRange.length > 0
        ? "Applied the style to the selected characters (not committed yet)."
        : "Applied the style to the whole field base (not committed yet)."
    } catch {
      errorText = error.localizedDescription
    }
  }

  func clearSelectionStyle() {
    guard var value, !selectedFieldName.isEmpty else { return }
    errorText = nil
    do {
      let base = value.baseStyle
      if selectedRange.length > 0 {
        value = try value.applying(style: base, to: selectedRange)
      } else {
        value = value.removingAllRuns()
      }
      self.value = value
      richSummary = Self.summary(value)
      updateFitNote()
      statusText = "Cleared the styled run in the selection (not committed yet)."
    } catch {
      errorText = error.localizedDescription
    }
  }

  func embedFont(from url: URL) {
    errorText = nil
    embeddedFontNote = ""
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= 64 * 1024 * 1024 else {
        throw PDFError(.limitExceeded, "The font file is larger than the 64 MiB import limit")
      }
      let inspector = try TrueTypeInspector.inspect(data)
      guard !inspector.isCFF else {
        throw PDFError(
          .unsupported,
          "Field appearance font embedding currently supports TrueType outline programs; "
            + "CFF/OpenType programs are refused rather than substituted")
      }
      guard inspector.permitsEditableSubsetEmbedding else {
        throw PDFError(
          .unsupported,
          "This font's embedding permissions do not allow embedding in a PDF form")
      }
      let family = url.deletingPathExtension().lastPathComponent
      let source = FormEmbeddedFontSource(
        program: data, familyName: family, faceName: family, isBold: false, isItalic: false)
      guard var value, !selectedFieldName.isEmpty else { return }
      value.baseStyle.font = .embedded(source)
      self.value = value
      embeddedFontLabel = "Embedded: " + family
      embeddedFontNote =
        "Eligible TrueType program. The appearance embeds a tagged subset with a ToUnicode map; "
        + "the text must be covered by the program's glyphs."
      updateFitNote()
      statusText = "Base font set to the embedded program (not committed yet)."
    } catch {
      errorText = error.localizedDescription
    }
  }

  func clearEmbeddedFont() {
    guard var value else { return }
    value.baseStyle.font = nil
    self.value = value
    embeddedFontLabel = "Field default font"
    embeddedFontNote = ""
    updateFitNote()
  }

  func useStandardFace(_ face: StandardTextFont) {
    guard var value else { return }
    value.baseStyle.font = .standard(face)
    value.baseStyle.bold = face.isBold
    value.baseStyle.italic = face.isItalic
    self.value = value
    embeddedFontLabel = "Standard face: " + face.rawValue
    embeddedFontNote = ""
    updateFitNote()
  }

  func commit() {
    errorText = nil
    guard let document, let value, !selectedFieldName.isEmpty else { return }
    if document.applyFormRichTextFieldValue(name: selectedFieldName, value: value) {
      statusText =
        "Committed the rich value, /RV mirror and appearances as one Undo step."
      refresh()
    } else {
      errorText = document.formRichTextLastError ?? "The rich value could not be committed."
      statusText = "Nothing was changed."
    }
  }

  private func updateFitNote() {
    fitNote = ""
    guard let document, let value, !selectedFieldName.isEmpty else { return }
    if let message = document.formRichTextFieldFitMessage(name: selectedFieldName, value: value) {
      fitNote = "Not committable: " + message
    }
  }

  static func summary(_ value: FormRichTextValue) -> String {
    let runs = value.runs.count
    if runs == 0 { return "Plain text, no styled runs." }
    return String(runs) + " styled run(s); " + String(value.plainText.count)
      + " character(s) of text."
  }

  static func color(from components: [Double]) -> Color {
    guard components.count == 3 else { return .black }
    return Color(
      red: components[0], green: components[1], blue: components[2])
  }

  static func components(from color: Color) -> [Double] {
    let native = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
    return [
      Double(native.redComponent), Double(native.greenComponent),
      Double(native.blueComponent),
    ]
  }
}

@MainActor
final class FormRichTextPanelController: NSWindowController {
  let model: FormRichTextPanelModel

  init(document: SPDFDocument) {
    let model = FormRichTextPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Rich Text Field Editor"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 780, height: 560)
    panel.contentView = NSHostingView(rootView: FormRichTextPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the rich text panel")
  }

  func refresh() { model.refresh() }
}

/// One field, its plain text and its rich mirror, for the editor.
struct FormRichTextFieldValue: Sendable {
  let value: FormRichTextValue
  let inheritedFontNote: String
}

private enum FormRichTextAssociationKeys {
  /// Address used only as an associated-object key; the value is never read.
  nonisolated(unsafe) static var error: UInt8 = 0
}

extension SPDFDocument {
  func showFormRichTextFieldEditor() {
    if let controller = windowControllers.compactMap({
      $0 as? FormRichTextPanelController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FormRichTextPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowFormRichTextEditor: Bool {
    viewer != nil && editSession.currentGraph != nil
  }

  var formRichTextLastError: String? {
    get { objc_getAssociatedObject(self, &FormRichTextAssociationKeys.error) as? String }
    set {
      objc_setAssociatedObject(
        self, &FormRichTextAssociationKeys.error, newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }

  func formRichTextFieldRows() -> [FormRichTextPanelModel.FieldRow] {
    guard let graph = editSession.currentGraph else { return [] }
    let properties = (try? FormEffectivePropertiesReader.allProperties(
      in: graph, pageIDs: editSession.pageIDs)) ?? []
    return properties.filter { $0.kind == .text && !$0.isReadOnly }.map { property in
      FormRichTextPanelModel.FieldRow(
        id: property.fieldName, name: property.fieldName,
        valuePreview: property.displayValue ?? "",
        rich: property.richValue != nil || property.isRichText)
    }
  }

  func formRichTextFieldValue(name: String) -> FormRichTextFieldValue? {
    guard let graph = editSession.currentGraph,
      let properties = try? FormEffectivePropertiesReader.properties(
        forFieldNamed: name, in: graph)
    else { return nil }
    let text = properties.displayValue ?? ""
    var base = FormRichTextStyle(
      fontSize: properties.defaultAppearanceSize,
      color: properties.defaultAppearanceColor)
    var note = ""
    if let fontName = properties.defaultAppearanceFontName {
      note = "Inherited default appearance font: "
        + String(decoding: fontName.bytes, as: UTF8.self)
    } else {
      note = "No /DA font is present; the declared Helvetica default is used."
    }
    if case .string(let richData)? = properties.richValue,
      let decoded = FormRichTextRTF.decode(String(decoding: richData, as: UTF8.self)),
      decoded.plainText == text,
      let font = properties.defaultAppearanceFontName
    {
      var value = decoded
      base = value.baseStyle
      if let face = FormAppearanceFonts.standardFace(
        named: String(decoding: font.bytes, as: UTF8.self))
      {
        base.font = .standard(face)
      }
      value.baseStyle = base
      return FormRichTextFieldValue(value: value, inheritedFontNote: note)
    }
    let value = FormRichTextValue(plainText: text, baseStyle: base)
    return FormRichTextFieldValue(value: value, inheritedFontNote: note)
  }

  /// Validate the value without mutating anything; returns a refusal message.
  func formRichTextFieldFitMessage(name: String, value: FormRichTextValue) -> String? {
    guard let graph = editSession.currentGraph else { return "No editable graph" }
    let command = SetFormRichTextCommand(fieldName: name, value: value)
    do {
      try command.validate(in: graph)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  @discardableResult
  func applyFormRichTextFieldValue(name: String, value: FormRichTextValue) -> Bool {
    let command = SetFormRichTextCommand(fieldName: name, value: value)
    guard let graph = editSession.currentGraph else { return false }
    do {
      try command.validate(in: graph)
    } catch {
      formRichTextLastError = error.localizedDescription
      return false
    }
    let applied = applyFormAdvancedTransaction(
      PDFTransaction([command]), actionName: "Set Rich Form Text")
    if !applied, formRichTextLastError == nil {
      formRichTextLastError = "The document is not editable right now."
    }
    return applied
  }
}

// MARK: - SwiftUI panel

struct FormRichTextPanelView: View {
  @ObservedObject var model: FormRichTextPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        header
        Divider()
        fieldPicker
        Divider()
        editorSection
        Divider()
        styleSection
        Divider()
        fontSection
        footer
      }
      .padding(18)
    }
    .frame(minWidth: 780, minHeight: 560)
    .accessibilityLabel("Rich text field editor")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Rich Text Field Editor").font(.title3).bold()
      Text(model.statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
      Text(model.richSummary).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var fieldPicker: some View {
    HStack(spacing: 10) {
      Text("Text field:").font(.caption)
      Picker(
        "Text field",
        selection: Binding(
          get: { model.selectedFieldName },
          set: { model.selectField($0) })
      ) {
        ForEach(model.fieldRows) { row in
          Text(row.name + (row.rich ? " (rich)" : "")).tag(row.name)
        }
      }
      .labelsHidden()
      .frame(width: 260)
      Spacer()
      Button("Refresh Fields") { model.refresh() }
    }
  }

  private var editorSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Field text").font(.headline)
      Text(
        "Select characters and apply a style; without a selection the style applies to the "
          + "whole field base. Commit writes the value, the /RV mirror and all widget "
          + "appearances in one Undo step.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      FormRichTextEditor(model: model)
        .frame(minHeight: 150)
      Text(model.selectionLabel).font(.caption2).foregroundStyle(.secondary)
      if !model.fitNote.isEmpty {
        Text(model.fitNote).font(.caption2).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var styleSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Selection style").font(.headline)
      HStack(spacing: 12) {
        Toggle("Bold", isOn: $model.bold).toggleStyle(.button)
        Toggle("Italic", isOn: $model.italic).toggleStyle(.button)
        Text("Size").font(.caption)
        Stepper(
          value: Binding(
            get: { model.fontSize },
            set: { model.fontSize = $0 }),
          in: 4...96, step: 1
        ) {
          Text(String(format: "%.0f pt", model.fontSize)).font(.caption)
        }
        .frame(width: 150)
        ColorPicker("Color", selection: $model.color)
          .frame(width: 150)
        Spacer()
      }
      HStack(spacing: 10) {
        Button("Apply Style to Selection") { model.applySelectionStyle() }
          .accessibilityLabel("Apply style to the selected characters")
        Button("Clear Styled Run") { model.clearSelectionStyle() }
        Spacer()
        Button("Commit Rich Value") { model.commit() }
          .disabled(!model.canCommit)
          .accessibilityLabel("Commit the rich field value")
      }
    }
  }

  private var fontSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Field base font").font(.headline)
      Text(
        "Selection-level runs use Standard-14 faces. One embedded TrueType program may be the "
          + "field base font; it is subset-embedded with a ToUnicode map and the text must be "
          + "covered by the program's glyphs.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Text(model.embeddedFontLabel).font(.caption)
        Button("Embed Font File…") { chooseFontFile() }
        Button("Use Helvetica") { model.useStandardFace(.helvetica) }
        Button("Use Default") { model.clearEmbeddedFont() }
        Spacer()
      }
      if !model.embeddedFontNote.isEmpty {
        Text(model.embeddedFontNote).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "No document script is authored or executed by this editor; the field value and "
          + "appearance are ordinary static PDF data.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func chooseFontFile() {
    let panel = NSOpenPanel()
    panel.title = "Choose an Embeddable TrueType Font"
    panel.allowedContentTypes = [.font]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.embedFont(from: url)
  }
}

/// An editable NSTextView bridged into SwiftUI so selection-level styling is
/// possible (a SwiftUI TextEditor does not expose the selection).
struct FormRichTextEditor: NSViewRepresentable {
  @ObservedObject var model: FormRichTextPanelModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let textView = NSTextView()
    textView.isRichText = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.font = NSFont.systemFont(ofSize: 13)
    textView.delegate = context.coordinator
    textView.textContainerInset = NSSize(width: 6, height: 6)
    scrollView.documentView = textView
    context.coordinator.textView = textView
    textView.string = model.editorText
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.model = model
    guard let textView = nsView.documentView as? NSTextView else { return }
    if textView.string != model.editorText {
      let selected = textView.selectedRange()
      textView.string = model.editorText
      let length = (model.editorText as NSString).length
      let location = min(selected.location, max(0, length - 1))
      textView.setSelectedRange(NSRange(location: max(0, location), length: 0))
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var model: FormRichTextPanelModel
    weak var textView: NSTextView?

    init(model: FormRichTextPanelModel) {
      self.model = model
    }

    func textDidChange(_ notification: Notification) {
      guard let textView else { return }
      model.editorTextChanged(textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView else { return }
      model.selectionChanged(textView.selectedRange())
    }
  }
}
