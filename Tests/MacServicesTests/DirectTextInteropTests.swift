import AppKit
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import Testing

@Suite("Direct page text editing interop")
struct DirectTextInteropTests {
  @Test @MainActor func standardFontParagraphErasurePreservesFollowingTextForEveryVariant() throws {
    let text = "A paragraph with ordinary words."
    for family in RewritePageTextCommand.standardFonts.sorted() {
      let (base, pageID) = try graph(content: "BT /SPDFText 16 Tf 42 700 Td (\(text)) Tj ( Adjacent) Tj ET")
      var source = base
      guard case .dictionary(let page)? = source.objects[pageID],
        case .dictionary(let resources)? = page[PDFName("Resources")],
        case .dictionary(let fonts)? = resources[PDFName("Font")],
        case .reference(let fontID)? = fonts.values.first,
        case .dictionary(var font)? = source.objects[fontID]
      else { throw CocoaError(.fileReadCorruptFile) }
      font[PDFName("BaseFont")] = .name(PDFName(family))
      source.objects[fontID] = .dictionary(font)
      let advance = try #require(NativeParagraphEditing.standardAdvance(text, family: family, size: 16))
      let edited = try PDFEditingEngine.commit(PDFTransaction([
        RewritePageTextCommand(pageID: pageID, originalText: [0: text],
          lines: [.init(text: "Replacement", x: 42, baseline: 600)],
          fontSize: 16, color: [0, 0, 0], standardFontAdvances: [0: advance])
      ]), to: source)
      let before = try bounds("Adjacent", in: source)
      let after = try bounds("Adjacent", in: edited)
      #expect(abs(before.minX - after.minX) < 0.02, "\(family) adjacent pen must stay fixed")
      #expect(abs(before.minY - after.minY) < 0.02, "\(family) adjacent baseline must stay fixed")
    }
  }
  @Test @MainActor func paragraphRewriteRemovesOldTextAndPreservesAdjacentPenAndGraphics() throws {
    let one = "Original first paragraph line"
    let two = "Original second paragraph line"
    let (original, pageID) = try graph(content: """
      0.2 0.6 0.8 rg 30 620 480 100 re f 0 g
      BT /SPDFText 16 Tf 42 700 Td (\(one)) Tj ( Neighbor one) Tj
      0 -22 Td (\(two)) Tj ( Neighbor two) Tj ET
      2 0 0 2 10 20 cm
      """)
    let advanceOne = try #require(NativeParagraphEditing.standardAdvance(one, family: "Helvetica", size: 16))
    let advanceTwo = try #require(NativeParagraphEditing.standardAdvance(two, family: "Helvetica", size: 16))
    let originalBytes = try PDFWriter.write(original)
    let lines = [PageTextLine(text: "Longer edited paragraph", x: 68, baseline: 600),
      PageTextLine(text: "with a second wrapped line.", x: 68, baseline: 578)]
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [0: one, 2: two], lines: lines,
      fontSize: 18, color: [0.1, 0.2, 0.8], standardFontAdvances: [0: advanceOne, 2: advanceTwo])
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: original)
    #expect(try PDFWriter.write(original) == originalBytes)
    let reader = try #require(PDFDocument(data: PDFWriter.write(edited)))
    #expect(reader.string?.contains("Original") == false)
    #expect(reader.string?.contains("Longer edited paragraph") == true)
    for neighbor in ["Neighbor one", "Neighbor two"] {
      let before = try bounds(neighbor, in: original)
      let after = try bounds(neighbor, in: edited)
      #expect(abs(before.minX - after.minX) < 0.02)
      #expect(abs(before.minY - after.minY) < 0.02)
    }
    let replacement = try bounds("Longer edited paragraph", in: edited)
    #expect(abs(replacement.minX - 68) < 0.01)
    #expect(replacement.minY > 593 && replacement.maxY < 622)
    // The final page cm must not double the saved position or font size.
    let attributes = try #require(reader.page(at: 0)?.selection(for: replacement)?.attributedString)
    let font = try #require(attributes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(abs(font.pointSize - 18) < 0.1)
  }

  @Test @MainActor func paragraphRewriteRefusesStaleGlyphAndClippingState() throws {
    let text = "A complete source paragraph line"
    let (original, pageID) = try graph(content: """
      q 30 600 400 140 re W n
      BT /SPDFText 16 Tf 42 700 Td (\(text)) Tj ET Q
      """)
    let advance = try #require(NativeParagraphEditing.standardAdvance(text, family: "Helvetica", size: 16))
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [0: text],
      lines: [.init(text: "Replacement", x: 42, baseline: 700)], fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: [0: advance])
    #expect(throws: PDFError.self) { try command.validate(in: original) }
    let (plain, _) = try graph(content: "BT /SPDFText 16 Tf 42 700 Td (Different text) Tj ET")
    #expect(throws: PDFError.self) { try command.validate(in: plain) }
    let (supported, _) = try graph(content: "BT /SPDFText 16 Tf 42 700 Td (\(text)) Tj ET")
    let missingGlyph = RewritePageTextCommand(
      pageID: pageID, originalText: [0: text],
      lines: [.init(text: "Unavailable glyph: 🐈", x: 42, baseline: 700)],
      fontSize: 16, color: [0, 0, 0], standardFontAdvances: [0: advance])
    #expect(throws: PDFError.self) { try missingGlyph.validate(in: supported) }
    var repeated = supported
    if case .dictionary(var dictionary)? = repeated.objects[pageID],
      let contents = dictionary[PDFName("Contents")]
    {
      if case .array(let streams) = contents {
        dictionary[PDFName("Contents")] = .array(streams + streams)
      } else {
        dictionary[PDFName("Contents")] = .array([contents, contents])
      }
      repeated.objects[pageID] = .dictionary(dictionary)
    }
    let repeatedCommand = RewritePageTextCommand(
      pageID: pageID, originalText: [0: text],
      lines: [.init(text: "Replacement", x: 42, baseline: 700)],
      fontSize: 16, color: [0, 0, 0], standardFontAdvances: [0: advance])
    #expect(throws: PDFError.self) { try repeatedCommand.validate(in: repeated) }
  }

  @Test @MainActor func nativeParagraphGroupingRequiresAFullWrappingRoundTrip() throws {
    let font = try #require(NSFont(name: "Helvetica", size: 16))
    let text = "A natural paragraph can be edited directly on the page with automatic wrapping and predictable saved line positions."
    let lines = NativeParagraphEditing.wrappedLines(text, font: font, width: 265)
    #expect(lines.count >= 3)
    let instructions = lines.enumerated().map { index, line in
      "1 0 0 1 42 \(700 - index * 22) Tm (\(line)) Tj"
    }.joined(separator: "\n")
    let (original, pageID) = try graph(content: "BT /SPDFText 16 Tf\n\(instructions)\nET")
    let reader = try #require(PDFDocument(data: PDFWriter.write(original)))
    let page = try #require(reader.page(at: 0))
    let blocks = try lines.enumerated().map { index, line in
      let rect = try bounds(line, in: original)
      return PageTextTarget(pageIndex: 0, runIndex: index,
        rect: [rect.minX, rect.minY, rect.maxX, rect.maxY], text: line,
        style: .init(fontFamily: "Helvetica", fontSize: 16, fillColor: [0, 0, 0]))
    }
    let grouped = NativeParagraphEditing.targets(from: blocks, pageID: pageID, graph: original, page: page)
    let paragraph = try #require(grouped.first?.paragraph)
    #expect(grouped.count == 1)
    #expect(grouped[0].text == text)
    #expect(paragraph.originalText.count == lines.count)
    // Nearby short labels are separate objects even when aligned.
    let labels = blocks.enumerated().map { index, block in
      PageTextTarget(pageIndex: 0, runIndex: index, rect: block.rect,
        text: "Label \(index)", style: block.style)
    }
    #expect(NativeParagraphEditing.targets(from: labels, pageID: pageID, graph: original, page: page)
      .allSatisfy { $0.paragraph == nil })
  }
  private func graph(content: String) throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let page = parsed.pageIDs[0]
    let authored = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(pageID: page, rect: [40, 650, 450, 700], text: "Fixture")
      ]), to: parsed.graph)
    var result = authored
    guard case .dictionary(let dictionary)? = result.objects[page],
      case .dictionary(let resources)? = dictionary[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")], let font = fonts.keys.first
    else { throw CocoaError(.fileReadCorruptFile) }
    let stream: PDFObjectID
    switch dictionary[PDFName("Contents")] {
    case .reference(let id)?: stream = id
    case .array(let entries)?:
      guard case .reference(let id)? = entries.last else { throw CocoaError(.fileReadCorruptFile) }
      stream = id
    default: throw CocoaError(.fileReadCorruptFile)
    }
    let actual = content.replacingOccurrences(
      of: "/SPDFText ", with: "/\(String(decoding: font.bytes, as: UTF8.self)) ")
    result.objects[stream] = .stream(PDFStream(bytes: Data(actual.utf8)))
    return (result, page)
  }

  private func bounds(_ needle: String, in graph: PDFGraph) throws -> CGRect {
    let document = try #require(PDFDocument(data: PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    let text = try #require(page.string) as NSString
    let range = text.range(of: needle)
    #expect(range.location != NSNotFound)
    return try #require(page.selection(for: range)).bounds(for: page)
  }

  @Test func movingMiddleTextPreservesAdjacentAdvancesAndNextLine() throws {
    let (original, page) = try graph(
      content: """
        BT /SPDFText 16 Tf 42 700 Td (Before ) Tj (Moving) Tj ( After) Tj
        0 -40 Td (Next line) Tj ET
        """)
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveTextCommand(pageID: page, runIndex: 1, dx: 50, dy: -30)
      ]), to: original)
    let before = try bounds("Moving", in: original)
    let after = try bounds("Moving", in: moved)
    #expect(abs(after.minX - before.minX - 50) < 0.1)
    #expect(abs(after.minY - before.minY + 30) < 0.1)
    for neighbor in ["Before", "After", "Next line"] {
      let a = try bounds(neighbor, in: original)
      let b = try bounds(neighbor, in: moved)
      #expect(abs(a.minX - b.minX) < 0.1)
      #expect(abs(a.minY - b.minY) < 0.1)
    }
  }

  @Test func movementUsesPageCoordinatesThroughGraphicsTransforms() throws {
    let (original, page) = try graph(
      content: """
        q 2 0 0 1.5 12 20 cm
        BT /SPDFText 16 Tf 42 420 Td (Moving) Tj ET Q
        BT /SPDFText 16 Tf 42 600 Td (Neighbor) Tj ET
        """)
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveTextCommand(pageID: page, runIndex: 0, dx: 50, dy: -30)
      ]), to: original)
    let a = try bounds("Moving", in: original)
    let b = try bounds("Moving", in: moved)
    #expect(abs(b.minX - a.minX - 50) < 0.1)
    #expect(abs(b.minY - a.minY + 30) < 0.1)
    #expect(try bounds("Neighbor", in: moved) == bounds("Neighbor", in: original))
  }

  @Test func transientHiddenTextPreservesSourceAndFollowingPen() throws {
    let (original, page) = try graph(
      content: """
        0.2 0.6 0.8 rg 30 660 400 70 re f 0 g
        BT /SPDFText 16 Tf 42 700 Td (Before ) Tj (Moving) Tj ( After) Tj ET
        """)
    let originalBytes = try PDFWriter.write(original)
    let preview = try PageTextEditing.hidingBlock(pageID: page, runIndex: 1, in: original)
    #expect(try PDFWriter.write(original) == originalBytes)
    #expect(try bounds("After", in: preview) == bounds("After", in: original))
    // A real reader still processes the invisible run's original advances.
    let document = try #require(PDFDocument(data: PDFWriter.write(preview)))
    #expect(document.string?.contains("Before Moving After") == true)
    // Render in an independent engine: background pixels remain identical,
    // while the active glyph region loses its black ink.
    func pixels(_ graph: PDFGraph) throws -> [UInt8] {
      let data = try PDFWriter.write(graph)
      let provider = try #require(CGDataProvider(data: data as CFData))
      let pdf = try #require(CGPDFDocument(provider))
      let page = try #require(pdf.page(at: 1))
      let context = try #require(
        CGContext(
          data: nil, width: 600, height: 850,
          bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 600, height: 850))
      context.drawPDFPage(page)
      let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      return Array(UnsafeBufferPointer(start: bytes, count: 600 * 850 * 4))
    }
    func darkPixels(_ bytes: [UInt8], rect: CGRect) -> Int {
      var count = 0
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          let offset = (849 - y) * 2400 + x * 4
          if bytes[offset] < 35 && bytes[offset + 1] < 35 && bytes[offset + 2] < 35 { count += 1 }
        }
      }
      return count
    }
    let area = try bounds("Moving", in: original).insetBy(dx: -1, dy: -1)
    let beforePixels = try pixels(original)
    let previewPixels = try pixels(preview)
    #expect(darkPixels(beforePixels, rect: area) > 15)
    #expect(darkPixels(previewPixels, rect: area) == 0)
    var changedOutside = 0
    for y in 0..<850 {
      for x in 0..<600 where !area.contains(CGPoint(x: x, y: y)) {
        let offset = (849 - y) * 2400 + x * 4
        if beforePixels[offset..<offset + 4] != previewPixels[offset..<offset + 4] {
          changedOutside += 1
        }
      }
    }
    #expect(changedOutside == 0)
  }

  @Test func stylingMiddleTextDoesNotRestyleItsNeighbors() throws {
    let (original, page) = try graph(
      content: """
        BT /SPDFText 16 Tf 42 700 Td (Before ) Tj (Moving) Tj ( After) Tj ET
        """)
    let styled = try PDFEditingEngine.commit(
      PDFTransaction([
        ChangeTextStyleCommand(
          pageID: page, runIndex: 1,
          style: TextStyleChange(fontSize: 22, fillColor: [1, 0, 0]))
      ]), to: original)
    let document = try #require(PDFDocument(data: PDFWriter.write(styled)))
    let text = try #require(document.page(at: 0)?.attributedString)
    for (needle, size) in [("Before", 16.0), ("Moving", 22.0), ("After", 16.0)] {
      let range = (text.string as NSString).range(of: needle)
      let font = try #require(
        text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
      #expect(abs(font.pointSize - size) < 0.1)
    }
  }
  @Test func directPreviewRefusesTransformsAndSpacingItCannotMatch() throws {
    for content in [
      "BT /SPDFText 16 Tf 0 1 -1 0 200 200 Tm (Rotated) Tj ET",
      "BT /SPDFText 16 Tf 42 700 Td 2 Tc (Spaced) Tj ET",
      "BT /SPDFText 16 Tf 42 700 Td [(Kerned) -120 (text)] TJ ET",
    ] {
      let (original, page) = try graph(content: content)
      let bytes = try PDFWriter.write(original)
      #expect(throws: PDFError.self) {
        try PageTextEditing.hidingBlock(pageID: page, runIndex: 0, in: original)
      }
      #expect(try PDFWriter.write(original) == bytes)
    }
  }

  @Test func coincidentRotatedShowsHaveDeterministicReadingOrder() throws {
    let (original, page) = try graph(
      content: """
        BT /SPDFText 16 Tf 0 1 -1 0 200 200 Tm (First) Tj ET
        BT /SPDFText 16 Tf 0 1 -1 0 200 200 Tm (Other) Tj ET
        """)
    let expected = try PageTextLayout.build(pageID: page, in: original).clusters.map(\.text)
    for _ in 0..<20 {
      #expect(try PageTextLayout.build(pageID: page, in: original).clusters.map(\.text) == expected)
      let reopened = try PDFParser.parse(PDFWriter.write(original))
      #expect(
        try PageTextLayout.build(pageID: reopened.pageIDs[0], in: reopened.graph).clusters.map(
          \.text) == expected)
    }
  }

}
