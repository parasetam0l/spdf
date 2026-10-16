import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P13-001/002/003/004/011..014/024 and P18-001/002/005/006/008/023..029
/// evidence: content parsing, text-run mapping, and narrow text replacement.
@Suite("Text editing")
struct TextEditTests {
  @Test func contentParserPreservesSpansAndUnknownOperators() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textEditPages())
    let content = try PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph)
    // Every instruction's span text ends with its operator name.
    for instruction in content.instructions {
      let text = String(decoding: content.bytes[instruction.span], as: UTF8.self)
      #expect(text.hasSuffix(instruction.operatorName))
    }
    let operators = content.instructions.map(\.operatorName)
    #expect(operators.contains("BT"))
    #expect(operators.contains("Tj"))
    #expect(operators.contains("TJ"))
    #expect(operators.contains("ET"))
    // Spans are ordered and non-overlapping.
    for (previous, next) in zip(content.instructions, content.instructions.dropFirst()) {
      #expect(previous.span.upperBound <= next.span.lowerBound)
    }
  }

  @Test func inlineImagePayloadAmbiguityDoesNotCorruptInstructions() throws {
    // The payload contains "EIx" (not a boundary) and a real "EI" boundary.
    var raw: [UInt8] = []
    raw += Array("q BI /W 2 /H 2 /CS /G /BPC 8 /F /AHx ID ".utf8)
    raw += Array("AB EIxCD".utf8)
    raw += [0x0A]
    raw += Array("EI\nQ BT /F1 12 Tf 10 10 Td (after) Tj ET\n".utf8)
    var graph = PDFFixtures.graph()
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(raw)))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let content = try PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph)
    let instructions = content.instructions
    #expect(instructions.first?.operatorName == "q")
    #expect(instructions.contains { $0.operatorName == "BI" && $0.isInlineImage })
    #expect(instructions.contains { $0.operatorName == "Q" })
    let runs = try TextRunIndexer.runs(in: content, graph: parsed.graph)
    #expect(runs.first?.text == "after")
  }

  @Test func textRunsMapToOperandsOnTheFixture() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textEditPages())
    let content = try PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph)
    let runs = try TextRunIndexer.runs(in: content, graph: parsed.graph)
    #expect(runs.count == 4)
    #expect(runs[0].text == "Replace this text")
    #expect(runs[0].fontSize == 24)
    #expect(runs[0].fontResource == PDFName("F1"))
    #expect(runs[0].baselineY == 710)
    #expect(runs[1].text == "Kern")
    #expect(runs[2].text == "ing stays")
    #expect(runs[3].text == "Quotes (kept)")
    // Every span slices exactly the operand token.
    for run in runs {
      let token = String(decoding: content.bytes[run.stringSpan], as: UTF8.self)
      #expect(token.hasPrefix("(") && token.hasSuffix(")"))
    }
  }

  @Test func replaceTextRewritesOnlyTheTargetOperand() throws {
    let original = try PDFFixtures.textEditPages()
    let parsed = try PDFParser.parse(original)
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "Edited fixture line")
      ]), to: parsed.graph)
    let content = try PageContent.load(pageID: pageID, in: graph)
    let text = String(decoding: content.bytes, as: UTF8.self)
    #expect(text.contains("(Edited fixture line)"))
    #expect(!text.contains("Replace this text"))
    // Neighboring instructions stay byte-identical; only the operand changes.
    let originalContent = try PageContent.load(pageID: pageID, in: parsed.graph)
    for index in 1..<originalContent.instructions.count {
      let before = originalContent.instructions[index].span
      let after = content.instructions[index].span
      #expect(originalContent.bytes[before] == content.bytes[after])
    }
    // All other objects are untouched (P18-023).
    let editedStreamID = content.segments[0].objectID
    for (id, value) in parsed.graph.objects where id != editedStreamID {
      #expect(graph.objects[id] == value)
    }
    // Full round trip through the writer.
    let rewritten = try PDFParser.parse(PDFWriter.write(graph))
    #expect(rewritten.graph == graph)
    let reruns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: rewritten.graph), graph: rewritten.graph)
    #expect(reruns[0].text == "Edited fixture line")
  }

  @Test func replaceTextRefusesUnencodableAndUnsupportedFonts() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textEditPages())
    let pageID = parsed.pageIDs[0]
    // WinAnsi has no arrow glyph: refuse rather than substitute (P18-006).
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "arrow \u{2192}")
        ]), to: parsed.graph)
    }

    // MacRoman fonts are out of the first supported profile.
    var unsupported = parsed.graph
    guard case .dictionary(let page)? = unsupported.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(var font)? = unsupported.objects[fontID]
    else {
      Issue.record("Fixture font missing")
      return
    }
    font[PDFName("Encoding")] = .name(PDFName("MacRomanEncoding"))
    unsupported.objects[fontID] = .dictionary(font)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "Edited")
        ]), to: unsupported)
    }
  }

  @Test func differencesOverrideCodesForDecodingAndEncoding() throws {
    // Codes 65/66 render an arrow and a bullet via Differences.
    var graph = try PDFParser.parse(PDFFixtures.textEditPages()).graph
    let pageID = PDFObjectID(3)
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(var font)? = graph.objects[fontID]
    else {
      Issue.record("Fixture font missing")
      return
    }
    font[PDFName("Encoding")] = .dictionary([
      PDFName("BaseEncoding"): .name(PDFName("WinAnsiEncoding")),
      PDFName("Differences"): .array([
        .integer(65), .name(PDFName("uni2192")), .name(PDFName("bullet")),
      ]),
    ])
    graph.objects[fontID] = .dictionary(font)
    let simple = try #require(SimpleFont.resolve(resource: PDFName("F1"), page: page, in: graph))
    #expect(simple.decode([65, 66]) == "\u{2192}\u{2022}")
    #expect(simple.encode("\u{2192}\u{2022}") == [65, 66])

    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "\u{2192}\u{2022}")
      ]), to: graph)
    let text = String(
      decoding: try PageContent.load(pageID: pageID, in: replaced).bytes, as: UTF8.self)
    #expect(text.contains("(AB)"))
  }

  @Test func contentArraysKeepUntouchedStreamsByteIdentical() throws {
    // Split the fixture's content into two streams; only the second changes.
    var graph = try PDFParser.parse(PDFFixtures.textEditPages()).graph
    let pageID = PDFObjectID(3)
    let contentID = PDFObjectID(5)
    guard case .stream(let stream)? = graph.objects[contentID] else {
      Issue.record("Content stream missing")
      return
    }
    let bytes = [UInt8](stream.bytes)
    let split = bytes.count / 2
    graph.objects[PDFObjectID(10)] = .stream(
      PDFStream(dictionary: stream.dictionary, bytes: Data(bytes[0..<split])))
    graph.objects[PDFObjectID(11)] = .stream(
      PDFStream(dictionary: stream.dictionary, bytes: Data(bytes[split...])))
    graph.objects.removeValue(forKey: contentID)
    guard case .dictionary(var page)? = graph.objects[pageID] else { return }
    page[PDFName("Contents")] = .array([
      .reference(PDFObjectID(10)), .reference(PDFObjectID(11)),
    ])
    graph.objects[pageID] = .dictionary(page)

    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    let runIndex = try #require(runs.firstIndex { $0.text == "ing stays" })
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: "ing changed")
      ]), to: graph)
    #expect(replaced.objects[PDFObjectID(10)] == graph.objects[PDFObjectID(10)])
    let newText = String(
      decoding: try PageContent.load(pageID: pageID, in: replaced).bytes, as: UTF8.self)
    #expect(newText.contains("(ing changed)"))
  }

  @Test func widthsAndAdvancesIncludeSpacingScalingAndMissingWidth() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    guard case .dictionary(let page)? = parsed.graph.objects[PDFObjectID(3)],
      let font = SimpleFont.resolve(resource: PDFName("F1"), page: page, in: parsed.graph)
    else {
      Issue.record("Fixture font missing")
      return
    }
    #expect(font.width(of: 65) == 500)  // A
    #expect(font.width(of: 32) == 250)  // space
    #expect(
      font.advance(
        of: [65, 66], fontSize: 20, charSpacing: 0, wordSpacing: 0, horizontalScale: 100)
        == 20)
    #expect(
      font.advance(of: [32], fontSize: 20, charSpacing: 0, wordSpacing: 0, horizontalScale: 100)
        == 5)
    #expect(
      font.advance(of: [65], fontSize: 10, charSpacing: 1, wordSpacing: 0, horizontalScale: 50)
        == 3.0)

    // Codes outside the Widths range fall back to the descriptor MissingWidth.
    var crafted = parsed.graph
    guard case .dictionary(let fontDictionary)? = crafted.objects[PDFObjectID(4)] else {
      Issue.record("Fixture font missing")
      return
    }
    var narrowed = fontDictionary
    narrowed[PDFName("FirstChar")] = .integer(65)
    narrowed[PDFName("LastChar")] = .integer(65)
    narrowed[PDFName("Widths")] = .array([.integer(600)])
    crafted.objects[PDFObjectID(4)] = .dictionary(narrowed)
    guard case .dictionary(let craftedPage)? = crafted.objects[PDFObjectID(3)],
      let craftedFont = SimpleFont.resolve(
        resource: PDFName("F1"), page: craftedPage, in: crafted)
    else {
      Issue.record("Crafted font missing")
      return
    }
    #expect(craftedFont.width(of: 65) == 600)
    #expect(craftedFont.width(of: 66) == 250)
    #expect(
      craftedFont.advance(
        of: [66], fontSize: 10, charSpacing: 1, wordSpacing: 2, horizontalScale: 50)
        == 1.75)
  }

  @Test func tjReplacementCompensatesFollowingMembers() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "A")]),
      to: parsed.graph)
    let members = try Self.tjMembers(in: graph, pageID: pageID)
    #expect(members == [.string(Data("A".utf8)), .integer(-1000), .string(Data("CD".utf8))])
    let reopened = try PDFParser.parse(PDFWriter.write(graph))
    let reopenedMembers = try Self.tjMembers(in: reopened.graph, pageID: pageID)
    #expect(reopenedMembers == members)
  }

  @Test func tjInsertionAndDeletionCompensate() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]

    // Insertion within the first run: "AB" -> "AXB" widens by 10 units, so
    // the -500 adjustment becomes 0 (the following member keeps its spot).
    let inserted = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "AXB")]),
      to: parsed.graph)
    let insertedMembers = try Self.tjMembers(in: inserted, pageID: pageID)
    #expect(
      insertedMembers == [.string(Data("AXB".utf8)), .integer(0), .string(Data("CD".utf8))])

    // Deletion removes the text and cancels its 20-unit advance entirely.
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "")]),
      to: parsed.graph)
    let deletedMembers = try Self.tjMembers(in: deleted, pageID: pageID)
    #expect(deletedMembers == [.string(Data()), .integer(-1500), .string(Data("CD".utf8))])

    // Insertion inside the last member needs no compensation and keeps the
    // literal operand path.
    let content = try PageContent.load(pageID: pageID, in: parsed.graph)
    let runs = try TextRunIndexer.runs(in: content, graph: parsed.graph)
    let lastIndex = try #require(runs.firstIndex { $0.text == "CD" })
    let lastEdited = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: lastIndex, replacement: "CXD")]),
      to: parsed.graph)
    let text = String(
      decoding: try PageContent.load(pageID: pageID, in: lastEdited).bytes, as: UTF8.self)
    #expect(text.contains("(CXD)"))
  }

  @Test func middleMemberReplacementKeepsNeighborPlacement() throws {
    // P18-003: replacing a middle TJ member splits the instruction at member
    // boundaries — only the target member and the following adjustment
    // change — and both the preceding and following runs keep their
    // page-space positions.
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("BT /F1 20 Tf 42 710 Td [(AB) -500 (CD) -200 (EF)] TJ ET\n".utf8)))
    let before = try PageTextLayout.build(pageID: pageID, in: graph)
    let abBefore = before.clusters.filter { $0.runIndex == 0 }.map(\.bounds)
    let efBefore = before.clusters.filter { $0.runIndex == 2 }.map(\.bounds)
    #expect(abBefore.count == 2 && efBefore.count == 2)

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 1, replacement: "CXD")]),
      to: graph)
    // "CD" (advance 20) to "CXD" (advance 30) widens by 10, so the -200
    // adjustment becomes +300; every other member is untouched.
    let members = try Self.tjMembers(in: edited, pageID: pageID)
    #expect(
      members == [
        .string(Data("AB".utf8)), .integer(-500), .string(Data("CXD".utf8)), .integer(300),
        .string(Data("EF".utf8)),
      ])
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    for (beforeBounds, afterBounds) in zip(
      abBefore, after.clusters.filter({ $0.runIndex == 0 }).map(\.bounds))
    {
      for (beforeValue, afterValue) in zip(beforeBounds, afterBounds) {
        #expect(abs(beforeValue - afterValue) < 0.001)
      }
    }
    for (beforeBounds, afterBounds) in zip(
      efBefore, after.clusters.filter({ $0.runIndex == 2 }).map(\.bounds))
    {
      for (beforeValue, afterValue) in zip(beforeBounds, afterBounds) {
        #expect(abs(beforeValue - afterValue) < 0.001)
      }
    }
  }

  @Test func replacementPreservesSurroundingTextState() throws {
    // P18-004: character/word spacing, rise, leading, and the font selection
    // surrounding the edited run survive the replacement byte-for-byte, and
    // the compensation accounts for the spacing when holding the following
    // run's position.
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(
        bytes: Data(
          "BT /F1 20 Tf 2 Tc 3 Tw 1 Ts 4 TL 42 710 Td [(AB) -500 (CD)] TJ ET\n".utf8)))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "A")]),
      to: graph)
    let raw = String(
      decoding: try PageContent.load(pageID: pageID, in: edited).bytes, as: UTF8.self)
    for fragment in ["2 Tc", "3 Tw", "1 Ts", "4 TL", "/F1 20 Tf"] {
      #expect(raw.contains(fragment))
    }
    // With Tc=2 the old "AB" advance is 24, the new "A" advance is 12, so the
    // -500 adjustment becomes -1100 and "CD" holds x=76; the rise puts the
    // first cluster's baseline at 711.
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    let first = after.clusters.filter { $0.runIndex == 0 }
    #expect(first.count == 1)
    #expect(first[0].bounds[1] == 711)
    let following = after.clusters.filter { $0.runIndex == 1 }
    #expect(following.count == 2)
    #expect(abs(following[0].bounds[0] - 76) < 0.001)
  }

  @Test func fallbackFontSubstitutesMissingGlyphs() throws {
    // P18-007: Helvetica has no fi ligature, so the DejaVu fallback program
    // is embedded and the target shows in it while the following run keeps
    // the original font and position.
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("Test font program is corrupt")
      return
    }
    let before = try PageTextLayout.build(pageID: pageID, in: graph)
    let cdBefore = before.clusters.filter { $0.runIndex == 1 }.map(\.bounds)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: pageID, runIndex: 0, replacement: "Aﬁ",
          fallbackFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      ]), to: graph)
    // The replacement extracts exactly through the fallback ToUnicode.
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    #expect(after.text(in: 0..<after.clusters.count) == "AﬁCD")
    // The following run holds its position under fallback compensation.
    let cdAfter = after.clusters.filter { $0.runIndex == 1 }.map(\.bounds)
    #expect(cdAfter.count == cdBefore.count)
    for (beforeBounds, afterBounds) in zip(cdBefore, cdAfter) {
      for (beforeValue, afterValue) in zip(beforeBounds, afterBounds) {
        #expect(abs(beforeValue - afterValue) < 0.001)
      }
    }
    // The font switch is visible in the bytes: the fallback selection plus
    // the restoring original selection around the rewritten instruction.
    let raw = String(
      decoding: try PageContent.load(pageID: pageID, in: edited).bytes, as: UTF8.self)
    #expect(raw.contains("SPDFF"))
    #expect(raw.components(separatedBy: "/F1 20 Tf").count - 1 == 2)
  }

  @Test func fallbackRefusesWhenCoverageIncomplete() throws {
    // P18-007: Cyrillic ER is in neither Helvetica nor the DejaVu subset, so
    // the fallback refuses naming the missing scalar; nothing substitutes.
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("Test font program is corrupt")
      return
    }
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(
            pageID: pageID, runIndex: 0, replacement: "A\u{041F}",
            fallbackFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
        ]), to: graph)
      Issue.record("uncovered fallback replacement was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("U+41F"))
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func fallbackWrapsSharedFontScope() throws {
    // P18-007: two runs sharing one font selection — replacing the first
    // with fallback text wraps only the target, so the following run keeps
    // the original font, decoded text and actual laid-out position.
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("BT /F1 20 Tf 42 710 Td (target) Tj (keep) Tj ET\n".utf8)))
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("Test font program is corrupt")
      return
    }
    let before = try PageTextLayout.build(pageID: pageID, in: graph)
    let keepBefore = before.clusters.filter { $0.runIndex == 1 }.map(\.bounds)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: pageID, runIndex: 0, replacement: "ﬁA",
          fallbackFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      ]), to: graph)
    let content = try PageContent.load(pageID: pageID, in: edited)
    let runs = try TextRunIndexer.runs(in: content, graph: edited)
    #expect(runs.count == 2)
    #expect(runs[0].text == "ﬁA")
    #expect(String(decoding: runs[0].fontResource.bytes, as: UTF8.self).hasPrefix("SPDFF"))
    #expect(runs[1].text == "keep")
    #expect(runs[1].fontResource == PDFName("F1"))
    // The follower keeps its laid-out position under the restored font.
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    let keepAfter = after.clusters.filter { $0.runIndex == 1 }.map(\.bounds)
    #expect(keepAfter.count == keepBefore.count)
    for (beforeBounds, afterBounds) in zip(keepBefore, keepAfter) {
      for (beforeValue, afterValue) in zip(beforeBounds, afterBounds) {
        #expect(abs(beforeValue - afterValue) < 0.001)
      }
    }
    // Original selection, fallback selection, restoring selection.
    let raw = String(decoding: content.bytes, as: UTF8.self)
    #expect(raw.components(separatedBy: "/F1 20 Tf").count - 1 == 2)
    #expect(raw.contains("SPDFF"))
  }

  @Test func overflowPreviewMeasuresBeforeCommitting() throws {
    // P18-011: the preview reports old/new advances, the overhang, and
    // whether it reaches following text — all without mutating.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let before = parsed.graph
    let fitting = try ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "A")
      .previewOverflow(in: parsed.graph)
    #expect(fitting.oldAdvance == 20)
    #expect(fitting.newAdvance == 10)
    #expect(fitting.overflow == 0)
    #expect(fitting.fits)
    #expect(!fitting.overlapsFollowingText)
    // "AXB" widens by 10 pt to x=72 where "CD" starts: past the box but
    // exactly touching, so no overlap.
    let touching = try ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "AXB")
      .previewOverflow(in: parsed.graph)
    #expect(touching.oldAdvance == 20)
    #expect(touching.newAdvance == 30)
    #expect(touching.overflow == 10)
    #expect(!touching.fits)
    #expect(!touching.overlapsFollowingText)
    // "AXXXXB" reaches well into "CD".
    let overlapping = try ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "AXXXXB")
      .previewOverflow(in: parsed.graph)
    #expect(overlapping.newAdvance == 60)
    #expect(overlapping.overflow == 40)
    #expect(!overlapping.fits)
    #expect(overlapping.overlapsFollowingText)
    // Nothing mutated by measuring.
    #expect(parsed.graph == before)
  }

  @Test func refusePolicyThrowsBeforeMutating() throws {
    // P18-010: under .refuse, a wider replacement throws showing the
    // measured overhang; fitting text still commits.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(
            pageID: pageID, runIndex: 0, replacement: "AXB", overflowPolicy: .refuse)
        ]), to: parsed.graph)
      Issue.record("overflowing replacement was accepted under .refuse")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("10"))
    } catch {
      Issue.record("wrong error type \(error)")
    }
    let fitting = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: pageID, runIndex: 0, replacement: "CD", overflowPolicy: .refuse)
      ]), to: parsed.graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: fitting)
    #expect(layout.text(in: 0..<layout.clusters.count).hasPrefix("CD"))
  }

  @Test func overflowPreviewCoversFallbackReplacements() throws {
    // P18-011 through the fallback path: advances come from the program's
    // own inspected widths without embedding anything.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("Test font program is corrupt")
      return
    }
    let report = try ReplaceTextCommand(
      pageID: pageID, runIndex: 0, replacement: "Aﬁ",
      fallbackFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      .previewOverflow(in: parsed.graph)
    // Inspector advances are raw font units (A 1401, ﬁ 1290 of 2048 upem).
    let expectedNew = Double(1401 + 1290) / 2048 * 20
    let expectedOverflow = ((expectedNew - 20) * 1000).rounded() / 1000
    #expect(report.oldAdvance == 20)
    #expect(abs(report.newAdvance - expectedNew) < 1e-9)
    #expect(abs(report.overflow - expectedOverflow) < 1e-9)
    #expect(!report.fits)
    // The 6.279 pt overhang ends at x≈68.3, short of "CD" at x=72.
    #expect(!report.overlapsFollowingText)
  }

  @Test func tjReplacementWithoutWidthsRefusesWhenTextFollows() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textEditPages())
    let pageID = parsed.pageIDs[0]
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 1, replacement: "Kernel")]),
        to: parsed.graph)
      Issue.record("TJ member replacement without width data was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func replacementPreservesFollowingGlyphPositions() throws {
    // P15-023: an appearance-oriented change (same font and size, narrower
    // replacement) keeps every following glyph where it was: the TJ
    // compensation is proven at the geometry level, not only the operand
    // level. Bounds agree within serialization rounding (adjustments round
    // to 0.001 text-space units), far below a point.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let before = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let cdBefore = before.clusters.filter { $0.runIndex == 1 }.map(\.bounds)
    #expect(cdBefore.count == 2)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "A")]),
      to: parsed.graph)
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    let cdAfter = after.clusters.filter { $0.runIndex == 1 }.map(\.bounds)
    #expect(cdAfter.count == cdBefore.count)
    for (beforeBounds, afterBounds) in zip(cdBefore, cdAfter) {
      for (beforeValue, afterValue) in zip(beforeBounds, afterBounds) {
        #expect(abs(beforeValue - afterValue) < 0.001)
      }
    }
    // Replacing the last member needs no compensation and leaves the
    // preceding run's glyphs exactly where they were.
    let lastEdited = try PDFEditingEngine.commit(
      PDFTransaction([ReplaceTextCommand(pageID: pageID, runIndex: 1, replacement: "CXD")]),
      to: parsed.graph)
    let lastAfter = try PageTextLayout.build(pageID: pageID, in: lastEdited)
    let abBefore = before.clusters.filter { $0.runIndex == 0 }.map(\.bounds)
    let abAfter = lastAfter.clusters.filter { $0.runIndex == 0 }.map(\.bounds)
    #expect(abAfter.count == abBefore.count)
    for (beforeBounds, afterBounds) in zip(abBefore, abAfter) {
      for (beforeValue, afterValue) in zip(beforeBounds, afterBounds) {
        #expect(abs(beforeValue - afterValue) < 0.001)
      }
    }
  }

  private static func tjMembers(in graph: PDFGraph, pageID: PDFObjectID) throws -> [PDFValue] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    guard let instruction = content.instructions.first(where: { $0.operatorName == "TJ" }),
      case .array(let members)? = instruction.operands.first?.value
    else {
      throw PDFError(.malformed, "TJ instruction missing")
    }
    return members
  }
}
