import Foundation
import PDFCore
import PDFEditing
import Testing
@testable import MacServices

/// UX-03/UX-04 evidence: searchable tool catalog with visible limitations,
/// validated presets, bounded recent files, contextual controls, and bounded
/// large-document budgets with measured 500/2,000-page classes.
@Suite("UX discovery and large-document budgets")
struct UXDiscoveryBudgetTests {
  @Test func catalogIsCompleteAndSearchableByTitleKeywordAndLimitation() throws {
    #expect(UXToolCatalog.validate().isEmpty)
    #expect(UXToolCatalog.entries.count >= 8)
    #expect(UXToolCatalog.entries.allSatisfy { !$0.limitations.isEmpty })
    #expect(UXToolCatalog.availableTools().count >= 6)

    let redact = UXToolCatalog.search("redact")
    #expect(redact.first?.entry.id == "security.redact")
    #expect(redact.first?.entry.limitations.isEmpty == false)

    // A limitation users remember is searchable, not only the tool name.
    let script = UXToolCatalog.search("JavaScript")
    #expect(script.contains { $0.entry.id == "forms.fill" })

    let shortcut = UXToolCatalog.search("Command+Shift+O")
    #expect(shortcut.contains { $0.entry.id == "scan.ocr" })

    // An unavailable tool stays discoverable and explains why.
    let signing = UXToolCatalog.search("signature")
    let signingEntry = try #require(signing.first { $0.entry.id == "signature.sign" }?.entry)
    #expect(!signingEntry.availability.isAvailable)
    #expect(signingEntry.availability.reason?.isEmpty == false)

    #expect(UXToolCatalog.search("text", context: .textSelection).allSatisfy {
      $0.entry.contexts.contains(.textSelection)
    })
    #expect(UXToolCatalog.entry(id: "missing.tool") == nil)
  }

  @Test func contextualControlsMapToTheDeclaredTools() throws {
    for context in UXToolContext.allCases {
      let controls = UXContextualControls.controls(for: context)
      #expect(!controls.isEmpty, "No contextual controls for \(context.rawValue)")
      for control in controls {
        if let toolID = control.toolID {
          #expect(UXToolCatalog.entry(id: toolID) != nil, "Unknown tool \(toolID)")
        }
        #expect(!control.hint.isEmpty)
      }
    }
    #expect(UXContextualControls.controls(for: .formField).first?.toolID == "forms.fill")
  }

  @Test func presetsValidateBeforeUseAndRefuseUnsupportedOptions() throws {
    let suiteName = "spdf.ux.tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UXPresetStore(defaults: defaults)

    let valid = UXPreset(
      name: "Scanned letter", toolID: "scan.ocr", options: ["language": "en-US", "level": "accurate"])
    #expect(valid.validated().isEmpty)
    #expect(store.save(valid).isEmpty)
    let loaded = store.load()
    #expect(loaded == [valid])
    #expect(store.loadIssues.isEmpty)

    let unknownOption = UXPreset(
      name: "Bad option", toolID: "scan.ocr", options: ["profile": "x"])
    let optionIssues = unknownOption.validated()
    #expect(optionIssues.contains { $0.contains("unsupported option") })
    #expect(!store.save(unknownOption).isEmpty)

    let unknownTool = UXPreset(name: "Bad tool", toolID: "sign", options: [:])
    #expect(unknownTool.validated().contains { $0.contains("unknown tool") })

    // A stored preset from a newer schema is reported, not silently used.
    let raw: [[String: Any]] = [[
      "schemaVersion": UXPreset.schemaVersion + 1, "name": "Future", "toolID": "scan.ocr",
      "options": [:],
    ]]
    defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: UXPresetStore.defaultsKey)
    #expect(store.load().isEmpty)
    #expect(store.loadIssues.contains { $0.contains("schema") })
    defaults.set(Data("not json".utf8), forKey: UXPresetStore.defaultsKey)
    #expect(store.load().isEmpty)
    #expect(!store.loadIssues.isEmpty)
  }

  @Test func recentFilesAreBoundedDeduplicatedAndContentFree() throws {
    var recent = UXRecentFiles()
    for index in 0..<20 {
      recent.record(URL(fileURLWithPath: "/tmp/document-\(index).pdf"),
        at: Date(timeIntervalSince1970: Double(index)))
    }
    #expect(recent.entries.count == UXRecentFiles.maximumEntries)
    #expect(recent.entries.first?.displayName == "document-19.pdf")
    #expect(recent.mostRecent(3).count == 3)
    // Re-opening moves the file to the top without duplicating it.
    recent.record(URL(fileURLWithPath: "/tmp/document-10.pdf"),
      at: Date(timeIntervalSince1970: 100))
    #expect(recent.entries.filter { $0.displayName == "document-10.pdf" }.count == 1)
    #expect(recent.entries.first?.displayName == "document-10.pdf")
    recent.remove(path: "/tmp/document-10.pdf")
    #expect(!recent.entries.contains { $0.displayName == "document-10.pdf" })
    // Only file path/name/timestamp are stored.
    #expect(recent.entries.allSatisfy { !$0.path.isEmpty && !$0.displayName.isEmpty })
  }

  @Test func largeDocumentProfileDeclaresClassesBudgetsAndDecision() throws {
    #expect(UXLargeDocumentProfile.validate().isEmpty)
    #expect(UXLargeDocumentProfile.classes.map(\.id) == ["500-page", "2000-page", "large-byte"])
    for documentClass in UXLargeDocumentProfile.classes {
      let budget = try #require(UXLargeDocumentProfile.budget(for: documentClass.id))
      #expect(budget.openSeconds > 0)
      #expect(budget.saveSeconds > 0)
      #expect(budget.cancellationSeconds > 0)
      #expect(budget.residentMemoryMB > 0)
    }
    #expect(!UXLargeDocumentProfile.machineName.isEmpty)
    #expect(!UXLargeDocumentProfile.decision.notImplemented.isEmpty)
    #expect(!UXLargeDocumentProfile.decision.boundedCaches.isEmpty)
    #expect(UXLargeDocumentProfile.budget(for: "unknown") == nil)
  }

  @Test func boundedPageCacheEvictsWithoutUnboundedGrowth() throws {
    let cache = BoundedPageCache<String>(capacity: 2)
    let first = PDFObjectID(1)
    let second = PDFObjectID(2)
    let third = PDFObjectID(3)
    cache.insert("one", for: first)
    cache.insert("two", for: second)
    #expect(cache.value(for: first) == "one")
    cache.insert("three", for: third)
    #expect(cache.count == 2)
    #expect(cache.evictions == 1)
    #expect(cache.value(for: second) == nil)
    #expect(cache.value(for: third) == "three")
    #expect(cache.statistics.contains("capacity=2"))
  }

  @Test func cancellableScanStopsWithinTheDeclaredBudget() throws {
    let pageIDs = (1...500).map { PDFObjectID($0) }
    let result = UXLargeDocumentQualification.cancellableScanWithLimit(
      pageIDs: pageIDs, cancelAfter: 10)
    #expect(result.cancelled)
    #expect(result.processed == 10)
    let budget = try #require(UXLargeDocumentProfile.budget(for: "500-page"))
    #expect(result.latencySeconds <= budget.cancellationSeconds)
    let notCancelled = UXLargeDocumentQualification.cancellableScan(pageIDs: pageIDs) { false }
    #expect(!notCancelled.cancelled)
    #expect(notCancelled.processed == 500)
  }

  @Test func syntheticPDFMatchesDeclaredPageCount() throws {
    let data = try UXLargeDocumentQualification.syntheticPDF(pages: 30)
    let parsed = try PDFParser.parse(data)
    #expect(try PDFPageTree.pageIDs(in: parsed.graph).count == 30)
  }

  @Test func fiveHundredPageClassMeetsMeasuredBudgets() throws {
    let measurement = try UXLargeDocumentQualification.measure(classID: "500-page")
    #expect(measurement.pageCount == 500)
    #expect(!measurement.machine.isEmpty)
    #expect(measurement.passed, "\(measurement.issues.joined(separator: "; "))")
    #expect(measurement.openSeconds > 0)
    #expect(measurement.saveSeconds > 0)
    #expect(measurement.residentMemoryMB > 0)
  }

  @Test func twoThousandPageClassMeetsMeasuredBudgetsWhenExtended() throws {
    guard ProcessInfo.processInfo.environment["SPDF_UX_LARGE_EXTENDED"] == "1" else { return }
    let measurement = try UXLargeDocumentQualification.measure(classID: "2000-page")
    #expect(measurement.pageCount == 2000)
    #expect(measurement.passed, "\(measurement.issues.joined(separator: "; "))")
  }
}
