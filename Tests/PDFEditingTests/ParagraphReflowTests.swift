import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P19-007–P19-015: fixed-box reflow planning and application — line breaking
/// with punctuation rules, long-word policy, alignment/indent/spacing,
/// overflow choices, collision refusal, and preservation of other content.
@Suite("Paragraph reflow")
struct ParagraphReflowTests {
  private func fixture() -> PDFGraph {
    let lines: [(String, Double, Double, Double)] = [
      ("Quarterly Report", 42, 700, 24),
      ("First body line of the report.", 42, 660, 12),
      ("Second body line follows here.", 42, 640, 12),
      ("Third body line ends the block.", 42, 620, 12),
      ("Page 1", 500, 60, 12),
      ("Footer note at the bottom.", 42, 200, 12),
    ]
    var content = Data()
    for line in lines {
      content.append(
        Data("BT /F1 \(line.3) Tf \(line.1) \(line.2) Td (\(line.0)) Tj ET\n".utf8))
    }
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func paragraph(_ graph: PDFGraph, pageID: PDFObjectID) throws
    -> TextParagraphCandidate
  {
    let candidates = try ParagraphReconstruction.candidatesForEditing(pageID: pageID, in: graph)
    return try #require(candidates.first { $0.kind == .flowing })
  }

  private func measurementFonts(_ graph: PDFGraph, pageID: PDFObjectID) throws
    -> (SimpleFont, IndexedTextFont?)
  {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Fixture page is missing")
    }
    let simple = try #require(SimpleFont.resolve(resource: PDFName("F1"), page: page, in: graph))
    return (simple, IndexedTextFont.resolve(resource: PDFName("F1"), page: page, in: graph))
  }

  private func pageText(_ graph: PDFGraph, pageID: PDFObjectID) throws -> String {
    let content = try PageContent.load(pageID: pageID, in: graph)
    return try TextRunIndexer.runs(
      in: content, graph: graph, allowStandard14MetricFallback: true)
      .map(\.text).joined(separator: " ")
  }

  @Test func reflowReplacesParagraphAndPreservesOtherContent() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let replacement =
      "Replacement text long enough to wrap across several lines inside the paragraph box "
      + "while the rest of the page stays exactly as it was before the reflow."
    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph).plan
    #expect(plan.lines.count >= 4)
    #expect(plan.lines.map(\.text).joined(separator: " ").contains("Replacement text"))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: replacement)
      ]), to: graph)
    let text = try pageText(edited, pageID: pageID)
    #expect(text.contains("Replacement text"))
    #expect(text.contains("exactly as it was before"))
    #expect(text.contains("the reflow."))
    // Unrelated content is untouched.
    #expect(text.contains("Quarterly Report"))
    #expect(text.contains("Page 1"))
    #expect(!text.contains("Second body line"))
    // The reflowed paragraph survives a full write/reparse.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    let reparsedText = try pageText(reparsed.graph, pageID: reparsed.pageIDs[0])
    #expect(reparsedText.contains("Replacement text"))
    #expect(reparsedText.contains("Quarterly Report"))
  }

  @Test func lineBreakingHonorsPunctuationAndLongWords() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    // Closing punctuation stays with the previous line.
    let punctuation = "alpha beta gamma delta epsilon zeta eta theta iota kappa, lambda mu nu."
    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: punctuation, in: graph).plan
    for line in plan.lines {
      #expect(!line.text.hasPrefix(","))
      #expect(!line.text.hasPrefix("."))
    }
    // A word wider than the box is never split silently: allow reports
    // overflow, clip refuses.
    let longWord = String(repeating: "x", count: 120)
    let allowed = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: longWord, in: graph,
      options: ParagraphReflowOptions(overflow: .allow))
    #expect(allowed.plan.overflowed)
    #expect(allowed.plan.lines.count == 1)
    #expect(allowed.plan.warnings.contains { $0.contains("past the paragraph box") })
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: longWord,
            options: ParagraphReflowOptions(overflow: .clip))
        ]), to: graph)
    }
  }

  @Test func alignmentIndentAndSpacingArePlanned() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let (font, metrics) = try measurementFonts(graph, pageID: pageID)
    let replacement = "Alignment probe text that wraps into two or three lines."
    let centered = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: ParagraphReflowOptions(alignment: .center, lineSpacing: 30)).plan
    #expect(centered.lines.count >= 2)
    for line in centered.lines {
      let width = ParagraphReflow.advance(
        of: line.text, font: font, metrics: metrics, size: line.fontSize)
      let center = line.x + width / 2
      let boxCenter = (candidate.bounds[0] + candidate.bounds[2]) / 2
      #expect(abs(center - boxCenter) < 1)
    }
    let deltas = zip(centered.lines, centered.lines.dropFirst()).map { $0.y - $1.y }
    #expect(deltas.allSatisfy { abs($0 - 30) < 0.01 })

    let indented = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: ParagraphReflowOptions(alignment: .left, firstLineIndent: 30)).plan
    #expect(abs(indented.lines[0].x - (candidate.bounds[0] + 30)) < 0.01)
    #expect(abs(indented.lines[1].x - candidate.bounds[0]) < 0.01)

    let boxWidth = candidate.bounds[2] - candidate.bounds[0]
    let boundaryWord = (1...100).map { String(repeating: "x", count: $0) }.first { word in
      let width = ParagraphReflow.advance(
        of: word, font: font, metrics: metrics, size: 12)
      return width > boxWidth - 30 && width <= boxWidth
    }
    let word = try #require(boundaryWord)
    let unchangedPlan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: word, in: graph,
      options: ParagraphReflowOptions(alignment: .left)).plan
    let indentedPlan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: word, in: graph,
      options: ParagraphReflowOptions(alignment: .left, firstLineIndent: 30)).plan
    #expect(!unchangedPlan.overflowed)
    #expect(indentedPlan.overflowed)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: word,
            options: ParagraphReflowOptions(
              alignment: .left, firstLineIndent: 30, overflow: .clip))
        ]), to: graph)
    }
  }

  @Test func paragraphSpacingMovesBlockAndFollowingSameColumnText() throws {
    let graph = fixture()
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    let candidate = try paragraph(graph, pageID: pageID)
    let replacement = candidate.text.replacingOccurrences(of: "\n", with: " ")
      + String(repeating: " paragraph expansion", count: 10)
    let baseline = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: ParagraphReflowOptions(downstreamShift: true, maxDownstreamShift: 500)).plan
    let spacingOptions = ParagraphReflowOptions(
      additionalParagraphSpacingBefore: 12, additionalParagraphSpacingAfter: 8,
      maxDownstreamShift: 500)
    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: spacingOptions).plan

    #expect(plan.lines.count == baseline.lines.count)
    for (line, original) in zip(plan.lines, baseline.lines) {
      #expect(abs(line.y - (original.y - 12)) < 0.01)
    }
    #expect(baseline.downstreamDelta > 0)
    #expect(abs(plan.downstreamDelta - (baseline.downstreamDelta + 20)) < 0.01)
    let sourceRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    let footerIndex = try #require(
      sourceRuns.firstIndex { $0.text.contains("Footer note at the bottom.") })
    #expect(
      plan.downstreamText.contains {
        $0.runIndex == footerIndex
          && abs($0.y - (200 - plan.downstreamDelta)) < 0.01
      })

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: replacement,
          options: spacingOptions)
      ]), to: graph)
    let editedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: edited), graph: edited)
    let footer = try #require(editedRuns.first { $0.text.contains("Footer note at the bottom.") })
    #expect(abs(footer.baselineY - (200 - plan.downstreamDelta)) < 0.01)

    let shiftedPastBox = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: "A short line", in: graph,
      options: ParagraphReflowOptions(
        additionalParagraphSpacingBefore: 100, overflow: .allow)).plan
    #expect(shiftedPastBox.overflowed)
    #expect(shiftedPastBox.warnings.contains { $0.contains("past the paragraph box") })
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: "A short line",
            options: ParagraphReflowOptions(
              additionalParagraphSpacingBefore: 100, overflow: .clip))
        ]), to: graph)
    }
  }

  @Test func justifiedAlignmentFillsNonfinalLinesAndKeepsFinalLineNatural() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let replacement =
      "Alpha beta gamma supercalifragilisticexpialidocious delta epsilon zeta eta theta iota kappa lambda."
    let options = ParagraphReflowOptions(alignment: .justified)
    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: options).plan

    #expect(plan.lines.count >= 2)
    #expect(!plan.warnings.contains { $0.contains("falls back to left") })
    let expandedLines = plan.lines.dropLast().filter { $0.segments.count > 1 }
    #expect(!expandedLines.isEmpty)
    for line in expandedLines {
      #expect(line.segments.map(\.text).joined() == line.text)
      let lastSegment = try #require(line.segments.last)
      let rightEdge = lastSegment.x + lastSegment.width
      #expect(abs(rightEdge - candidate.bounds[2]) < 0.01)
    }
    let finalLine = try #require(plan.lines.last)
    #expect(finalLine.segments.count == 1)

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: replacement, options: options)
      ]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(edited))
    let savedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: reparsed.pageIDs[0], in: reparsed.graph),
      graph: reparsed.graph)
    let savedStreamText = savedRuns.map(\.text).joined()
    for line in plan.lines where !line.text.isEmpty {
      #expect(savedStreamText.contains(line.text))
    }
  }

  @Test func overflowChoicesAreExplicit() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let longText = Array(repeating: "wrap", count: 22).joined(separator: " ")
    // The box fits three lines; this text needs many more.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: longText,
            options: ParagraphReflowOptions(overflow: .clip))
        ]), to: graph)
    }
    let allowed = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: longText, in: graph,
      options: ParagraphReflowOptions(overflow: .allow)).plan
    #expect(allowed.overflowed)
    #expect(allowed.lines.count > 3)
    let shrunk = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: longText, in: graph,
      options: ParagraphReflowOptions(overflow: .shrinkToFit)).plan
    #expect(shrunk.fontSize < candidate.fontSize)
    #expect(shrunk.fontSize >= 4)
  }

  @Test func collisionsAreRefusedUnlessAllowed() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let replacement = Array(repeating: "collision", count: 40).joined(separator: " ")
    // Large spacing drives the planned lines into the footer's bounds.
    let colliding = ParagraphReflowOptions(lineSpacing: 65, overflow: .allow)
    let result = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: colliding)
    #expect(!result.collisions.isEmpty)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: replacement,
            options: colliding)
        ]), to: graph)
    }
    let allowed = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: replacement,
          options: ParagraphReflowOptions(
            lineSpacing: 65, overflow: .allow, allowCollisions: true))
      ]), to: graph)
    #expect(try pageText(allowed, pageID: pageID).contains("collision"))
  }

  @Test func lowConfidenceParagraphsAreRefusedUnlessConfirmed() throws {
    // A label-shaped candidate has a low confidence and is refused by default.
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let label = try #require(
      try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
        .first { $0.kind == .label })
    #expect(label.confidence < 0.6)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: label, replacement: "Confirmed label")
        ]), to: graph)
    }
    // Confirmed reflows succeed; without spans the original style is kept.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: label, replacement: "Confirmed label",
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: graph)
    // The label's narrow box wraps the replacement; the words are present.
    let labelText = try pageText(edited, pageID: pageID)
    #expect(labelText.contains("Confirmed"))
    #expect(labelText.contains("label"))
  }

  @Test func lowConfidencePreservesOriginalLineStyles() throws {
    // Two original lines with distinct styles; a low-confidence candidate
    // keeps those styles when the replacement is distributed.
    var content = Data()
    content.append(
      Data("BT /F1 12 Tf 42 660 Td (Plain first line) Tj ET\n".utf8))
    content.append(
      Data("BT /F2 12 Tf 1 0 0 rg 42 640 Td (Red second line) Tj ET\n".utf8))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([
              PDFName("F1"): .reference(PDFObjectID(3)),
              PDFName("F2"): .reference(PDFObjectID(6)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    // A synthetic low-confidence candidate over the two lines.
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let base = try #require(candidates.first { $0.lineIndices.count == 2 })
    let low = TextParagraphCandidate(
      kind: base.kind, lineIndices: base.lineIndices, runIndices: base.runIndices,
      lineRunIndices: base.lineRunIndices, runStyles: base.runStyles,
      clusterRange: base.clusterRange, text: base.text, bounds: base.bounds,
      fontSize: base.fontSize, alignment: base.alignment,
      firstLineIndent: base.firstLineIndent, lineSpacing: base.lineSpacing, confidence: 0.4,
      structureRole: base.structureRole)
    let result = try ParagraphReflow.plan(
      pageID: pageID, candidate: low,
      replacement: "First chunk words here second chunk words there", in: graph,
      options: ParagraphReflowOptions(allowLowConfidence: true))
    // The replacement is distributed over the original lines' styles: the red
    // style (index 1) appears in the plan.
    #expect(result.plan.lines.contains { line in
      line.segments.contains { $0.styleIndex == 1 }
    })
    #expect(result.plan.styles.count == 2)
  }

  @Test func refusedReflowsLeaveTheDocumentUntouched() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let before = try PageContent.load(pageID: pageID, in: graph).segments[0].decoded
    // Clip refusal and collision refusal both leave the input graph alone.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate,
            replacement: Array(repeating: "wrap", count: 60).joined(separator: " "),
            options: ParagraphReflowOptions(overflow: .clip))
        ]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate,
            replacement: Array(repeating: "collision", count: 40).joined(separator: " "),
            options: ParagraphReflowOptions(lineSpacing: 65, overflow: .allow))
        ]), to: graph)
    }
    let after = try PageContent.load(pageID: pageID, in: graph).segments[0].decoded
    #expect(before == after)
  }

  @Test func reflowDoesNotShiftOtherColumnsOrImages() throws {
    // Two columns plus an image: reflowing the left paragraph must leave the
    // right column's runs and the image draw byte-identical.
    var content = Data()
    content.append(Data("BT /F1 12 Tf 42 660 Td (Left column line one) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 640 Td (Left column line two) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 340 600 Td (Right column text) Tj ET\n".utf8))
    content.append(Data("q 100 0 0 100 340 400 cm /Im1 Do Q\n".utf8))
    let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(6): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: green)),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))]),
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let left = try #require(
      candidates.first { $0.kind == .flowing && $0.bounds[0] < 200 })
    let runsBefore = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    let rightBefore = runsBefore.filter { $0.text.contains("Right column") }
      .map { $0.text }
    let imageBefore = try PageContent.load(pageID: pageID, in: graph)
      .instructions.filter { $0.operatorName == "Do" }
      .map { $0.operands.map(\.value) }

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: left,
          replacement: "Reflowed left column text that wraps a little further.")
      ]), to: graph)
    let editedContent = try PageContent.load(pageID: pageID, in: edited)
    let runsAfter = try TextRunIndexer.runs(in: editedContent, graph: edited)
    let rightAfter = runsAfter.filter { $0.text.contains("Right column") }
      .map { $0.text }
    #expect(rightAfter == rightBefore)
    let imageAfter = editedContent.instructions.filter { $0.operatorName == "Do" }
      .map { $0.operands.map(\.value) }
    #expect(imageAfter == imageBefore)
    let text = try pageText(edited, pageID: pageID)
    #expect(text.contains("Right column text"))
    // Wrapped lines drop the joining space in the concatenated extraction.
    #expect(text.contains("Reflowed"))
    #expect(text.contains("further."))
  }

  @Test func TJArrayRunsAreRefused() throws {
    // A paragraph whose text sits inside a TJ array is refused explicitly.
    var content = Data()
    content.append(Data("BT /F1 12 Tf 42 660 Td [(Hello) -200 (World)] TJ ET\n".utf8))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let candidate = try #require(candidates.first)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(pageID: pageID, candidate: candidate, replacement: "nope")
        ]), to: graph)
    }
  }

  @Test func multiRunStylesArePreserved() throws {
    // A paragraph with two inline styles: black regular and red bold.
    var content = Data()
    content.append(
      Data(
        "BT /F1 12 Tf 42 660 Td (Regular ) Tj /F2 12 Tf 1 0 0 rg (Bold) Tj ET\n".utf8))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica-Bold")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([
              PDFName("F1"): .reference(PDFObjectID(3)),
              PDFName("F2"): .reference(PDFObjectID(6)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try #require(
      try ParagraphReconstruction.candidates(pageID: pageID, in: graph).first)
    #expect(candidate.runStyles.count == 2)
    #expect(candidate.runStyles[1].fontResource == "F2")
    #expect(candidate.runStyles[1].fillColor == [1, 0, 0])
    #expect(candidate.lineRunIndices == [[0, 1]])

    let spans = [
      ParagraphSpan(text: "New", styleIndex: 0),
      ParagraphSpan(text: "Bold", styleIndex: 1),
    ]
    let result = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: "", in: graph,
      options: ParagraphReflowOptions(spans: spans, allowLowConfidence: true))
    let firstLine = try #require(result.plan.lines.first)
    #expect(firstLine.segments.count == 2)
    #expect(firstLine.segments[0].styleIndex == 0)
    #expect(firstLine.segments[1].styleIndex == 1)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: "",
          options: ParagraphReflowOptions(spans: spans, allowLowConfidence: true))
      ]), to: graph)
    let editedContent = try PageContent.load(pageID: pageID, in: edited)
    let stream = String(decoding: editedContent.segments[0].decoded, as: UTF8.self)
    #expect(stream.contains("/F2"))
    #expect(stream.contains("1 0 0 rg"))
    let text = try pageText(edited, pageID: pageID)
    #expect(text.contains("New"))
    #expect(text.contains("Bold"))
  }

  @Test func combiningMarksStayWithTheirBase() throws {
    // A combining mark that would start a token attaches to the previous one.
    let paragraphs = ParagraphReflow.tokenParagraphs(spans: [
      ParagraphSpan(text: "ab", styleIndex: 0),
      ParagraphSpan(text: "\u{0301}cd ef", styleIndex: 0),
    ])
    #expect(paragraphs.count == 1)
    let tokens = try #require(paragraphs.first)
    #expect(tokens.map(\.text) == ["ab\u{0301}cd", "ef"])
  }

  @Test func explicitLineBreaksSurviveRepeatEditAfterReopen() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let replacement = "First authored line\nSecond authored line"

    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph).plan
    #expect(plan.lines.map(\.text) == ["First authored line", "Second authored line"])
    #expect(abs((plan.lines[0].y - plan.lines[1].y) - candidate.lineSpacing) < 0.01)

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: replacement)
      ]), to: graph)
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    let reopenedPageID = try PDFPageTree.pageIDs(in: reparsed.graph)[0]
    let reopenedText = try pageText(reparsed.graph, pageID: reopenedPageID)
    #expect(reopenedText.contains("First authored line"))
    #expect(reopenedText.contains("Second authored line"))
    let reopenedCandidate = try paragraph(reparsed.graph, pageID: reopenedPageID)
    #expect(reopenedCandidate.text == replacement)

    let revisedReplacement = "First revised line\nSecond authored line"
    let repeatedPlan = try ParagraphReflow.plan(
      pageID: reopenedPageID, candidate: reopenedCandidate,
      replacement: revisedReplacement, in: reparsed.graph).plan
    #expect(repeatedPlan.lines.map(\.text) == ["First revised line", "Second authored line"])

    let repeatedEdit = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: reopenedPageID, candidate: reopenedCandidate,
          replacement: revisedReplacement)
      ]), to: reparsed.graph)
    let repeatedReparse = try PDFParser.parse(try PDFWriter.write(repeatedEdit))
    let repeatedPageID = try PDFPageTree.pageIDs(in: repeatedReparse.graph)[0]
    let finalCandidate = try paragraph(repeatedReparse.graph, pageID: repeatedPageID)
    #expect(finalCandidate.text == revisedReplacement)
  }

  @Test func sourceMapMapsNewSegmentsToRuns() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try paragraph(graph, pageID: pageID)
    let result = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate,
      replacement: "Source map probe text that wraps onto another line.", in: graph)
    #expect(!result.plan.sourceMap.isEmpty)
    // The first line maps back to the original first line's runs.
    let firstEntry = try #require(result.plan.sourceMap.first)
    #expect(firstEntry.lineIndex == 0)
    #expect(firstEntry.sourceRunIndices == candidate.lineRunIndices[0])
    // Appended lines fall back to style-matched runs of the paragraph.
    let appended = result.plan.sourceMap.filter { $0.lineIndex > 0 }
    #expect(!appended.isEmpty)
    #expect(appended.allSatisfy { !$0.sourceRunIndices.isEmpty })
    #expect(
      appended.allSatisfy { source in
        source.sourceRunIndices.allSatisfy { candidate.runIndices.contains($0) }
      })
  }

  @Test func longMixedAndNonLatinTextReflow() throws {
    // A ToUnicode font maps ASCII codes to Greek letters; reflow must encode
    // through the reverse CMap and stay one-to-one (no complex shaping).
    var cmap = """
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /CMapName /F1-UCS2 def
      /CMapType 2 def
      1 begincodespacerange
      <41> <5A>
      endcodespacerange
      26 beginbfchar

      """
    for code in 65...90 {
      let greek = 0x3B1 + (code - 65)
      cmap += String(format: "<%02X> <%04X>\n", code, greek)
    }
    cmap += """
      endbfchar
      endcmap
      CMapName currentdict /CMap defineresource pop
      end
      end

      """
    var content = Data()
    content.append(Data("BT /F1 12 Tf 42 660 Td (ABCDEF) Tj ET\n".utf8))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("ToUnicode"): .reference(PDFObjectID(6)),
        ]),
        PDFObjectID(6): .stream(PDFStream(bytes: Data(cmap.utf8))),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try #require(
      try ParagraphReconstruction.candidates(pageID: pageID, in: graph).first)
    // The original text decodes through ToUnicode as Greek.
    #expect(candidate.text == "αβγδεζ")

    // A long Greek replacement reflows across many lines and round-trips.
    let words = Array(repeating: "αβγ", count: 60).joined(separator: " ")
    let result = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: words, in: graph,
      options: ParagraphReflowOptions(overflow: .allow, allowLowConfidence: true))
    #expect(result.plan.lines.count > 3)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: words,
          options: ParagraphReflowOptions(overflow: .allow, allowLowConfidence: true))
      ]), to: graph)
    let text = try pageText(edited, pageID: pageID)
    // Line breaks drop the space in the concatenated extraction, so count the
    // word itself rather than space-separated chunks.
    #expect(text.components(separatedBy: "αβγ").count - 1 == 60)
    // Mixed styles plus non-Latin text are refused when unencodable.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: "汉字 text")
        ]), to: graph)
    }
  }
}
