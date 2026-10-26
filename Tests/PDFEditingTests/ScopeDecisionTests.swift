import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("PostScript/EPS and multimedia scope decisions")
struct ScopeDecisionTests {
  // MARK: SPC-04

  @Test func epsDetectionAndExplicitReplacementDecision() {
    let data = Data("""
      %!PS-Adobe-3.0 EPSF-3.0
      %%BoundingBox: 0 0 612 792
      %%HiResBoundingBox: 0.0 0.0 612.0 792.0
      %%Pages: 1
      %%BeginPreview: 4 4 1 4
      %%%%
      %%EndPreview
      %%EndComments
      %%EOF
      """.utf8)
    let detection = PostScriptScope.detect(data)
    #expect(detection.format == .eps)
    #expect(detection.boundingBox == [0, 0, 612, 792])
    #expect(detection.pageCountHint == 1)
    #expect(detection.isDSCConforming)
    #expect(detection.hasEPSPreview)
    let decision = PostScriptScope.decision(for: detection)
    #expect(decision.outcome == .explicitReplacementException)
    #expect(decision.allowed == false)
    #expect(decision.excludedEngines.contains("Ghostscript"))
    #expect(decision.report().contains("Explicitly excluded engines"))
    #expect(PostScriptScope.profile.contains("replacement exception"))
    #expect(PostScriptScope.profile.contains("no PostScript interpreter"))
    #expect(PostScriptScope.report(for: data).contains("BoundingBox"))
  }

  @Test func postScriptAndNonPostScriptClassification() {
    let ps = Data("%!PS-Adobe-3.0\n%%Pages: 2\nshowpage\n%%EOF\n".utf8)
    let psDetection = PostScriptScope.detect(ps)
    #expect(psDetection.format == .postScript)
    #expect(psDetection.pageCountHint == 2)
    #expect(PostScriptScope.decision(for: psDetection).allowed == false)

    let pdf = Data("%PDF-1.7\n%...\n".utf8)
    #expect(PostScriptScope.detect(pdf).format == .pdf)
    #expect(PostScriptScope.decision(for: PostScriptScope.detect(pdf)).outcome == .notPostScript)

    let unknown = Data("hello world".utf8)
    let unknownDetection = PostScriptScope.detect(unknown)
    #expect(unknownDetection.format == .unknown)
    #expect(unknownDetection.warnings.contains { $0.contains("recognised") })
    #expect(PostScriptScope.decision(for: unknownDetection).allowed == false)
  }

  @Test func epsWithoutBoundingBoxIsFlaggedUnsafe() {
    let data = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%EndComments\n%%EOF\n".utf8)
    let detection = PostScriptScope.detect(data)
    #expect(detection.format == .eps)
    #expect(detection.boundingBox == nil)
    #expect(detection.warnings.contains { $0.contains("no readable") })
    #expect(PostScriptScope.decision(for: detection).outcome == .explicitReplacementException)
  }

  // MARK: SPC-05

  private func mediaGraph() -> PDFGraph {
    let pageID = PDFObjectID(4)
    let contentID = PDFObjectID(5)
    let annots: [PDFValue] = [
      .reference(PDFObjectID(10)),  // Movie
      .reference(PDFObjectID(11)),  // Sound
      .reference(PDFObjectID(12)),  // Screen with action
      .reference(PDFObjectID(13)),  // RichMedia
      .reference(PDFObjectID(14)),  // 3D
    ]
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("Names"): .dictionary([
          PDFName("EmbeddedFiles"): .dictionary([
            PDFName("Names"): .array([
              .string(Data("a.txt".utf8)),
              .reference(PDFObjectID(20)),
              .string(Data("b.txt".utf8)),
              .reference(PDFObjectID(21)),
            ])
          ])
        ]),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(pageID)]),
      ]),
      contentID: .stream(PDFStream(bytes: Data("".utf8))),
      pageID: .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        PDFName("Contents"): .reference(contentID),
        PDFName("Annots"): .array(annots),
      ]),
      PDFObjectID(10): .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Movie")),
        PDFName("A"): .dictionary([PDFName("S"): .name(PDFName("Movie"))]),
      ]),
      PDFObjectID(11): .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Sound")),
      ]),
      PDFObjectID(12): .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Screen")),
        PDFName("A"): .dictionary([PDFName("S"): .name(PDFName("Rendition"))]),
      ]),
      PDFObjectID(13): .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("RichMedia")),
      ]),
      PDFObjectID(14): .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("3D")),
        PDFName("3DD"): .reference(PDFObjectID(30)),
      ]),
      PDFObjectID(30): .stream(
        PDFStream(
          dictionary: [PDFName("Type"): .name(PDFName("3D"))],
          bytes: Data("% fake 3D stream".utf8))),
      PDFObjectID(20): .dictionary([
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data("a.txt".utf8)),
      ]),
      PDFObjectID(21): .dictionary([
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data("b.txt".utf8)),
      ]),
    ]
    return PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func multimediaInventoryDetectsPreservesAndDisclosesExclusions() {
    let graph = mediaGraph()
    let before = graph
    let report = MultimediaScope.inventory(graph, pageIDs: [PDFObjectID(4)])
    #expect(report.pageCount == 1)
    #expect(report.uses.count == 5)
    #expect(report.embeddedFileCount == 2)
    #expect(report.has3D)
    #expect(report.hasRichMedia)
    #expect(report.hasLegacyMovie)
    #expect(report.hasSound)
    #expect(report.uses.allSatisfy { $0.preserved })
    #expect(report.uses.first { $0.kind == .threeD }?.pageIndex == 0)
    #expect(report.uses.first { $0.kind == .movie }?.hasInteractiveAction == true)
    #expect(report.uses.first { $0.kind == .sound }?.hasInteractiveAction == true)
    #expect(MultimediaScope.policy.playback == .excluded)
    #expect(MultimediaScope.policy.annotationEditing == .excluded)
    #expect(MultimediaScope.policy.modelInteraction == .excluded)
    #expect(MultimediaScope.policy.preservation == .preserved)
    #expect(report.report().contains("not playback parity"))
    #expect(report.report().contains("explicit disclosed exclusions"))
    #expect(graph == before)
  }

  @Test func emptyMediaInventoryAndMalformedAnnotations() {
    let pageID = PDFObjectID(4)
    let empty = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(pageID)]),
        ]),
        pageID: .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let emptyReport = MultimediaScope.inventory(empty, pageIDs: [pageID])
    #expect(emptyReport.uses.isEmpty)
    #expect(emptyReport.embeddedFileCount == 0)
    #expect(emptyReport.report().contains("0 media object"))

    let malformed = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(pageID)]),
        ]),
        pageID: .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
          PDFName("Annots"): .array([.reference(PDFObjectID(99))]),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let malformedReport = MultimediaScope.inventory(malformed, pageIDs: [pageID])
    #expect(malformedReport.uses.isEmpty)
    #expect(malformedReport.warnings.contains { $0.contains("malformed") })
  }
}
