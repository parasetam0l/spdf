import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// AUT-07 App surface: declarative recipe import/export. Recipes are JSON data
/// only; validation never executes an operation, resolves a destination or uses
/// the network. Import is gated by the compatibility report before acceptance.
@MainActor
final class RecipePortabilitySession {
  static let shared = RecipePortabilitySession()

  private static let defaultRecipe = RecipeDocument(
    name: "Current sPDF recipe",
    operations: [
      RecipeOperation(type: "optimize", settings: ["profile": .string("lossless")])
    ],
    metadata: ["origin": "sPDF Editor default"])

  private(set) var current: RecipeDocument
  private(set) var importedFromFile: Bool

  private init() {
    current = Self.defaultRecipe
    importedFromFile = false
  }

  func acceptImported(_ recipe: RecipeDocument) {
    current = recipe
    importedFromFile = true
  }

  func reset() {
    current = Self.defaultRecipe
    importedFromFile = false
  }
}

@MainActor
final class RecipePortabilityModel: ObservableObject {
  @Published private(set) var currentName: String
  @Published private(set) var operationCount: Int
  @Published private(set) var report: String?
  @Published private(set) var statusText: String?
  @Published private(set) var errorText: String?
  @Published private(set) var importedFromFile: Bool

  private let session: RecipePortabilitySession

  init(session: RecipePortabilitySession = .shared) {
    self.session = session
    currentName = session.current.name
    operationCount = session.current.operations.count
    importedFromFile = session.importedFromFile
  }

  func refreshCurrent() {
    currentName = session.current.name
    operationCount = session.current.operations.count
    importedFromFile = session.importedFromFile
  }

  @discardableResult
  func importRecipe() -> Bool {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    panel.message = "Choose a declarative sPDF recipe (.json). The validator never executes it."
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    do {
      let data = try Data(contentsOf: url)
      let validation = try RecipePortability.validate(data: data)
      let compatibility = RecipePortability.compatibilityReport(validation)
      report = compatibility
      guard validation.isAccepted, let recipe = validation.recipe else {
        errorText = "The recipe was not imported; see the compatibility report."
        statusText = nil
        presentReport(compatibility, title: "Recipe Not Imported", accepted: false)
        return false
      }
      guard presentReport(
        compatibility, title: "Import Recipe " + (recipe.name.isEmpty ? "(unnamed)" : recipe.name),
        accepted: true)
      else {
        statusText = "Import cancelled; the current recipe was not changed."
        errorText = nil
        return false
      }
      session.acceptImported(recipe)
      refreshCurrent()
      statusText = "Imported " + recipe.name + " (" + String(recipe.operations.count)
        + " operation(s)). Nothing was executed."
      errorText = nil
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = nil
      return false
    }
  }

  @discardableResult
  func exportCurrentRecipe() -> Bool {
    do {
      let data = try RecipePortability.export(session.current)
      let validation = try RecipePortability.validate(data: data)
      let compatibility = RecipePortability.compatibilityReport(validation)
      report = compatibility
      guard validation.isAccepted else {
        errorText = "The current recipe no longer validates and was not exported."
        presentReport(compatibility, title: "Recipe Not Exported", accepted: false)
        return false
      }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.canCreateDirectories = true
      panel.nameFieldStringValue =
        (session.current.name.isEmpty ? "recipe" : session.current.name) + ".spdfrecipe.json"
      panel.message = "Export the current declarative recipe. No code, paths or network "
        + "references are written."
      guard panel.runModal() == .OK, let url = panel.url else { return false }
      try data.write(to: url, options: .atomic)
      statusText = "Exported " + (session.current.name.isEmpty ? "recipe" : session.current.name)
        + " to " + url.lastPathComponent + "."
      errorText = nil
      return true
    } catch {
      errorText = error.localizedDescription
      return false
    }
  }

  func loadReport() {
    do {
      let data = try RecipePortability.export(session.current)
      let validation = try RecipePortability.validate(data: data)
      report = RecipePortability.compatibilityReport(validation)
      statusText = nil
      errorText = validation.isAccepted ? nil : "The current recipe does not validate."
    } catch {
      errorText = error.localizedDescription
    }
  }

  @MainActor
  private func presentReport(_ text: String, title: String, accepted: Bool) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.alertStyle = accepted ? .informational : .warning
    alert.informativeText =
      "Review the compatibility report before accepting. Recipes are declarative data; "
      + "nothing is executed by importing or exporting them."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let textView = NSTextView(frame: scroll.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = text
    scroll.documentView = textView
    alert.accessoryView = scroll
    if accepted {
      alert.addButton(withTitle: "Import Recipe")
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn
    }
    alert.addButton(withTitle: "OK")
    alert.runModal()
    return false
  }
}

struct RecipePortabilityPanel: View {
  @ObservedObject var model: RecipePortabilityModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recipe Portability").font(.headline)
      Text(
        "Recipes are declarative JSON: no code, expressions, paths or network references. "
          + "Import validates the format and shows a compatibility report before acceptance; "
          + "export writes the current recipe. Nothing is executed here."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Text("Current recipe: " + model.currentName)
        Text("· " + String(model.operationCount) + " operation(s)")
        if model.importedFromFile { Text("· imported") }
      }
      HStack {
        Button("Import Recipe…") { model.importRecipe() }
        Button("Export Current Recipe…") { model.exportCurrentRecipe() }
        Button("Show Compatibility Report") { model.loadReport() }
      }
      if let status = model.statusText {
        Text(status).font(.caption).foregroundStyle(.green)
      }
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      if let report = model.report {
        Text("Compatibility report").font(.subheadline.weight(.semibold))
        ScrollView {
          Text(report).font(.caption.monospaced()).textSelection(.enabled)
        }
      } else {
        Text("No report yet.").font(.caption).foregroundStyle(.secondary)
      }
      Text(
        "Boundary: importing a profile never executes arbitrary code and incompatible "
          + "operations are explained before any files are processed. This panel does not "
          + "run recipes; batch execution remains an explicit separate action."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(minWidth: 720, minHeight: 520)
    .onAppear { model.loadReport() }
  }
}

extension SPDFDocument {
  var canShowRecipePortability: Bool { true }

  /// Hook: Tools > Recipe Portability…; also used by the direct import/export menu items.
  @MainActor
  func presentRecipePortability() {
    let model = RecipePortabilityModel()
    model.refreshCurrent()
    let hosting = NSHostingView(rootView: RecipePortabilityPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 580)
    let alert = NSAlert()
    alert.messageText = "Recipe Portability"
    alert.alertStyle = .informational
    alert.informativeText =
      "Import is gated by a compatibility report; recipes are declarative and never run "
      + "from this dialog."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  /// Hook: Tools > Import Recipe….
  @MainActor
  func importRecipe() {
    _ = RecipePortabilityModel().importRecipe()
  }

  /// Hook: Tools > Export Recipe….
  @MainActor
  func exportRecipe() {
    _ = RecipePortabilityModel().exportCurrentRecipe()
  }
}
