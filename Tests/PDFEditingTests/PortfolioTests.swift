import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// SPC-01: portfolio collection reading/authoring, folder grouping, and exact
/// component-byte preservation across compatible edits.
@Suite("PDF portfolio")
struct PortfolioTests {
  private func component(
    _ fileName: String, folder: [String] = [], bytes: Data, description: String? = nil,
    mime: String? = nil
  ) throws -> PortfolioComponent {
    try PortfolioAuthoring.makeComponent(
      fileName: fileName, folderPath: folder, data: bytes, description: description,
      mimeType: mime)
  }

  private func bytes(_ seed: UInt8, count: Int) -> Data {
    Data((0..<count).map { UInt8((Int(seed) &+ $0) & 0xFF) })
  }

  private func parse(_ data: Data) throws -> PDFGraph {
    try PDFParser.parse(data).graph
  }

  @Test func createdPortfolioRoundTripsStructureAndExactBytes() throws {
    let invoice = try component("invoice.pdf", folder: ["Invoices"], bytes: bytes(1, count: 300),
      description: "January invoice", mime: "application/pdf")
    let photo = try component("photo.png", folder: ["Media", "2026"], bytes: bytes(7, count: 512),
      description: "Reference photo", mime: "image/png")
    let notes = try component("notes.txt", bytes: bytes(9, count: 64), mime: "text/plain")
    let columns = [
      PortfolioColumn(title: "File name", subtype: "F", order: 0),
      PortfolioColumn(title: "Description", subtype: "D", order: 1),
      PortfolioColumn(title: "Size", subtype: "S", order: 2),
    ]
    let data = try PortfolioAuthoring.create(
      components: [invoice, photo, notes], title: "Quarterly package", columns: columns)
    let graph = try parse(data)
    let inventory = try PortfolioReader.read(in: graph)
    #expect(inventory.hasCollection)
    #expect(inventory.title == "Quarterly package")
    #expect(inventory.columns.map(\.title) == columns.map(\.title))
    #expect(inventory.columns.map(\.subtype) == columns.map(\.subtype))
    #expect(inventory.components.count == 3)
    let byName = Dictionary(uniqueKeysWithValues: inventory.components.map { ($0.fullName, $0) })
    #expect(byName["Invoices/invoice.pdf"]?.data == invoice.data)
    #expect(byName["Media/2026/photo.png"]?.data == photo.data)
    #expect(byName["notes.txt"]?.data == notes.data)
    #expect(byName["Invoices/invoice.pdf"]?.folderPath == ["Invoices"])
    #expect(byName["Media/2026/photo.png"]?.folderPath == ["Media", "2026"])
    #expect(byName["Invoices/invoice.pdf"]?.fileName == "invoice.pdf")
    #expect(byName["Invoices/invoice.pdf"]?.mimeType == "application/pdf")
    #expect(byName["Invoices/invoice.pdf"]?.description == "January invoice")
    #expect(inventory.folderPaths == [["Invoices"], ["Media", "2026"]])
    #expect(inventory.totalByteCount == 300 + 512 + 64)
    let report = inventory.report()
    #expect(report.contains("Invoices / invoice.pdf") || report.contains("Invoices"))
    #expect(report.contains("Declared portfolio profile"))
    #expect(report.contains("Component bytes are never re-encoded"))
  }

  @Test func compatibleEditsPreserveOtherComponentBytesAndIdentity() throws {
    let alpha = try component("alpha.txt", bytes: bytes(3, count: 40))
    let beta = try component("beta.txt", folder: ["Docs"], bytes: bytes(5, count: 80))
    let created = try PortfolioAuthoring.create(components: [alpha, beta], title: "Edits")
    var graph = try parse(created)

    let gammaBytes = bytes(11, count: 120)
    let gamma = try component("gamma.bin", folder: ["Docs"], bytes: gammaBytes, mime: "application/octet-stream")
    graph = try PortfolioAuthoring.add(gamma, to: graph)
    let replacedBeta = bytes(13, count: 90)
    graph = try PortfolioAuthoring.replaceBytes(named: "Docs/beta.txt", with: replacedBeta, in: graph)

    let afterAdd = try PortfolioReader.read(in: graph)
    #expect(afterAdd.components.count == 3)
    let byName = Dictionary(uniqueKeysWithValues: afterAdd.components.map { ($0.fullName, $0) })
    #expect(byName["alpha.txt"]?.data == alpha.data, "unrelated bytes are unchanged")
    #expect(byName["Docs/gamma.bin"]?.data == gammaBytes)
    #expect(byName["Docs/beta.txt"]?.data == replacedBeta)
    #expect(byName["Docs/beta.txt"]?.fileName == "beta.txt", "identity is preserved")

    graph = try PortfolioAuthoring.removeComponent(named: "alpha.txt", from: graph)
    let afterRemove = try PortfolioReader.read(in: graph)
    #expect(afterRemove.components.count == 2)
    #expect(!afterRemove.components.contains { $0.fullName == "alpha.txt" })
    #expect(
      Dictionary(uniqueKeysWithValues: afterRemove.components.map { ($0.fullName, $0) })[
        "Docs/beta.txt"]?.data == replacedBeta)
    #expect(
      Dictionary(uniqueKeysWithValues: afterRemove.components.map { ($0.fullName, $0) })[
        "Docs/gamma.bin"]?.data == gammaBytes)

    // The edited graph is still a valid PDF package with the collection intact.
    let rewritten = try PDFWriter.write(graph)
    let reparsed = try PortfolioReader.read(in: try parse(rewritten))
    #expect(reparsed.hasCollection)
    #expect(reparsed.components.count == 2)
  }

  @Test func plainAttachmentDocumentIsBrowsedWithoutACollection() throws {
    let attachments = AddAttachmentCommand(
      name: "data.csv", fileName: "data.csv", mimeType: "text/csv", description: "Values",
      data: Data("a,b\n1,2\n".utf8))
    var graph = PDFFixtures.graph()
    try attachments.validate(in: graph)
    graph = try attachments.apply(to: graph)
    let inventory = try PortfolioReader.read(in: graph)
    #expect(!inventory.hasCollection)
    #expect(inventory.components.count == 1)
    #expect(inventory.components[0].data == Data("a,b\n1,2\n".utf8))
    #expect(inventory.columns == PortfolioReader.defaultColumns)
  }

  @Test func emptyPortfolioIsValid() throws {
    let data = try PortfolioAuthoring.create(components: [], title: "Empty package")
    let graph = try parse(data)
    let inventory = try PortfolioReader.read(in: graph)
    #expect(inventory.hasCollection)
    #expect(inventory.title == "Empty package")
    #expect(inventory.components.isEmpty)
    // One blank page keeps the file an ordinary readable PDF.
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    #expect(pageIDs.count == 1)
  }

  @Test func unsafeOrDuplicateComponentsAreRefused() throws {
    #expect(throws: PDFError.self) {
      _ = try PortfolioAuthoring.makeComponent(fileName: "../escape.txt", data: Data([1]))
    }
    #expect(throws: PDFError.self) {
      _ = try PortfolioAuthoring.makeComponent(fileName: "sub/dir.txt", data: Data([1]))
    }
    #expect(throws: PDFError.self) {
      _ = try PortfolioAuthoring.makeComponent(
        fileName: "file.txt", folderPath: [".."], data: Data([1]))
    }
    let duplicate = try component("same.txt", bytes: Data([1]))
    #expect(throws: PDFError.self) {
      _ = try PortfolioAuthoring.create(components: [duplicate, duplicate])
    }
    let data = try PortfolioAuthoring.create(components: [duplicate])
    var graph = try parse(data)
    #expect(throws: PDFError.self) {
      _ = try PortfolioAuthoring.add(duplicate, to: graph)
    }
    graph = try PortfolioAuthoring.add(
      try component("other.txt", bytes: Data([2])), to: graph)
    #expect(throws: PDFError.self) {
      _ = try PortfolioAuthoring.replaceBytes(named: "missing.txt", with: Data([3]), in: graph)
    }
  }

  @Test func folderConventionIsDeclaredAndPreserved() throws {
    let deep = try component(
      "report.txt", folder: ["Clients", "Acme", "2026"], bytes: Data("report".utf8))
    let data = try PortfolioAuthoring.create(components: [deep])
    let inventory = try PortfolioReader.read(in: try parse(data))
    #expect(inventory.components.first?.folderPath == ["Clients", "Acme", "2026"])
    #expect(inventory.components.first?.name == "Clients/Acme/2026/report.txt")
    #expect(inventory.folderPaths == [["Clients", "Acme", "2026"]])
    #expect(
      PortfolioBoundary.declaredProfile.lowercased().contains("acrobat"))
  }
}
