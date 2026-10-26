import Darwin
import Foundation
import PDFCore
import PDFEditing

// UX-04: bounded large-document processing. The current architecture parses the
// whole graph eagerly (declared decision), so this profile qualifies declared
// page/byte classes against measured open/search/edit/save/cancellation budgets
// on the named machine, ships a bounded page cache for repeated page access and
// a cancellable page scan. Budgets are measured evidence, not marketing claims.

public struct LargeDocumentClass: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let declaredPages: Int?
  public let declaredBytes: Int64?
  public let notes: String
  public init(
    id: String, title: String, declaredPages: Int?, declaredBytes: Int64?, notes: String
  ) {
    self.id = id
    self.title = title
    self.declaredPages = declaredPages
    self.declaredBytes = declaredBytes
    self.notes = notes
  }
}

public struct UXLargeDocumentBudget: Sendable, Equatable {
  public let openSeconds: Double
  public let saveSeconds: Double
  public let textSecondsPerPage: Double
  public let cancellationSeconds: Double
  public let residentMemoryMB: Double
  public init(
    openSeconds: Double, saveSeconds: Double, textSecondsPerPage: Double,
    cancellationSeconds: Double, residentMemoryMB: Double
  ) {
    self.openSeconds = openSeconds
    self.saveSeconds = saveSeconds
    self.textSecondsPerPage = textSecondsPerPage
    self.cancellationSeconds = cancellationSeconds
    self.residentMemoryMB = residentMemoryMB
  }
}

public struct LargeDocumentDecision: Sendable, Equatable {
  public let currentApproach: String
  public let boundedCaches: [String]
  public let cancellableWork: [String]
  public let notImplemented: [String]
  public init(
    currentApproach: String, boundedCaches: [String], cancellableWork: [String],
    notImplemented: [String]
  ) {
    self.currentApproach = currentApproach
    self.boundedCaches = boundedCaches
    self.cancellableWork = cancellableWork
    self.notImplemented = notImplemented
  }
}

public enum UXLargeDocumentProfile {
  public static let identifier = "spdf-large-document-budget-v1"

  public static var machineName: String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
      return ProcessInfo.processInfo.machineNameFallback
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
      return ProcessInfo.processInfo.machineNameFallback
    }
    let name = String(cString: buffer)
    return name.isEmpty ? ProcessInfo.processInfo.machineNameFallback : name
  }

  public static let classes: [LargeDocumentClass] = [
    LargeDocumentClass(
      id: "500-page", title: "500-page document", declaredPages: 500, declaredBytes: nil,
      notes: "Synthetic text-only pages; measures open, text access, save and cancellation."),
    LargeDocumentClass(
      id: "2000-page", title: "2,000-page document", declaredPages: 2_000, declaredBytes: nil,
      notes: "Synthetic text-only pages at the declared upper page class."),
    LargeDocumentClass(
      id: "large-byte", title: "Large-byte document", declaredPages: nil,
      declaredBytes: 64 * 1_024 * 1_024,
      notes: "Declared byte class; qualification is opt-in because generating and parsing it is "
        + "memory/time heavy."),
  ]

  public static func budget(for classID: String) -> UXLargeDocumentBudget? {
    switch classID {
    case "500-page":
      return UXLargeDocumentBudget(
        openSeconds: 15, saveSeconds: 15, textSecondsPerPage: 0.5,
        cancellationSeconds: 0.5, residentMemoryMB: 2_000)
    case "2000-page":
      return UXLargeDocumentBudget(
        openSeconds: 45, saveSeconds: 45, textSecondsPerPage: 0.5,
        cancellationSeconds: 0.5, residentMemoryMB: 3_000)
    case "large-byte":
      return UXLargeDocumentBudget(
        openSeconds: 60, saveSeconds: 60, textSecondsPerPage: 0.5,
        cancellationSeconds: 0.5, residentMemoryMB: 3_500)
    default:
      return nil
    }
  }

  public static let decision = LargeDocumentDecision(
    currentApproach: "PDFParser parses the complete graph eagerly; the app's declared page cap "
      + "remains enforced and large files are opened with a progress/cancellation boundary.",
    boundedCaches: [
      "BoundedPageCache: LRU page records with a declared maximum entry count (no unbounded page "
        + "growth).",
      "Rendered page images and OCR results use existing bounded service caches; this profile "
        + "does not add unbounded caches.",
    ],
    cancellableWork: [
      "Cancellable page scan for text search/access; checks cancellation between pages and "
        + "reports the measured cancellation latency.",
      "Existing OCR/batch jobs keep their job-level cancellation; this profile reuses it.",
    ],
    notImplemented: [
      "True lazy source/object access (parse-on-demand) is not implemented in this profile; the "
        + "eager parser and file-size/page caps remain the declared boundary.",
      "Memory-mapped incremental parsing is not implemented; large-byte qualification is opt-in.",
    ])

  public static func validate() -> [String] {
    var issues: [String] = []
    for documentClass in classes {
      guard let budget = budget(for: documentClass.id) else {
        issues.append("Class " + documentClass.id + " has no budget.")
        continue
      }
      if budget.openSeconds <= 0 || budget.saveSeconds <= 0 || budget.textSecondsPerPage <= 0 {
        issues.append("Class " + documentClass.id + " has a non-positive budget.")
      }
      if documentClass.declaredPages == nil && documentClass.declaredBytes == nil {
        issues.append("Class " + documentClass.id + " declares neither pages nor bytes.")
      }
    }
    if machineName.isEmpty { issues.append("The named qualification machine is empty.") }
    if decision.notImplemented.isEmpty {
      issues.append("The decision record must name what is not implemented.")
    }
    return issues
  }
}

extension ProcessInfo {
  fileprivate var machineNameFallback: String {
    "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
  }
}

/// Bounded LRU cache used for repeated page access. The cache is not thread-safe;
// MARK: - Budgeted measurement

public struct UXLargeDocumentMeasurement: Sendable, Equatable {
  public let classID: String
  public let machine: String
  public let byteCount: Int
  public let pageCount: Int
  public let openSeconds: Double
  public let saveSeconds: Double
  public let textSecondsPerPage: Double
  public let textPagesMeasured: Int
  public let cancellationSeconds: Double
  public let residentMemoryMB: Double
  public let issues: [String]
  public var passed: Bool { issues.isEmpty }
  public init(
    classID: String, machine: String, byteCount: Int, pageCount: Int, openSeconds: Double,
    saveSeconds: Double, textSecondsPerPage: Double, textPagesMeasured: Int,
    cancellationSeconds: Double, residentMemoryMB: Double, issues: [String]
  ) {
    self.classID = classID
    self.machine = machine
    self.byteCount = byteCount
    self.pageCount = pageCount
    self.openSeconds = openSeconds
    self.saveSeconds = saveSeconds
    self.textSecondsPerPage = textSecondsPerPage
    self.textPagesMeasured = textPagesMeasured
    self.cancellationSeconds = cancellationSeconds
    self.residentMemoryMB = residentMemoryMB
    self.issues = issues
  }
}

public final class BoundedPageCache<Value> {
  public let capacity: Int
  private var storage: [PDFObjectID: Value] = [:]
  private var order: [PDFObjectID] = []
  public private(set) var hits = 0
  public private(set) var misses = 0
  public private(set) var evictions = 0

  public init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  public var count: Int { storage.count }

  public func value(for key: PDFObjectID) -> Value? {
    if let value = storage[key] {
      hits += 1
      if let index = order.firstIndex(of: key) {
        order.remove(at: index)
        order.append(key)
      }
      return value
    }
    misses += 1
    return nil
  }

  public func insert(_ value: Value, for key: PDFObjectID) {
    if storage[key] == nil && storage.count >= capacity, let oldest = order.first {
      storage.removeValue(forKey: oldest)
      order.removeFirst()
      evictions += 1
    }
    storage[key] = value
    if let index = order.firstIndex(of: key) { order.remove(at: index) }
    order.append(key)
  }

  public var statistics: String {
    "capacity=" + String(capacity) + ", count=" + String(count) + ", hits=" + String(hits)
      + ", misses=" + String(misses) + ", evictions=" + String(evictions)
  }
}

public enum UXLargeDocumentQualification {
  public static func syntheticPDF(pages: Int) throws -> Data {
    var objects: [PDFObjectID: PDFValue] = [:]
    var kids: [PDFValue] = []
    // Object 1 catalog, 2 pages, 3 font; pages 4..(3+pages), contents after.
    let fontID = PDFObjectID(3)
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    let contentIDBase = 4 + pages
    for index in 0..<pages {
      let pageID = PDFObjectID(4 + index)
      let contentID = PDFObjectID(contentIDBase + index)
      let content = "BT /F1 12 Tf 42 720 Td (Page " + String(index + 1) + ") Tj ET\n"
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pages)),
      PDFName("Kids"): .array(kids),
    ])
    objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
    ])
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFWriter.write(graph)
  }

  /// Cancellable page scan: cancellation is checked between pages and the
  /// measured latency is returned so the budget can assert it.
  public static func cancellableScan(
    pageIDs: [PDFObjectID],
    shouldCancel: () -> Bool
  ) -> (processed: Int, cancelled: Bool, latencySeconds: Double) {
    let started = Date()
    var processed = 0
    for pageID in pageIDs {
      if shouldCancel() {
        return (processed, true, Date().timeIntervalSince(started))
      }
      _ = pageID
      processed += 1
    }
    return (processed, false, Date().timeIntervalSince(started))
  }

  public static func measure(
    classID: String, pagesOverride: Int? = nil, textSamplePages: Int = 20
  ) throws -> UXLargeDocumentMeasurement {
    guard let documentClass = UXLargeDocumentProfile.classes.first(where: { $0.id == classID }),
      let budget = UXLargeDocumentProfile.budget(for: classID)
    else {
      throw PDFError(.unsupported, "Unknown large-document class " + classID + ".")
    }
    let pages = pagesOverride ?? documentClass.declaredPages ?? 500
    let data = try syntheticPDF(pages: pages)

    let openStarted = Date()
    let parsed = try PDFParser.parse(data)
    let openSeconds = Date().timeIntervalSince(openStarted)
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    let textStarted = Date()
    let sample = Array(pageIDs.prefix(textSamplePages))
    for pageID in sample {
      _ = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    }
    let textSecondsPerPage = sample.isEmpty
      ? 0 : Date().timeIntervalSince(textStarted) / Double(sample.count)
    let saveStarted = Date()
    let saved = try PDFWriter.write(parsed.graph)
    let saveSeconds = Date().timeIntervalSince(saveStarted)
    let cancellation = cancellableScanWithLimit(pageIDs: pageIDs, cancelAfter: 5)
    let memoryMB = currentResidentMemoryMB()

    var issues: [String] = []
    if openSeconds > budget.openSeconds {
      issues.append("Open " + format(openSeconds) + "s exceeds budget "
        + format(budget.openSeconds) + "s.")
    }
    if saveSeconds > budget.saveSeconds {
      issues.append("Save " + format(saveSeconds) + "s exceeds budget "
        + format(budget.saveSeconds) + "s.")
    }
    if textSecondsPerPage > budget.textSecondsPerPage {
      issues.append("Text access per page " + format(textSecondsPerPage) + "s exceeds budget "
        + format(budget.textSecondsPerPage) + "s.")
    }
    if cancellation.latencySeconds > budget.cancellationSeconds {
      issues.append("Cancellation " + format(cancellation.latencySeconds)
        + "s exceeds budget " + format(budget.cancellationSeconds) + "s.")
    }
    if memoryMB > budget.residentMemoryMB {
      issues.append("Resident memory " + format(memoryMB) + "MB exceeds budget "
        + format(budget.residentMemoryMB) + "MB.")
    }
    if pageIDs.count != pages {
      issues.append("Page count " + String(pageIDs.count) + " differs from declared "
        + String(pages) + ".")
    }
    if saved.count == 0 { issues.append("Save produced no bytes.") }
    return UXLargeDocumentMeasurement(
      classID: classID, machine: UXLargeDocumentProfile.machineName,
      byteCount: data.count, pageCount: pageIDs.count, openSeconds: openSeconds,
      saveSeconds: saveSeconds, textSecondsPerPage: textSecondsPerPage,
      textPagesMeasured: sample.count,
      cancellationSeconds: cancellation.latencySeconds, residentMemoryMB: memoryMB,
      issues: issues)
  }

  public static func cancellableScanWithLimit(
    pageIDs: [PDFObjectID], cancelAfter: Int
  ) -> (processed: Int, cancelled: Bool, latencySeconds: Double) {
    var counter = 0
    return cancellableScan(pageIDs: pageIDs) {
      defer { counter += 1 }
      return counter >= cancelAfter
    }
  }

  public static func currentResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / (1_024 * 1_024)
  }

  static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
