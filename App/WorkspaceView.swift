import AppKit
import MacServices
import PDFCore
import PDFEditing
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var viewer: PDFViewingSession
  @ObservedObject var documentState: WorkspaceDocumentState
  var onSave: () -> Void
  var onUndo: () -> Void
  var onRedo: () -> Void
  var onOpenDroppedFile: ((URL) -> Void)?
  @ObservedObject var comments: CommentsModel
  @ObservedObject var forms: FormsModel
  @ObservedObject var signatures: SignaturesModel
  @ObservedObject var structure: StructureModel
  var onSelectComment: (Comment) -> Void
  var onDeleteComment: (Comment) -> Void
  var onReplyComment: (Comment) -> Void
  var onSetStateComments: ([Comment], PDFName?) -> Void
  var onSubmitFormText: (String, String) -> Void
  var onDraftFormText: (String, String) -> Void
  var onToggleForm: (String, Bool) -> Void
  var onSelectFormChoice: (String, String) -> Void
  var onSelectFormField: (FormField) -> Void
  var onSelectSignature: (Int) -> Void
  var onSelectStructurePage: (Int) -> Void
  var onEditStructureRole: (PDFObjectID, String) -> Void
  var onEditStructureAltText: (PDFObjectID) -> Void
  var onMarkStructureArtifact: (PDFObjectID) -> Void
  @ObservedObject var fonts: FontsModel
  @ObservedObject var jobs: JobProgressCenter
  var onProvisionFont: (String) -> Void
  var onSuggestStructureTags: () -> Void
  var onAcceptStructureSuggestion: (UUID) -> Void
  var onRejectStructureSuggestion: (UUID) -> Void
  var onApplyStructureSuggestions: () -> Void
  var onDiscardStructureSuggestions: () -> Void
  var onOrganizePages: () -> Void
  var onInsertBlankPage: () -> Void
  var onRotateRight: () -> Void
  var onImageGeometry: ((Int, Int, Double, Double, Double, Double) -> Void)? = nil
  var onImageFlip: ((Int, Int, Bool) -> Void)? = nil
  var onImageRotate: ((Int, Int, Int) -> Void)? = nil
  var onImageCrop: ((Int, Int) -> Void)? = nil
  var onImageReplace: ((Int, Int) -> Void)? = nil
  var onHighlight: () -> Void
  var onNote: () -> Void
  @State private var pageEntry = "1"
  @State private var inspectorVisible = true
  @State private var inspectorPopover = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 1_000
      VStack(spacing: 0) {
        commandBar(wide: wide)
        Divider()
        if !canEdit && !viewer.isLocked {
          editingRestrictionBanner
          Divider()
        }
        if viewer.isSearchVisible {
          searchBar
          Divider()
        }
        if case .failed(let message) = viewer.documentState {
          ContentUnavailableView(
            "Could Not Open Document", systemImage: "doc.badge.gearshape",
            description: Text(message))
        } else if case .empty = viewer.documentState {
          ContentUnavailableView(
            "No Document", systemImage: "doc", description: Text("Open a PDF to begin."))
        } else if case .loading = viewer.documentState {
          ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewer.isLocked {
          ContentUnavailableView(
            "Password-protected PDF", systemImage: "lock.doc",
            description: Text("Choose Tools → Security → Unlock Document to continue."))
        } else {
          HStack(spacing: 0) {
            HSplitView {
              if viewer.isSidebarVisible { navigationPanel }
              pageCanvas
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if usesProperties && wide && inspectorVisible {
              Divider()
              propertiesInspector
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Divider()
        documentFooter
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .onDrop(of: [.pdf], isTargeted: nil) { providers in
        for provider in providers {
          _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { Task { @MainActor in onOpenDroppedFile?(url) } }
          }
        }
        return true
      }
    }
    .onAppear { pageEntry = String(max(1, viewer.pageNumber)) }
    .onChange(of: viewer.pageNumber) { _, page in pageEntry = String(page) }
  }

  private func commandBar(wide: Bool) -> some View {
    HStack(spacing: 8) {
      iconButton("Toggle sidebar", symbol: "sidebar.left") { viewer.isSidebarVisible.toggle() }
        .help("Show or hide navigation")
      Divider().frame(height: 18)
      ViewThatFits(in: .horizontal) {
        toolStrip(compact: false)
        toolStrip(compact: true)
      }
      Spacer(minLength: 4)
      HStack(spacing: 2) {
        iconButton("Undo", symbol: "arrow.uturn.backward", action: onUndo)
          .disabled(
            !documentState.canUndo && !viewer.hasPendingPageTextChanges && !viewer.canUndoPageTyping
          )
        iconButton("Redo", symbol: "arrow.uturn.forward", action: onRedo)
          .disabled(!documentState.canRedo && !viewer.canRedoPageTyping)
      }
      Divider().frame(height: 18)
      iconButton("Find", symbol: "magnifyingglass") { viewer.showSearch() }
        .help("Find in document (⌘F)")
      if usesProperties {
        iconButton(inspectorTitle, symbol: "sidebar.right") {
          if wide { inspectorVisible.toggle() } else { inspectorPopover.toggle() }
        }
        .popover(isPresented: $inspectorPopover, arrowEdge: .bottom) {
          propertiesInspector.frame(height: 520)
        }
      }
      if viewer.isEditingPageText && (!wide || !inspectorVisible) {
        Button("Done") { _ = viewer.pendingEditFinisher?() }
          .buttonStyle(.borderedProminent).controlSize(.small)
      }
      Button(action: onSave) { Label("Save", systemImage: "square.and.arrow.down") }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(!documentState.hasChanges)
        .help("Save document (⌘S)")
    }
    .padding(.horizontal, 12).frame(height: 44)
    .background(.bar)
    .disabled(viewer.isLocked)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Document toolbar")
  }

  private func toolStrip(compact: Bool) -> some View {
    HStack(spacing: 2) {
      toolButton("Select", image: "cursorarrow", tool: .select, compact: compact)
      toolButton("Edit PDF", image: "square.and.pencil", tool: .textEdit, compact: false)
      toolButton("Add Text", image: "text.badge.plus", tool: .addText, compact: compact)
      toolButton("Images", image: "photo", tool: .imageEdit, compact: compact)
      Divider().frame(height: 18).padding(.horizontal, 4)
      toolButton("Comments", image: "text.bubble", tool: .annotate, compact: compact)
      toolButton("Pages", image: "square.grid.2x2", tool: .page, compact: compact)
    }
    .fixedSize()
  }
  private func toolButton(_ title: String, image: String, tool: ViewerToolMode, compact: Bool)
    -> some View
  {
    Button {
      guard viewer.activateTool(tool) else { return }
      viewer.isInkToolActive = false
      if tool == .annotate {
        viewer.showComments()
        viewer.isSidebarVisible = true
      }
      if tool == .page {
        viewer.showPages()
        viewer.isSidebarVisible = true
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: image).font(.system(size: 13))
        if !compact { Text(title) }
      }
    }
    .buttonStyle(WorkspaceToolStyle(selected: viewer.activeTool == tool))
    .disabled(tool != .select && !canEdit)
    .help(tool != .select && !canEdit
      ? "\(toolHelp(tool, fallback: title)) Editing unavailable: \(viewer.editingRestrictionNotice ?? "this document is view-only.")"
      : toolHelp(tool, fallback: title))
    .accessibilityLabel(title)
    .accessibilityValue(tool != .select && !canEdit
      ? "Unavailable. \(viewer.editingRestrictionNotice ?? "This document is view-only.")"
      : viewer.activeTool == tool ? "Active" : "Inactive")
  }

  private func toolHelp(_ tool: ViewerToolMode, fallback: String) -> String {
    switch tool {
    case .select:
      return "Select page text and graphics. In overlaps, use Edit PDF to target text or Images to target graphics."
    case .textEdit:
      return "Edit PDF: edits horizontal text with ordinary character spacing on unrotated pages. Click a block or press ⌥⌘↓/↑; double-click to type. Unsupported source text remains unchanged."
    case .imageEdit:
      return "Images: select, move and resize supported page-level graphics; press ⌥⌘↓/↑ to cycle objects. Nested, clipped or transformed placements may be view-only with a reason shown in the inspector."
    default:
      return fallback
    }
  }

  private var navigationPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 3) {
        navigationTab(.pages, title: "Pages", symbol: "square.on.square")
        navigationTab(.comments, title: "Comments", symbol: "text.bubble")
        navigationTab(.forms, title: "Forms", symbol: "rectangle.and.pencil.and.ellipsis")
        Spacer(minLength: 0)
        Menu {
          ForEach(SidebarMode.allCases, id: \.self) { mode in
            Button(sidebarTitle(mode)) { viewer.sidebarMode = mode }
          }
        } label: {
          Image(systemName: "ellipsis").frame(width: 24, height: 26)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Navigation panels")
      }
      .padding(.horizontal, 8).frame(height: 38)
      HStack {
        Text(sidebarTitle(viewer.sidebarMode)).font(.system(size: 11, weight: .semibold))
        Spacer()
        if viewer.sidebarMode == .pages {
          Text("\(viewer.pageCount)").font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14).padding(.bottom, 10)
      if viewer.activeTool == .page {
        HStack(spacing: 8) {
          Button("Organize…", action: onOrganizePages).controlSize(.small)
          iconButton(
            "Insert Blank Page", symbol: "plus.rectangle.on.rectangle", action: onInsertBlankPage)
          iconButton("Rotate Right", symbol: "rotate.right", action: onRotateRight)
        }.padding(.horizontal, 10).padding(.bottom, 8)
      }
      if viewer.activeTool == .annotate {
        HStack(spacing: 6) {
          iconButton("Highlight", symbol: "highlighter", action: onHighlight)
            .disabled(viewer.view.currentSelection == nil || !canEdit)
          iconButton("Add Note", symbol: "note.text.badge.plus", action: onNote)
            .disabled(viewer.view.currentSelection == nil || !canEdit)
          Button {
            viewer.toggleInkTool()
          } label: {
            Image(systemName: "scribble").frame(width: 32, height: 32)
          }
          .buttonStyle(WorkspaceToolStyle(selected: viewer.isInkToolActive))
          .help(viewer.isInkToolActive ? "Stop drawing" : "Draw on page")
          .accessibilityLabel("Draw")
          .disabled(!canEdit)
          Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.bottom, 8)
      }
      Divider()
      sidebarContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .frame(
      minWidth: 170,
      idealWidth: viewer.sidebarWidth > 0 ? min(260, max(170, viewer.sidebarWidth)) : 200,
      maxWidth: 280
    )
    .frame(maxHeight: .infinity)
    .background(WorkspaceNavigationSizer(viewer: viewer))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Document navigation")
  }

  private func navigationTab(_ mode: SidebarMode, title: String, symbol: String) -> some View {
    Button {
      viewer.sidebarMode = mode
    } label: {
      Image(systemName: symbol).font(.system(size: 13)).frame(width: 24, height: 24)
    }
    .buttonStyle(WorkspaceToolStyle(selected: viewer.sidebarMode == mode))
    .help(title).accessibilityLabel("Show \(title.lowercased())")
    .accessibilityValue(viewer.sidebarMode == mode ? "Selected" : "")
  }

  private var documentFooter: some View {
    HStack(spacing: 12) {
      HStack(spacing: 6) {
        if let job = jobs.jobs.first {
          ProgressView().controlSize(.mini)
          Text(job.title).lineLimit(1)
          Button {
            jobs.requestCancel(id: job.id)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless).help("Cancel \(job.title)")
          .disabled(!jobs.canCancel(id: job.id))
        } else {
          Circle().fill(documentState.hasChanges ? Color.orange : Color.secondary.opacity(0.45))
            .frame(width: 4, height: 4)
          Text(
            !canEdit
              ? "Read only" : documentState.hasChanges ? "Unsaved changes" : "All changes saved")
        }
      }
      .font(.system(size: 10)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 5) {
        iconButton("Previous page", symbol: "chevron.left") { viewer.previousPage() }.disabled(
          !viewer.canGoBack)
        TextField("Page", text: $pageEntry)
          .textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 28)
          .padding(.vertical, 3)
          .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
          .onSubmit {
            if let page = Int(pageEntry) { viewer.go(to: page) }
            pageEntry = String(viewer.pageNumber)
          }
          .accessibilityLabel("Page number")
        Text("of \(viewer.pageCount)").foregroundStyle(.secondary).monospacedDigit()
        iconButton("Next page", symbol: "chevron.right") { viewer.nextPage() }.disabled(
          !viewer.canGoForward)
      }.font(.system(size: 11))
      HStack(spacing: 4) {
        iconButton("Zoom out", symbol: "minus") { viewer.zoomOut() }
        Menu {
          Button("Fit Page") { viewer.fitPage() }
          Button("Fit Width") { viewer.fitWidth() }
          Divider()
          ForEach([50, 75, 100, 125, 150, 200], id: \.self) { percent in
            Button("\(percent)%") { viewer.setZoom(Double(percent) / 100) }
          }
        } label: {
          Text("\(Int(viewer.scale*100))%").monospacedDigit().frame(minWidth: 38)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Zoom \(Int(viewer.scale*100)) percent")
        iconButton("Zoom in", symbol: "plus") { viewer.zoomIn() }
        Divider().frame(height: 12).padding(.horizontal, 4)
        Button("Fit Page") { viewer.fitPage() }.buttonStyle(.borderless)
        Menu {
          Button("Continuous") { viewer.setContinuous(true) }
          Button("Single Page") { viewer.setContinuous(false) }
        } label: {
          Image(systemName: "rectangle.split.1x2").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Page layout")
      }
      .font(.system(size: 11))
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 14).frame(height: 32)
    .background(.bar)
    .disabled(viewer.isLocked)
  }

  private var searchBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Find in document", text: $viewer.searchText)
        .textFieldStyle(.plain).frame(minWidth: 140, maxWidth: 280)
        .focused($searchFocused).onSubmit { viewer.runSearch() }.accessibilityLabel("Find text")
      Text(searchStatus).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      iconButton("Previous match", symbol: "chevron.up") { viewer.searchPrevious() }.disabled(
        !hasCurrentMatches)
      iconButton("Next match", symbol: "chevron.down") { viewer.searchNext() }.disabled(
        !hasCurrentMatches)
      Spacer()
      iconButton("Close search", symbol: "xmark") { viewer.hideSearch() }
    }
    .padding(.horizontal, 16).frame(height: 38).background(.bar)
    .onAppear { DispatchQueue.main.async { searchFocused = true } }
  }
  private var searchStatus: String {
    if viewer.searchText.isEmpty { return "" }
    if viewer.searchedText != viewer.searchText { return "Return to search" }
    return viewer.searchMatchCount == 0
      ? "No matches" : "\(viewer.searchIndex) of \(viewer.searchMatchCount)"
  }
  private var hasCurrentMatches: Bool {
    viewer.searchedText == viewer.searchText && viewer.searchMatchCount > 0
  }
  private var usesTextProperties: Bool {
    viewer.activeTool == .textEdit || viewer.activeTool == .addText
  }
  private var hasNativeTextSelection: Bool {
    viewer.selectedGraphics.isEmpty
      && viewer.view.currentSelection?.string?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
  private var usesProperties: Bool {
    usesTextProperties || viewer.activeTool == .imageEdit || !viewer.selectedGraphics.isEmpty
      || hasNativeTextSelection
  }
  private var inspectorTitle: String {
    if usesTextProperties { return "Text properties" }
    if hasNativeTextSelection { return "Text selection" }
    return "Image properties"
  }
  @ViewBuilder private var propertiesInspector: some View {
    if !viewer.selectedGraphics.isEmpty {
      WorkspaceGraphicInspector(viewer: viewer)
    } else if usesTextProperties {
      WorkspaceTextInspector(viewer: viewer)
    } else if hasNativeTextSelection {
      WorkspaceTextSelectionInspector(viewer: viewer) {
        _ = viewer.activateTool(.textEdit)
      }
    } else {
      WorkspaceGraphicInspector(viewer: viewer)
    }
  }
  private var canEdit: Bool { viewer.allowsContentEditing && !viewer.isLocked }
  private var editingRestrictionBanner: some View {
    let reason = viewer.editingRestrictionNotice ?? "This document is view-only."
    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.lock.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Editing unavailable").font(.system(size: 11, weight: .semibold))
        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Document Info") {
        viewer.sidebarMode = .info
        viewer.isSidebarVisible = true
      }
      .buttonStyle(.link)
      .accessibilityHint("Opens document capabilities and security details")
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Editing unavailable")
  }
  private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12)).frame(width: 32, height: 32)
    }
    .buttonStyle(.borderless).accessibilityLabel(title).help(title)
  }
  private func sidebarTitle(_ mode: SidebarMode) -> String {
    switch mode {
    case .pages: return "Pages"
    case .comments: return "Comments"
    case .forms: return "Forms"
    case .signatures: return "Signatures"
    case .structure: return "Structure"
    case .fonts: return "Fonts"
    case .inspector: return "Selection Info"
    case .info: return "Document Info"
    }
  }

  private var sidebarContent: some View {
    Group {
      switch viewer.sidebarMode {
      case .pages:
        NativeView(view: viewer.thumbnails)
          .accessibilityLabel("Page thumbnails")
      case .comments:
        CommentsPanel(
          comments: comments.comments, pageCount: viewer.pageCount,
          canEditContent: canEdit, editingRestrictionNotice: viewer.editingRestrictionNotice,
          onSelect: onSelectComment, onDelete: onDeleteComment,
          onReply: onReplyComment, onSetStateComments: onSetStateComments)
      case .forms:
        FormsPanel(
          fields: forms.fields, orphanedWidgetCount: forms.orphanedWidgetCount,
          canEditContent: canEdit, editingRestrictionNotice: viewer.editingRestrictionNotice,
          onSubmitText: onSubmitFormText,
          onDraftText: onDraftFormText, onToggle: onToggleForm,
          onSelectChoice: onSelectFormChoice, onSelect: onSelectFormField)
      case .signatures:
        SignaturesPanel(entries: signatures.entries, onSelect: onSelectSignature)
      case .fonts:
        FontsPanel(model: fonts, onProvision: onProvisionFont)
      case .inspector:
        SelectionInspectorPanel(
          viewer: viewer, onImageGeometry: onImageGeometry,
          onImageFlip: onImageFlip, onImageRotate: onImageRotate,
          onImageCrop: onImageCrop, onImageReplace: onImageReplace)
      case .info:
        DocumentInfoPanel(viewer: viewer)
      case .structure:
        StructurePanel(
          model: structure, canEditContent: canEdit,
          editingRestrictionNotice: viewer.editingRestrictionNotice,
          onSelect: onSelectStructurePage,
          onEditRole: onEditStructureRole, onEditAltText: onEditStructureAltText,
          onMarkArtifact: onMarkStructureArtifact,
          onSuggestTags: onSuggestStructureTags,
          onAcceptSuggestion: onAcceptStructureSuggestion,
          onRejectSuggestion: onRejectStructureSuggestion,
          onApplySuggestions: onApplyStructureSuggestions,
          onDiscardSuggestions: onDiscardStructureSuggestions)
      }
    }
  }

  private var pageCanvas: some View {
    VStack(spacing: 0) {
      // P12-018: rulers align with the page pane edges in the same
      // layout pass, with a corner square where they meet.
      if viewer.areRulersVisible {
        HStack(spacing: 0) {
          Color.clear.frame(width: 28, height: 22)
          HorizontalRuler(viewer: viewer).frame(height: 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Horizontal ruler")
      }
      HStack(spacing: 0) {
        if viewer.areRulersVisible {
          VerticalRuler(viewer: viewer).frame(width: 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vertical ruler")
        }
        ZStack {
          NativeView(view: viewer.view)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("PDF pages")
            .accessibilityValue(viewer.selectedObjectSummary ?? "No selection")
            .accessibilityHint(
              "In Edit PDF or Images mode, use the next and previous actions to select supported page objects. In Edit PDF mode, selected text can be opened for typing.")
            .accessibilityActions {
              if viewer.canSelectAdjacentPageObject {
                Button("Select Next Page Object") {
                  _ = viewer.selectAdjacentPageObject()
                }
                Button("Select Previous Page Object") {
                  _ = viewer.selectAdjacentPageObject(reverse: true)
                }
                if viewer.canEditSelectedPageText {
                  Button("Edit Selected Text") {
                    DispatchQueue.main.async {
                      _ = viewer.editSelectedPageText()
                    }
                  }
                }
              }
            }
          PageEditOverlay(viewer: viewer)
          GraphicSelectionOverlay(viewer: viewer)
          if viewer.areGuidesVisible {
            ZStack {
              GuideOverlayView(viewer: viewer)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Alignment guides")
          }
          if viewer.isInkToolActive {
            InkOverlay(viewer: viewer)
          }
        }
      }
    }
    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct NativeView<V: NSView>: NSViewRepresentable {
  let view: V
  func makeNSView(context: Context) -> V { view }
  func updateNSView(_ nsView: V, context: Context) {}
}
