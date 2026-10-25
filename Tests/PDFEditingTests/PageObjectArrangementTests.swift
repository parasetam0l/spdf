import CoreGraphics
import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// IMG-04/IMG-05 evidence: group transforms, duplicate/delete, align and
/// distribute, paint-order changes, grouping and the declared-profile refusals.
@Suite("Page-object arrangement")
struct PageObjectArrangementTests {
  // MARK: - IMG-04 group transforms

  @Test func mixedMoveKeepsRelationshipsAndReopensInPlace() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let secondPage = parsed.pageIDs[1]
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, x: 360, baseline: 320, text: "Mixed move"),
        AddImageStampCommand(
          pageID: pageID, rect: [300, 400, 340, 430], width: 2, height: 2,
          rgb8: Data(repeating: 90, count: 12)),
        authoredTextCommand(pageID: pageID, x: 360, baseline: 200, text: "Unselected"),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let documentImage = try #require(refs.first { $0.kind == .documentImage })
    let textBox = try #require(refs.first {
      $0.kind == .authoredTextBox && $0.bounds[1] > 250
    })
    let stamp = try #require(refs.first { $0.kind == .imageStamp })
    let untouched = try #require(refs.first {
      $0.kind == .authoredTextBox && $0.bounds[1] < 250
    })
    let selection = try PageObjectSelection.make([documentImage, textBox, stamp])
    #expect(selection.isMixed)
    #expect(selection.count == 3)

    let before = Dictionary(uniqueKeysWithValues: selection.members.map {
      ($0.identity, $0.bounds)
    })
    let untouchedStream = try #require(untouched.streamID)
    let untouchedObject = graph.objects[untouchedStream]
    let untouchedBounds = untouched.bounds
    let secondPageObject = graph.objects[secondPage]
    let gapBefore = textBox.bounds[0] - stamp.bounds[2]

    let commands = try PageObjectArrangement.moveCommands(
      selection, dx: 12, dy: -7, in: graph)
    #expect(commands.count == 3)
    let moved = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)

    let movedRefs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: moved)
    for (identity, bounds) in before {
      let after = try #require(movedRefs.first { $0.identity == identity })
      #expect(abs(after.bounds[0] - (bounds[0] + 12)) < 1e-6)
      #expect(abs(after.bounds[1] - (bounds[1] - 7)) < 1e-6)
    }
    let movedTextBox = try #require(movedRefs.first { $0.identity == textBox.identity })
    let movedStamp = try #require(movedRefs.first { $0.identity == stamp.identity })
    #expect(abs((movedTextBox.bounds[0] - movedStamp.bounds[2]) - gapBefore) < 1e-6)
    // Unrelated content and pages are untouched by the group move.
    #expect(moved.objects[untouchedStream] == untouchedObject)
    #expect(movedRefs.first { $0.identity == untouched.identity }?.bounds == untouchedBounds)
    #expect(moved.objects[secondPage] == secondPageObject)

    // The moved objects stay selectable at their new positions after reopen.
    let reopened = try PDFParser.parse(PDFWriter.write(moved)).graph
    let reopenedRefs = try PageObjectSelectionProfile.selectable(
      pageID: pageID, in: reopened)
    for (identity, bounds) in before {
      let after = try #require(reopenedRefs.first { $0.identity == identity })
      #expect(abs(after.bounds[0] - (bounds[0] + 12)) < 1e-6)
      #expect(abs(after.bounds[1] - (bounds[1] - 7)) < 1e-6)
    }
  }

  @Test func textBoxMoveRewritesPaintAndMetadataOnly() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, x: 100, baseline: 300, text: "Hello box"),
        authoredTextCommand(pageID: pageID, x: 100, baseline: 150, text: "Second box"),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    #expect(refs.count == 2)
    let first = refs[0]
    let second = refs[1]
    let streamID = try #require(first.streamID)
    let secondStreamID = try #require(second.streamID)
    let beforeDictionary = try #require(PageObjectContent.streamDictionary(streamID, in: graph))
    let beforeInstructionBytes = try streamBytes(streamID, in: graph)
    let secondObject = graph.objects[secondStreamID]

    let selection = try PageObjectSelection.make([first])
    let commands = try PageObjectArrangement.moveCommands(selection, dx: 7, dy: -3, in: graph)
    #expect(commands.count == 1)
    let moved = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)

    let afterDictionary = try #require(
      PageObjectContent.streamDictionary(streamID, in: moved))
    let boxBefore = try #require(rectangleValues(beforeDictionary))
    let boxAfter = try #require(rectangleValues(afterDictionary))
    #expect(abs(boxAfter[0] - (boxBefore[0] + 7)) < 1e-6)
    #expect(abs(boxAfter[1] - (boxBefore[1] - 3)) < 1e-6)
    #expect(abs(boxAfter[2] - boxBefore[2]) < 1e-6)
    let lineBefore = try #require(lineValues(beforeDictionary))
    let lineAfter = try #require(lineValues(afterDictionary))
    #expect(abs(lineAfter.0 - (lineBefore.0 + 7)) < 1e-6)
    #expect(abs(lineAfter.1 - (lineBefore.1 - 3)) < 1e-6)
    let instructions = try AddedGraphics.decodedInstructions(streamID: streamID, in: moved)
    let tm = try #require(instructions.last { $0.operatorName == "Tm" })
    let values = tm.operands.compactMap { PageObjectContent.geometryNumber($0.value) }
    #expect(values.count == 6)
    #expect(abs(values[4] - 107) < 0.01)
    #expect(abs(values[5] - 297) < 0.01)
    let textOperand = try #require(
      instructions.first { $0.operatorName == "Tj" }?.operands.first)
    #expect(textOperand.value == .string(Data("Hello box".utf8)))
    // The moved box stream changed only geometry; its text and dictionary keys
    // are preserved. The second box and the native page stream are untouched.
    #expect(
      try streamBytes(streamID, in: moved) != beforeInstructionBytes)
    #expect(moved.objects[secondStreamID] == secondObject)

    let reopened = try PDFParser.parse(PDFWriter.write(moved))
    let reopenedRefs = try PageObjectSelectionProfile.selectable(
      pageID: pageID, in: reopened.graph)
    let reopenedFirst = try #require(reopenedRefs.first { $0.identity == first.identity })
    #expect(abs(reopenedFirst.bounds[0] - (first.bounds[0] + 7)) < 1e-6)
    #expect(abs(reopenedFirst.bounds[1] - (first.bounds[1] - 3)) < 1e-6)
  }

  @Test func mixedGroupResizeStaysUniformForTextBoxes() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, x: 100, baseline: 300, text: "Scale me"),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 120, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let box = refs[0]
    let rectangle = refs[1]
    let selection = try PageObjectSelection.make([box, rectangle])
    let group = try #require(selection.bounds)
    let destination = [
      group[0], group[1], group[0] + (group[2] - group[0]) * 2,
      group[1] + (group[3] - group[1]) * 2,
    ]
    let commands = try PageObjectArrangement.resizeCommands(
      selection, from: group, to: destination, in: graph)
    #expect(commands.count == 2)
    let resized = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    let resizedRefs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: resized)
    for member in selection.members {
      let transform = try #require(
        PageObjectRects.mapping(member: member.bounds, from: group, to: destination))
      let after = try #require(resizedRefs.first { $0.identity == member.identity })
      let expectedMinX = member.bounds[0] + transform.dx
      let expectedMinY = member.bounds[1] + transform.dy
      let expectedWidth = (member.bounds[2] - member.bounds[0]) * transform.scaleX
      let expectedHeight = (member.bounds[3] - member.bounds[1]) * transform.scaleY
      #expect(abs(after.bounds[0] - expectedMinX) < 1e-5)
      #expect(abs(after.bounds[1] - expectedMinY) < 1e-5)
      #expect(abs((after.bounds[2] - after.bounds[0]) - expectedWidth) < 1e-5)
      #expect(abs((after.bounds[3] - after.bounds[1]) - expectedHeight) < 1e-5)
    }
    // The text box keeps a uniform font scale: 12 pt becomes 24 pt and the
    // authored wrapping width doubles with it.
    let boxStream = try #require(box.streamID)
    let instructions = try AddedGraphics.decodedInstructions(streamID: boxStream, in: resized)
    #expect(abs((PageObjectContent.textSize(instructions: instructions) ?? 0) - 24) < 1e-6)
    let dictionary = try #require(PageObjectContent.streamDictionary(boxStream, in: resized))
    let boxAfter = try #require(rectangleValues(dictionary))
    #expect(abs(boxAfter[2] - 320) < 1e-5)

    // A non-uniform group resize that includes a text box is refused before
    // any command runs.
    let skewed = [
      group[0], group[1], group[0] + (group[2] - group[0]) * 2,
      group[1] + (group[3] - group[1]) * 3,
    ]
    #expect(throws: PDFError.self) {
      _ = try PageObjectArrangement.resizeCommands(
        selection, from: group, to: skewed, in: graph)
    }
  }

  @Test func graphicsOnlyGroupResizeSupportsIndependentAxes() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([20, 20, 60, 60]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [100, 40, 140, 80], width: 2, height: 2,
          rgb8: Data(repeating: 30, count: 12)),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let selection = try PageObjectSelection.make(refs)
    let group = try #require(selection.bounds)
    let destination = [
      group[0], group[1], group[0] + (group[2] - group[0]) * 2,
      group[1] + (group[3] - group[1]) * 0.5,
    ]
    let commands = try PageObjectArrangement.resizeCommands(
      selection, from: group, to: destination, in: graph)
    // The rectangle's mapped origin is unchanged, so only its scale command is
    // emitted; the stamp needs both a move and a scale.
    #expect(commands.count == 3)
    let resized = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    let resizedRefs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: resized)
    for member in selection.members {
      let transform = try #require(
        PageObjectRects.mapping(member: member.bounds, from: group, to: destination))
      let after = try #require(resizedRefs.first { $0.identity == member.identity })
      #expect(abs(after.bounds[0] - (member.bounds[0] + transform.dx)) < 1e-5)
      #expect(abs(after.bounds[1] - (member.bounds[1] + transform.dy)) < 1e-5)
      #expect(
        abs(
          (after.bounds[2] - after.bounds[0])
            - (member.bounds[2] - member.bounds[0]) * transform.scaleX) < 1e-5)
      #expect(
        abs(
          (after.bounds[3] - after.bounds[1])
            - (member.bounds[3] - member.bounds[1]) * transform.scaleY) < 1e-5)
    }
  }

  // MARK: - IMG-05 align and distribute

  @Test func alignAndDistributeMoveOnlyTheSelectedObjects() throws {
    let built = try threeRectanglesWithBystander()
    let graph = built.graph
    let pageID = built.pageID
    let refs = built.refs
    let selection = try PageObjectSelection.make(Array(refs.prefix(3)))
    let bystander = refs[3]
    let bystanderStream = try #require(bystander.streamID)
    let bystanderObject = graph.objects[bystanderStream]

    let leftAligned = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.alignCommands(selection, alignment: .left, in: graph)),
      to: graph)
    var alignedRefs = try PageObjectSelectionProfile.selectable(
      pageID: pageID, in: leftAligned)
    let leftEdges = alignedRefs.prefix(3).map { $0.bounds[0] }
    #expect(leftEdges.allSatisfy { abs($0 - 10) < 1e-6 })
    #expect(alignedRefs[3].bounds == bystander.bounds)
    #expect(leftAligned.objects[bystanderStream] == bystanderObject)

    // Re-resolve the selection after the commit: arrangement commands always
    // use the current page-space bounds.
    let leftSelection = try PageObjectSelection.make(Array(
      alignedRefs.prefix(3)))
    let rightAligned = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.alignCommands(
          leftSelection, alignment: .right, in: leftAligned)),
      to: leftAligned)
    alignedRefs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: rightAligned)
    let rightEdges = alignedRefs.prefix(3).map { $0.bounds[2] }
    #expect(rightEdges.allSatisfy { abs($0 - rightEdges[0]) < 1e-6 })
    #expect(abs(rightEdges[0] - 50) < 1e-6)

    // Aligning to the page uses the media box, not the selection bounds.
    let pageBuilt = try threeRectanglesWithBystander()
    let pageSelection = try PageObjectSelection.make(Array(pageBuilt.refs.prefix(3)))
    let pageAligned = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.alignCommands(
          pageSelection, alignment: .right, reference: .page, in: pageBuilt.graph)),
      to: pageBuilt.graph)
    let media = try #require(
      try mediaBox(pageID: pageBuilt.pageID, in: pageAligned))
    let pageEdges = try PageObjectSelectionProfile.selectable(
      pageID: pageBuilt.pageID, in: pageAligned).prefix(3).map { $0.bounds[2] }
    #expect(pageEdges.allSatisfy { abs($0 - media[2]) < 1e-6 })

    // Equal-gap horizontal distribution keeps the outer objects fixed.
    let distributedBuilt = try threeRectanglesWithBystander()
    let distributedSelection = try PageObjectSelection.make(
      Array(distributedBuilt.refs.prefix(3)))
    let distributed = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.distributeCommands(
          distributedSelection, axis: .horizontal, in: distributedBuilt.graph)),
      to: distributedBuilt.graph)
    let distributedRefs = try PageObjectSelectionProfile.selectable(
      pageID: distributedBuilt.pageID, in: distributed)
    let widths = distributedRefs.prefix(3).map { $0.bounds[2] - $0.bounds[0] }
    let gaps = (1..<3).map { index in
      distributedRefs[index].bounds[0] - distributedRefs[index - 1].bounds[2]
    }
    #expect(abs(gaps[0] - gaps[1]) < 1e-6)
    #expect(abs(distributedRefs[0].bounds[0] - 10) < 1e-6)
    #expect(abs(distributedRefs[2].bounds[2] - 230) < 1e-6)
    #expect(abs(widths[0] - 20) < 1e-6 && abs(widths[1] - 40) < 1e-6)

    // Two objects have no interior spacing to distribute.
    let pair = try PageObjectSelection.make(Array(distributedBuilt.refs.prefix(2)))
    #expect(throws: PDFError.self) {
      _ = try PageObjectArrangement.distributeCommands(
        pair, axis: .horizontal, in: distributedBuilt.graph)
    }
  }

  @Test func arrangementMathIsFiniteAndRefusesInvalidInput() throws {
    let group = [0.0, 0.0, 100.0, 100.0]
    let destination = [0.0, 0.0, 200.0, 50.0]
    let transform = try #require(
      PageObjectRects.mapping(member: [10, 10, 30, 30], from: group, to: destination))
    #expect(abs(transform.scaleX - 2) < 1e-9)
    #expect(abs(transform.scaleY - 0.5) < 1e-9)
    #expect(abs(transform.dx - 10) < 1e-9)
    #expect(abs(transform.dy + 5) < 1e-9)
    #expect(!transform.isIdentity)
    #expect(PageObjectRects.mapping(member: [0, 0, 1, 1], from: [0, 0, 0, 10], to: group) == nil)
    #expect(PageObjectRects.mapping(member: [0, 0, 1, 1], from: group, to: group) != nil)

    let rects = [[10.0, 0, 30, 20], [100, 0, 140, 20], [200, 0, 230, 20]]
    let deltas = try #require(
      PageObjectArrangementMath.distributionDeltas(rects: rects, axis: .horizontal))
    #expect(deltas.allSatisfy { $0.allSatisfy(\.isFinite) })
    #expect(abs(deltas[0][0]) < 1e-9 && abs(deltas[2][0]) < 1e-9)
    let aligned = try #require(
      PageObjectArrangementMath.alignmentDeltas(
        rects: rects, alignment: .middle, reference: [0, 0, 300, 100]))
    #expect(abs((rects[0][1] + aligned[0][1]) - 40) < 1e-9)
    #expect(PageObjectArrangementMath.distributionDeltas(rects: Array(rects.prefix(2)),
      axis: .horizontal) == nil)
    #expect(PageObjectArrangementMath.alignmentDeltas(
      rects: [[0, 0, Double.nan, 1]], alignment: .left, reference: [0, 0, 10, 10]) == nil)
    #expect(PageObjectRects.union([[0, 0, 10, 10], [20, 20, 30, 30]]) == [0, 0, 30, 30])
    #expect(PageObjectRects.union([]) == nil)
  }

  // MARK: - Duplicate / delete / reorder / group

  @Test func duplicateAndDeleteKeepOriginalContentIntact() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, x: 100, baseline: 300, text: "Copy me"),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 120, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    #expect(refs.count == 2)
    let selection = try PageObjectSelection.make(refs)
    let originalIdentities = Set(selection.members.map(\.identity))
    let originalBytes = try PDFWriter.write(graph)

    let duplicateCommands = try PageObjectArrangement.duplicateCommands(
      selection, offsetX: 14, offsetY: -14, in: graph)
    #expect(duplicateCommands.count == 1)
    let duplicated = try PDFEditingEngine.commit(
      PDFTransaction(duplicateCommands), to: graph)
    let duplicatedRefs = try PageObjectSelectionProfile.selectable(
      pageID: pageID, in: duplicated)
    #expect(duplicatedRefs.count == 4)
    let clones = duplicatedRefs.filter { !originalIdentities.contains($0.identity) }
    #expect(clones.count == 2)
    for clone in clones {
      let original = try #require(
        selection.members.first { $0.kind == clone.kind && $0.groupID == nil }
      )
      let source = try #require(
        refs.first { $0.kind == clone.kind })
      #expect(abs(clone.bounds[0] - (source.bounds[0] + 14)) < 1e-5)
      #expect(abs(clone.bounds[1] - (source.bounds[1] - 14)) < 1e-5)
      #expect(original.kind == clone.kind)
    }
    // The copied text box keeps its authored geometry and text.
    let cloneBox = try #require(clones.first { $0.kind == .authoredTextBox })
    let cloneStream = try #require(cloneBox.streamID)
    let cloneDictionary = try #require(
      PageObjectContent.streamDictionary(cloneStream, in: duplicated))
    let cloneBoxValues = try #require(rectangleValues(cloneDictionary))
    #expect(abs(cloneBoxValues[0] - 114) < 1e-5)
    #expect(abs(cloneBoxValues[1] - 286) < 1e-5)
    let cloneInstructions = try AddedGraphics.decodedInstructions(
      streamID: cloneStream, in: duplicated)
    #expect(cloneInstructions.contains { instruction in
      instruction.operatorName == "Tj"
        && instruction.operands.first?.value == .string(Data("Copy me".utf8))
    })

    let cloneSelection = try PageObjectSelection.make(clones)
    let deleteCommands = try PageObjectArrangement.deleteCommands(
      cloneSelection, in: duplicated)
    let deleted = try PDFEditingEngine.commit(PDFTransaction(deleteCommands), to: duplicated)
    let remaining = try PageObjectSelectionProfile.selectable(pageID: pageID, in: deleted)
    #expect(remaining.count == 2)
    for member in selection.members {
      let after = try #require(remaining.first { $0.identity == member.identity })
      #expect(after.bounds == member.bounds)
    }
    let deletedBytes = try PDFWriter.write(deleted)
    #expect(deletedBytes != originalBytes)
    let reopened = try PDFParser.parse(PDFWriter.write(deleted))
    #expect(
      try PageObjectSelectionProfile.selectable(pageID: pageID, in: reopened.graph).count == 2)
    #expect(throws: PDFError.self) {
      _ = try PageObjectArrangement.duplicateCommands(
        cloneSelection, in: deleted)
    }
  }

  @Test func reorderChangesPaintOrderWithoutTouchingOtherContent() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let nativeContents = try PageObjectContent.pageContents(pageID, in: graph)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 10, 30, 30]),
          style: AddedShapeStyle(strokeColor: [1, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([40, 40, 60, 60]),
          style: AddedShapeStyle(strokeColor: [0, 1, 0])),
      ]), to: graph)
    var contents = try PageObjectContent.pageContents(pageID, in: graph)
    #expect(contents.count == 3)
    let first = contents[1]
    let second = contents[2]
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let firstRef = try #require(refs.first { $0.streamID == first })
    let secondRef = try #require(refs.first { $0.streamID == second })

    let front = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.reorderCommands(
          try PageObjectSelection.make([firstRef]), destination: .front, in: graph)),
      to: graph)
    contents = try PageObjectContent.pageContents(pageID, in: front)
    #expect(contents == [nativeContents[0], second, first])

    let back = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.reorderCommands(
          try PageObjectSelection.make([secondRef]), destination: .back, in: graph)),
      to: graph)
    contents = try PageObjectContent.pageContents(pageID, in: back)
    #expect(contents == [second, nativeContents[0], first])

    let forward = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.reorderCommands(
          try PageObjectSelection.make([secondRef]), destination: .forward, in: back)),
      to: back)
    contents = try PageObjectContent.pageContents(pageID, in: forward)
    #expect(contents == [nativeContents[0], second, first])

    // Unrelated native content and the untouched stream stay byte-identical.
    let fixtureNativeObject = try PDFParser.parse(PDFFixtures.threePages())
      .graph.objects[nativeContents[0]]
    #expect(forward.objects[nativeContents[0]] == graph.objects[nativeContents[0]])
    #expect(forward.objects[nativeContents[0]] == fixtureNativeObject)

    // Original document images cannot change paint order.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let imagePage = parsed.pageIDs[0]
    let imageRefs = try PageObjectSelectionProfile.selectable(
      pageID: imagePage, in: parsed.graph)
    #expect(throws: PDFError.self) {
      _ = try PageObjectArrangement.reorderCommands(
        try PageObjectSelection.make([imageRefs[0]]), destination: .front,
        in: parsed.graph)
    }

    // A stream carrying marked content refuses instead of breaking tags.
    guard case .stream(let stream)? = graph.objects[first] else {
      Issue.record("rectangle stream missing")
      return
    }
    var taggedBytes = Data("q\n/Span << /ActualText (x) >> BDC\n".utf8)
    taggedBytes.append(stream.bytes)
    taggedBytes.append(Data("EMC\nQ\n".utf8))
    var tagged = graph
    var taggedDictionary = stream.dictionary
    taggedDictionary[PDFName("Length")] = .integer(Int64(taggedBytes.count))
    tagged.objects[first] = .stream(
      PDFStream(dictionary: taggedDictionary, bytes: taggedBytes))
    let taggedRef = try #require(
      try PageObjectSelectionProfile.selectable(pageID: pageID, in: tagged)
        .first { $0.streamID == first })
    #expect(throws: PDFError.self) {
      _ = try PageObjectArrangement.reorderCommands(
        try PageObjectSelection.make([taggedRef]), destination: .front, in: tagged)
    }
  }

  @Test func groupUngroupPersistAndNeverTouchPaint() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, x: 100, baseline: 300, text: "Grouped"),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 120, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let selection = try PageObjectSelection.make(refs)
    let streamIDs = refs.compactMap(\.streamID)
    let contentsBefore = try PageObjectContent.pageContents(pageID, in: graph)
    let paintBefore = streamIDs.map { graph.objects[$0] }

    let groupCommands = try PageObjectArrangement.groupCommands(
      selection, label: "pair", groupID: "pair-1", in: graph)
    let grouped = try PDFEditingEngine.commit(PDFTransaction(groupCommands), to: graph)
    let groups = try AddedGraphicsGroups.list(in: grouped)
    #expect(groups.count == 1)
    #expect(groups[0].members == streamIDs)
    let groupedContents = try PageObjectContent.pageContents(pageID, in: grouped)
    #expect(groupedContents == contentsBefore)
    #expect(streamIDs.map { grouped.objects[$0] } == paintBefore)
    let groupedRefs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: grouped)
    #expect(groupedRefs.allSatisfy { $0.groupID == "pair-1" })
    let expanded = try PageObjectSelectionProfile.expandingGroups(
      try PageObjectSelection.make([groupedRefs[0]]), in: grouped)
    #expect(expanded.count == 2)

    // Persisted identity survives save/reopen.
    let reopened = try PDFParser.parse(PDFWriter.write(grouped))
    let reopenedGroups = try AddedGraphicsGroups.list(in: reopened.graph)
    #expect(reopenedGroups == groups)
    let reopenedRefs = try PageObjectSelectionProfile.selectable(
      pageID: pageID, in: reopened.graph)
    #expect(reopenedRefs.allSatisfy { $0.groupID == "pair-1" })

    let ungroupCommands = try PageObjectArrangement.ungroupCommands(
      expanded, in: reopened.graph)
    #expect(ungroupCommands.count == 1)
    let ungrouped = try PDFEditingEngine.commit(
      PDFTransaction(ungroupCommands), to: reopened.graph)
    let ungroupedGroups = try AddedGraphicsGroups.list(in: ungrouped)
    #expect(ungroupedGroups.isEmpty)
    let ungroupedContents = try PageObjectContent.pageContents(pageID, in: ungrouped)
    let reopenedContents = try PageObjectContent.pageContents(pageID, in: reopened.graph)
    #expect(ungroupedContents == reopenedContents)

    // Document images stay outside the group profile.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let imagePage = parsed.pageIDs[0]
    let imageRefs = try PageObjectSelectionProfile.selectable(
      pageID: imagePage, in: parsed.graph)
    #expect(throws: PDFError.self) {
      _ = try PageObjectArrangement.groupCommands(
        try PageObjectSelection.make([imageRefs[0]]), in: parsed.graph)
    }
  }

  @Test func deletePrunesGroupMembershipAndPreservesSharedResources() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 10, 40, 40]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [100, 100, 140, 140], width: 2, height: 2,
          rgb8: Data(repeating: 77, count: 12)),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let streams = refs.compactMap(\.streamID)
    let imageResourceStreams = graph.objects.filter {
      if case .stream(let stream) = $0.value {
        return stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image"))
      }
      return false
    }
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        CreateAddedGroupCommand(members: streams, label: "pair", groupID: "pair")
      ]), to: graph)
    let firstSelection = try PageObjectSelection.make([refs[0]])
    let deletedOne = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.deleteCommands(firstSelection, in: graph)),
      to: graph)
    let remainingGroups = try AddedGraphicsGroups.list(in: deletedOne)
    #expect(remainingGroups.count == 1)
    #expect(remainingGroups[0].members == [streams[1]])
    let secondSelection = try PageObjectSelection.make([refs[1]])
    let deletedAll = try PDFEditingEngine.commit(
      PDFTransaction(
        try PageObjectArrangement.deleteCommands(secondSelection, in: graph)),
      to: deletedOne)
    let remainingGroupRecords = try AddedGraphicsGroups.list(in: deletedAll)
    #expect(remainingGroupRecords.isEmpty)
    // Shared image resources stay in the graph; only the placement is detached.
    for (objectID, value) in imageResourceStreams {
      #expect(deletedAll.objects[objectID] == value)
    }
  }

  @Test func failedTransactionLeavesTheStagedGraphUntouched() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, text: "Atomic"),
        AddTextObjectCommand(pageID: pageID, rect: [300, 100, 420, 130], text: "Legacy"),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    let box = try #require(refs.first { $0.kind == .authoredTextBox })
    let legacy = try #require(refs.first { $0.kind == .addedText })
    let bytesBefore = try PDFWriter.write(graph)
    let selection = try PageObjectSelection.make([box, legacy])
    let moveCommands = try PageObjectArrangement.moveCommands(
      selection, dx: 5, dy: 5, in: graph)
    #expect(moveCommands.count == 2)
    // Appending a command that refuses makes the whole transaction fail; the
    // caller's graph value is never mutated.
    let legacyStream = try #require(legacy.streamID)
    let invalid = moveCommands + [
      ScaleAddedGraphicCommand(streamID: legacyStream, scaleX: 2, scaleY: 2)
    ]
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(PDFTransaction(invalid), to: graph)
    }
    let bytesAfter = try PDFWriter.write(graph)
    #expect(bytesAfter == bytesBefore)

    // Eligibility refusal happens before any command is built.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let imagePage = parsed.pageIDs[0]
    let imageRefs = try PageObjectSelectionProfile.selectable(
      pageID: imagePage, in: parsed.graph)
    let imageBytes = try PDFWriter.write(parsed.graph)
    do {
      _ = try PageObjectArrangement.deleteCommands(
        try PageObjectSelection.make([imageRefs[0]]), in: parsed.graph)
      Issue.record("document image deletion was not refused")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("original page content"))
    }
    let imageBytesAfter = try PDFWriter.write(parsed.graph)
    #expect(imageBytesAfter == imageBytes)
  }

  // MARK: - Fixtures

  private func threeRectanglesWithBystander() throws -> (
    graph: PDFGraph, pageID: PDFObjectID, refs: [PageObjectRef]
  ) {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 10, 30, 30]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([100, 50, 140, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([200, 20, 230, 50]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([400, 400, 420, 420]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    return (graph, pageID, refs)
  }

  private func authoredTextCommand(
    pageID: PDFObjectID, x: Double = 100, baseline: Double = 300, text: String
  ) -> AddPageTextLinesCommand {
    let format = PageTextFormat(font: .helvetica, size: 12, color: [0, 0, 0])
    let segment = PageTextSegment(text: text, x: x, format: format, width: 54)
    let line = PageTextLine(
      text: text, x: x, baseline: baseline, segments: [segment], endsParagraph: true)
    let box = PageTextBox(
      x: x, firstBaseline: baseline, width: 160, lineSpacing: 14.4, wraps: true)
    return AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)
  }

  private func streamBytes(_ streamID: PDFObjectID, in graph: PDFGraph) throws -> Data {
    guard case .stream(let stream)? = graph.objects[streamID] else { return Data() }
    return stream.bytes
  }

  /// The authored box geometry [x, firstBaseline, width, lineSpacing].
  private func rectangleValues(_ dictionary: [PDFName: PDFValue]) -> [Double]? {
    guard case .array(let values)? = dictionary[PDFName("SPDFTextBox")],
      values.count == 5
    else { return nil }
    return values.prefix(4).compactMap { PageObjectContent.geometryNumber($0) }
      .isEmpty ? nil : values.prefix(4).compactMap { PageObjectContent.geometryNumber($0) }
  }

  /// The first authored line position (x, baseline).
  private func lineValues(_ dictionary: [PDFName: PDFValue]) -> (Double, Double)? {
    guard case .array(let records)? = dictionary[PDFName("SPDFTextLines")],
      case .array(let fields)? = records.first, fields.count >= 4,
      let x = PageObjectContent.geometryNumber(fields[2]),
      let y = PageObjectContent.geometryNumber(fields[3])
    else { return nil }
    return (x, y)
  }

  private func mediaBox(pageID: PDFObjectID, in graph: PDFGraph) throws -> [Double]? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    return DocumentInventoryBox.mediaBox(of: page, in: graph)
  }
}
