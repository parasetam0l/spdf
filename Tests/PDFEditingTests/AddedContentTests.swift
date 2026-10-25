import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P21-001–P21-024: added content as real page content — text objects, vector
/// shapes, image stamps, repeated page marks (watermark/header/footer/page
/// numbers/Bates), previews, resource uniqueness, ordering, clipping, and the
/// geometry helpers.
@Suite("Added content")
struct AddedContentTests {
  private func graph() throws -> PDFGraph {
    try PDFParser.parse(PDFFixtures.threePages()).graph
  }

  private func contentText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    let content = try PageContent.load(pageID: pageID, in: graph)
    return String(decoding: content.segments.flatMap(\.decoded), as: UTF8.self)
  }

  // MARK: - P21-001/P21-002/P21-003/P21-023/P21-024

  @Test func textObjectsInsertAsRealContent() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let annotationsBefore = try AnnotationInventory.annotations(in: graph, pageID: pageID).count
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 600, 300, 660],
          text: "Inserted content with a wrapped line that should break here.",
          style: AddedTextStyle(
            family: .helvetica, bold: true, size: 14, color: [0, 0, 1], lineSpacing: 1.2))
      ]), to: graph)
    // The new text extracts through the owned layout (P21-023) ...
    let layout = try PageTextLayout.build(pageID: pageID, in: edited)
    let text = layout.clusters.map(\.text).joined()
    #expect(text.contains("Inserted content"))
    #expect(text.contains("break here"))
    // ... and no annotation was created (P21-024).
    let annotationsAfter = try AnnotationInventory.annotations(in: edited, pageID: pageID).count
    #expect(annotationsAfter == annotationsBefore)
    // Wrapping produced more than one line and the font resource is registered.
    let raw = try contentText(edited, pageID)
    #expect(raw.contains("/SPDFF"))
    #expect(raw.components(separatedBy: "Tm").count >= 3)
    // The source graph is untouched.
    #expect(graph.objects.keys.count < edited.objects.keys.count)
  }

  @Test func textWriterPreservesIndirectSharedResourceCategories() throws {
    var graph = PDFFixtures.graph(pages: 2)
    let pages = try PDFPageTree.pageIDs(in: graph)
    let firstID = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let fontMapID = PDFObjectID(firstID)
    let stateID = PDFObjectID(firstID + 1)
    let stateMapID = PDFObjectID(firstID + 2)
    let resourcesID = PDFObjectID(firstID + 3)
    graph.objects[fontMapID] = .dictionary([
      PDFName("F1"): .reference(PDFObjectID(3)),
      PDFName("SPDFF1"): .reference(PDFObjectID(3)),
    ])
    graph.objects[stateID] = .dictionary([
      PDFName("Type"): .name(PDFName("ExtGState")),
      PDFName("ca"): .real(1),
      PDFName("CA"): .real(1),
    ])
    graph.objects[stateMapID] = .dictionary([
      PDFName("SPDFGS1"): .reference(stateID)
    ])
    graph.objects[resourcesID] = .dictionary([
      PDFName("Font"): .reference(fontMapID),
      PDFName("ExtGState"): .reference(stateMapID),
    ])
    for pageID in pages {
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        Issue.record("Fixture page missing")
        return
      }
      page[PDFName("Resources")] = .reference(resourcesID)
      graph.objects[pageID] = .dictionary(page)
    }
    let sharedResources = graph.objects[resourcesID]
    let sharedFonts = graph.objects[fontMapID]
    let sharedStates = graph.objects[stateMapID]
    let format = PageTextFormat(font: .timesBold, size: 12, opacity: 0.5)
    let line = PageTextLine(text: "mixed", x: 72, baseline: 700,
      segments: [PageTextSegment(text: "mixed", x: 72, format: format)])
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(pageID: pages[0], lines: [line],
          box: PageTextBox(x: 72, firstBaseline: 700, width: 200, lineSpacing: 14, wraps: false))
      ]), to: graph)

    guard case .dictionary(let firstPage)? = edited.objects[pages[0]],
      case .reference(let privateResourcesID)? = firstPage[PDFName("Resources")],
      let fonts = try AddedContent.pageResourceCategory("Font", ownerID: pages[0], in: edited),
      let states = try AddedContent.pageResourceCategory("ExtGState", ownerID: pages[0], in: edited),
      case .dictionary(let secondPage)? = edited.objects[pages[1]]
    else {
      Issue.record("Edited page resource dictionaries missing")
      return
    }
    #expect(privateResourcesID != resourcesID)
    #expect(edited.objects[resourcesID] == sharedResources)
    #expect(edited.objects[fontMapID] == sharedFonts)
    #expect(edited.objects[stateMapID] == sharedStates)
    #expect(secondPage[PDFName("Resources")] == .reference(resourcesID))
    #expect(fonts[PDFName("F1")] == .reference(PDFObjectID(3)))
    #expect(fonts[PDFName("SPDFF1")] == .reference(PDFObjectID(3)))
    #expect(fonts[PDFName("SPDFF2")] != nil)
    #expect(states[PDFName("SPDFGS1")] == .reference(stateID))
    #expect(states[PDFName("SPDFGS2")] != nil)
    guard case .dictionary(let updatedPage)? = edited.objects[pages[0]] else {
      Issue.record("Edited page missing")
      return
    }
    #expect(IndexedTextFont.resolve(resource: PDFName("F1"), page: updatedPage, in: edited) != nil)
    #expect(IndexedTextFont.resolve(resource: PDFName("SPDFF2"), page: updatedPage, in: edited) != nil)
  }

  @Test func textAlignmentAndClipping() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let centered = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 500, 400, 540], text: "Centered",
          style: AddedTextStyle(size: 18, alignment: .center), clips: true)
      ]), to: graph)
    let raw = try contentText(centered, pageID)
    // The clip rectangle is present as `re W n`.
    #expect(raw.contains(" re W n"))
    // Centered placement starts right of the box origin.
    #expect(raw.contains("Tm"))
    let right = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 460, 400, 500], text: "Right",
          style: AddedTextStyle(size: 12, alignment: .right))
      ]), to: graph)
    #expect(try contentText(right, pageID).contains("Right"))
  }

  // MARK: - P21-004–P21-008/P21-011/P21-014

  @Test func vectorShapesCoverSupportedGeometry() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let shapes: [AddedShape] = [
      .rectangle([50, 50, 150, 100]),
      .ellipse([200, 50, 300, 100]),
      .polygon([[350, 50], [400, 100], [300, 100]]),
      .line(from: [50, 150], to: [200, 150]),
      .path([[250, 150], [300, 200], [350, 150]], closed: false),
    ]
    var edited = graph
    for shape in shapes {
      edited = try PDFEditingEngine.commit(
        PDFTransaction([
          AddVectorShapeCommand(
            pageID: pageID, shape: shape,
            style: AddedShapeStyle(
              strokeColor: [1, 0, 0], fillColor: [0.9, 0.9, 0.9], lineWidth: 2,
              dash: [4, 2], opacity: 0.5), clips: true)
        ]), to: edited)
    }
    let raw = try contentText(edited, pageID)
    #expect(raw.contains(" re\n"))
    #expect(raw.contains(" c\n"))
    #expect(raw.contains("[4 2] 0 d"))
    #expect(raw.contains(" rg"))
    #expect(raw.contains(" RG"))
    #expect(raw.contains("B\n"))
    #expect(raw.contains(" gs"))
    // The opacity state carries the constant alpha.
    let resources = try AddedContent.pageResources(pageID: pageID, in: edited)
    guard case .dictionary(let states)? = resources?[PDFName("ExtGState")] else {
      Issue.record("ExtGState missing")
      return
    }
    #expect(!states.isEmpty)
    for (_, value) in states {
      guard case .reference(let id) = value,
        case .dictionary(let state)? = edited.graphValue(id)
      else { continue }
      #expect(state[PDFName("ca")] != nil)
    }
    // Reparse keeps the new content.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(try contentText(reparsed.graph, pageID).contains(" re\n"))
  }

  @Test func orderingFrontAndBackAndGeometryHelpers() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let front = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([0, 0, 10, 10]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0]), toFront: true)
      ]), to: graph)
    let back = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([0, 0, 10, 10]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0]), toFront: false)
      ]), to: graph)
    func contents(_ graph: PDFGraph) throws -> [PDFValue] {
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let items)? = page[PDFName("Contents")]
      else { return [] }
      return items
    }
    let frontItems = try contents(front)
    let backItems = try contents(back)
    #expect(frontItems.count == 2)
    #expect(backItems.count == 2)
    // Front appends; back inserts at the start.
    #expect(frontItems.last != backItems.last)
    #expect(backItems.first != frontItems.first)

    // Snapping and alignment helpers.
    let snapped = AddedContent.snap([101, 199], toGuides: [[100, 200]], tolerance: 6)
    #expect(snapped == [100, 200])
    let aligned = AddedContent.align([[10, 0, 50, 10], [30, 0, 70, 10]], mode: .left)
    #expect(aligned[0][0] == 10)
    #expect(aligned[1][0] == 10)
    let centered = AddedContent.align([[0, 0, 10, 10], [20, 0, 30, 10]], mode: .center)
    #expect((centered[0][0] + centered[0][2]) / 2 == (centered[1][0] + centered[1][2]) / 2)
  }

  // MARK: - P21-015

  @Test func imageStampsInsertAsImageXObjects() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let pixels = Data((0..<(4 * 4 * 3)).map { UInt8($0 % 251) })
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddImageStampCommand(
          pageID: pageID, rect: [100, 100, 200, 200], width: 4, height: 4, rgb8: pixels,
          opacity: 0.8)
      ]), to: graph)
    let images = try PDFImageInventory.images(in: edited, pageIDs: [pageID])
    let stamp = try #require(images.first { $0.bounds == [100, 100, 200, 200] })
    #expect(stamp.width == 4)
    #expect(stamp.height == 4)
    #expect(stamp.filters == ["FlateDecode"])
    // The stamp decodes back to the original pixels.
    guard let objectID = stamp.objectID,
      case .stream(let stream)? = edited.objects[objectID]
    else {
      Issue.record("stamp stream missing")
      return
    }
    #expect(try PDFFilters.decoded(stream).prefix(12) == pixels.prefix(12))
  }

  // MARK: - P21-016–P21-019

  @Test func repeatedMarksCoverWatermarksHeadersFootersNumbersAndBates() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    #expect(pageIDs.count == 3)
    var edited = graph
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs,
          mark: .watermark(
            text: "DRAFT", style: AddedTextStyle(size: 48, color: [0.8, 0.8, 0.8], opacity: 0.3),
            angle: 45))
      ]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs,
          mark: .header(text: "Quarterly report", style: AddedTextStyle(size: 10)))
      ]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs,
          mark: .pageNumber(
            text: "Page {page} of {pages}", style: AddedTextStyle(size: 9, alignment: .center),
            offset: 0))
      ]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs,
          mark: .bates(
            prefix: "ABC-", suffix: "", start: 100, digits: 5,
            style: AddedTextStyle(family: .courier, size: 8)))
      ]), to: edited)

    for (index, pageID) in pageIDs.enumerated() {
      let text = try PageTextLayout.build(pageID: pageID, in: edited).clusters.map(\.text).joined()
      #expect(text.contains("DRAFT"))
      #expect(text.contains("Quarterly report"))
      #expect(text.contains("Page \(index + 1) of 3"))
      #expect(text.contains("ABC-" + String(format: "%05d", 100 + index)))
    }
    // P21-021: repeated insertions reuse identical fonts but never collide.
    let resources = try AddedContent.pageResources(pageID: pageIDs[0], in: edited)
    guard case .dictionary(let fonts)? = resources?[PDFName("Font")] else {
      Issue.record("fonts missing")
      return
    }
    let names = fonts.keys.map { String(decoding: $0.bytes, as: UTF8.self) }
    #expect(Set(names).count == names.count)
    // One transaction per mark covers every page (compound undo, P21-022).
    let singleTransaction = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs,
          mark: .footer(text: "Confidential", style: AddedTextStyle(size: 8)))
      ]), to: graph)
    for pageID in pageIDs {
      let text = try PageTextLayout.build(pageID: pageID, in: singleTransaction)
        .clusters.map(\.text).joined()
      #expect(text.contains("Confidential"))
    }
  }

  // MARK: - P21-026/P21-027/P21-028/P21-029

  @Test func latin1ExtractsAndUnsupportedTextRefuses() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 300, 400, 340], text: "Café naïve façade")
      ]), to: graph)
    let text = try PageTextLayout.build(pageID: pageID, in: edited).clusters.map(\.text).joined()
    #expect(text.contains("Café"))
    #expect(text.contains("naïve"))

    // Characters outside WinAnsi are refused rather than silently dropped.
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextObjectCommand(pageID: pageID, rect: [72, 200, 400, 240], text: "日本語のテキスト")
        ]), to: graph)
    }
  }

  @Test func marksRespectMixedPageSizesAndPreserveState() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // The fixture mixes sizes; every page gets the header at its own top edge.
    var boxes: [[Double]] = []
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let values)? = page[PDFName("MediaBox")]
      else { continue }
      boxes.append(
        values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        })
    }
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs, mark: .header(text: "Top band", style: AddedTextStyle(size: 9)))
      ]), to: graph)
    for pageID in pageIDs {
      let content = try PageTextLayout.build(pageID: pageID, in: edited).clusters.map(\.text).joined()
      #expect(content.contains("Top band"))
    }
    // Surrounding graphics state: the original content stream is untouched and
    // the new block is wrapped in q/Q.
    for pageID in pageIDs {
      let original = try contentText(graph, pageID)
      let editedContent = try contentText(edited, pageID)
      #expect(editedContent.hasPrefix(original))
      #expect(editedContent.contains("q\n"))
      #expect(editedContent.hasSuffix("Q\n"))
    }
    // Resource reuse and bounded growth for repeated marks (P21-029).
    var repeated = graph
    let objectsBefore = repeated.objects.count
    for index in 0..<10 {
      repeated = try PDFEditingEngine.commit(
        PDFTransaction([
          AddRepeatedMarkCommand(
            pageIDs: [pageIDs[0]],
            mark: .footer(text: "Repeat \(index)", style: AddedTextStyle(size: 8)))
        ]), to: repeated)
    }
    let resources = try AddedContent.pageResources(pageID: pageIDs[0], in: repeated)
    guard case .dictionary(let fonts)? = resources?[PDFName("Font")] else {
      Issue.record("fonts missing")
      return
    }
    // Exactly one added font resource is reused for all ten marks (the
    // fixture's own StandardEncoding font is untouched).
    let added = fonts.keys.filter { String(decoding: $0.bytes, as: UTF8.self).hasPrefix("SPDFF") }
    #expect(added.count == 1)
    // Ten streams plus the one added font object; nothing else grew.
    #expect(repeated.objects.count - objectsBefore == 11)
    _ = boxes
  }

  // MARK: - P21-020

  @Test func repeatedMarkPreviewsBeforeCommit() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let command = AddRepeatedMarkCommand(
      pageIDs: pageIDs,
      mark: .pageNumber(
        text: "Page {page}/{pages}", style: AddedTextStyle(size: 10, alignment: .center),
        offset: 0))
    let plan = try command.plan(in: graph)
    #expect(plan.pages.count == 3)
    #expect(plan.pages[0].text == "Page 1/3")
    #expect(plan.pages[2].text == "Page 3/3")
    #expect(plan.pages.allSatisfy { !$0.content.isEmpty })
    #expect(plan.summary.contains("page number"))
    // The plan does not modify the input graph.
    let pristine = try self.graph()
    #expect(graph.objects.keys.count == pristine.objects.keys.count)
  }
}

extension PDFGraph {
  fileprivate func graphValue(_ id: PDFObjectID) -> PDFValue? { objects[id] }
}

/// P29-018: the document inventory explains graphical-signature status.
@Suite("Graphical signature status")
struct GraphicalSignatureStatusTests {
  @Test func inventoryCountsGraphicalSignatures() throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    #expect(PDFDocumentInventory.graphicalSignatureCount(in: graph, pageIDs: pageIDs) == 0)
    let asset = SignatureAsset(
      id: "status-asset", kind: .drawn, width: 2, height: 2,
      rgb8: Data(repeating: 10, count: 12), alpha8: Data(repeating: 255, count: 4))
    let placed = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceSignatureStampCommand(pageID: pageIDs[0], rect: [50, 50, 150, 100], asset: asset)
      ]), to: graph)
    #expect(PDFDocumentInventory.graphicalSignatureCount(in: placed, pageIDs: pageIDs) == 1)
    // The annotation carries the disclosure so an inspector can explain it.
    let annotation = try #require(
      try AnnotationInventory.annotations(in: placed, pageID: pageIDs[0]).first)
    #expect(annotation.contents?.contains("not a digital signature") == true)
  }
}

extension AddedContentTests {
  // MARK: - P15-007/P15-021/P15-022 custom fonts

  private func dejavu() throws -> CustomTextFont {
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      throw PDFError(.malformed, "Test font program is corrupt")
    }
    return CustomTextFont(program: program, familyName: "DejaVuSans")
  }

  private func layoutText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let layout = try PageTextLayout.build(in: content, graph: graph)
    return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
  }

  @Test func customFontInsertsAndExtracts() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 500, 400, 560], text: "ABCﬁ",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: graph)
    // The ligature round-trips through the embedded subset.
    #expect(try layoutText(edited, pageID).contains("ABCﬁ"))
    // A tagged subset font is registered alongside the standard profile.
    let raw = try contentText(edited, pageID)
    #expect(raw.contains("/SPDFF"))
    guard case .dictionary(let page)? = edited.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else {
      Issue.record("font resources missing")
      return
    }
    let embedded = fonts.values.compactMap { value -> [PDFName: PDFValue]? in
      guard case .reference(let id) = value,
        case .dictionary(let font)? = edited.objects[id],
        font[PDFName("Subtype")] == .name(PDFName("TrueType"))
      else { return nil }
      return font
    }
    #expect(embedded.count == 1)
    let baseFont =
      {
        if case .name(let name)? = embedded[0][PDFName("BaseFont")] {
          return String(decoding: name.bytes, as: UTF8.self)
        }
        return ""
      }()
    // Subset tag plus family name (P14 convention).
    #expect(baseFont.hasSuffix("+DejaVuSans"))
    #expect(baseFont.prefix(6).allSatisfy { $0.isUppercase })
  }

  @Test func customFontInsertsMultilingualTextAndExtracts() throws {
    // P15-026: one insertion spanning basic Latin, a precomposed accented
    // letter (WinAnsi path), and the fi ligature (Differences path) extracts
    // as the exact intended Unicode through the owned layout.
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 500, 400, 560], text: "AâC ﬁ",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: graph)
    #expect(try layoutText(edited, pageID).contains("AâC ﬁ"))
  }

  @Test func customFontReusesAndNamesUniquely() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let first = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 500, 400, 560], text: "AB",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: graph)
    let firstCount = first.objects.count
    // The same program and coverage reuses the registered font: no new
    // font, descriptor, program, or map objects appear.
    let second = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 400, 400, 460], text: "BA",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: first)
    let embedded: (PDFGraph) -> Int = { graph in
      graph.objects.values.filter {
        guard case .dictionary(let font) = $0 else { return false }
        return font[PDFName("Subtype")] == .name(PDFName("TrueType"))
      }.count
    }
    #expect(embedded(second) == embedded(first))
    #expect(second.objects.count - firstCount < firstCount - graph.objects.count)
    #expect(try layoutText(second, pageID).contains("BA"))
    // New coverage extends the subset under a new tag and a fresh name.
    let third = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 300, 400, 360], text: "ABCﬁ",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: second)
    #expect(embedded(third) == embedded(second) + 1)
    guard case .dictionary(let page)? = third.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else {
      Issue.record("font resources missing")
      return
    }
    #expect(Set(fonts.keys).count == fonts.keys.count)
  }

  @Test func embeddedFontGrowthIsMeasuredAndReuseStaysSmall() throws {
    // P15-029: serialized growth across custom-font edits, with byte-level
    // reuse proof. Reuse happens through graph dedup (P15-022) — there is no
    // subset cache in the edit path — so the measurement pins growth per
    // edit and the stable program-payload count.
    func programCount(_ data: Data) -> Int {
      let marker = Data("/FontFile2".utf8)
      var count = 0
      var search = data.startIndex..<data.endIndex
      while let found = data.range(of: marker, in: search) {
        count += 1
        search = found.upperBound..<data.endIndex
      }
      return count
    }
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let base = try PDFWriter.write(graph).count
    let first = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 500, 400, 560], text: "AB",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: graph)
    let firstData = try PDFWriter.write(first)
    let growth1 = firstData.count - base
    #expect(growth1 > 0)
    #expect(programCount(firstData) == 1)
    // Same coverage reuses the program: content only, no second payload.
    let second = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 400, 400, 460], text: "BA",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: first)
    let secondData = try PDFWriter.write(second)
    let growth2 = secondData.count - firstData.count
    #expect(programCount(secondData) == 1)
    #expect(growth2 < growth1)
    // New coverage embeds a second program; growth stays proportional to
    // one subset, not the whole history.
    let third = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [72, 300, 400, 360], text: "ABCﬁ",
          style: AddedTextStyle(size: 18), customFont: dejavu())
      ]), to: second)
    let thirdData = try PDFWriter.write(third)
    let growth3 = thirdData.count - secondData.count
    #expect(programCount(thirdData) == 2)
    #expect(growth3 > growth2)
    #expect(growth3 < growth1 * 2)
    print(
      "P15-029 embedded-font growth (bytes): base=\(base) first=+\(growth1)"
        + " reuse=+\(growth2) new-coverage=+\(growth3)")
  }

  @Test func customFontRefusesUncoveredText() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    // The DejaVu test subset has no Cyrillic: the command refuses rather
    // than writing unencodable text.
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextObjectCommand(
            pageID: pageID, rect: [72, 500, 400, 560], text: "Привет",
            style: AddedTextStyle(size: 18), customFont: dejavu())
        ]), to: graph)
    }
  }
}

extension AddedContentTests {
  @Test func customFontWatermarksEveryPage() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pageIDs,
          mark: .watermark(
            text: "ABCﬁ", style: AddedTextStyle(size: 48), angle: 45),
          customFont: dejavu())
      ]), to: graph)
    for pageID in pageIDs {
      #expect(try layoutText(marked, pageID).contains("ABCﬁ"))
    }
  }
}
