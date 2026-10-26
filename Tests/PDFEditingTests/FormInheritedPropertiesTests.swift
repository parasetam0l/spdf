import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-05 evidence: inherited /DA, /DR, /Q, /MaxLen and /TU resolution.
@Suite("Form inherited properties")
struct FormInheritedPropertiesTests {
  struct Fixture {
    var graph: PDFGraph
    let pageID: PDFObjectID
    let parentID: PDFObjectID
    let childID: PDFObjectID
    let importedFontID: PDFObjectID
  }

  private func fixture(withImportedFont: Bool = false) throws -> Fixture {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    let helvetica = PDFObjectID(100)
    let parent = PDFObjectID(101)
    let child = PDFObjectID(102)
    let imported = PDFObjectID(103)
    let importedCmap = PDFObjectID(104)
    graph.objects[helvetica] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    var fonts: [PDFName: PDFValue] = [PDFName("F1"): .reference(helvetica)]
    if withImportedFont {
      let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap "
        + "/CMapName /Adobe-Identity-UCS def /CMapType 2 def "
        + "1 begincodespacerange <00> <FF> endcodespacerange "
        + "2 beginbfchar <41> <0041> <42> <0042> endbfchar endcmap "
        + "CMapName currentdict /CMap defineresource pop end end"
      graph.objects[importedCmap] = .stream(PDFStream(bytes: Data(cmap.utf8)))
      graph.objects[imported] = .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("ImportedLatin")),
        PDFName("FirstChar"): .integer(65),
        PDFName("LastChar"): .integer(66),
        PDFName("Widths"): .array([.integer(600), .integer(600)]),
        PDFName("ToUnicode"): .reference(importedCmap),
      ])
      fonts[PDFName("Fimport")] = .reference(imported)
    }
    graph.objects[parent] = .dictionary([
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("T"): .string(AnnotationText.encode("Group")),
      PDFName("Ff"): .integer(2),
      PDFName("DA"): .string(Data("/F1 18 Tf 0 0 1 rg".utf8)),
      PDFName("Q"): .integer(2),
      PDFName("MaxLen"): .integer(12),
      PDFName("TU"): .string(AnnotationText.encode("Qualified name")),
      PDFName("Kids"): .array([.reference(child)]),
    ])
    graph.objects[child] = .dictionary([
      PDFName("T"): .string(AnnotationText.encode("Child")),
      PDFName("Parent"): .reference(parent),
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Rect"): .array([.integer(72), .integer(600), .integer(372), .integer(624)]),
      PDFName("P"): .reference(pageID),
      PDFName("F"): .integer(4),
    ])
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "page missing")
    }
    page[PDFName("Annots")] = .array([.reference(child)])
    graph.objects[pageID] = .dictionary(page)
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "catalog missing")
    }
    catalog[PDFName("AcroForm")] = .dictionary([
      PDFName("Fields"): .array([.reference(parent)]),
      PDFName("DA"): .string(Data("/F1 10 Tf 0 g".utf8)),
      PDFName("DR"): .dictionary([PDFName("Font"): .dictionary(fonts)]),
    ])
    graph.objects[catalogID] = .dictionary(catalog)
    return Fixture(
      graph: graph, pageID: pageID, parentID: parent, childID: child,
      importedFontID: imported)
  }

  @Test func inheritedAppearanceAlignmentAndLengthResolveFromParent() throws {
    let fixture = try fixture()
    guard let field = try FormInventory.fields(in: fixture.graph, pageIDs: [fixture.pageID])
      .first(where: { $0.name == "Group.Child" })
    else {
      Issue.record("child field missing")
      return
    }
    let properties = try FormEffectivePropertiesReader.properties(
      for: field, in: fixture.graph, pageIDs: [fixture.pageID])
    #expect(properties.defaultAppearanceSize == 18)
    #expect(properties.defaultAppearanceColor == [0, 0, 1])
    #expect(properties.defaultAppearanceFontName == PDFName("F1"))
    #expect(properties.alignment == 2)
    #expect(properties.maxLength == 12)
    #expect(properties.tooltip == "Qualified name")
    #expect(properties.isRequired)
    let handle = try FormEffectivePropertiesReader.appearanceFont(
      for: properties, in: fixture.graph)
    #expect(handle == .standard(face: .helvetica, resourceName: PDFName("F1")))
  }

  @Test func acroFormDefaultAppearanceIsTheLastFallback() throws {
    var fixture = try fixture()
    guard case .dictionary(var parent)? = fixture.graph.objects[fixture.parentID] else {
      Issue.record("parent missing")
      return
    }
    parent.removeValue(forKey: PDFName("DA"))
    parent.removeValue(forKey: PDFName("Q"))
    fixture.graph.objects[fixture.parentID] = .dictionary(parent)
    guard let field = try FormInventory.fields(in: fixture.graph, pageIDs: [fixture.pageID])
      .first(where: { $0.name == "Group.Child" })
    else {
      Issue.record("child missing")
      return
    }
    let properties = try FormEffectivePropertiesReader.properties(
      for: field, in: fixture.graph, pageIDs: [fixture.pageID])
    #expect(properties.defaultAppearanceSize == 10)
    #expect(properties.defaultAppearanceColor == [0, 0, 0])
    #expect(properties.alignment == 0)
  }

  @Test func importedFontWithToUnicodeResolvesToAnEncodableHandle() throws {
    var fixture = try fixture(withImportedFont: true)
    guard case .dictionary(var parent)? = fixture.graph.objects[fixture.parentID] else {
      Issue.record("parent missing")
      return
    }
    parent[PDFName("DA")] = .string(Data("/Fimport 11 Tf 0 g".utf8))
    fixture.graph.objects[fixture.parentID] = .dictionary(parent)
    guard let field = try FormInventory.fields(in: fixture.graph, pageIDs: [fixture.pageID])
      .first(where: { $0.name == "Group.Child" })
    else {
      Issue.record("child missing")
      return
    }
    let properties = try FormEffectivePropertiesReader.properties(
      for: field, in: fixture.graph, pageIDs: [fixture.pageID])
    let handle = try FormEffectivePropertiesReader.appearanceFont(
      for: properties, in: fixture.graph)
    #expect(handle.encode("AB") == [65, 66])
    #expect(handle.encode("C") == nil)
    #expect(handle.isComposite == false)
  }

  @Test func unresolvedDefaultAppearanceFontRefusesInsteadOfSubstituting() throws {
    var fixture = try fixture()
    guard case .dictionary(var parent)? = fixture.graph.objects[fixture.parentID] else {
      Issue.record("parent missing")
      return
    }
    parent[PDFName("DA")] = .string(Data("/Missing 12 Tf 0 g".utf8))
    fixture.graph.objects[fixture.parentID] = .dictionary(parent)
    guard let field = try FormInventory.fields(in: fixture.graph, pageIDs: [fixture.pageID])
      .first(where: { $0.name == "Group.Child" })
    else {
      Issue.record("child missing")
      return
    }
    let properties = try FormEffectivePropertiesReader.properties(
      for: field, in: fixture.graph, pageIDs: [fixture.pageID])
    #expect(throws: PDFError.self) {
      _ = try FormEffectivePropertiesReader.appearanceFont(
        for: properties, in: fixture.graph)
    }
  }

  @Test func richFillUsesInheritedFontAndRightAlignment() throws {
    let fixture = try fixture()
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormRichTextCommand(
          fieldName: "Group.Child", value: .plain("Hi", style: FormRichTextStyle(fontSize: 12)))
      ]), to: fixture.graph)
    guard let childID = FormAuthoringSupport.findField(named: "Group.Child", in: edited),
      case .dictionary(let field)? = edited.objects[childID]
    else {
      Issue.record("child missing after edit")
      return
    }
    guard case .string(let daData)? = field[PDFName("DA")] else {
      Issue.record("DA missing")
      return
    }
    let da = String(decoding: daData, as: UTF8.self)
    #expect(da.contains("/F1"))
    #expect(da.contains("12"))
    // Right alignment inherited from the parent moves the first show operator
    // away from the left edge.
    guard case .dictionary(let appearance)? = field[PDFName("AP")],
      case .reference(let streamID)? = appearance[PDFName("N")],
      case .stream(let stream)? = edited.objects[streamID],
      let decoded = try? PDFFilters.decoded(stream)
    else {
      Issue.record("appearance missing")
      return
    }
    let content = String(decoding: decoded, as: UTF8.self)
    #expect(content.contains("Tj"))
    let tokens = content.split(whereSeparator: { " \n".contains($0) })
    var firstX: Double?
    for index in 2..<tokens.count where tokens[index] == "Tm" {
      if let x = Double(tokens[index - 2]) { firstX = x }
      break
    }
    #expect((firstX ?? 0) > 5)
  }

  @Test func inheritedMaxLengthRefusesOverlongRichValue() throws {
    let fixture = try fixture()
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormRichTextCommand(
            fieldName: "Group.Child", value: .plain("This exceeds the limit"))
        ]), to: fixture.graph)
    }
  }
}
