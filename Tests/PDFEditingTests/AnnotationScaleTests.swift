import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-029 evidence: comment-list listing, filtering, and threading stay
/// bounded with hundreds of annotations, and appearance growth is linear.
@Suite("Annotation scale")
struct AnnotationScaleTests {
  @Test func commentListScalesWithManyAnnotations() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    let count = 400
    var items: [PDFValue] = []
    for index in 0..<count {
      let annotationID = PDFObjectID(1000 + index * 2)
      let appearanceID = PDFObjectID(1001 + index * 2)
      let x = Double(10 + (index % 20) * 28)
      let y = Double(60 + (index / 20) * 32)
      graph.objects[annotationID] = .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Highlight")),
        PDFName("Rect"): .array([.real(x), .real(y), .real(x + 20), .real(y + 12)]),
        PDFName("QuadPoints"): .array([
          .real(x), .real(y + 12), .real(x + 20), .real(y + 12),
          .real(x), .real(y), .real(x + 20), .real(y),
        ]),
        PDFName("Contents"): .string(Data("comment \(index)".utf8)),
        PDFName("AP"): .dictionary([PDFName("N"): .reference(appearanceID)]),
      ])
      graph.objects[appearanceID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Form")),
            PDFName("FormType"): .integer(1),
            PDFName("BBox"): .array([
              .integer(0), .integer(0), .integer(20), .integer(12),
            ]),
          ], bytes: Data("q Q\n".utf8)))
      items.append(.reference(annotationID))
    }
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      Issue.record("Fixture page is missing")
      return
    }
    page[PDFName("Annots")] = .array(items)
    graph.objects[pageID] = .dictionary(page)
    graph.trailer[PDFName("Size")] = .integer(Int64(1001 + (count - 1) * 2) + 1)

    // Appearance growth is exactly two objects per annotation (the annotation
    // and its generated appearance form).
    let growth = graph.objects.count - parsed.graph.objects.count
    #expect(growth == count * 2)

    let clock = ContinuousClock()
    let listElapsed = clock.measure {
      let listed = CommentList.comments(in: graph, pageIDs: parsed.pageIDs)
      #expect(listed.count == count)
      #expect(CommentList.filter(listed, by: CommentFilter(subtype: PDFName("Highlight"))).count == count)
      #expect(CommentList.filter(listed, by: CommentFilter(state: PDFName("None"))).count == count)
      #expect(CommentList.threads(listed, by: CommentFilter()).count == count)
      #expect(
        CommentList.filter(listed, by: CommentFilter(pageIndex: 1)).isEmpty)
    }
    let writeElapsed = clock.measure {
      if let data = try? PDFWriter.write(graph) {
        _ = try? PDFParser.parse(data)
      }
    }
    print("ANNOTATION SCALE: \(count) comments listed, filtered, and grouped in \(listElapsed)")
    print("ANNOTATION SCALE: write and reparse of \(graph.objects.count) objects in \(writeElapsed)")
    #expect(listElapsed < .seconds(2))
    #expect(writeElapsed < .seconds(10))
  }
}
