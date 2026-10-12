import CryptoKit
import Foundation
import PDFCore
import Security

/// P30-017/P30-018: placement, appearance, and reservation for one signature.
public struct PDFSigningOptions: Sendable, Equatable {
  public let fieldName: String
  public let pageIndex: Int
  /// Page-space widget rectangle.
  public let rect: [Double]
  public let reason: String?
  public let location: String?
  /// Reserved /Contents bytes (hex space is twice this).
  public let reservationBytes: Int
  public let signingTime: Date

  public init(
    fieldName: String = "Signature1", pageIndex: Int = 0, rect: [Double] = [72, 72, 272, 112],
    reason: String? = nil, location: String? = nil, reservationBytes: Int = 16_384,
    signingTime: Date = Date()
  ) {
    self.fieldName = fieldName
    self.pageIndex = pageIndex
    self.rect = rect
    self.reason = reason
    self.location = location
    self.reservationBytes = reservationBytes
    self.signingTime = signingTime
  }
}

/// P30-016–P30-022/P30-025: signature generation. Signatures are produced by
/// the Security framework from keychain identities; the signed bytes never
/// change after signing, and insufficient reservations fail before any output
/// is produced.
public enum PDFSigningWriter {
  /// Sentinel numbers keep the /ByteRange fields fixed-width so the final
  /// values can be patched without shifting any offsets (P30-018).
  static let byteRangeSentinel = 1_000_000_000

  struct Plan {
    var graph: PDFGraph
    var signatureID: PDFObjectID
    var widgetID: PDFObjectID
    var changedIDs: [PDFObjectID]
  }

  /// P30-016–P30-019: sign a graph as a full rewrite.
  public static func sign(
    _ graph: PDFGraph, identity: SecIdentity, options: PDFSigningOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    let plan = try prepare(graph, options: options, limits: limits)
    let data = try PDFWriter.serialize(plan.graph, limits: limits)
    return try embed(
      data, signatureID: plan.signatureID, identity: identity, options: options, limits: limits)
  }

  /// P30-020/P30-022: append a signed revision to an existing file. The
  /// original bytes are preserved exactly; signing an already-signed document
  /// adds another revision whose signature covers only that revision.
  public static func signIncremental(
    _ source: ParsedPDF, identity: SecIdentity, options: PDFSigningOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    guard source.graph.trailer[PDFName("Encrypt")] == nil else {
      throw PDFError(.unsupported, "Signing encrypted documents is not supported")
    }
    let plan = try prepare(source.graph, options: options, limits: limits)
    let previousStartXRef = try finalStartXRef(in: source.source)

    var output = source.source
    if output.last != 0x0A { output.append(0x0A) }
    let baseLength = output.count
    var body = Data()
    var offsets: [PDFObjectID: Int] = [:]
    for id in plan.changedIDs.sorted() {
      guard let value = plan.graph.objects[id] else { continue }
      offsets[id] = baseLength + body.count
      body.append(Data("\(id.number) \(id.generation) obj\n".utf8))
      body.append(try PDFWriter.serializedValue(value, limits: limits))
      body.append(Data("\nendobj\n".utf8))
    }
    let xrefOffset = baseLength + body.count
    var table = "xref\n0 1\n0000000000 65535 f \n"
    for id in plan.changedIDs.sorted() {
      guard let offset = offsets[id] else { continue }
      table += "\(id.number) 1\n"
      table += String(format: "%010lld %05d n \n", Int64(offset), id.generation)
    }
    var trailer = source.graph.trailer
    let highest = max(
      plan.graph.objects.keys.map(\.number).max() ?? 0,
      source.graph.objects.keys.map(\.number).max() ?? 0)
    trailer[PDFName("Size")] = .integer(Int64(highest) + 1)
    trailer[PDFName("Prev")] = .integer(Int64(previousStartXRef))
    var trailerData = Data("trailer\n".utf8)
    trailerData.append(try PDFWriter.serializedValue(.dictionary(trailer), limits: limits))

    output.append(body)
    output.append(Data(table.utf8))
    output.append(trailerData)
    output.append(Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return try embed(
      output, signatureID: plan.signatureID, identity: identity, options: options, limits: limits)
  }

  // MARK: - Preparation (P30-017)

  static func prepare(
    _ graph: PDFGraph, options: PDFSigningOptions, limits: PDFLimits
  ) throws -> Plan {
    guard options.reservationBytes >= 512, options.reservationBytes <= 1_048_576 else {
      throw PDFError(.malformed, "The signature reservation is out of bounds")
    }
    try AnnotationSupport.validateRect(options.rect)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard options.pageIndex >= 0, options.pageIndex < pageIDs.count else {
      throw PDFError(.malformed, "The signature page does not exist")
    }
    let pageID = pageIDs[options.pageIndex]
    let existingFields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    guard !existingFields.contains(where: { $0.name == options.fieldName }) else {
      throw PDFError(.malformed, "A field named \(options.fieldName) already exists")
    }

    var graph = graph
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    let fontID = PDFObjectID(highest + 1)
    let appearanceID = PDFObjectID(highest + 2)
    let signatureID = PDFObjectID(highest + 3)
    let widgetID = PDFObjectID(highest + 4)
    var changedIDs: [PDFObjectID] = [fontID, appearanceID, signatureID, widgetID]

    graph.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
    ])

    var signatureDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Sig")),
      PDFName("Filter"): .name(PDFName("Adobe.PPKLite")),
      PDFName("SubFilter"): .name(PDFName("adbe.pkcs7.detached")),
      PDFName("ByteRange"): .array([
        .integer(0), .integer(Int64(byteRangeSentinel)), .integer(Int64(byteRangeSentinel)),
        .integer(Int64(byteRangeSentinel)),
      ]),
      PDFName("Contents"): .string(Data(repeating: 0, count: options.reservationBytes)),
      PDFName("M"): .string(Data(pdfDate(options.signingTime).utf8)),
    ]
    if let reason = options.reason {
      signatureDictionary[PDFName("Reason")] = .string(Data(reason.utf8))
    }
    if let location = options.location {
      signatureDictionary[PDFName("Location")] = .string(Data(location.utf8))
    }
    graph.objects[signatureID] = .dictionary(signatureDictionary)

    let width = options.rect[2] - options.rect[0]
    let height = options.rect[3] - options.rect[1]
    let content = """
      q 0.8 w 0.5 0.5 \(width - 1) \(height - 1) re S Q
      BT /Helv 9 Tf 4 \(height / 2 - 4) Td (Digitally signed) Tj ET

      """
    graph.objects[appearanceID] = .stream(
      AnnotationSupport.formAppearance(
        rect: options.rect, content: content,
        resources: [PDFName("Font"): .dictionary([PDFName("Helv"): .reference(fontID)])]))

    graph.objects[widgetID] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("FT"): .name(PDFName("Sig")),
      PDFName("T"): .string(Data(options.fieldName.utf8)),
      PDFName("V"): .reference(signatureID),
      PDFName("Rect"): .array(options.rect.map { .real($0) }),
      PDFName("P"): .reference(pageID),
      PDFName("F"): .integer(132),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(appearanceID)]),
    ])

    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The signature page is malformed")
    }
    var annotations: [PDFValue] = []
    if case .array(let existing)? = page[PDFName("Annots")] { annotations = existing }
    annotations.append(.reference(widgetID))
    page[PDFName("Annots")] = .array(annotations)
    graph.objects[pageID] = .dictionary(page)
    changedIDs.append(pageID)

    // AcroForm: keep the field tree canonical and provide the appearance font.
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    else {
      throw PDFError(.malformed, "The catalog is missing")
    }
    let acroFormID: PDFObjectID
    var acroForm: [PDFName: PDFValue]
    if case .reference(let existing)? = catalog[PDFName("AcroForm")],
      case .dictionary(let dictionary)? = graph.objects[existing]
    {
      acroFormID = existing
      acroForm = dictionary
    } else {
      acroFormID = PDFObjectID(highest + 5)
      changedIDs.append(acroFormID)
      acroForm = [:]
      catalog[PDFName("AcroForm")] = .reference(acroFormID)
      graph.objects[rootID] = .dictionary(catalog)
      changedIDs.append(rootID)
    }
    var fields: [PDFValue] = []
    if case .array(let existing)? = acroForm[PDFName("Fields")] { fields = existing }
    fields.append(.reference(widgetID))
    acroForm[PDFName("Fields")] = .array(fields)
    acroForm[PDFName("SigFlags")] = .integer(3)
    var dr: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = acroForm[PDFName("DR")] { dr = existing }
    var fonts: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = dr[PDFName("Font")] { fonts = existing }
    fonts[PDFName("Helv")] = .reference(fontID)
    dr[PDFName("Font")] = .dictionary(fonts)
    acroForm[PDFName("DR")] = .dictionary(dr)
    graph.objects[acroFormID] = .dictionary(acroForm)
    changedIDs.append(acroFormID)

    return Plan(
      graph: graph, signatureID: signatureID, widgetID: widgetID,
      changedIDs: Array(Set(changedIDs)))
  }

  // MARK: - Embedding (P30-018/P30-019/P30-021)

  static func embed(
    _ data: Data, signatureID: PDFObjectID, identity: SecIdentity, options: PDFSigningOptions,
    limits: PDFLimits
  ) throws -> Data {
    var output = data
    let sentinelPattern = Data("1000000000 1000000000 1000000000".utf8)
    guard let sentinelRange = output.range(of: sentinelPattern) else {
      throw PDFError(.malformed, "The signature reservation markers are missing")
    }
    let zeros = Data(repeating: 0x30, count: options.reservationBytes * 2)
    guard let contentsRange = output.range(of: zeros, in: sentinelRange.upperBound..<output.count)
    else {
      throw PDFError(.malformed, "The signature contents reservation is missing")
    }
    let lt = contentsRange.lowerBound - 1
    let gt = contentsRange.upperBound
    guard lt >= 0, output[lt] == 0x3C, gt < output.count, output[gt] == 0x3E else {
      throw PDFError(.malformed, "The signature contents reservation is malformed")
    }

    // Patch the fixed-width ByteRange fields in place.
    let values = [lt, gt + 1, output.count - (gt + 1)]
    var position = sentinelRange.lowerBound
    for value in values {
      let text = String(format: "%010d", value)
      output.replaceSubrange(position..<(position + 10), with: Data(text.utf8))
      position += 11
    }

    var signedBytes = Data(output[0..<lt])
    signedBytes.append(output[(gt + 1)...])
    let cms = try CMSSigner.detachedSignature(
      signedBytes: signedBytes, identity: identity, signingTime: options.signingTime, limits: limits)
    guard cms.count <= options.reservationBytes else {
      // P30-021: never write a corrupted output for an undersized reservation.
      throw PDFError(
        .limitExceeded,
        "The signature needs \(cms.count) bytes but only \(options.reservationBytes) were reserved")
    }
    var hex = cms.map { String(format: "%02X", $0) }.joined()
    hex += String(repeating: "0", count: options.reservationBytes * 2 - hex.count)
    output.replaceSubrange((lt + 1)..<gt, with: Data(hex.utf8))

    // Self-verification with the signer's certificate as an explicit anchor.
    let parsed = try PDFParser.parse(output, limits: limits)
    guard
      let signature = try PDFSignatureInventory.signatures(in: parsed.graph)
        .first(where: { $0.objectID == signatureID })
    else {
      throw PDFError(.malformed, "The generated signature could not be inventoried")
    }
    let certificate = PDFSigningIdentity.certificate(of: identity)
    let validation = PDFSignatureValidator.validate(
      signature, source: output, finalGraph: parsed.graph,
      trustedAnchors: certificate.map { [$0] } ?? [], limits: limits)
    guard validation.crypto == .valid else {
      throw PDFError(
        .malformed, "The generated signature failed self-verification: \(validation.details)")
    }
    return output
  }

  // MARK: - Helpers

  static func pdfDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "'D:'yyyyMMddHHmmss'Z'"
    return formatter.string(from: date)
  }

  static func finalStartXRef(in source: Data) throws -> Int {
    let bytes = [UInt8](source)
    guard let marker = source.range(of: Data("startxref".utf8), options: .backwards) else {
      throw PDFError(.malformed, "Missing final cross-reference pointer")
    }
    var index = marker.upperBound
    while index < bytes.count,
      bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09
    {
      index += 1
    }
    var value = 0
    while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
      value = value * 10 + Int(bytes[index] - 0x30)
      index += 1
    }
    guard value > 0, value < bytes.count else {
      throw PDFError(.malformed, "Final cross-reference pointer is outside the file")
    }
    return value
  }
}
