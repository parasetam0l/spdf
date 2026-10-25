import AppKit
import Combine
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PAG-01 model

/// One thumbnail tile: physical order, document label, resolved page geometry
/// and the rendered preview. Mixed-size and rotated pages keep their own
/// aspect ratio while the tile width follows the zoom.
struct PageOrganizerTile: Identifiable {
  var id: PDFObjectID { info.pageID }
  let info: PageOrganizerPageInfo
  let thumbnail: NSImage?
}

@MainActor
final class PageOrganizerCanvasModel: ObservableObject {
  @Published var tiles: [PageOrganizerTile] = []
  @Published var selection: Set<PDFObjectID> = []
  @Published var zoom: Double = 120
  @Published var rangeText = ""
  @Published var message: String?
  @Published var errorMessage: String?
  @Published var dropTargetPageID: PDFObjectID?
  @Published var showsReplacePagesSheet = false
  /// Retained while the Replace Pages sheet is open so typed policy choices
  /// and the preview survive parent view updates.
  @Published var replacePagesModel: ReplacePagesModel?

  private weak var document: SPDFDocument?
  private var anchorPageID: PDFObjectID?
  private var thumbnailCache: [PDFObjectID: NSImage] = [:]
  private var cachedZoom: Double = 0
  private var draggingPageIDs: [PDFObjectID] = []

  init(document: SPDFDocument) {
    self.document = document
    refresh(regenerateThumbnails: true)
  }

  var orderedSelection: [PDFObjectID] {
    tiles.map(\.info.pageID).filter { selection.contains($0) }
  }

  var selectionSummary: String {
    if selection.isEmpty { return "No pages selected" }
    return "\(selection.count) page\(selection.count == 1 ? "" : "s") selected"
  }

  func refresh(regenerateThumbnails: Bool = false) {
    guard let document, let graph = document.editSession.currentGraph else {
      tiles = []
      return
    }
    do {
      let infos = try PageOrganizerInfo.pages(in: graph)
      selection = selection.filter { id in infos.contains { $0.pageID == id } }
      if regenerateThumbnails || abs(zoom - cachedZoom) > 0.5 {
        rebuildThumbnails(document: document, infos: infos)
      }
      tiles = infos.map { info in
        PageOrganizerTile(info: info, thumbnail: thumbnailCache[info.pageID])
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func rebuildThumbnails(
    document: SPDFDocument, infos: [PageOrganizerPageInfo]
  ) {
    guard let data = try? document.editSession.bytesForSave(),
      let pdf = PDFDocument(data: data)
    else { return }
    let pixelWidth = max(80, Int(zoom * 2))
    thumbnailCache.removeAll()
    for info in infos {
      guard let page = pdf.page(at: info.pageIndex + 1) else { continue }
      let display = info.displaySize
      let aspect = display[0] > 0 ? display[1] / display[0] : 1
      let size = NSSize(
        width: pixelWidth, height: max(40, Int(Double(pixelWidth) * aspect)))
      thumbnailCache[info.pageID] = page.thumbnail(of: size, for: .cropBox)
    }
    cachedZoom = zoom
  }

  func setZoom(_ value: Double) {
    zoom = min(260, max(70, value))
    refresh(regenerateThumbnails: true)
  }

  // MARK: Selection

  func select(_ tile: PageOrganizerTile, modifiers: NSEvent.ModifierFlags) {
    let pageID = tile.info.pageID
    if modifiers.contains(.shift), let anchor = anchorPageID,
      let anchorIndex = tiles.firstIndex(where: { $0.info.pageID == anchor }),
      let index = tiles.firstIndex(where: { $0.info.pageID == pageID })
    {
      let range = anchorIndex <= index ? anchorIndex...index : index...anchorIndex
      if modifiers.contains(.command) {
        for offset in range { selection.insert(tiles[offset].info.pageID) }
      } else {
        selection = Set(range.map { tiles[$0].info.pageID })
      }
      return
    }
    if modifiers.contains(.command) {
      if selection.contains(pageID) {
        selection.remove(pageID)
      } else {
        selection.insert(pageID)
      }
      anchorPageID = pageID
    } else {
      selection = [pageID]
      anchorPageID = pageID
    }
  }

  func selectAll() {
    selection = Set(tiles.map(\.info.pageID))
  }

  func clearSelection() {
    selection.removeAll()
    anchorPageID = nil
  }

  func selectRange(_ text: String) {
    guard !tiles.isEmpty else { return }
    let indices = PageRange.parse(text, pageCount: tiles.count)
    guard !indices.isEmpty else {
      errorMessage = "Enter a page range such as 1-3, 5 or 2-4,7."
      return
    }
    selection = Set(indices.map { tiles[$0].info.pageID })
    anchorPageID = tiles[indices[0]].info.pageID
    errorMessage = nil
  }

  // MARK: Drag/reorder

  func beginDragging(_ tile: PageOrganizerTile) {
    let ordered = orderedSelection
    if ordered.contains(tile.info.pageID) {
      draggingPageIDs = ordered
    } else {
      // Dragging an unselected tile selects it first so focus follows the move.
      selection = [tile.info.pageID]
      anchorPageID = tile.info.pageID
      draggingPageIDs = [tile.info.pageID]
    }
  }

  func completeDrop(before target: PageOrganizerTile) {
    defer { draggingPageIDs = []; dropTargetPageID = nil }
    guard !draggingPageIDs.isEmpty else { return }
    let moving = draggingPageIDs
    let targetID = target.info.pageID
    guard !moving.contains(targetID) else { return }
    let remaining = tiles.map(\.info.pageID).filter { !moving.contains($0) }
    guard let targetIndex = remaining.firstIndex(of: targetID) else { return }
    apply(
      [MovePagesCommand(pageIDs: moving, toIndex: targetIndex)],
      actionName: "Move Pages", keepSelection: moving)
  }

  // MARK: Batch actions (one transaction each)

  func moveSelectionUp() {
    guard let target = blockShiftTarget(by: -1) else { return }
    apply(
      [MovePagesCommand(pageIDs: orderedSelection, toIndex: target)],
      actionName: "Move Pages")
  }

  func moveSelectionDown() {
    guard let target = blockShiftTarget(by: 1) else { return }
    apply(
      [MovePagesCommand(pageIDs: orderedSelection, toIndex: target)],
      actionName: "Move Pages")
  }

  func moveSelectionToStart() {
    let moving = orderedSelection
    guard !moving.isEmpty else { return }
    apply([MovePagesCommand(pageIDs: moving, toIndex: 0)], actionName: "Move Pages")
  }

  func moveSelectionToEnd() {
    let moving = orderedSelection
    guard !moving.isEmpty else { return }
    let remaining = tiles.map(\.info.pageID).filter { !moving.contains($0) }
    apply(
      [MovePagesCommand(pageIDs: moving, toIndex: remaining.count)],
      actionName: "Move Pages")
  }

  /// Block position is the number of unselected pages before the first
  /// selected page; up/down moves by one unselected page.
  private func blockShiftTarget(by delta: Int) -> Int? {
    let moving = orderedSelection
    guard !moving.isEmpty,
      let firstSelected = moving.first
    else {
      message = "Select at least one page first."
      return nil
    }
    let remaining = tiles.map(\.info.pageID).filter { !moving.contains($0) }
    guard let position = remaining.firstIndex(of: firstSelected) else { return nil }
    return min(max(0, position + delta), remaining.count)
  }

  func rotateSelection(byDegrees degrees: Int) {
    let moving = orderedSelection
    guard !moving.isEmpty else { return }
    apply(
      [RotatePagesCommand(pageIDs: moving, byDegrees: degrees)],
      actionName: "Rotate Pages")
  }

  func duplicateSelection() {
    let moving = orderedSelection
    guard !moving.isEmpty else { return }
    apply(
      [DuplicatePagesCommand(pageIDs: moving)], actionName: "Duplicate Pages",
      keepSelection: moving)
  }

  func deleteSelection() {
    let moving = orderedSelection
    guard !moving.isEmpty else { return }
    guard moving.count < tiles.count else {
      errorMessage = "At least one page must remain in the document."
      return
    }
    apply([DeletePagesCommand(pageIDs: moving)], actionName: "Delete Pages")
  }

  func extractSelection() {
    let moving = orderedSelection
    guard !moving.isEmpty else {
      message = "Select pages to extract."
      return
    }
    document?.presentExtractSelectedPages(pageIDs: moving)
  }

  func openReplacePages() {
    guard !orderedSelection.isEmpty else {
      errorMessage = "Select the destination pages to replace first."
      return
    }
    guard let document else { return }
    replacePagesModel = ReplacePagesModel(
      document: document,
      destinationPageIDs: orderedSelection,
      onApplied: { [weak self] in self?.refresh(regenerateThumbnails: true) })
    showsReplacePagesSheet = true
  }

  private func apply(
    _ commands: [any PDFEditCommand], actionName: String,
    keepSelection: [PDFObjectID]? = nil
  ) {
    guard let document, !commands.isEmpty else { return }
    let ids = keepSelection ?? orderedSelection
    guard document.applyPageOrganizerTransaction(
      PDFTransaction(commands), actionName: actionName)
    else {
      errorMessage = "The page action was refused."
      return
    }
    selection = Set(ids)
    message = actionName + " applied as one undoable step."
    refresh(regenerateThumbnails: true)
  }
}

// MARK: - Window controller

@MainActor
final class PageOrganizerCanvasController: NSWindowController {
  let model: PageOrganizerCanvasModel

  init(document: SPDFDocument) {
    let model = PageOrganizerCanvasModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Organize Pages"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 780, height: 560)
    panel.contentView = NSHostingView(rootView: PageOrganizerCanvasView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the page organizer")
  }

  func refresh() {
    model.refresh(regenerateThumbnails: true)
  }
}

// MARK: - View

struct PageOrganizerCanvasView: View {
  @ObservedObject var model: PageOrganizerCanvasModel

  private var columns: [GridItem] {
    [GridItem(.adaptive(minimum: model.zoom, maximum: model.zoom * 1.9), spacing: 12)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      toolbar
      Divider()
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
          ForEach(model.tiles) { tile in
            tileView(tile)
          }
        }
        .padding(6)
      }
      Divider()
      actionBar
    }
    .padding(14)
    .frame(minWidth: 780, minHeight: 560)
    .sheet(isPresented: $model.showsReplacePagesSheet) {
      if let replaceModel = model.replacePagesModel {
        ReplacePagesPanel(model: replaceModel)
      }
    }
    .accessibilityLabel("Thumbnail page organizer")
  }

  private var toolbar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Text("Organize Pages").font(.title3.weight(.semibold))
        Spacer()
        Text(model.selectionSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        HStack(spacing: 6) {
          Text("Zoom").font(.caption).foregroundStyle(.secondary)
          Slider(
            value: Binding(
              get: { model.zoom },
              set: { model.setZoom($0) }),
            in: 70...260)
            .frame(width: 150)
            .accessibilityLabel("Thumbnail zoom")
        }
        HStack(spacing: 6) {
          TextField("Range e.g. 1-3,5", text: $model.rangeText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .onSubmit { model.selectRange(model.rangeText) }
            .accessibilityLabel("Page range selection")
          Button("Select Range") { model.selectRange(model.rangeText) }
            .accessibilityLabel("Select page range")
        }
        Button("Select All") { model.selectAll() }
          .accessibilityLabel("Select all pages")
        Button("Clear") { model.clearSelection() }
          .accessibilityLabel("Clear page selection")
        Spacer()
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func tileView(_ tile: PageOrganizerTile) -> some View {
    let selected = model.selection.contains(tile.info.pageID)
    let isDropTarget = model.dropTargetPageID == tile.info.pageID
    let display = tile.info.displaySize
    let aspect = display[0] > 0 ? display[1] / display[0] : 1
    let height = model.zoom * aspect
    return VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.secondary.opacity(0.08))
          .frame(width: model.zoom, height: height)
        if let thumbnail = tile.thumbnail {
          Image(nsImage: thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: model.zoom - 8, height: max(20, height - 8))
            .padding(4)
        } else {
          Text("Page \(tile.info.physicalLabel)")
            .font(.caption)
            .frame(width: model.zoom, height: height)
        }
        Text(tile.info.physicalLabel)
          .font(.caption2.weight(.semibold))
          .padding(3)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
          .padding(4)
        if tile.info.rotation != 0 {
          Text("\(tile.info.rotation)°")
            .font(.caption2)
            .padding(3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      .frame(width: model.zoom, height: height)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(
            isDropTarget ? Color.accentColor
              : (selected ? Color.accentColor : Color.secondary.opacity(0.35)),
            lineWidth: isDropTarget ? 3 : (selected ? 2 : 1)))
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onTapGesture {
        model.select(tile, modifiers: NSEvent.modifierFlags)
      }
      .onDrag {
        model.beginDragging(tile)
        return NSItemProvider(object: String(tile.info.pageID.number) as NSString)
      }
      .onDrop(
        of: [UTType.utf8PlainText, UTType.text],
        delegate: PageOrganizerDropDelegate(target: tile, model: model))
      .accessibilityLabel(
        "Page \(tile.info.physicalLabel), label \(tile.info.label)"
          + (selected ? ", selected" : ""))
      HStack(spacing: 4) {
        Text(tile.info.label)
          .font(.caption2.weight(.medium))
        Text(
          "\(Int(tile.info.displaySize[0].rounded()))×\(Int(tile.info.displaySize[1].rounded()))"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var actionBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button("Move Up") { model.moveSelectionUp() }
          .accessibilityLabel("Move selected pages up")
        Button("Move Down") { model.moveSelectionDown() }
          .accessibilityLabel("Move selected pages down")
        Button("To Start") { model.moveSelectionToStart() }
        Button("To End") { model.moveSelectionToEnd() }
        Divider().frame(height: 18)
        Button("Rotate Left") { model.rotateSelection(byDegrees: -90) }
        Button("Rotate Right") { model.rotateSelection(byDegrees: 90) }
        Button("Duplicate") { model.duplicateSelection() }
        Button("Delete") { model.deleteSelection() }
        Spacer()
        Button("Extract…") { model.extractSelection() }
        Button("Replace Pages…") { model.openReplacePages() }
          .accessibilityLabel("Replace selected destination pages")
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      .font(.callout)
      Text(
        "Every action is one transaction and one undo step. Drag thumbnails to reorder; "
          + "⌘-click toggles and ⇧-click extends the selection. Labels come from /PageLabels.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Drop delegate

struct PageOrganizerDropDelegate: DropDelegate {
  let target: PageOrganizerTile
  let model: PageOrganizerCanvasModel

  func dropEntered(info: DropInfo) {
    model.dropTargetPageID = target.info.pageID
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if model.dropTargetPageID == target.info.pageID {
      model.dropTargetPageID = nil
    }
  }

  func performDrop(info: DropInfo) -> Bool {
    model.completeDrop(before: target)
    return true
  }
}

