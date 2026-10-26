import Foundation
import PDFCore
import Testing
@testable import MacServices

/// UX-03/UX-04 evidence writer (opt-in):
///   SPDF_UX_BUDGET_ARTIFACT_DIR=<dir> [SPDF_UX_LARGE_EXTENDED=1] swift test --filter UXBudgetArtifactTests
/// Writes the tool catalog, preset/contextual/recent models, the large-document
/// budget profile/decision and measured 500-page (and optionally 2,000-page)
/// classes. Without the env variable this test does nothing.
@Suite("UX discovery and budget artifacts")
struct UXBudgetArtifactTests {
  @Test func writesArtifactsWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directoryPath = environment["SPDF_UX_BUDGET_ARTIFACT_DIR"], !directoryPath.isEmpty
    else { return }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var toolRows: [[String: Any]] = []
    for entry in UXToolCatalog.entries {
      toolRows.append([
        "id": entry.id,
        "title": entry.title,
        "category": entry.category.rawValue,
        "summary": entry.summary,
        "limitations": entry.limitations,
        "keywords": entry.keywords,
        "contexts": entry.contexts.map(\.rawValue),
        "shortcut": entry.shortcut ?? "",
        "available": entry.availability.isAvailable,
        "unavailableReason": entry.availability.reason ?? "",
        "presetOptions": entry.presetOptions,
      ])
    }
    var controlRows: [[String: Any]] = []
    for control in UXContextualControls.controls {
      controlRows.append([
        "id": control.id, "title": control.title, "hint": control.hint,
        "context": control.context.rawValue, "toolID": control.toolID ?? "",
      ])
    }
    let searchChecks: [String: [String]] = [
      "redact": UXToolCatalog.search("redact").map(\.entry.id),
      "javascript": UXToolCatalog.search("JavaScript").map(\.entry.id),
    ]
    let catalog: [String: Any] = [
      "identifier": UXToolCatalog.identifier,
      "issues": UXToolCatalog.validate(),
      "tools": toolRows,
      "searchChecks": searchChecks,
      "contextualControls": controlRows,
    ]
    try writeJSON(catalog, to: directory.appendingPathComponent("ux-tool-catalog.json"))

    let decision = UXLargeDocumentProfile.decision
    var classRows: [[String: Any]] = []
    for documentClass in UXLargeDocumentProfile.classes {
      let budget = UXLargeDocumentProfile.budget(for: documentClass.id)
      var row: [String: Any] = [
        "id": documentClass.id,
        "title": documentClass.title,
        "openSeconds": budget?.openSeconds ?? 0,
        "saveSeconds": budget?.saveSeconds ?? 0,
        "textSecondsPerPage": budget?.textSecondsPerPage ?? 0,
        "cancellationSeconds": budget?.cancellationSeconds ?? 0,
        "residentMemoryMB": budget?.residentMemoryMB ?? 0,
      ]
      if let declaredPages = documentClass.declaredPages { row["declaredPages"] = declaredPages }
      if let declaredBytes = documentClass.declaredBytes { row["declaredBytes"] = declaredBytes }
      classRows.append(row)
    }
    let budgetProfile: [String: Any] = [
      "identifier": UXLargeDocumentProfile.identifier,
      "machine": UXLargeDocumentProfile.machineName,
      "issues": UXLargeDocumentProfile.validate(),
      "classes": classRows,
      "decision": [
        "currentApproach": decision.currentApproach,
        "boundedCaches": decision.boundedCaches,
        "cancellableWork": decision.cancellableWork,
        "notImplemented": decision.notImplemented,
      ],
    ]
    try writeJSON(budgetProfile, to: directory.appendingPathComponent("ux-budget-profile.json"))

    let measurement500 = try UXLargeDocumentQualification.measure(classID: "500-page")
    try writeJSON(measurementJSON(measurement500),
      to: directory.appendingPathComponent("ux-large-500.json"))

    if environment["SPDF_UX_LARGE_EXTENDED"] == "1" {
      let measurement2000 = try UXLargeDocumentQualification.measure(classID: "2000-page")
      try writeJSON(measurementJSON(measurement2000),
        to: directory.appendingPathComponent("ux-large-2000.json"))
    }

    // Reference cache evidence for bounded page access.
    let cache = BoundedPageCache<String>(capacity: 8)
    for index in 0..<12 { cache.insert("page-\(index)", for: PDFObjectID(index + 1)) }
    try writeJSON([
      "capacity": cache.capacity, "count": cache.count, "evictions": cache.evictions,
      "statistics": cache.statistics,
    ], to: directory.appendingPathComponent("ux-bounded-cache.json"))

    #expect(UXToolCatalog.validate().isEmpty)
    #expect(!UXLargeDocumentProfile.machineName.isEmpty)
  }

  private func measurementJSON(_ measurement: UXLargeDocumentMeasurement) -> [String: Any] {
    [
      "classID": measurement.classID,
      "machine": measurement.machine,
      "byteCount": measurement.byteCount,
      "pageCount": measurement.pageCount,
      "openSeconds": measurement.openSeconds,
      "saveSeconds": measurement.saveSeconds,
      "textSecondsPerPage": measurement.textSecondsPerPage,
      "textPagesMeasured": measurement.textPagesMeasured,
      "cancellationSeconds": measurement.cancellationSeconds,
      "residentMemoryMB": measurement.residentMemoryMB,
      "passed": measurement.passed,
      "issues": measurement.issues,
    ]
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }
}
