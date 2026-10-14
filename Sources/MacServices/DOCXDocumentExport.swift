import Foundation
import PDFCore
import PDFEditing

/// Reconstruct a captured graph on the concurrent executor. Atomic output
/// replacement finishes before the caller can acknowledge cancellation.
public enum DOCXDocumentExport {
  public static func export(
    pageIDs: [PDFObjectID], in graph: PDFGraph, to url: URL,
    mode: DOCXExportMode = .editable
  ) async throws -> Int {
    try Task.checkCancellation()
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph, mode: mode)
    try Task.checkCancellation()
    let resolver: DOCXImageResolver = { request in
      try? PDFImageExport.docxResource(for: request, pageIDs: pageIDs, in: graph)
    }
    let data = try DOCXExport.package(reconstruction: reconstruction, imageResolver: resolver)
    try Task.checkCancellation()
    try data.write(to: url, options: .atomic)
    try Task.checkCancellation()
    return reconstruction.blocks.count
  }
}
