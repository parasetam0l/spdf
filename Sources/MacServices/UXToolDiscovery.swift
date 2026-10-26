import Foundation

// UX-03: predictable discovery. One searchable catalog describes every
// implemented tool with its limitations, a recent-file model and contextual
// controls, plus validated user presets. Users find a tool and its limits from
// the UI without reading developer diagnostics.

public enum UXToolCategory: String, CaseIterable, Sendable, Equatable {
  case document
  case editing
  case forms
  case review
  case scan
  case security
  case accessibility
  case export
  case automation
}

public enum UXToolContext: String, CaseIterable, Sendable, Equatable {
  case noDocument
  case documentOpen
  case textSelection
  case formField
  case scannedPage
  case comparison
  case comments
  case redaction
  case signature
  case accessibility
}

public enum UXToolAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)

  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }
  public var reason: String? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

public struct UXToolEntry: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let category: UXToolCategory
  public let summary: String
  /// Human-facing limitations shown with the tool; never developer diagnostics.
  public let limitations: [String]
  public let keywords: [String]
  public let contexts: [UXToolContext]
  public let shortcut: String?
  public let availability: UXToolAvailability
  /// Preset option names this tool accepts; unknown names are refused.
  public let presetOptions: [String]

  public init(
    id: String, title: String, category: UXToolCategory, summary: String,
    limitations: [String], keywords: [String], contexts: [UXToolContext],
    shortcut: String?, availability: UXToolAvailability,
    presetOptions: [String] = []
  ) {
    self.id = id
    self.title = title
    self.category = category
    self.summary = summary
    self.limitations = limitations
    self.keywords = keywords
    self.contexts = contexts
    self.shortcut = shortcut
    self.availability = availability
    self.presetOptions = presetOptions
  }

  public var limitationSummary: String {
    limitations.first ?? "No limitations are declared for this tool."
  }
}

public struct UXToolSearchResult: Sendable, Equatable, Identifiable {
  public let entry: UXToolEntry
  public let score: Int
  public var id: String { entry.id }
  public init(entry: UXToolEntry, score: Int) {
    self.entry = entry
    self.score = score
  }
}

public enum UXToolCatalog {
  public static let identifier = "spdf-ux-tool-catalog-v1"

  public static let entries: [UXToolEntry] = [
    UXToolEntry(
      id: "document.open", title: "Open PDF", category: .document,
      summary: "Open a local PDF document and its pages.",
      limitations: [
        "Encrypted files need a password before any editing.",
        "Signed documents can be read; editing and saving invalidates existing signatures.",
      ],
      keywords: ["open", "file", "document", "pdf"], contexts: [.noDocument],
      shortcut: "Command+O", availability: .available),
    UXToolEntry(
      id: "edit.text", title: "Edit text", category: .editing,
      summary: "Edit existing text runs with the native editor.",
      limitations: [
        "Only Standard-14 and supported embedded fonts are editable.",
        "This profile edits streams whose filter chain is absent or plain FlateDecode.",
      ],
      keywords: ["text", "caret", "type", "edit", "font"], contexts: [.documentOpen, .textSelection],
      shortcut: "V", availability: .available, presetOptions: ["alignment", "fontSize"]),
    UXToolEntry(
      id: "forms.fill", title: "Fill form fields", category: .forms,
      summary: "Fill text, choice and button fields with generated appearances.",
      limitations: [
        "Imported document JavaScript and actions are preserved but never executed.",
        "Read-only, saved or signed fields are refused explicitly.",
      ],
      keywords: ["form", "field", "fill", "checkbox", "choice"], contexts: [.formField],
      shortcut: nil, availability: .available, presetOptions: ["overwriteExisting"]),
    UXToolEntry(
      id: "review.comments", title: "Comments and review", category: .review,
      summary: "Add, reply to and resolve comments with keyboard access.",
      limitations: [
        "Review state is stored in this app's form of the comment; other readers vary.",
      ],
      keywords: ["comment", "review", "reply", "resolve"], contexts: [.comments, .documentOpen],
      shortcut: "Command+Shift+M", availability: .available),
    UXToolEntry(
      id: "scan.ocr", title: "OCR scanned pages", category: .scan,
      summary: "Recognize scanned text through the reviewed OCR job queue.",
      limitations: [
        "Recognition quality depends on the scan; the result is never claimed as perfect.",
        "Network and cloud OCR are not available in this profile.",
      ],
      keywords: ["ocr", "scan", "recognize", "text layer"], contexts: [.scannedPage],
      shortcut: "Command+Shift+O", availability: .available,
      presetOptions: ["language", "level"]),
    UXToolEntry(
      id: "security.redact", title: "Redact content", category: .security,
      summary: "Mark content, preview and apply redaction before saving.",
      limitations: [
        "Redaction is irreversible and removes hidden content only for covered objects.",
        "The document is saved as a new file; the original is never overwritten.",
      ],
      keywords: ["redact", "black out", "remove", "sanitize"], contexts: [.redaction],
      shortcut: "Command+Shift+R", availability: .available,
      presetOptions: ["paintScope"]),
    UXToolEntry(
      id: "signature.sign", title: "Sign document", category: .security,
      summary: "Sign with an existing identity or sign an existing field.",
      limitations: [
        "Signing needs an installed identity; this build has no hardware-token profile.",
        "Trust evaluation is offline; timestamping varies by the selected identity.",
      ],
      keywords: ["sign", "signature", "certificate", "identity"], contexts: [.signature],
      shortcut: nil,
      availability: .unavailable(
        reason: "Requires an installed signing identity; import one in Signature settings."),
      presetOptions: ["reason"]),
    UXToolEntry(
      id: "accessibility.structure", title: "Accessibility structure", category: .accessibility,
      summary: "Review tags, reading order and accessibility findings.",
      limitations: [
        "Machine checks are not a conformance claim; human review stays required.",
        "Assisted tagging produces reviewed suggestions, not automatic conformance.",
      ],
      keywords: ["accessibility", "tag", "reading order", "voiceover", "a11y"],
      contexts: [.accessibility, .documentOpen], shortcut: nil, availability: .available),
    UXToolEntry(
      id: "export.batch", title: "Batch recipes", category: .export,
      summary: "Run reviewed batch recipes over selected files.",
      limitations: [
        "Only declared safe operations are available; unsupported operations are refused.",
        "Each file reports its own outcome; partial success is never reported as full success.",
      ],
      keywords: ["batch", "recipe", "export", "automation", "convert"], contexts: [.documentOpen],
      shortcut: nil, availability: .available, presetOptions: ["destinationPolicy"]),
  ]

  public static func entry(id: String) -> UXToolEntry? {
    entries.first { $0.id == id }
  }

  /// Case-insensitive search across titles, keywords, summaries and limitations
  /// (so users can find a tool by the limitation they remember). An unavailable
  /// tool is still listed with its reason; it is never silently hidden.
  public static func search(_ query: String, context: UXToolContext? = nil) -> [UXToolSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [UXToolSearchResult] = []
    for entry in entries {
      if let context, !entry.contexts.contains(context) { continue }
      if trimmed.isEmpty {
        results.append(UXToolSearchResult(entry: entry, score: 0))
        continue
      }
      let needle = trimmed.lowercased()
      var score = 0
      if entry.title.lowercased().contains(needle) { score += 10 }
      if entry.id.lowercased().contains(needle) { score += 8 }
      if entry.keywords.contains(where: { $0.lowercased().contains(needle) }) { score += 6 }
      if entry.summary.lowercased().contains(needle) { score += 4 }
      if entry.limitations.contains(where: { $0.lowercased().contains(needle) }) { score += 3 }
      if let shortcut = entry.shortcut?.lowercased(), shortcut.contains(needle) { score += 2 }
      if score > 0 { results.append(UXToolSearchResult(entry: entry, score: score)) }
    }
    return results.sorted {
      $0.score != $1.score ? $0.score > $1.score : $0.entry.title < $1.entry.title
    }
  }

  public static func contextualTools(for context: UXToolContext) -> [UXToolEntry] {
    entries.filter { $0.contexts.contains(context) }
  }

  public static func availableTools() -> [UXToolEntry] {
    entries.filter { $0.availability.isAvailable }
  }

  public static func validate() -> [String] {
    var issues: [String] = []
    var ids = Set<String>()
    for entry in entries {
      if !ids.insert(entry.id).inserted { issues.append("Duplicate tool id " + entry.id + ".") }
      if entry.title.isEmpty { issues.append("Tool " + entry.id + " has no title.") }
      if entry.summary.isEmpty { issues.append("Tool " + entry.id + " has no summary.") }
      if entry.limitations.isEmpty {
        issues.append("Tool " + entry.id + " discloses no limitations.")
      }
      if entry.contexts.isEmpty { issues.append("Tool " + entry.id + " has no contexts.") }
      if case .unavailable(let reason) = entry.availability, reason.isEmpty {
        issues.append("Tool " + entry.id + " is unavailable without a reason.")
      }
    }
    return issues
  }
}

// MARK: - Presets

public struct UXPreset: Codable, Sendable, Equatable, Identifiable {
  public static let schemaVersion = 1
  public let schemaVersion: Int
  public let name: String
  public let toolID: String
  public let options: [String: String]
  public var id: String { name }

  public init(name: String, toolID: String, options: [String: String]) {
    self.schemaVersion = Self.schemaVersion
    self.name = name
    self.toolID = toolID
    self.options = options
  }

  /// Validate before use: the preset must point at a catalog tool, use only its
  /// declared option names and have a supported schema. Values are plain strings;
  /// a preset can never carry code or an operation outside the catalog.
  public func validated() -> [String] {
    var issues: [String] = []
    if schemaVersion != Self.schemaVersion {
      issues.append(
        "Preset \"" + name + "\" uses schema " + String(schemaVersion)
          + "; this build supports " + String(Self.schemaVersion) + ".")
    }
    guard let tool = UXToolCatalog.entry(id: toolID) else {
      issues.append("Preset \"" + name + "\" refers to the unknown tool \"" + toolID + "\".")
      return issues
    }
    if !tool.availability.isAvailable {
      issues.append(
        "Preset \"" + name + "\" targets the unavailable tool \"" + tool.title + "\": "
          + (tool.availability.reason ?? "unavailable") + ".")
    }
    for option in options.keys where !tool.presetOptions.contains(option) {
      issues.append(
        "Preset \"" + name + "\" sets the unsupported option \"" + option + "\" for "
          + tool.title + ".")
    }
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("A preset needs a name.")
    }
    return issues
  }
}

/// User-defaults backed preset store. Invalid presets are reported instead of
/// being silently dropped, and no preset can execute code.
public final class UXPresetStore {
  public static let defaultsKey = "spdf.ux.presets"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public private(set) var loadIssues: [String] = []

  public func load() -> [UXPreset] {
    loadIssues = []
    guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
    do {
      let presets = try JSONDecoder().decode([UXPreset].self, from: data)
      var valid: [UXPreset] = []
      for preset in presets {
        let issues = preset.validated()
        if issues.isEmpty {
          valid.append(preset)
        } else {
          loadIssues.append(contentsOf: issues)
        }
      }
      return valid
    } catch {
      loadIssues.append(
        "Stored presets cannot be read and were left untouched: " + error.localizedDescription)
      return []
    }
  }

  @discardableResult
  public func save(_ preset: UXPreset) -> [String] {
    let issues = preset.validated()
    guard issues.isEmpty else { return issues }
    var presets = load()
    presets.removeAll { $0.name == preset.name }
    presets.append(preset)
    write(presets)
    return []
  }

  public func remove(named name: String) {
    var presets = load()
    presets.removeAll { $0.name == name }
    write(presets)
  }

  private func write(_ presets: [UXPreset]) {
    guard let data = try? JSONEncoder().encode(presets) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}

// MARK: - Recent files

public struct UXRecentFileEntry: Codable, Sendable, Equatable, Identifiable {
  public let path: String
  public let displayName: String
  public let lastOpened: Date
  public var id: String { path }
  public init(url: URL, lastOpened: Date) {
    self.path = url.standardizedFileURL.path
    self.displayName = url.lastPathComponent
    self.lastOpened = lastOpened
  }
}

/// Bounded recent-file list. Only file URLs and timestamps are stored; no
/// document content or thumbnail is retained.
public struct UXRecentFiles: Sendable, Equatable {
  public static let maximumEntries = 12
  public private(set) var entries: [UXRecentFileEntry]
  public init(entries: [UXRecentFileEntry] = []) {
    self.entries = Array(entries.prefix(Self.maximumEntries))
  }

  public mutating func record(_ url: URL, at date: Date = Date()) {
    let entry = UXRecentFileEntry(url: url, lastOpened: date)
    entries.removeAll { $0.path == entry.path }
    entries.insert(entry, at: 0)
    if entries.count > Self.maximumEntries {
      entries.removeLast(entries.count - Self.maximumEntries)
    }
  }

  public func mostRecent(_ count: Int = 5) -> [UXRecentFileEntry] {
    Array(entries.prefix(count))
  }

  public mutating func remove(path: String) {
    entries.removeAll { $0.path == path }
  }
}

// MARK: - Contextual controls

public struct UXContextualControl: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let hint: String
  public let context: UXToolContext
  public let toolID: String?
  public init(id: String, title: String, hint: String, context: UXToolContext, toolID: String?) {
    self.id = id
    self.title = title
    self.hint = hint
    self.context = context
    self.toolID = toolID
  }
}

public enum UXContextualControls {
  public static let controls: [UXContextualControl] = [
    UXContextualControl(
      id: "control.selection", title: "Selection", hint: "Shift+Arrow extends the selection.",
      context: .textSelection, toolID: "edit.text"),
    UXContextualControl(
      id: "control.formField", title: "Form field", hint: "Tab moves to the next field; Return "
        + "applies.", context: .formField, toolID: "forms.fill"),
    UXContextualControl(
      id: "control.scan", title: "OCR", hint: "Command+Shift+O starts a reviewed OCR job.",
      context: .scannedPage, toolID: "scan.ocr"),
    UXContextualControl(
      id: "control.redaction", title: "Redaction", hint: "Mark, preview, then apply redaction.",
      context: .redaction, toolID: "security.redact"),
    UXContextualControl(
      id: "control.comments", title: "Comments", hint: "Command+Shift+M opens the comment panel.",
      context: .comments, toolID: "review.comments"),
    UXContextualControl(
      id: "control.accessibility", title: "Accessibility", hint: "Review tags and findings; "
        + "human review remains required.", context: .accessibility,
      toolID: "accessibility.structure"),
    UXContextualControl(
      id: "control.document", title: "Document", hint: "Command+O opens a document.",
      context: .documentOpen, toolID: "document.open"),
    UXContextualControl(
      id: "control.comparison", title: "Comparison", hint: "Choose two pages to compare; "
        + "changes are navigated with the comparison controls.", context: .comparison,
      toolID: nil),
    UXContextualControl(
      id: "control.signature", title: "Signature", hint: "Sign with an installed identity; "
        + "import one in Signature settings first.", context: .signature,
      toolID: "signature.sign"),
    UXContextualControl(
      id: "control.none", title: "Open a document", hint: "Command+O opens a document.",
      context: .noDocument, toolID: "document.open"),
  ]

  public static func controls(for context: UXToolContext) -> [UXContextualControl] {
    controls.filter { $0.context == context }
  }
}
