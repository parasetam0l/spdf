import Foundation
import PDFCore
import PDFEditing

/// OCR-06: connects mixed-page classification to recognition results. The
/// service decides which pages should be recognized, keeps already-selectable
/// digital text untouched, replaces only the chosen generated layer, and turns
/// the recognized lines into bounded layer commands that preserve pixels,
/// placements and coordinates.
public enum OCRMixedPageService {
  public struct PreparedPlan: Sendable, Equatable {
    public let profiles: [OCRMixedPageProfile]
    public let options: OCRMixedPageOptions
    public let summaryLines: [String]

    public var ocrPageIndexes: [Int] {
      profiles.filter { $0.action == .addBoundedLayer }.map(\.pageIndex)
    }

    public var replacingPageIndexes: [Int] {
      profiles.filter { $0.action == .replaceGeneratedLayer }.map(\.pageIndex)
    }

    public var skippedProfiles: [OCRMixedPageProfile] {
      profiles.filter { $0.action == .skip }
    }

    public var hasWork: Bool { !ocrPageIndexes.isEmpty || !replacingPageIndexes.isEmpty }
  }

  public struct PreparedCommands: Sendable, Equatable {
    public let commands: [AddBoundedSearchableTextLayerCommand]
    public let acceptedLineCount: Int
    public let droppedLineCount: Int
    public let skippedPages: [String]
    public let summaryLines: [String]
  }

  /// Classify pages and return the recognition page indexes plus replacement
  /// information. Nothing is recognized or changed here.
  public static func plan(
    graph: PDFGraph, pageIDs: [PDFObjectID],
    selectedPageIndexes: [Int]? = nil,
    options: OCRMixedPageOptions = OCRMixedPageOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> PreparedPlan {
    let pagePlan = try OCRMixedPagePlanner.plan(
      in: graph, pageIDs: pageIDs, selectedPageIndexes: selectedPageIndexes,
      options: options, limits: limits)
    return PreparedPlan(
      profiles: pagePlan.profiles, options: options,
      summaryLines: pagePlan.summaryLines)
  }

  /// Convert recognized page results into bounded-layer commands. Lines outside
  /// the scan bounds, overlapping existing selectable digital text, or with
  /// invalid geometry are dropped; pages with no remaining evidence are
  /// reported, not silently committed.
  public static func commands(
    results: [OCRPageResult], graph: PDFGraph, pageIDs: [PDFObjectID],
    plan: PreparedPlan, limits: PDFLimits = PDFLimits()
  ) -> PreparedCommands {
    let profileByIndex = Dictionary(
      uniqueKeysWithValues: plan.profiles.map { ($0.pageIndex, $0) })
    var commands: [AddBoundedSearchableTextLayerCommand] = []
    var accepted = 0
    var dropped = 0
    var skipped: [String] = []
    for result in results {
      guard let profile = profileByIndex[result.pageIndex],
        profile.action != .skip,
        pageIDs.indices.contains(result.pageIndex)
      else { continue }
      let lines = result.lines.map {
        SearchableTextLine(text: $0.text, rect: $0.rect, confidence: $0.confidence)
      }
      let bounded = OCRMixedPagePlanner.boundedLines(
        lines, for: profile, options: plan.options)
      dropped += lines.count - bounded.count
      guard !bounded.isEmpty else {
        skipped.append(
          "P\(result.pageIndex + 1): no recognized line fell inside the bounded scan regions")
        continue
      }
      accepted += bounded.count
      let command = AddBoundedSearchableTextLayerCommand(
        pageID: profile.pageID,
        lines: bounded.map(\.line),
        boundedRegions: profile.boundedRegions.map(\.rect),
        replaceExistingLayer: profile.action == .replaceGeneratedLayer)
      do {
        try command.validate(in: graph)
        commands.append(command)
      } catch {
        skipped.append(
          "P\(result.pageIndex + 1): " + error.localizedDescription)
      }
    }
    var summaryLines: [String] = []
    summaryLines.append(
      "Bounded OCR commands: \(commands.count) page(s); \(accepted) line(s) accepted; "
        + "\(dropped) line(s) outside bounds/digital text dropped; \(skipped.count) page(s) skipped.")
    summaryLines.append(contentsOf: skipped)
    return PreparedCommands(
      commands: commands, acceptedLineCount: accepted, droppedLineCount: dropped,
      skippedPages: skipped, summaryLines: summaryLines)
  }
}
