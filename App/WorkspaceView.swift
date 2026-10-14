import AppKit
import MacServices
import PDFCore
import PDFEditing
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var viewer: PDFViewingSession
  var onOpenDroppedFile: ((URL) -> Void)?
  @ObservedObject var comments: CommentsModel
  @ObservedObject var forms: FormsModel
  @ObservedObject var signatures: SignaturesModel
  @ObservedObject var structure: StructureModel
  var onSelectComment: (Comment) -> Void
  var onDeleteComment: (Comment) -> Void
  var onReplyComment: (Comment) -> Void
  var onSetStateComment: (Comment, PDFName?) -> Void
  var onSubmitFormText: (String, String) -> Void
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
  @State private var pageEntry = "1"
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Button {
          viewer.isSidebarVisible.toggle()
        } label: {
          Image(systemName: "sidebar.left")
            // P12-026: the label carries the minimum hit size (borderless
            // buttons size to content, so button-level frames are ignored).
            .frame(minWidth: 32, minHeight: 32)
        }
        // P12-026: primary pointer targets keep a minimum hit size without
        // giving up the dense desktop layout (the visuals stay compact; the
        // hit area grows).
        .help("Toggle page thumbnails").accessibilityLabel("Toggle page thumbnails")
        Picker("Sidebar", selection: $viewer.sidebarMode) {
          Text("Pages").tag(SidebarMode.pages)
          Text("Comments").tag(SidebarMode.comments)
          Text("Forms").tag(SidebarMode.forms)
          Text("Signatures").tag(SidebarMode.signatures)
          Text("Structure").tag(SidebarMode.structure)
          Text("Fonts").tag(SidebarMode.fonts)
          Text("Inspector").tag(SidebarMode.inspector)
          Text("Info").tag(SidebarMode.info)
        }
        .labelsHidden()
        .frame(width: 124)
        .disabled(!viewer.isSidebarVisible)
        .accessibilityLabel("Sidebar content")
        Divider().frame(height: 18)
        Button {
          viewer.previousPage()
        } label: {
          Image(systemName: "chevron.left")
            .frame(minWidth: 32, minHeight: 32)
        }
        .disabled(!viewer.canGoBack).help("Previous page").accessibilityLabel("Previous page")
        HStack(spacing: 6) {
          TextField("Page", text: $pageEntry)
            .frame(width: 42).multilineTextAlignment(.center)
            .onSubmit {
              if let page = Int(pageEntry) { viewer.go(to: page) }
              pageEntry = String(viewer.pageNumber)
            }
            .accessibilityLabel("Page number")
          Text("of \(viewer.pageCount)").foregroundStyle(.secondary).monospacedDigit()
        }
        Button {
          viewer.nextPage()
        } label: {
          Image(systemName: "chevron.right")
            .frame(minWidth: 32, minHeight: 32)
        }
        .disabled(!viewer.canGoForward).help("Next page").accessibilityLabel("Next page")
        Spacer()
        Button {
          viewer.zoomOut()
        } label: {
          Image(systemName: "minus.magnifyingglass")
            .frame(minWidth: 32, minHeight: 32)
        }
        .help("Zoom out").accessibilityLabel("Zoom out")
        Text("\(Int(viewer.scale * 100))%")
          .monospacedDigit().frame(minWidth: 44).accessibilityLabel(
            "Zoom \(Int(viewer.scale * 100)) percent")
        Button {
          viewer.zoomIn()
        } label: {
          Image(systemName: "plus.magnifyingglass")
            .frame(minWidth: 32, minHeight: 32)
        }
        .help("Zoom in").accessibilityLabel("Zoom in")
        Button("Fit Page") { viewer.fitPage() }
        // P12-021: running background jobs with concise descriptions and
        // cancellation, inline in the toolbar.
        if let job = jobs.jobs.first {
          HStack(spacing: 6) {
            ProgressView(value: job.fraction) { Text(job.title) }
              .frame(width: 120)
            Text("\(job.completed)/\(job.total)")
              .monospacedDigit().foregroundStyle(.secondary)
            Button {
              jobs.requestCancel(id: job.id)
            } label: {
              Image(systemName: "xmark.circle")
            }
            .help("Cancel \(job.title)").accessibilityLabel("Cancel \(job.title)")
            .disabled(!jobs.canCancel(id: job.id))
          }
        }
        Picker("Page layout", selection: Binding(
          get: { viewer.view.displayMode == .singlePageContinuous },
          set: { viewer.setContinuous($0) })) {
          Text("Continuous").tag(true)
          Text("Single Page").tag(false)
        }
        .labelsHidden()
        .frame(width: 130)
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 16).padding(.vertical, 12)
      .background(.bar)
      .disabled(viewer.isLocked)
      // P10-003: dropping PDF files onto the window opens them (Dock
      // drops and Finder opens arrive through the application delegate).
      .onDrop(of: [.pdf], isTargeted: nil) { providers in
        for provider in providers {
          _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { onOpenDroppedFile?(url) }
          }
        }
        return true
      }
      Divider()
      if viewer.isSearchVisible {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Find", text: $viewer.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .focused($searchFocused)
            .onSubmit { viewer.runSearch() }
            .accessibilityLabel("Find text")
          Text(
            viewer.searchMatchCount == 0
              ? "No matches" : "\(viewer.searchIndex) of \(viewer.searchMatchCount)"
          )
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
          Button {
            viewer.searchPrevious()
          } label: {
            Image(systemName: "chevron.up")
          }
          .help("Previous match").accessibilityLabel("Previous match")
          .disabled(viewer.searchMatchCount == 0)
          Button {
            viewer.searchNext()
          } label: {
            Image(systemName: "chevron.down")
          }
          .help("Next match").accessibilityLabel("Next match")
          .disabled(viewer.searchMatchCount == 0)
          Spacer()
          Button {
            viewer.hideSearch()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .help("Close search").accessibilityLabel("Close search")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .onAppear {
          // Focus after SwiftUI has attached the conditional native text field.
          DispatchQueue.main.async { searchFocused = true }
        }
        Divider()
      }
      if case .failed(let message) = viewer.documentState {
        ContentUnavailableView(
          "Could Not Open Document", systemImage: "doc.badge.gearshape",
          description: Text(message))
      } else if case .empty = viewer.documentState {
        ContentUnavailableView(
          "No Document", systemImage: "doc",
          description: Text("Open a PDF to view it here."))
      } else if case .loading = viewer.documentState {
        ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewer.isLocked {
        ContentUnavailableView(
          "Password-protected PDF", systemImage: "lock.doc",
          description: Text("Unlock from the File menu (Unlock Document…) to view this document."))
      } else {
        HSplitView {
          if viewer.isSidebarVisible {
            switch viewer.sidebarMode {
            case .pages:
              NativeView(view: viewer.thumbnails)
                .frame(
                  minWidth: 144,
                  idealWidth: viewer.sidebarWidth > 0 ? viewer.sidebarWidth : 168,
                  maxWidth: 320)
                .accessibilityLabel("Page thumbnails")
            case .comments:
              CommentsPanel(
                comments: comments.comments, pageCount: viewer.pageCount,
                onSelect: onSelectComment, onDelete: onDeleteComment,
                onReply: onReplyComment, onSetState: onSetStateComment)
            case .forms:
              FormsPanel(
                fields: forms.fields, orphanedWidgetCount: forms.orphanedWidgetCount,
                onSubmitText: onSubmitFormText,
                onDraftText: { forms.pendingText[$0] = $1 }, onToggle: onToggleForm,
                onSelectChoice: onSelectFormChoice, onSelect: onSelectFormField)
            case .signatures:
              SignaturesPanel(entries: signatures.entries, onSelect: onSelectSignature)
            case .fonts:
              FontsPanel(model: fonts, onProvision: onProvisionFont)
            case .inspector:
              SelectionInspectorPanel(viewer: viewer)
            case .info:
              DocumentInfoPanel(viewer: viewer)
            case .structure:
              StructurePanel(
                model: structure, onSelect: onSelectStructurePage,
                onEditRole: onEditStructureRole, onEditAltText: onEditStructureAltText,
                onMarkArtifact: onMarkStructureArtifact,
                onSuggestTags: onSuggestStructureTags,
                onAcceptSuggestion: onAcceptStructureSuggestion,
                onRejectSuggestion: onRejectStructureSuggestion,
                onApplySuggestions: onApplyStructureSuggestions,
                onDiscardSuggestions: onDiscardStructureSuggestions)
            }
          }
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
                  .accessibilityLabel("PDF pages")
                  .accessibilityValue(viewer.selectedObjectSummary ?? "No selection")
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
                if viewer.isInkToolActive {              InkOverlay(viewer: viewer)
                }
              }
            }
          }
          .frame(minWidth: 500)
        }
      }
      Divider()
      HStack {
        Label("Viewing", systemImage: "eye").foregroundStyle(.secondary)
        Spacer()
        Text("\(viewer.pageCount) \(viewer.pageCount == 1 ? "page" : "pages")").foregroundStyle(
          .secondary)
      }
      .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
    }
    .onAppear { pageEntry = String(max(1, viewer.pageNumber)) }
    .onChange(of: viewer.pageNumber) { _, page in pageEntry = String(page) }
  }
}

private struct NativeView<V: NSView>: NSViewRepresentable {
  let view: V
  func makeNSView(context: Context) -> V { view }
  func updateNSView(_ nsView: V, context: Context) {}
}
