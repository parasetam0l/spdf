import CoreGraphics
import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("Prepress spot colors, hairlines and marks")
struct PrepressToolsTests {
  private func pageGraph(
    contents: [String], mediaBoxes: [[Double]]? = nil,
    resources: [[PDFName: PDFValue]]? = nil, extraObjects: [PDFObjectID: PDFValue] = [:]
  ) -> PDFGraph {
    let pageIDs = (0..<contents.count).map { PDFObjectID(4 + $0 * 2) }
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(contents.count)),
        PDFName("Kids"): .array(pageIDs.map(PDFValue.reference)),
      ]),
    ]
    for (index, pageID) in pageIDs.enumerated() {
      let contentID = PDFObjectID(pageID.number + 1)
      objects[contentID] = .stream(PDFStream(bytes: Data(contents[index].utf8)))
      let media = mediaBoxes?[index] ?? [0, 0, 612, 792]
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array(media.map { .real($0) }),
        PDFName("Resources"): .dictionary(resources?[index] ?? [:]),
        PDFName("Contents"): .reference(contentID),
      ])
    }
    for (id, value) in extraObjects { objects[id] = value }
    return PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func imageStream(colorSpace: PDFValue, width: Int = 1, height: Int = 1) -> PDFStream {
    PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(Int64(width)),
        PDFName("Height"): .integer(Int64(height)),
        PDFName("BitsPerComponent"): .integer(8),
        PDFName("ColorSpace"): colorSpace,
      ],
      bytes: Data(repeating: 128, count: max(width * height, 1)))
  }

  private func tintFunction() -> PDFValue {
    .dictionary([
      PDFName("FunctionType"): .integer(2),
      PDFName("Domain"): .array([.real(0), .real(1)]),
      PDFName("C0"): .array([.real(0), .real(0), .real(0), .real(0)]),
      PDFName("C1"): .array([.real(1), .real(0), .real(0), .real(0)]),
      PDFName("N"): .integer(1),
    ])
  }

  private func spotGraph() -> PDFGraph {
    let tint = PDFObjectID(30)
    let deviceN = PDFValue.array([
      .name(PDFName("DeviceN")),
      .array([.name(PDFName("Orange")), .name(PDFName("Violet"))]),
      .name(PDFName("DeviceCMYK")),
      .reference(tint),
    ])
    let indirectSeparation = PDFObjectID(31)
    let indirectValue = PDFValue.array([
      .name(PDFName("Separation")), .name(PDFName("PANTONE 300 C")),
      .name(PDFName("DeviceCMYK")), .reference(tint),
    ])
    let directSeparation = PDFValue.array([
      .name(PDFName("Separation")), .name(PDFName("PANTONE 185 C")),
      .name(PDFName("DeviceRGB")), .reference(tint),
    ])
    let page1Resources: [PDFName: PDFValue] = [
      PDFName("XObject"): .dictionary([
        PDFName("Im1"): .reference(PDFObjectID(20))
      ])
    ]
    let page2Resources: [PDFName: PDFValue] = [
      PDFName("ColorSpace"): .dictionary([
        PDFName("CS1"): .reference(indirectSeparation)
      ]),
      PDFName("XObject"): .dictionary([
        PDFName("Im2"): .reference(PDFObjectID(21)),
        PDFName("Im3"): .reference(PDFObjectID(22)),
      ]),
    ]
    return pageGraph(
      contents: ["q 20 0 0 20 10 10 cm /Im1 Do Q", "q 20 0 0 20 40 10 cm /Im2 Do Q"],
      resources: [page1Resources, page2Resources],
      extraObjects: [
        PDFObjectID(20): .stream(imageStream(colorSpace: directSeparation)),
        PDFObjectID(21): .stream(imageStream(colorSpace: .reference(indirectSeparation))),
        PDFObjectID(22): .stream(imageStream(colorSpace: deviceN)),
        indirectSeparation: .array(indirectValue.arrayValue ?? []),
        tint: tintFunction(),
      ])
  }

  @Test func spotInventoryFindsSeparationAndDeviceN() throws {
    let graph = spotGraph()
    let report = SpotColorInventory.inventory(graph, pageIDs: [PDFObjectID(4), PDFObjectID(6)])
    #expect(report.pageCount == 2)
    #expect(report.spotNames.contains("PANTONE 185 C"))
    #expect(report.spotNames.contains("PANTONE 300 C"))
    #expect(report.spotNames.contains("Orange"))
    #expect(report.spotNames.contains("Violet"))
    #expect(report.uses.contains { $0.kind == .deviceN && $0.name == "Orange" })
    #expect(report.uses.first { $0.name == "PANTONE 300 C" }?.isShared == true)
    #expect(report.report().contains("no CMYK conversion"))
  }

  @Test func remapRenamesNamesOnlyAndPreservesTransforms() throws {
    let graph = spotGraph()
    let tintBefore = graph.objects[PDFObjectID(30)]
    let indirectBefore = graph.objects[PDFObjectID(31)]
    let request = SpotColorRemapRequest(
      mappings: [
        "PANTONE 185 C": "Magenta",
        "PANTONE 300 C": "Magenta",
        "Orange": "Magenta",
        "Missing": "Black",
        "Violet": "Violet",
      ], reason: "test remap")
    let (remapped, report) = try SpotColorRemap.apply(
      graph, pageIDs: [PDFObjectID(4), PDFObjectID(6)], request: request)
    #expect(report.renamedOccurrences >= 3)
    #expect(report.unknownSources == ["Missing"])
    #expect(report.skippedIdentity == ["Violet"])
    #expect(report.mergedTargets["Magenta"]?.count == 3)
    #expect(report.report().contains("Plate-colorant-name remap only"))
    #expect(remapped.objects[PDFObjectID(30)] == tintBefore)
    #expect(remapped.objects[PDFObjectID(31)] == indirectBefore?.replacingArrayColorant(
      from: "PANTONE 300 C", to: "Magenta"))
    // Direct image color space name changed; alternate space and tint are intact.
    guard case .stream(let image)? = remapped.objects[PDFObjectID(20)] else {
      Issue.record("Image disappeared")
      return
    }
    guard case .array(let colorSpace)? = image.dictionary[PDFName("ColorSpace")],
      case .name(let spotName) = colorSpace[1]
    else {
      Issue.record("Image color space is malformed")
      return
    }
    #expect(String(decoding: spotName.bytes, as: UTF8.self) == "Magenta")
    #expect(colorSpace[2] == .name(PDFName("DeviceRGB")))
    #expect(colorSpace[3] == .reference(PDFObjectID(30)))
    // DeviceN names were remapped while the unrelated name stayed.
    guard case .stream(let deviceNImage)? = remapped.objects[PDFObjectID(22)],
      case .array(let deviceNColorSpace)? = deviceNImage.dictionary[PDFName("ColorSpace")],
      case .array(let names) = deviceNColorSpace[1]
    else {
      Issue.record("DeviceN image is malformed")
      return
    }
    #expect(names[0] == .name(PDFName("Magenta")))
    #expect(names[1] == .name(PDFName("Violet")))
  }

  @Test func remapAppearanceIsUnchangedInAnIndependentRender() throws {
    let graph = spotGraph()
    let before = try renderPageBytes(graph: graph, pageIndex: 0)
    let beforeSecond = try renderPageBytes(graph: graph, pageIndex: 1)
    let request = SpotColorRemapRequest(
      mappings: ["PANTONE 185 C": "Magenta", "PANTONE 300 C": "Cyan"])
    let (remapped, _) = try SpotColorRemap.apply(
      graph, pageIDs: [PDFObjectID(4), PDFObjectID(6)], request: request)
    let after = try renderPageBytes(graph: remapped, pageIndex: 0)
    let afterSecond = try renderPageBytes(graph: remapped, pageIndex: 1)
    #expect(before == after)
    #expect(beforeSecond == afterSecond)
  }

  @Test func remapRefusesInvalidTargetNamesAndIsAnEditCommand() throws {
    let graph = spotGraph()
    #expect(throws: PDFError.self) {
      _ = try SpotColorRemap.apply(
        graph, pageIDs: [PDFObjectID(4)],
        request: SpotColorRemapRequest(mappings: ["PANTONE 185 C": "Bad/Name"]))
    }
    #expect(throws: PDFError.self) {
      _ = try SpotColorRemap.apply(
        graph, pageIDs: [PDFObjectID(4)],
        request: SpotColorRemapRequest(mappings: ["PANTONE 185 C": ""]))
    }
    let command = SpotColorRemapCommand(
      pageIDs: [PDFObjectID(4)],
      request: SpotColorRemapRequest(mappings: ["PANTONE 185 C": "Magenta"]))
    try command.validate(in: graph)
    let committed = try command.apply(to: graph)
    #expect(committed != graph)
    #expect(command.name == "Remap Spot Colors")
  }

  private func renderPageBytes(graph: PDFGraph, pageIndex: Int) throws -> Data {
    let data = try PDFWriter.write(graph)
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider),
      let page = document.page(at: pageIndex + 1)
    else { throw PDFError(.malformed, "Fixture page is unreadable") }
    let box = page.getBoxRect(.mediaBox)
    let width = max(1, Int(box.width.rounded()))
    let height = max(1, Int(box.height.rounded()))
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PDFError(.malformed, "Could not render fixture page") }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.drawPDFPage(page)
    guard let image = context.makeImage(), let provider = image.dataProvider,
      let bytes = provider.data
    else { throw PDFError(.malformed, "Could not read rendered fixture page") }
    return bytes as Data
  }
}

extension PDFValue {
  var arrayValue: [PDFValue]? {
    if case .array(let values) = self { return values }
    return nil
  }

  func replacingArrayColorant(from source: String, to target: String) -> PDFValue {
    guard case .array(let values) = self, values.count >= 2,
      case .name(let firstName) = values[1],
      String(decoding: firstName.bytes, as: UTF8.self) == source
    else { return self }
    var newValues = values
    newValues[1] = .name(PDFName(target))
    return .array(newValues)
  }
}
