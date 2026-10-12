import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P14-023: Type 3 glyph programs are detected (readable, never rewritten),
/// editing through them refuses with a reason, and their programs survive
/// unrelated edits byte-identically.
@Suite("Type 3 fonts")
struct Type3FontTests {
  private func parsedTagged() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    return (parsed.graph, parsed.pageIDs[0])
  }

  private func taggedPage(in graph: PDFGraph, pageID: PDFObjectID) throws
    -> [PDFName: PDFValue]
  {
    let page = try #require(graph.objects[pageID])
    guard case .dictionary(let dictionary) = page else {
      throw PDFError(.malformed, "Page missing")
    }
    return dictionary
  }

  @Test func type3DetectionLeavesReadingSupported() throws {
    let (graph, pageID) = try parsedTagged()
    // Font resource F1 is the Type3 font; it resolves for reading (ToUnicode)
    // but not for writing.
    guard
      let font = SimpleFont.resolve(
        resource: PDFName("F1"), page: try taggedPage(in: graph, pageID: pageID), in: graph)
    else {
      Issue.record("F1 did not resolve")
      return
    }
    #expect(font.isType3)
    #expect(font.isSupported)
    // The fixture maps every code to a "square" program, so writing can
    // reuse verified programs; without readable programs it refuses.
    #expect(font.isEditable)
    // Reading still works: the page's text extracts through the ToUnicode
    // map of the Type3 font.
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(text.contains("Tagged heading"))
    #expect(text.contains("Tagged paragraph text"))
    // Inventory records the Type3 fact.
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: [pageID])
    #expect(fonts.contains { $0.isType3 && $0.subtype == "Type3" })
    // A non-Type3 fixture font stays editable.
    let widths = try PDFParser.parse(PDFFixtures.textWidthsPages())
    guard
      let simple = SimpleFont.resolve(
        resource: PDFName("F1"), page: try taggedPage(in: widths.graph, pageID: widths.pageIDs[0]),
        in: widths.graph)
    else {
      Issue.record("widths F1 did not resolve")
      return
    }
    #expect(!simple.isType3 && simple.isEditable)
  }

  @Test func replacementReusesVerifiedGlyphPrograms() throws {
    // Every code in the fixture names an existing "square" program, so a
    // same-length replacement is writable and extracts as intended.
    let (graph, pageID) = try parsedTagged()
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "Tagged heading!")
      ]), to: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: edited)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(text.contains("Tagged heading!"))
  }

  @Test func replacementRefusesWhenProgramsAreMissing() throws {
    // Emptying CharProcs removes the programs the codes name: replacement
    // must refuse rather than paint nothing.
    let (graph, pageID) = try parsedTagged()
    var mutated = graph
    mutated.objects[PDFObjectID(10)] = .dictionary([:])
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "X")
        ]), to: mutated)
      Issue.record("replacement without glyph programs was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("Type 3"))
    }
    // A font without any CharProcs at all refuses earlier (unreadable).
    var stripped = graph
    stripped.objects[PDFObjectID(7)] = {
      guard case .dictionary(var font)? = graph.objects[PDFObjectID(7)] else { return .null }
      font.removeValue(forKey: PDFName("CharProcs"))
      return .dictionary(font)
    }()
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "X")
        ]), to: stripped)
      Issue.record("replacement without CharProcs was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("Type 3"))
    }
  }

  @Test func redactionRefusesType3Paint() throws {
    // A glyph program may paint beyond the advance box, so covering the box
    // cannot guarantee removal; redaction refuses.
    let (graph, pageID) = try parsedTagged()
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactRegionsCommand(pageID: pageID, regions: [[40, 690, 240, 735]])
        ]), to: graph)
      Issue.record("Type3 redaction was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("Type 3"))
    }
  }

  @Test func reflowRefusesWhenProgramsAreMissing() throws {
    let (graph, pageID) = try parsedTagged()
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    guard let candidate = candidates.first(where: { $0.text.contains("Tagged heading") }) else {
      Issue.record("no heading candidate on the tagged fixture")
      return
    }
    // With programs present the plan succeeds (the downstream suite proves
    // the committed reflow keeps structure references valid).
    _ = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: "Replacement heading", in: graph)
    var stripped = graph
    stripped.objects[PDFObjectID(7)] = {
      guard case .dictionary(var font)? = graph.objects[PDFObjectID(7)] else { return .null }
      font.removeValue(forKey: PDFName("CharProcs"))
      return .dictionary(font)
    }()
    do {
      _ = try ParagraphReflow.plan(
        pageID: pageID, candidate: candidate, replacement: "Replacement heading",
        in: stripped)
      Issue.record("reflow without glyph programs was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("Type 3"))
    }
  }

  @Test func glyphProgramsSurviveUnrelatedEditsByteIdentically() throws {
    let (graph, pageID) = try parsedTagged()
    let watched: [PDFObjectID] = [
      PDFObjectID(7), PDFObjectID(10), PDFObjectID(11), PDFObjectID(12),
    ]
    let before = watched.map { graph.objects[$0] }
    // An unrelated structural edit: set the document language.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([SetStructureLanguageCommand(language: "de")]), to: graph)
    for (index, id) in watched.enumerated() {
      #expect(edited.objects[id] == before[index], "object \(id.number) changed")
    }
    // Byte-level: the serialized objects are identical across a full
    // write/reparse, including the CharProcs dictionary and both programs.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    for (index, id) in watched.enumerated() {
      let beforeBytes = try PDFWriter.serializedValue(before[index]!, limits: PDFLimits())
      let afterBytes = try PDFWriter.serializedValue(
        try #require(reparsed.graph.objects[id]), limits: PDFLimits())
      #expect(beforeBytes == afterBytes, "object \(id.number) bytes changed")
    }
  }
}
