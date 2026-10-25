import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

// FRM-01/FRM-02: the review and design panel. Detection proposals are reviewed
// here; canvas gestures are committed by SPDFDocument routes, never directly by
// this model.

@MainActor
final class FormDesignPanelModel: ObservableObject {
  struct CandidateRow: Identifiable, Equatable {
    let id: UUID
    let pageLabel: String
    let kind: FormDetectedFieldKind
    let name: String
    let label: String?
    let confidence: String
    let evidence: String
    let warnings: String
    let refusal: String?
    let decision: FormFieldDetectionReview.Decision
    let isEligible: Bool
    let source: String
  }

  struct WidgetRow: Identifiable, Equatable {
    let id: String
    let fieldName: String
    let label: String
    let detail: String
    let isSelected: Bool
  }

  @Published var statusText = "No field proposals. Nothing is created until you review proposals."
  @Published var errorText: String?
  @Published var detectionSummary = ""
  @Published var rows: [CandidateRow] = []
  @Published var acceptedCount = 0
  @Published var rejectedCount = 0
  @Published var pendingCount = 0
  @Published var canCreate = false
  @Published var previewMode: FormDesignPreviewMode = .design
  @Published var newFieldChoice = "Select"
  @Published var radioOptionCount = 3
  @Published var showTabOrder = true
  @Published var showGuides = true
  @Published var minimumConfidence = 0.6
  @Published var widgetRows: [WidgetRow] = []
  @Published var tabOrder: [String] = []
  @Published var suggestedTabOrder: [String] = []
  /// True while the reviewer has reordered the list but not applied it.
  @Published var tabOrderDirty = false
  @Published var tabOrderStatus = ""
  @Published var selectedFieldName = ""
  @Published var labelDraft = ""
  @Published var pageLabel = ""
  @Published var modeNote = ""

  private weak var document: SPDFDocument?
  private let session: FormDesignSession

  init(document: SPDFDocument, session: FormDesignSession) {
    self.document = document
    self.session = session
    self.minimumConfidence = session.minimumConfidence
    self.previewMode = session.previewMode
    self.radioOptionCount = session.radioOptionCount
    self.showTabOrder = session.showTabOrder
    self.showGuides = session.showGuides
    refresh()
  }

  // MARK: Refresh

  func refresh() {
    guard let document else { return }
    document.syncFormDesignPage()
    errorText = session.errorMessage
    if let message = session.statusMessage, !message.isEmpty {
      statusText = message
    }
    if let report = session.detectionReport {
      detectionSummary = report.summary
    } else if session.detectionReport == nil {
      detectionSummary = ""
    }
    if let review = session.review {
      rows = review.report.candidates
        .filter { $0.pageIndex == session.pageIndex }
        .map { candidate in
          let effective = review.effectiveCandidate(candidate.id) ?? candidate
          return CandidateRow(
            id: candidate.id,
            pageLabel: "Page " + String(candidate.pageIndex + 1),
            kind: effective.kind,
            name: effective.suggestedName,
            label: effective.label,
            confidence: effective.confidenceLabel,
            evidence: effective.evidence.joined(separator: " · "),
            warnings: effective.warnings.joined(separator: " "),
            refusal: effective.refusalReason,
            decision: review.decision(for: candidate.id),
            isEligible: effective.isEligible,
            source: effective.source?.label ?? "")
        }
      acceptedCount = review.acceptedCount
      rejectedCount = review.rejectedCount
      pendingCount = review.pendingCount
      canCreate = review.canCommit
    } else {
      rows = []
      acceptedCount = 0
      rejectedCount = 0
      pendingCount = 0
      canCreate = false
    }
    refreshCanvasState(document: document)
    pageLabel = "Page " + String(document.formDesignPageIndex() + 1)
    if session.newFieldKind == nil {
      newFieldChoice = "Select"
    } else if let kind = session.newFieldKind {
      switch kind {
      case .text: newFieldChoice = "Text Field"
      case .checkbox: newFieldChoice = "Checkbox"
      case .radio: newFieldChoice = "Radio Group"
      }
    }
    switch session.previewMode {
    case .design:
      modeNote =
        "Design preview: drag a field to move it, drag a handle to resize, shift-click to "
        + "select several widgets, drag on empty space to draw the chosen field, and click a "
        + "proposal to accept or reject it. Every commit is one Undo step."
    case .fill:
      modeNote =
        "Fill preview: the design overlay is off and ordinary form filling is available. "
        + "Switch to Design to move fields or review proposals."
    }
  }

  private func refreshCanvasState(document: SPDFDocument) {
    let widgets = document.formDesignWidgetsForCurrentPage()
    let selected = Set(session.selection.widgets.map(\.id))
    widgetRows = widgets.map { widget in
      WidgetRow(
        id: widget.id, fieldName: widget.fieldName, label: widget.label ?? "(no label)",
        detail: widget.fieldKind.rawValue + " · page " + String(widget.pageIndex + 1),
        isSelected: selected.contains(widget.id))
    }
    let state = document.formDesignTabOrderState()
    if !tabOrderDirty {
      tabOrder = state.current
    }
    suggestedTabOrder = state.suggested
    if let first = session.selection.fieldNames.first {
      selectedFieldName = first
      if let widget = widgets.first(where: { $0.fieldName == first }) {
        labelDraft = widget.label ?? ""
      }
    } else {
      selectedFieldName = ""
    }
  }

  // MARK: Detection

  func detect(allPages: Bool) {
    errorText = nil
    session.minimumConfidence = minimumConfidence
    _ = document?.runFormFieldDetection(allPages: allPages)
    tabOrder = []
    refresh()
  }

  func accept(_ id: UUID) { document?.acceptFormCandidate(id) }
  func reject(_ id: UUID) { document?.rejectFormCandidate(id) }
  func reset(_ id: UUID) { document?.resetFormCandidate(id) }
  func acceptAll() { document?.acceptAllFormCandidates() }
  func rejectAll() { document?.rejectAllFormCandidates() }

  func updateName(_ id: UUID, _ name: String) {
    document?.updateFormCandidate(id, name: name)
  }

  func updateLabel(_ id: UUID, _ label: String) {
    document?.updateFormCandidate(id, label: label)
  }

  func updateKind(_ id: UUID, _ kind: FormDetectedFieldKind) {
    document?.updateFormCandidate(id, kind: kind)
  }

  func createFields() {
    errorText = nil
    _ = document?.createAcceptedFormFields()
    refresh()
  }

  // MARK: Canvas controls

  func setPreviewMode(_ mode: FormDesignPreviewMode) {
    previewMode = mode
    document?.setFormDesignPreviewMode(mode)
    refresh()
  }

  func setNewFieldChoice(_ choice: String) {
    newFieldChoice = choice
    switch choice {
    case "Text Field": session.newFieldKind = .text
    case "Checkbox": session.newFieldKind = .checkbox
    case "Radio Group": session.newFieldKind = .radio
    default: session.newFieldKind = nil
    }
    session.canvas?.refreshFromDocument()
  }

  func setRadioOptionCount(_ count: Int) {
    radioOptionCount = count
    session.radioOptionCount = count
  }

  func setShowTabOrder(_ value: Bool) {
    showTabOrder = value
    session.showTabOrder = value
    session.canvas?.refreshFromDocument()
  }

  func setShowGuides(_ value: Bool) {
    showGuides = value
    session.showGuides = value
    session.canvas?.refreshFromDocument()
  }

  func setMinimumConfidence(_ value: Double) {
    minimumConfidence = value
    session.minimumConfidence = value
  }

  func toggleWidget(_ row: WidgetRow) {
    guard let document else { return }
    if let widget = document.formDesignWidgetsForCurrentPage().first(where: { $0.id == row.id }) {
      document.toggleFormWidgetSelection(widget)
    }
    refresh()
  }

  func applySelectedFieldLabel() {
    guard !selectedFieldName.isEmpty else { return }
    errorText = nil
    if document?.applyFormFieldLabel(selectedFieldName, label: labelDraft) != true {
      errorText = session.errorMessage ?? "The label could not be applied."
    }
    refresh()
  }

  // MARK: Tab order

  func useReadingOrder() {
    tabOrder = suggestedTabOrder
    tabOrderDirty = true
    tabOrderStatus = "Reading order loaded. Choose Apply Tab Order to commit it."
  }

  func moveTabOrder(_ name: String, up: Bool) {
    guard let index = tabOrder.firstIndex(of: name) else { return }
    let target = up ? index - 1 : index + 1
    guard tabOrder.indices.contains(target) else { return }
    tabOrder.swapAt(index, target)
    tabOrderDirty = true
    tabOrderStatus = "Order changed; choose Apply Tab Order to commit it."
  }

  func applyTabOrder() {
    errorText = nil
    if document?.applyFormTabOrder(tabOrder) == true {
      tabOrderDirty = false
      tabOrderStatus = "Tab order committed as one Undo step."
    } else {
      tabOrderStatus = session.errorMessage ?? "The tab order was not committed."
    }
    refresh()
  }
}

// MARK: - Window controller

@MainActor
final class FormDesignPanelController: NSWindowController, NSWindowDelegate {
  let model: FormDesignPanelModel
  /// NSWindowController already declares a "document" property, so the retained
  /// link to our document uses its own name.
  private weak var pdfDocument: SPDFDocument?

  init(document: SPDFDocument, session: FormDesignSession) {
    self.pdfDocument = document
    let model = FormDesignPanelModel(document: document, session: session)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Form Design"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 860, height: 600)
    panel.contentView = NSHostingView(rootView: FormDesignPanelView(model: model))
    panel.center()
    super.init(window: panel)
    panel.delegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the form design panel")
  }

  func refresh() {
    model.refresh()
  }

  func windowWillClose(_ notification: Notification) {
    pdfDocument?.removeFormDesignCanvas()
  }
}

// MARK: - SwiftUI panel

struct FormDesignPanelView: View {
  @ObservedObject var model: FormDesignPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        detectionSection
        Divider()
        canvasSection
        Divider()
        selectionSection
        Divider()
        tabOrderSection
        footer
      }
      .padding(18)
    }
    .frame(minWidth: 860, minHeight: 600)
    .accessibilityLabel("Form design and field detection review")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Form Design").font(.title3).bold()
        Spacer()
        Text(model.pageLabel).font(.caption).foregroundStyle(.secondary)
      }
      Text(model.statusText)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      if !model.detectionSummary.isEmpty {
        Text(model.detectionSummary).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var detectionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Automatic field detection").font(.headline)
      Text(
        "Detection reads existing page text and recognized OCR text only. Proposals are listed "
          + "here with their confidence and eligibility; accepting a proposal still does not "
          + "create it until you press Create Fields.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button("Detect Fields on This Page") { model.detect(allPages: false) }
          .accessibilityLabel("Detect fields on this page")
        Button("Detect on All Pages") { model.detect(allPages: true) }
          .accessibilityLabel("Detect fields on all pages")
        Spacer()
        Text("Minimum confidence " + String(format: "%.0f%%", model.minimumConfidence * 100))
          .font(.caption).foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { model.minimumConfidence },
            set: { model.setMinimumConfidence($0) }),
          in: 0.3...0.95, step: 0.05
        )
        .frame(width: 130)
        .accessibilityLabel("Minimum detection confidence")
      }
      if !model.rows.isEmpty {
        HStack(spacing: 10) {
          Button("Accept All Eligible") { model.acceptAll() }
          Button("Reject All") { model.rejectAll() }
          Spacer()
          Text(
            String(model.acceptedCount) + " accepted · " + String(model.pendingCount)
              + " pending · " + String(model.rejectedCount) + " rejected")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(model.rows) { row in
          FormDesignCandidateRowView(model: model, row: row)
        }
      }
      HStack {
        Button("Create Fields") { model.createFields() }
          .disabled(!model.canCreate)
          .accessibilityLabel("Create accepted form fields")
        Text("Accepted proposals become one undoable step.").font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
  }

  private var canvasSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Design canvas").font(.headline)
      HStack(spacing: 12) {
        Picker(
          "Preview",
          selection: Binding(
            get: { model.previewMode.rawValue },
            set: { value in
              model.setPreviewMode(FormDesignPreviewMode(rawValue: value) ?? .design)
            })
        ) {
          ForEach(FormDesignPreviewMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 230)
        .accessibilityLabel("Design or fill preview")
        Spacer()
        Picker(
          "Draw",
          selection: Binding(
            get: { model.newFieldChoice },
            set: { model.setNewFieldChoice($0) })
        ) {
          Text("Select").tag("Select")
          Text("Text Field").tag("Text Field")
          Text("Checkbox").tag("Checkbox")
          Text("Radio Group").tag("Radio Group")
        }
        .frame(width: 190)
        .accessibilityLabel("Field kind to draw")
        Stepper(
          "Options: " + String(model.radioOptionCount),
          value: Binding(
            get: { model.radioOptionCount },
            set: { model.setRadioOptionCount($0) }),
          in: 2...6
        )
        .frame(width: 130)
      }
      HStack(spacing: 16) {
        Toggle(
          "Show tab order",
          isOn: Binding(
            get: { model.showTabOrder }, set: { model.setShowTabOrder($0) }))
          .accessibilityLabel("Show tab order badges")
        Toggle(
          "Show guides",
          isOn: Binding(
            get: { model.showGuides }, set: { model.setShowGuides($0) }))
          .accessibilityLabel("Show alignment guides")
        Spacer()
      }
      Text(model.modeNote)
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var selectionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Widgets on this page").font(.headline)
      if model.widgetRows.isEmpty {
        Text("No form fields on this page yet.").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(model.widgetRows) { row in
          HStack(spacing: 8) {
            Button {
              model.toggleWidget(row)
            } label: {
              Image(systemName: row.isSelected ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Select field " + row.fieldName)
            VStack(alignment: .leading, spacing: 1) {
              Text(row.fieldName).font(.caption)
              Text(row.label + " · " + row.detail).font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(.vertical, 1)
        }
      }
      if !model.selectedFieldName.isEmpty {
        HStack(spacing: 8) {
          Text("Label for " + model.selectedFieldName).font(.caption)
          TextField(
            "Tooltip label",
            text: Binding(
              get: { model.labelDraft }, set: { model.labelDraft = $0 }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .accessibilityLabel("Field label for " + model.selectedFieldName)
          Button("Apply Label") { model.applySelectedFieldLabel() }
        }
      }
    }
  }

  private var tabOrderSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tab order").font(.headline)
      Text(
        "The list below is the field tab order readers use. A radio group is one tab stop; "
          + "moving fields preserves their widgets.")
        .font(.caption2).foregroundStyle(.secondary)
      if model.tabOrder.isEmpty {
        Text("No fields to order.").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(model.tabOrder, id: \.self) { name in
          HStack(spacing: 8) {
            Text(String((model.tabOrder.firstIndex(of: name) ?? 0) + 1) + ".")
              .font(.caption).monospacedDigit()
              .frame(width: 26, alignment: .trailing)
            Text(name).font(.caption)
            Spacer()
            Button("Up") { model.moveTabOrder(name, up: true) }
              .buttonStyle(.link)
              .disabled(model.tabOrder.first == name)
              .accessibilityLabel("Move " + name + " up")
            Button("Down") { model.moveTabOrder(name, up: false) }
              .buttonStyle(.link)
              .disabled(model.tabOrder.last == name)
              .accessibilityLabel("Move " + name + " down")
          }
        }
      }
      HStack(spacing: 10) {
        Button("Use Reading Order") { model.useReadingOrder() }
        Button("Apply Tab Order") { model.applyTabOrder() }
          .disabled(model.tabOrder.isEmpty)
        Spacer()
        Text(model.tabOrderStatus).font(.caption2).foregroundStyle(.secondary)
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
        "Detection and review never create fields on their own; a created batch, a move, a "
          + "resize and a tab-order change are each one Undo step.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct FormDesignCandidateRowView: View {
  @ObservedObject var model: FormDesignPanelModel
  let row: FormDesignPanelModel.CandidateRow
  @State private var name: String
  @State private var label: String

  init(model: FormDesignPanelModel, row: FormDesignPanelModel.CandidateRow) {
    self.model = model
    self.row = row
    _name = State(initialValue: row.name)
    _label = State(initialValue: row.label ?? "")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Image(systemName: icon)
          .foregroundStyle(row.decision == .accepted ? Color.green : Color.secondary)
          .frame(width: 18)
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(row.kind.label).font(.caption).bold()
          Text(row.confidence).font(.caption2).foregroundStyle(.secondary)
          Text(row.pageLabel).font(.caption2).foregroundStyle(.secondary)
          if !row.source.isEmpty {
            Text(row.source).font(.caption2).foregroundStyle(.secondary)
          }
          if !row.isEligible {
            Text("refused").font(.caption2).foregroundStyle(.red)
          }
        }
        HStack(spacing: 6) {
          TextField(
            "Field name",
            text: Binding(
              get: { name },
              set: { value in
                name = value
                model.updateName(row.id, value)
              })
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 190)
          .accessibilityLabel("Proposal field name")
          TextField(
            "Label",
            text: Binding(
              get: { label },
              set: { value in
                label = value
                model.updateLabel(row.id, value)
              })
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 170)
          .accessibilityLabel("Proposal label")
          if row.label == nil {
            Text("no on-page label").font(.caption2).foregroundStyle(.orange)
          }
        }
        if !row.evidence.isEmpty {
          Text(row.evidence).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !row.warnings.isEmpty {
          Text(row.warnings).font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let refusal = row.refusal {
          Text(refusal).font(.caption2).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Button("Accept") { model.accept(row.id) }
          .disabled(!row.isEligible || row.decision == .accepted)
          .accessibilityLabel("Accept proposal " + row.name)
        Button("Reject") { model.reject(row.id) }
          .disabled(row.decision == .rejected)
          .accessibilityLabel("Reject proposal " + row.name)
        Menu("Kind") {
          ForEach(FormDetectedFieldKind.allCases, id: \.self) { kind in
            Button(kind.label) { model.updateKind(row.id, kind) }
          }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 70)
        .accessibilityLabel("Proposal kind")
      }
    }
    .padding(6)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  private var icon: String {
    switch row.decision {
    case .accepted: return "checkmark.circle.fill"
    case .rejected: return "minus.circle"
    case .pending: return "circle.dashed"
    }
  }
}
