import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures

/// Shared A11Y-03/A11Y-04 fixtures: untagged visual documents (headings,
/// paragraphs, lists, two columns, figures/captions) and a tagged table/form
/// document built from the shared tagged fixture.
enum A11YFixtures {
  static func untaggedDocument() -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let image = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
    let pageOne = """
      BT /F1 20 Tf 42 710 Td (Quarterly Report) Tj ET
      BT /F1 12 Tf 42 640 Td (First body line of the report.) Tj ET
      BT /F1 12 Tf 42 624 Td (Second body line follows here.) Tj ET
      BT /F1 12 Tf 42 608 Td (Third body line ends the block.) Tj ET
      BT /F1 12 Tf 42 570 Td (- Alpha item one) Tj ET
      BT /F1 12 Tf 42 554 Td (- Beta item two) Tj ET
      BT /F1 12 Tf 42 538 Td (- Gamma item three) Tj ET
      BT /F1 10 Tf 42 470 Td (Figure one: a green square) Tj ET
      BT /F1 9 Tf 42 40 Td (Confidential - internal use only) Tj ET
      q 100 0 0 100 42 480 cm /Im1 Do Q

      """
    let pageTwo = """
      BT /F1 12 Tf 42 640 Td (Page two body text.) Tj ET
      BT /F1 9 Tf 42 40 Td (Confidential - internal use only) Tj ET

      """
    // Two balanced columns: each line starts far from the other column.
    let pageThree = """
      BT /F1 12 Tf 42 640 Td (Left column line one.) Tj ET
      BT /F1 12 Tf 42 624 Td (Left column line two.) Tj ET
      BT /F1 12 Tf 42 608 Td (Left column line three.) Tj ET
      BT /F1 12 Tf 320 640 Td (Right column line one.) Tj ET
      BT /F1 12 Tf 320 624 Td (Right column line two.) Tj ET
      BT /F1 12 Tf 320 608 Td (Right column line three.) Tj ET

      """
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(3),
          PDFName("Kids"): .array([
            .reference(PDFObjectID(4)), .reference(PDFObjectID(6)),
            .reference(PDFObjectID(9)),
          ]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))]),
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(8))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(pageOne.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(pageTwo.utf8))),
        PDFObjectID(8): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: image)),
        PDFObjectID(9): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(10)),
        ]),
        PDFObjectID(10): .stream(PDFStream(bytes: Data(pageThree.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return (graph, [PDFObjectID(4), PDFObjectID(6), PDFObjectID(9)])
  }

  /// taggedPages() plus a Table (with TR/TH/TD cells) attached to the root.
  static func taggedTableGraph() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    var graph = parsed.graph
    let rootID = PDFObjectID(20)
    let tableID = PDFObjectID(70)
    let headerRowID = PDFObjectID(71)
    let dataRowID = PDFObjectID(74)
    let nameHeaderID = PDFObjectID(72)
    let ageHeaderID = PDFObjectID(73)
    let nameDataID = PDFObjectID(75)
    let ageDataID = PDFObjectID(76)
    graph.objects[tableID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("Table")),
      PDFName("P"): .reference(rootID),
      PDFName("K"): .array([
        .reference(headerRowID), .reference(dataRowID),
      ]),
    ])
    graph.objects[headerRowID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TR")),
      PDFName("P"): .reference(tableID),
      PDFName("K"): .array([
        .reference(nameHeaderID), .reference(ageHeaderID),
      ]),
    ])
    graph.objects[dataRowID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TR")),
      PDFName("P"): .reference(tableID),
      PDFName("K"): .array([
        .reference(nameDataID), .reference(ageDataID),
      ]),
    ])
    graph.objects[nameHeaderID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TH")),
      PDFName("P"): .reference(headerRowID),
      PDFName("A"): .dictionary([
        PDFName("O"): .name(PDFName("Table")),
        PDFName("Scope"): .name(PDFName("Column")),
      ]),
    ])
    graph.objects[ageHeaderID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TH")),
      PDFName("P"): .reference(headerRowID),
      PDFName("A"): .dictionary([
        PDFName("O"): .name(PDFName("Table")),
        PDFName("Scope"): .name(PDFName("Column")),
      ]),
    ])
    graph.objects[nameDataID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TD")),
      PDFName("P"): .reference(dataRowID),
      PDFName("A"): .dictionary([
        PDFName("O"): .name(PDFName("Table")),
        PDFName("Headers"): .array([.reference(nameHeaderID)]),
      ]),
    ])
    graph.objects[ageDataID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TD")),
      PDFName("P"): .reference(dataRowID),
    ])
    if case .dictionary(var root)? = graph.objects[rootID],
      case .array(var kids)? = root[PDFName("K")]
    {
      kids.append(.reference(tableID))
      root[PDFName("K")] = .array(kids)
      graph.objects[rootID] = .dictionary(root)
    }
    return (graph, parsed.pageIDs)
  }

  /// Table fixture plus two form fields with tooltips on page one.
  static func taggedTableWithForm() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    var (graph, pageIDs) = try taggedTableGraph()
    let pageID = pageIDs[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 460, 272, 484], name: "Name"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 420, 272, 444], name: "Email"),
        SetFormFieldTooltipCommand(fieldName: "Name", tooltip: "Full name"),
        SetFormFieldTooltipCommand(fieldName: "Email", tooltip: "Email address"),
      ]), to: graph)
    return (graph, pageIDs)
  }
}
