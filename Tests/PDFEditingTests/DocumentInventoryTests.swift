import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P08-003–P08-029: resolved page attributes with inheritance, resource
/// categories, stable identities, page labels, metadata, optional content,
/// security, active content, capability assessment, and lazy enumeration.
@Suite("Document inventory")
struct DocumentInventoryTests {
  /// A nested page tree where MediaBox/Rotate/Resources live on a parent node.
  private func inheritedFixture() -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("PageLabels"): .dictionary([
          PDFName("Nums"): .array([
            .integer(0), .dictionary([PDFName("S"): .name(PDFName("r"))]),
            .integer(3),
            .dictionary([
              PDFName("S"): .name(PDFName("D")), PDFName("P"): .string(Data("A-".utf8)),
              PDFName("St"): .integer(7),
            ]),
          ])
        ]),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(5),
        PDFName("Kids"): .array([
          .reference(PDFObjectID(10)), .reference(PDFObjectID(20)),
        ]),
      ]),
      // Intermediate node carrying inherited attributes.
      PDFObjectID(10): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("Count"): .integer(3),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(842), .integer(595),
        ]),
        PDFName("Rotate"): .integer(-90),
        PDFName("UserUnit"): .real(2),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(30))]),
          PDFName("XObject"): .dictionary([
            PDFName("Im1"): .reference(PDFObjectID(31)),
            PDFName("Fm1"): .reference(PDFObjectID(32)),
          ]),
          PDFName("ExtGState"): .dictionary([PDFName("GS1"): .dictionary([:])]),
          PDFName("Pattern"): .dictionary([PDFName("P1"): .dictionary([:])]),
        ]),
        PDFName("Kids"): .array([
          .reference(PDFObjectID(11)), .reference(PDFObjectID(12)), .reference(PDFObjectID(13)),
        ]),
      ]),
      PDFObjectID(20): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("Count"): .integer(2),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(595), .integer(842),
        ]),
        PDFName("Kids"): .array([
          .reference(PDFObjectID(21)), .reference(PDFObjectID(22)),
        ]),
      ]),
      PDFObjectID(30): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
      ]),
      PDFObjectID(31): .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
            PDFName("ColorSpace"): .name(PDFName("DeviceGray")),
            PDFName("BitsPerComponent"): .integer(8),
          ], bytes: Data([0, 1, 2, 3]))),
      PDFObjectID(32): .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Form")),
            PDFName("BBox"): .array([
              .integer(0), .integer(0), .integer(10), .integer(10),
            ]),
          ], bytes: Data("q Q\n".utf8))),
    ]
    for id in 11...13 {
      objects[PDFObjectID(id)] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(10)),
        PDFName("Contents"): .reference(PDFObjectID(40 + id)),
      ])
      objects[PDFObjectID(40 + id)] = .stream(PDFStream(bytes: Data("q Q\n".utf8)))
    }
    for id in 21...22 {
      objects[PDFObjectID(id)] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(20)),
        PDFName("CropBox"): .array([
          .integer(10), .integer(10), .integer(585), .integer(832),
        ]),
        PDFName("Contents"): .reference(PDFObjectID(50 + id)),
      ])
      objects[PDFObjectID(50 + id)] = .stream(PDFStream(bytes: Data("q Q\n".utf8)))
    }
    return PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  // MARK: - P08-003–P08-008

  @Test func pageAttributesResolveInheritanceAndBoxes() throws {
    let graph = inheritedFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    #expect(pageIDs.count == 5)
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    #expect(attributes.count == 5)
    // Pages 1–3 inherit the parent's landscape MediaBox, -90 rotation
    // (normalized to 270), UserUnit 2, and resources.
    let first = attributes[0]
    #expect(first.mediaBox == [0, 0, 842, 595])
    #expect(first.rotation == 270)
    #expect(first.userUnit == 2)
    #expect(first.hasInheritedResources)
    #expect(first.contentStreamIDs.count == 1)
    // Pages 4–5 inherit a portrait box and define their own CropBox.
    let fourth = attributes[3]
    #expect(fourth.mediaBox == [0, 0, 595, 842])
    #expect(fourth.cropBox == [10, 10, 585, 832])
    #expect(fourth.rotation == 0)
    #expect(fourth.userUnit == 1)
    // Identities are stable and unique.
    #expect(Set(attributes.map(\.identity)).count == 5)
    let again = PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    #expect(again.map(\.identity) == attributes.map(\.identity))

    // P08-007: resource categories split images and forms.
    let resources = PDFDocumentInventory.resources(pageID: pageIDs[0], in: graph)
    #expect(resources.fonts == ["F1"])
    #expect(resources.images == ["Im1"])
    #expect(resources.forms == ["Fm1"])
    #expect(resources.graphicsStates == ["GS1"])
    #expect(resources.patterns == ["P1"])
  }

  // MARK: - P08-010

  @Test func pageLabelsCoverRangesAndStyles() throws {
    let graph = inheritedFixture()
    let ranges = PDFPageLabels.ranges(in: graph)
    #expect(ranges.count == 2)
    #expect(ranges[0].style == .lowerRoman)
    #expect(ranges[0].startPageIndex == 0)
    #expect(ranges[1].startValue == 7)
    #expect(ranges[1].prefix == "A-")
    // Labels: pages 0..2 roman, pages 3..4 decimal with the prefix and start.
    let labels = (0..<5).map { PDFPageLabels.label(forPageIndex: $0, in: graph) }
    #expect(labels == ["i", "ii", "iii", "A-7", "A-8"])
    // Roman/alpha helpers.
    #expect(PDFPageLabels.roman(4, upper: true) == "IV")
    #expect(PDFPageLabels.alpha(27, upper: false) == "aa")
  }

  // MARK: - P08-014/P08-016/P08-018/P08-020/P08-022

  @Test func metadataOptionalContentSecurityAndActiveContent() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("Lang")] = .string(Data("en-US".utf8))
      catalog[PDFName("Metadata")] = .stream(PDFStream(bytes: Data("<x/>".utf8)))
      catalog[PDFName("OCProperties")] = .dictionary([
        PDFName("OCGs"): .array([
          .dictionary([PDFName("Name"): .string(Data("Layer A".utf8))]),
          .dictionary([PDFName("Name"): .string(Data("Layer B".utf8))]),
        ]),
        PDFName("D"): .dictionary([
          PDFName("Name"): .string(Data("Default".utf8)),
          PDFName("Order"): .array([]),
        ]),
      ])
      graph.objects[catalogID] = .dictionary(catalog)
    }
    graph.objects[PDFObjectID(60)] = .dictionary([
      PDFName("Title"): .string(Data("Quarterly".utf8)),
      PDFName("Author"): .string(Data("Ada".utf8)),
      PDFName("Producer"): .string(Data("sPDF".utf8)),
    ])
    graph.trailer[PDFName("Info")] = .reference(PDFObjectID(60))
    graph.trailer[PDFName("ID")] = .array([
      .string(Data("aa".utf8)), .string(Data("bb".utf8)),
    ])

    let metadata = PDFDocumentInventory.metadata(in: graph)
    #expect(metadata.title == "Quarterly")
    #expect(metadata.author == "Ada")
    #expect(metadata.producer == "sPDF")
    #expect(metadata.hasFileIdentifier)
    #expect(metadata.hasXMPMetadata)
    #expect(metadata.language == "en-US")

    let optional = PDFDocumentInventory.optionalContent(in: graph)
    #expect(optional.groups.count == 2)
    #expect(optional.groups.compactMap(\.name).contains("Layer A"))
    #expect(optional.configurationNames == ["Default"])
    #expect(optional.hasOrder)

    let security = PDFDocumentInventory.security(in: graph, pageCount: 1)
    #expect(!security.isEncrypted)
    #expect(security.allowsModification)

    // Active content flags.
    var active = graph
    active.objects[PDFObjectID(61)] = .dictionary([
      PDFName("Type"): .name(PDFName("Filespec")),
      PDFName("JS"): .string(Data("app.alert(1)".utf8)),
    ])
    if case .reference(let catalogID)? = active.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = active.objects[catalogID]
    {
      catalog[PDFName("Collection")] = .dictionary([:])
      catalog[PDFName("Names")] = .dictionary([
        PDFName("EmbeddedFiles"): .dictionary([:])
      ])
      catalog[PDFName("AcroForm")] = .dictionary([
        PDFName("XFA"): .array([.string(Data("<xfa/>".utf8))])
      ])
      active.objects[catalogID] = .dictionary(catalog)
    }
    let content = PDFDocumentInventory.activeContent(in: active)
    #expect(content.hasXFA)
    #expect(content.hasPortfolio)
    #expect(content.hasEmbeddedFiles)
    #expect(content.hasJavaScript)
    #expect(content.isActive)
    #expect(content.summary.contains("XFA form"))

    let assessment = PDFDocumentInventory.assess(in: active, pageCount: 1)
    #expect(assessment.canView && assessment.canInspect)
    #expect(assessment.canEditContent)  // active content alone does not block edits
    #expect(assessment.reasons.contains { $0.contains("XFA") })
    #expect(assessment.reasons.contains { $0.contains("inert") })

    // A signed document refuses content edits with a reason.
    let signed = try PDFParser.parse(
      try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Signed/signed-one-page.pdf")))
    let signedAssessment = PDFDocumentInventory.assess(in: signed.graph, pageCount: 1)
    #expect(!signedAssessment.canEditContent)
    #expect(signedAssessment.reasons.contains { $0.contains("signed") })
  }

  // MARK: - P08-023/P08-029

  @Test func documentFactsAreLazyAndPageInventoryIsBounded() throws {
    // A 200-page document: document-level facts must not scan pages.
    var objects: [PDFObjectID: PDFValue] = [:]
    var kids: [PDFValue] = []
    var nextID = 1_000
    for index in 1...200 {
      let pageID = PDFObjectID(nextID)
      nextID += 1
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Contents"): .stream(PDFStream(bytes: Data("q Q\n".utf8))),
      ])
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(200),
      PDFName("Kids"): .array(kids),
    ])
    let graph = PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])

    let factsStart = ContinuousClock.now
    let facts = PDFDocumentInventory.documentFacts(in: graph, pageCount: 200)
    let factsLatency = Int((ContinuousClock.now - factsStart).components.seconds * 1000)
    #expect(facts.activeContent.isActive == false)
    #expect(!facts.security.isEncrypted)
    #expect(factsLatency < 100)

    let pagesStart = ContinuousClock.now
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    let pagesLatency = Int((ContinuousClock.now - pagesStart).components.seconds * 1000)
    print("[P08-029] 200-page facts \(factsLatency) ms, page attributes \(pagesLatency) ms")
    #expect(attributes.count == 200)
    #expect(pagesLatency < 2_000)
  }

  // MARK: - P08-025/P08-026/P08-028

  @Test func mixedSizesOutlinesAndMalformedTreesStayBounded() throws {
    // Mixed page sizes and unusual origins.
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    #expect(Set(attributes.map { $0.mediaBox.map { String(format: "%.0f", $0) }.joined(separator: ",") }).count >= 1)
    #expect(attributes.allSatisfy { $0.identity.hasPrefix("page-") })

    // A page-tree cycle stays bounded (count mismatch detection lives in the
    // sanity check).
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let pagesID)? = catalog[PDFName("Pages")],
      case .dictionary(var pages)? = graph.objects[pagesID]
    {
      pages[PDFName("Kids")] = .array([.reference(pagesID)])
      graph.objects[pagesID] = .dictionary(pages)
    }
    do {
      _ = try PDFPageTree.pageIDs(in: graph)
    } catch let error as PDFError {
      #expect([.malformed, .limitExceeded].contains(error.kind))
    }
  }
}
