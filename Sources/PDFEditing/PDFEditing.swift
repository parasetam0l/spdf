import Foundation
import PDFCore

/// A semantic edit command with a stable target and explicit preconditions.
/// Commands are value types: they never mutate canonical graph state and are
/// validated against the staged graph before they are applied.
public protocol PDFEditCommand: Sendable {
  /// Human-readable command name used for undo labels and diagnostics.
  var name: String { get }
  /// P17-012/P17-022: pages this command is known to change, in page-identity
  /// terms, given the graph it will run against. An empty array means "not
  /// known here" and callers treat it as "all pages" for invalidation.
  /// Page-scoped commands report their own page; edits to shared resources
  /// (for example a shared image object) report every page that references
  /// them, so global effects are intentional and visible.
  func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID]
  /// Check preconditions against the current staged graph.
  func validate(in graph: PDFGraph) throws
  /// Produce the next graph from a staged copy. Only called after `validate`.
  func apply(to graph: PDFGraph) throws -> PDFGraph
}

extension PDFEditCommand {
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }
}

/// One or more commands committed atomically. All preconditions are checked
/// against the staged graph, mutations happen on copies, and the final graph
/// must pass full reference/page validation before it can replace canonical
/// state. Any failure leaves the input graph untouched.
public struct PDFTransaction: Sendable {
  public let commands: [any PDFEditCommand]

  public init(_ commands: [any PDFEditCommand]) {
    self.commands = commands
  }

  public var isEmpty: Bool { commands.isEmpty }
  public var name: String { commands.first?.name ?? "Edit" }
}

public enum PDFEditingEngine {
  /// Commit a transaction against `graph`, returning a validated successor
  /// graph. The input graph is never modified.
  public static func commit(
    _ transaction: PDFTransaction, to graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    guard !transaction.isEmpty else {
      throw PDFError(.malformed, "A transaction must contain at least one command")
    }
    var staged = graph
    for command in transaction.commands {
      try Task.checkCancellation()
      try command.validate(in: staged)
      staged = try command.apply(to: staged)
    }
    try staged.validate(limits: limits)
    return staged
  }
}
