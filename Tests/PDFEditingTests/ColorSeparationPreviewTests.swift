import CoreGraphics
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PRE-05: known colors and representative image jobs match defined targets
/// through public CoreGraphics profiles with explicit intents, black
/// preservation and output intents; unsupported profiles are refused, never
/// silently flattened.
@Suite("Color-managed conversion (PRE-05)")
struct ColorManagedConversionTests {
  // MARK: Color targets

  @Test func srgbIdentityAndDefinedGrayTarget() throws {
    let identity = try ColorManagedConversion.convertColor(
      [0.8, 0.4, 0.2], from: .deviceRGB, to: .sRGB,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(abs(identity[0] - 0.8) < 0.002)
    #expect(abs(identity[1] - 0.4) < 0.002)
    #expect(abs(identity[2] - 0.2) < 0.002)
    // Defined target: sRGB 0.5 gray through gamma 2.2 is about 0.497.
    let gray = try ColorManagedConversion.convertColor(
      [0.5, 0.5, 0.5], from: .deviceRGB, to: .genericGray,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(abs(gray[0] - 0.497) < 0.01)
  }

  @Test func labKnownTargets() throws {
    let white = try ColorManagedConversion.convertColor(
      [100, 0, 0], from: .labD50, to: .sRGB,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(abs(white[0] - 1) < 0.01)
    #expect(abs(white[1] - 1) < 0.01)
    #expect(abs(white[2] - 1) < 0.01)
    let black = try ColorManagedConversion.convertColor(
      [0, 0, 0], from: .labD50, to: .sRGB,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(black[0] < 0.01 && black[1] < 0.01 && black[2] < 0.01)
    let red = try ColorManagedConversion.convertColor(
      [53.24, 80.09, 67.2], from: .labD50, to: .sRGB,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(red[0] > 0.95 && red[1] < 0.05 && red[2] < 0.08)
    let back = try ColorManagedConversion.convertColor(
      [1, 0, 0], from: .deviceRGB, to: .labD50,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(back[0] > 50 && back.count == 3)
  }

  @Test func blackPreservationKeepsNeutralColorsKOnly() throws {
    let black = try ColorManagedConversion.convertColor(
      [0, 0, 0], from: .deviceRGB, to: .genericCMYK,
      options: ColorManagementOptions(blackPreservation: true))
    #expect(black == [0, 0, 0, 1])
    let gray = try ColorManagedConversion.convertColor(
      [0.5, 0.5, 0.5], from: .deviceRGB, to: .genericCMYK,
      options: ColorManagementOptions(blackPreservation: true))
    #expect(gray == [0, 0, 0, 0.5])
    let grayInput = try ColorManagedConversion.convertColor(
      [0.25], from: .deviceGray, to: .genericCMYK,
      options: ColorManagementOptions(blackPreservation: true))
    #expect(grayInput == [0, 0, 0, 0.75])
    let cmykBlack = try ColorManagedConversion.convertColor(
      [0, 0, 0, 0.8], from: .deviceCMYK, to: .genericCMYK,
      options: ColorManagementOptions(blackPreservation: true))
    #expect(cmykBlack == [0, 0, 0, 0.8])
    // Non-neutral colors still use the managed conversion.
    let red = try ColorManagedConversion.convertColor(
      [1, 0, 0], from: .deviceRGB, to: .genericCMYK,
      options: ColorManagementOptions(blackPreservation: true))
    #expect(red[1] > 0.5 && red[2] > 0.5 && red[3] < 0.2)
  }

  @Test func renderingIntentsAreExplicit() throws {
    for intent in ColorRenderingIntent.allCases {
      let options = ColorManagementOptions(intent: intent, blackPointCompensation: true)
      let converted = try ColorManagedConversion.convertColor(
        [0.2, 0.6, 0.9], from: .deviceRGB, to: .genericCMYK, options: options)
      #expect(converted.count == 4)
      #expect(converted.allSatisfy { (0...1).contains($0) })
      #expect(options.summary.contains(intent.title))
    }
  }

  @Test func embeddedICCSourceProfileIsUsed() throws {
    let srgbICC = try #require(
      CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData().map { $0 as Data })
    let red = try ColorManagedConversion.convertColor(
      [1, 0, 0], from: .icc(name: "sRGB", data: srgbICC, components: 3), to: .sRGB,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(abs(red[0] - 1) < 0.01)
    #expect(abs(red[1]) < 0.01)
    #expect(abs(red[2]) < 0.01)
  }

  // MARK: Image fixtures

  private func imageGraph(
    colorSpace: PDFValue, samples: [Int], width: Int, height: Int,
    extraImageEntries: [PDFName: PDFValue] = [:], profileICC: Data? = nil,
    content: String? = nil
  ) -> (graph: PDFGraph, pageID: PDFObjectID) {
    var objects: [PDFObjectID: PDFValue] = [:]
    var imageDict: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Image")),
      PDFName("Width"): .integer(Int64(width)),
      PDFName("Height"): .integer(Int64(height)),
      PDFName("BitsPerComponent"): .integer(8),
      PDFName("ColorSpace"): colorSpace,
      PDFName("Length"): .integer(Int64(samples.count)),
    ]
    for (key, value) in extraImageEntries { imageDict[key] = value }
    var profileReference: PDFValue?
    if let profileICC {
      let profileID = PDFObjectID(20)
      objects[profileID] = .stream(
        PDFStream(
          dictionary: [
            PDFName("N"): .integer(3),
            PDFName("Length"): .integer(Int64(profileICC.count)),
          ], bytes: profileICC))
      profileReference = .reference(profileID)
    }
    if let profileReference, case .array(var space) = colorSpace, space.count > 1 {
      space[1] = profileReference
      imageDict[PDFName("ColorSpace")] = .array(space)
    }
    let imageID = PDFObjectID(10)
    objects[imageID] = .stream(
      PDFStream(dictionary: imageDict, bytes: Data(samples.map(UInt8.init))))
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
    ])
    let pageContent = content ?? "q 100 0 0 100 50 50 cm /Im1 Do Q"
    objects[PDFObjectID(3)] = .stream(PDFStream(bytes: Data(pageContent.utf8)))
    objects[PDFObjectID(4)] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(200), .integer(200),
      ]),
      PDFName("Resources"): .dictionary([
        PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(imageID)])
      ]),
      PDFName("Contents"): .reference(PDFObjectID(3)),
    ])
    return (PDFGraph(version: "1.7", objects: objects, trailer: [
      PDFName("Root"): .reference(PDFObjectID(1))
    ]), PDFObjectID(4))
  }

  private func decodeImage(_ graph: PDFGraph) throws -> (stream: PDFStream, bytes: Data) {
    for value in graph.objects.values {
      guard case .stream(let stream) = value,
        stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image"))
      else { continue }
      return (stream, try PDFFilters.decoded(stream))
    }
    throw PDFError(.malformed, "image missing")
  }

  @Test func deviceRGBImageConvertsToDefinedGrayTargetAndWritesOutputIntent() throws {
    let fixture = imageGraph(
      colorSpace: .name(PDFName("DeviceRGB")),
      samples: [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255],
      width: 2, height: 2)
    let result = try ColorManagedConversion.convertImages(
      in: fixture.graph, pageIDs: [fixture.pageID], to: .genericGray,
      options: ColorManagementOptions(blackPointCompensation: false))
    #expect(result.report.convertedImages == 1)
    #expect(result.report.outputIntentWritten)
    #expect(result.report.refused.isEmpty)
    let decoded = try decodeImage(result.graph)
    #expect(decoded.stream.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceGray")))
    #expect(decoded.bytes.count == 4)
    let reference = try #require(
      CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [1, 0, 0]
      )?.converted(
        to: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
        intent: .relativeColorimetric, options: nil)
    )
    let expected = UInt8(max(0, min(255, ((reference.components?.first ?? 0) * 255).rounded())))
    #expect(abs(Int(decoded.bytes[0]) - Int(expected)) <= 1)
    // Output intent carries exactly the target profile bytes.
    guard case .reference(let catalogID)? = result.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = result.graph.objects[catalogID],
      case .array(let intents)? = catalog[PDFName("OutputIntents")],
      case .dictionary(let intent) = intents[0],
      case .reference(let profileID) = intent[PDFName("DestOutputProfile")],
      case .stream(let profile)? = result.graph.objects[profileID]
    else {
      Issue.record("output intent missing")
      return
    }
    let targetProfile = try #require(try ColorManagementTarget.genericGray.profileData())
    #expect(profile.bytes == targetProfile)
    #expect(intent[PDFName("S")] == .name(PDFName("GTS_PDFX")))
  }

  @Test func iccBasedImageUsesAuthoredProfileAndConverts() throws {
    let icc = try #require(
      CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData().map { $0 as Data })
    let fixture = imageGraph(
      colorSpace: .array([.name(PDFName("ICCBased")), .null]),
      samples: [255, 0, 0, 0, 255, 0], width: 2, height: 1, profileICC: icc)
    let result = try ColorManagedConversion.convertImages(
      in: fixture.graph, pageIDs: [fixture.pageID], to: .genericCMYK)
    #expect(result.report.convertedImages == 1)
    #expect(result.report.fromSpaces.contains { $0.contains("ICCBased") })
    #expect(
      result.report.notes.contains {
        $0.contains("embedded ICC profile was used as authored")
      })
    let decoded = try decodeImage(result.graph)
    #expect(decoded.stream.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceCMYK")))
    #expect(decoded.bytes.count == 8)
    #expect(result.report.outputIntentWritten)
  }

  @Test func unsupportedOrUnsafeSourcesAreRefusedNotFlattened() throws {
    let separation = imageGraph(
      colorSpace: .array([
        .name(PDFName("Separation")), .name(PDFName("Spot1")),
        .name(PDFName("DeviceGray")), .dictionary([:]),
      ]), samples: [0], width: 1, height: 1)
    let separationReport = try ColorManagedConversion.convertImages(
      in: separation.graph, pageIDs: [separation.pageID], to: .genericGray)
    #expect(separationReport.report.convertedImages == 0)
    #expect(separationReport.report.refused.contains { $0.contains("Separation") })
    #expect(!separationReport.report.outputIntentWritten)

    let masked = imageGraph(
      colorSpace: .name(PDFName("DeviceRGB")), samples: [0, 0, 0], width: 1, height: 1,
      extraImageEntries: [
        PDFName("Mask"): .array([
          .integer(0), .integer(1), .integer(0), .integer(1), .integer(0), .integer(1),
        ])
      ])
    let maskedReport = try ColorManagedConversion.convertImages(
      in: masked.graph, pageIDs: [masked.pageID], to: .genericGray)
    #expect(maskedReport.report.convertedImages == 0)
    #expect(maskedReport.report.refused.contains { $0.contains("masked") })

    let sixteenBit = imageGraph(
      colorSpace: .name(PDFName("DeviceRGB")), samples: [0, 0, 0], width: 1, height: 1,
      extraImageEntries: [PDFName("BitsPerComponent"): .integer(16)])
    let sixteenBitReport = try ColorManagedConversion.convertImages(
      in: sixteenBit.graph, pageIDs: [sixteenBit.pageID], to: .genericGray)
    #expect(sixteenBitReport.report.convertedImages == 0)
    #expect(sixteenBitReport.report.refused.contains { $0.contains("8-bit") })

    let dct = imageGraph(
      colorSpace: .name(PDFName("DeviceRGB")), samples: [0, 0, 0], width: 1, height: 1,
      extraImageEntries: [PDFName("Filter"): .name(PDFName("DCTDecode"))])
    let dctReport = try ColorManagedConversion.convertImages(
      in: dct.graph, pageIDs: [dct.pageID], to: .genericGray)
    #expect(dctReport.report.convertedImages == 0)
    #expect(dctReport.report.refused.contains { $0.contains("DCTDecode") })
    #expect(!dctReport.report.outputIntentWritten)
  }

  @Test func uniqueColorBoundRefusesInsteadOfApproximating() throws {
    let width = 64
    let height = 64
    var samples: [Int] = []
    for y in 0..<height {
      for x in 0..<width {
        samples.append(x * 3)
        samples.append(y * 3)
        samples.append(128)
      }
    }
    let fixture = imageGraph(
      colorSpace: .name(PDFName("DeviceRGB")), samples: samples,
      width: width, height: height)
    let result = try ColorManagedConversion.convertImages(
      in: fixture.graph, pageIDs: [fixture.pageID], to: .genericGray,
      options: ColorManagementOptions(maximumUniqueColors: 256))
    #expect(result.report.convertedImages == 0)
    #expect(result.report.refused.contains { $0.contains("bounded profile refuses") })
  }

  @Test func outputIntentCanBeDisabledAndLabHasNone() throws {
    let fixture = imageGraph(
      colorSpace: .name(PDFName("DeviceRGB")),
      samples: [10, 20, 30, 40, 50, 60], width: 2, height: 1)
    let noIntent = try ColorManagedConversion.convertImages(
      in: fixture.graph, pageIDs: [fixture.pageID], to: .sRGB,
      options: ColorManagementOptions(writeOutputIntent: false))
    #expect(noIntent.report.convertedImages == 1)
    #expect(!noIntent.report.outputIntentWritten)
    guard case .reference(let catalogID)? = noIntent.graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = noIntent.graph.objects[catalogID]
    else { Issue.record("catalog missing"); return }
    #expect(catalog[PDFName("OutputIntents")] == nil)
    let lab = try ColorManagedConversion.convertImages(
      in: fixture.graph, pageIDs: [fixture.pageID], to: .labD50)
    #expect(lab.report.convertedImages == 1)
    #expect(!lab.report.outputIntentWritten)
    #expect(lab.report.notes.contains { $0.contains("Lab target cannot carry") })
    let decoded = try decodeImage(lab.graph)
    #expect(decoded.bytes.count == 6)
  }

  @Test func commandRefusesWhenNothingIsConvertible() throws {
    let fixture = imageGraph(
      colorSpace: .array([
        .name(PDFName("Separation")), .name(PDFName("Spot1")),
        .name(PDFName("DeviceGray")), .dictionary([:]),
      ]), samples: [0], width: 1, height: 1)
    #expect(throws: PDFError.self) {
      try ColorManagedConversionCommand(target: .genericGray).apply(to: fixture.graph)
    }
    let converted = try ColorManagedConversionCommand(target: .genericGray)
      .apply(to: try PDFParser.parse(PDFFixtures.imagePages()).graph)
    #expect(!converted.objects.isEmpty)
  }
}

/// PRE-06: decision-first separation/overprint preview. Public Apple rendering
/// APIs are proven insufficient; the owned analyzer's process/spot plate and
/// overprint results are checked against independent hand-calculated rectangles.
@Suite("Separation and overprint preview (PRE-06)")
struct SeparationOverprintPreviewTests {
  private func graph(
    content: String, resources: [PDFName: PDFValue]? = nil,
    mediaBox: [Double] = [0, 0, 200, 100]
  ) -> (graph: PDFGraph, pageID: PDFObjectID) {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
      ]),
      PDFObjectID(3): .stream(PDFStream(bytes: Data(content.utf8))),
    ]
    var page: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array(mediaBox.map { .real($0) }),
      PDFName("Contents"): .reference(PDFObjectID(3)),
    ]
    if let resources { page[PDFName("Resources")] = .dictionary(resources) }
    objects[PDFObjectID(4)] = .dictionary(page)
    return (PDFGraph(version: "1.7", objects: objects, trailer: [
      PDFName("Root"): .reference(PDFObjectID(1))
    ]), PDFObjectID(4))
  }

  private func separationSpace(_ name: String) -> PDFValue {
    .array([
      .name(PDFName("Separation")), .name(PDFName(name)),
      .name(PDFName("DeviceCMYK")),
      .dictionary([PDFName("FunctionType"): .integer(2)]),
    ])
  }

  @Test func processCMYKRectangleCoverageMatchesHandReference() {
    let fixture = graph(content: "0 1 1 0 k 0 0 100 50 re f")
    let report = SeparationOverprintPreview.analyze(
      graph: fixture.graph, pageIDs: [fixture.pageID])
    let page = report.pages[0]
    #expect(abs(page.coverage(for: .magenta) - 0.25) < 1e-9)
    #expect(abs(page.coverage(for: .yellow) - 0.25) < 1e-9)
    #expect(page.coverage(for: .cyan) == 0)
    #expect(page.coverage(for: .black) == 0)
    #expect(page.knockoutOperations == 1)
    #expect(page.overprintOperations == 0)
  }

  @Test func spotAndDeviceNPlatesUseAuthoredNames() {
    var resources: [PDFName: PDFValue] = [
      PDFName("ColorSpace"): .dictionary([
        PDFName("CS1"): separationSpace("PANTONE 185 C"),
        PDFName("CS2"): .array([
          .name(PDFName("DeviceN")),
          .array([.name(PDFName("Orange")), .name(PDFName("Green"))]),
          .name(PDFName("DeviceCMYK")),
          .dictionary([PDFName("FunctionType"): .integer(2)]),
        ]),
      ])
    ]
    resources[PDFName("ColorSpace")] = .dictionary([
      PDFName("CS1"): separationSpace("PANTONE 185 C"),
      PDFName("CS2"): .array([
        .name(PDFName("DeviceN")),
        .array([.name(PDFName("Orange")), .name(PDFName("Green"))]),
        .name(PDFName("DeviceCMYK")),
        .dictionary([PDFName("FunctionType"): .integer(2)]),
      ]),
    ])
    let spotFixture = graph(
      content: "/CS1 cs 0.5 scn 0 0 100 50 re f", resources: resources)
    let spot = SeparationOverprintPreview.analyze(
      graph: spotFixture.graph, pageIDs: [spotFixture.pageID]).pages[0]
    #expect(abs(spot.coverage(for: .spot("PANTONE 185 C")) - 0.125) < 1e-9)
    #expect(spot.plates.count == 1)
    let deviceNFixture = graph(
      content: "/CS2 cs 0.25 0.5 scn 0 0 100 50 re f", resources: resources)
    let deviceN = SeparationOverprintPreview.analyze(
      graph: deviceNFixture.graph, pageIDs: [deviceNFixture.pageID]).pages[0]
    #expect(abs(deviceN.coverage(for: .spot("Orange")) - 0.0625) < 1e-9)
    #expect(abs(deviceN.coverage(for: .spot("Green")) - 0.125) < 1e-9)
  }

  @Test func overprintOperationsAndOverlapMatchHandReference() {
    let resources: [PDFName: PDFValue] = [
      PDFName("ExtGState"): .dictionary([
        PDFName("GS1"): .dictionary([
          PDFName("Type"): .name(PDFName("ExtGState")),
          PDFName("OP"): .boolean(true),
          PDFName("op"): .boolean(true),
          PDFName("OPM"): .integer(0),
        ])
      ])
    ]
    let fixture = graph(
      content: "0 0 0 1 k 0 0 100 100 re f /GS1 gs 0 1 0 0 k 50 0 100 100 re f",
      resources: resources)
    let page = SeparationOverprintPreview.analyze(
      graph: fixture.graph, pageIDs: [fixture.pageID]).pages[0]
    #expect(page.knockoutOperations == 1)
    #expect(page.overprintOperations == 1)
    #expect(abs(page.coverage(for: .black) - 0.5) < 1e-9)
    #expect(abs(page.coverage(for: .magenta) - 0.5) < 1e-9)
    let finding = page.overprintFindings.first
    #expect(finding != nil)
    #expect(abs((finding?.overprintAreaFraction ?? 0) - 0.25) < 1e-9)
  }

  @Test func allKnockoutByDefault() {
    let fixture = graph(
      content: "1 0 0 0 k 0 0 100 50 re f 0 1 0 0 k 100 0 100 50 re f")
    let report = SeparationOverprintPreview.analyze(
      graph: fixture.graph, pageIDs: [fixture.pageID])
    let page = report.pages[0]
    #expect(page.overprintOperations == 0)
    #expect(page.knockoutOperations == 2)
    #expect(page.overprintFindings.isEmpty)
    #expect(abs(page.coverage(for: .cyan) - 0.25) < 1e-9)
    #expect(abs(page.coverage(for: .magenta) - 0.25) < 1e-9)
  }

  @Test func decisionAndBoundaryAreExplicitNeverClaimThirdPartyAgreement() {
    let fixture = graph(content: "0 0 0 1 k 0 0 100 50 re f")
    let report = SeparationOverprintPreview.analyze(
      graph: fixture.graph, pageIDs: [fixture.pageID])
    let text = report.report()
    #expect(text.contains("Public Apple APIs are insufficient"))
    #expect(text.contains("Independent print reference: unavailable"))
    #expect(text.contains("third-party print-reference agreement is not claimed"))
    #expect(text.contains("owned preview approximation, not proof of print accuracy"))
    #expect(text.contains("declared area model v1"))
    #expect(report.publicAPIDecision.reasons.count >= 3)
    #expect(report.claimedAccuracy.contains("not estimated"))
  }

  @Test func imageAndTextInkAreReportedNotSilentlyOmitted() {
    let resources: [PDFName: PDFValue] = [
      PDFName("XObject"): .dictionary([
        PDFName("Im1"): .stream(
          PDFStream(dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(1),
            PDFName("Height"): .integer(1),
            PDFName("BitsPerComponent"): .integer(8),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("Length"): .integer(3),
          ], bytes: Data([1, 2, 3])))
      ]),
      PDFName("Font"): .dictionary([
        PDFName("F1"): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ])
      ]),
    ]
    let fixture = graph(
      content: "q 10 0 0 10 0 0 cm /Im1 Do Q BT /F1 12 Tf 10 10 Td (Hi) Tj ET",
      resources: resources)
    let page = SeparationOverprintPreview.analyze(
      graph: fixture.graph, pageIDs: [fixture.pageID]).pages[0]
    #expect(page.imagePaintOperators == 1)
    #expect(page.textPaintOperators == 1)
    #expect(page.ignoredNotes.contains { $0.contains("Image paint") })
    #expect(page.ignoredNotes.contains { $0.contains("Text ink") })
    #expect(page.plates.isEmpty)
  }
}
