import Foundation
import MacServices
import PDFCore
import PDFFixtures
import Testing

@Suite("Document export cancellation")
struct DocumentExportCancellationTests {
  @Test func canceledDOCXPreservesAnExistingDestination() async throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("existing.docx")
    let original = Data("Existing user file".utf8)
    try original.write(to: url)
    let job = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await DOCXDocumentExport.export(pageIDs: parsed.pageIDs, in: parsed.graph, to: url)
    }
    switch await job.result {
    case .success: Issue.record("Canceled DOCX export replaced the destination")
    case .failure(let error): #expect(error is CancellationError)
    }
    #expect(try Data(contentsOf: url) == original)
  }

  @Test func cancellationAfterTheFinalPageStillAcknowledgesTheRequest() async throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let job = Task {
      try await PageImageExport.export(
        pages: parsed.pageIDs, in: parsed.graph, to: directory, baseName: "finished",
        progress: { _, _ in withUnsafeCurrentTask { $0?.cancel() } })
    }
    switch await job.result {
    case .success: Issue.record("Final-page cancellation was silently ignored")
    case .failure(let error): #expect(error is CancellationError)
    }
    // A page whose atomic write already finished is retained, not deleted as
    // though it were an incomplete temporary output.
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("finished-0001.png").path))
  }
}
