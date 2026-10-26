import AppKit
import PDFCore
import PDFEditing
import SwiftUI

// A11Y-01 + A11Y-02: Accessibility > Structure and Reading Order… window. The tag
// list edits the structure tree (create/delete/group/split/reparent, ActualText,
// language, artifacts) through one undoable transaction per action; the reading
// order list connects tags to their page overlay bounds and reorders logical
// order only. A qualification button proves paint/overlay independence on copies.
// ApplicationDelegate owns the menu hook (reported to the Lead).

private enum StructureReadingOrderAssociationKeys {
  nonisolated(unsafe) static var controller: UInt8 = 0
}

@MainActor
final class StructureReadingOrderModel: ObservableObject {
  weak var document: SPDFDocument?
  @Published var elements: [PDFStructureElement] = []
  @Published var pageItems: [ReadingOrderItem] = []
  @Published var selection: Set<PDFObjectID> = []
  @Published var roleField = "P"
  @Published var actualTextField = ""
  @Published var languageField = ""
  @Published var status = "Select an element to edit its tag."
  @Published var reportText = ""

  private var pageIndex = 0

  func refresh() {
    guard let document, let graph = document.editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else {
      elements = []
      pageItems = []
      return
    }
    let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    elements = inventory?.elements ?? []
    let order = try? ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs)
    pageIndex = min(pageIndex, max(0, (order?.pages.count ?? 1) - 1))
    pageItems = order?.pages.first { $0.pageIndex == pageIndex }?.items ?? []
    if let selected = selectedElement {
      roleField = selected.rawRole == selected.role ? selected.role : selected.rawRole
      actualTextField = selected.actualText ?? ""
      languageField = selected.language ?? ""
    }
  }

  var selectedElement: PDFStructureElement? {
    guard let id = selection.first else { return nil }
    return elements.first { $0.objectID == id }
  }

  var rootElement: PDFStructureElement? {
    elements.first { $0.parentObjectID == nil }
  }

  private func apply(_ commands: [any PDFEditCommand], note: String) {
    guard let document else { return }
    do {
      try document.editSession.apply(PDFTransaction(commands))
      status = note
      refresh()
    } catch {
      status = "Edit failed: " + error.localizedDescription
    }
  }

  func createChild() {
    guard let selected = selectedElement, let elementID = selected.objectID else {
      status = "Select the parent element first."
      return
    }
    apply(
      [CreateStructureElementCommand(
        parentID: elementID, role: PDFName(roleField), title: "New " + roleField)],
      note: "Created a " + roleField + " child.")
  }

  func deleteSelection() {
    guard let selected = selectedElement, let elementID = selected.objectID else { return }
    apply([DeleteStructureElementCommand(elementID: elementID)], note: "Deleted the tag (paint unchanged).")
    selection = []
  }

  func groupSelection() {
    let ids = Array(selection)
    guard ids.count >= 2 else {
      status = "Select at least two sibling elements to group."
      return
    }
    guard let parent = elements.first(where: { $0.objectID == ids.first })?.parentObjectID
    else { return }
    apply(
      [GroupStructureElementsCommand(parentID: parent, elementIDs: ids)],
      note: "Grouped " + String(ids.count) + " elements.")
  }

  func splitSelection() {
    guard let selected = selectedElement, let elementID = selected.objectID,
      selected.children.count >= 2
    else {
      status = "Select a parent with at least two children to split."
      return
    }
    apply(
      [SplitStructureElementCommand(elementID: elementID, atIndex: selected.children.count / 2)],
      note: "Split the element into two.")
  }

  func reparentIntoSelection() {
    let ids = Array(selection)
    guard ids.count == 2,
      let newParent = elements.first(where: { $0.objectID == ids[1] }),
      let parentID = newParent.objectID
    else {
      status = "Select the element first (Ctrl-click adds the new parent)."
      return
    }
    apply(
      [ReparentStructureElementCommand(elementID: ids[0], newParentID: parentID)],
      note: "Reparented the element.")
  }

  func markArtifact() {
    guard let selected = selectedElement, let elementID = selected.objectID else { return }
    apply(
      [MarkStructureSubtreeArtifactCommand(elementID: elementID)],
      note: "Marked the subtree as an artifact.")
  }

  func restoreRole() {
    guard let selected = selectedElement, let elementID = selected.objectID else { return }
    apply(
      [UnmarkStructureArtifactCommand(elementID: elementID, role: PDFName(roleField))],
      note: "Restored the semantic role.")
  }

  func setRole() {
    guard let selected = selectedElement, let elementID = selected.objectID else { return }
    if selected.role == "Artifact" {
      restoreRole()
    } else {
      apply(
        [SetStructureRoleCommand(elementID: elementID, role: PDFName(roleField))],
        note: "Changed the role.")
    }
  }

  func setActualText() {
    guard let selected = selectedElement, let elementID = selected.objectID else { return }
    apply(
      [SetStructureActualTextCommand(
        elementID: elementID,
        actualText: actualTextField.isEmpty ? nil : actualTextField)],
      note: "Updated ActualText.")
  }

  func setLanguage() {
    guard let selected = selectedElement, let elementID = selected.objectID else { return }
    apply(
      [SetStructureLanguageCommand(
        elementID: elementID, language: languageField.isEmpty ? nil : languageField)],
      note: "Updated the element language.")
  }

  func movePageItem(up: Bool) {
    guard let document, let graph = document.editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph),
      pageIDs.indices.contains(pageIndex)
    else { return }
    let pageID = pageIDs[pageIndex]
    guard let selectedID = selection.first,
      let position = pageItems.firstIndex(where: { $0.elementID == selectedID })
    else {
      status = "Select a reading-order item first."
      return
    }
    let target = up ? position - 1 : position + 1
    guard pageItems.indices.contains(target) else { return }
    var order = pageItems.map(\.elementID)
    order.swapAt(position, target)
    apply(
      [ReorderPageReadingOrderCommand(pageID: pageID, orderedElementIDs: order)],
      note: up ? "Moved the tag earlier in reading order." : "Moved the tag later in reading order.")
  }

  func qualify() {
    guard let document, let graph = document.editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else { return }
    do {
      let report = try ReadingOrderEditor.qualify(in: graph, pageIDs: pageIDs)
      reportText = report.summary + "\n" + report.findings.joined(separator: "\n")
      status = report.passed
        ? "Independence verified: paint/overlays unchanged, order survives save."
        : "Qualification needs attention."
    } catch {
      reportText = ""
      status = "Qualification failed: " + error.localizedDescription
    }
  }
}

struct StructureReadingOrderPanel: View {
  @ObservedObject var model: StructureReadingOrderModel

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 6) {
        Text("Tag tree").font(.headline)
        List(selection: $model.selection) {
          ForEach(model.elements, id: \.objectID) { element in
            VStack(alignment: .leading, spacing: 1) {
              Text(element.role + (element.title.map { " — " + $0 } ?? ""))
                .font(.caption)
              if !element.actualText.isEmptyOrNil {
                Text("ActualText: " + (element.actualText ?? "")).font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }.tag(element.objectID)
          }
        }.frame(minHeight: 160)
        HStack {
          TextField("Role", text: $model.roleField).frame(width: 90)
          Button("Set Role") { model.setRole() }
          Button("New Child") { model.createChild() }
          Button("Delete") { model.deleteSelection() }
        }
        HStack {
          Button("Group") { model.groupSelection() }
          Button("Split") { model.splitSelection() }
          Button("Reparent") { model.reparentIntoSelection() }
          Button("Artifact") { model.markArtifact() }
        }
        HStack {
          TextField("ActualText", text: $model.actualTextField)
          Button("Apply") { model.setActualText() }
        }
        HStack {
          TextField("Language", text: $model.languageField).frame(width: 90)
          Button("Apply") { model.setLanguage() }
        }
      }.padding(8)
      VStack(alignment: .leading, spacing: 6) {
        Text("Visual reading order (current page)").font(.headline)
        List(selection: $model.selection) {
          ForEach(model.pageItems, id: \.elementID) { item in
            HStack {
              Text(String(item.orderIndex + 1) + ". " + item.role).font(.caption)
              Text(item.bounds.map { b in
                "[\(Int(b[0])),\(Int(b[1])) \(Int(b[2]))x\(Int(b[3]))]"
              } ?? "no overlay geometry")
                .font(.caption2).foregroundStyle(.secondary)
            }.tag(item.elementID)
          }
        }.frame(minHeight: 160)
        HStack {
          Button("Move Earlier") { model.movePageItem(up: true) }
          Button("Move Later") { model.movePageItem(up: false) }
          Button("Qualify Independence") { model.qualify() }
        }
        ScrollView {
          Text(model.reportText).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 90)
      }.padding(8)
    }
    .frame(minWidth: 780, minHeight: 520)
    .onAppear { model.refresh() }
    .onChange(of: model.selection) { _, _ in model.refresh() }
    Text(model.status).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
  }
}

@MainActor
final class StructureReadingOrderWindowController: NSWindowController {
  convenience init(model: StructureReadingOrderModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Structure and Reading Order"
    window.contentView = NSHostingView(rootView: StructureReadingOrderPanel(model: model))
    self.init(window: window)
  }
}

extension Optional where Wrapped == String {
  fileprivate var isEmptyOrNil: Bool { (self ?? "").isEmpty }
}

extension SPDFDocument {
  func structureReadingOrderInventory() -> PDFReadingOrderInventory? {
    guard let graph = editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else { return nil }
    return try? ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs)
  }

  /// Accessibility > Structure and Reading Order…: tag-tree editing plus the
  /// visual reading-order editor, both undoable through the document session.
  func showStructureReadingOrder() {
    if let existing = objc_getAssociatedObject(
      self, &StructureReadingOrderAssociationKeys.controller)
      as? StructureReadingOrderWindowController
    {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let model = StructureReadingOrderModel()
    model.document = self
    let controller = StructureReadingOrderWindowController(model: model)
    objc_setAssociatedObject(
      self, &StructureReadingOrderAssociationKeys.controller, controller,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    controller.showWindow(nil)
  }
}

