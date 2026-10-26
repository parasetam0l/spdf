import Foundation
import PDFCore
import Security

/// SIG-07: an empty signature field whose widget is deliberately invisible
/// (annotation Hidden + NoView flags). A later certificate signature therefore
/// has no painted appearance, and the presentation audit classifies it as a
/// hidden certificate signature — never as a drawn/typed mark.
public struct PDFHiddenSignatureFieldCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let fieldName: String

  public init(
    pageID: PDFObjectID, rect: [Double] = [72, 72, 172, 104], fieldName: String
  ) {
    self.pageID = pageID
    self.rect = rect
    self.fieldName = fieldName
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Hidden Signature Field" }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The hidden signature page is missing")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The hidden signature field needs a positive widget rectangle")
    }
    let trimmed = fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw PDFError(.malformed, "The hidden signature field needs a name")
    }
    let existing = (try? PDFSignatureFieldInventory.fields(in: graph))?.map(\.name) ?? []
    guard !existing.contains(trimmed) else {
      throw PDFError(.malformed, "A signature field named \(trimmed) already exists")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let existing = (try? PDFSignatureFieldInventory.fields(in: graph))?.map(\.name) ?? []
    guard !existing.contains(fieldName) else {
      throw PDFError(.malformed, "A signature field named \(fieldName) already exists")
    }
    var graph = try AddSignatureFieldCommand(
      pageID: pageID, rect: rect, name: fieldName
    ).apply(to: graph)
    let fields = try PDFSignatureFieldInventory.fields(in: graph)
    guard let field = fields.first(where: { $0.name == fieldName }),
      let widgetID = field.widgetID,
      case .dictionary(var widget)? = graph.objects[widgetID]
    else {
      throw PDFError(.malformed, "The hidden signature field widget was not created")
    }
    // Hidden (0x02) + NoView (0x20): no paint, no screen presentation. No /AP
    // is added here; the signing writer adds the normal appearance, which stays
    // invisible because of these flags.
    var flags: Int64 = 132
    switch widget[PDFName("F")] {
    case .integer(let existing)?: flags = existing
    default: break
    }
    widget[PDFName("F")] = .integer(flags | 0x02 | 0x20)
    graph.objects[widgetID] = .dictionary(widget)
    return graph
  }
}

/// SIG-07: options for a hidden certificate signature. This is a separate type
/// from PDFSigningOptions so a caller cannot accidentally obtain a hidden
/// signature by flipping a boolean on a visible signing request.
public struct PDFHiddenCertificateSigningOptions: Sendable, Equatable {
  public let fieldName: String
  public let pageIndex: Int
  public let rect: [Double]
  public let reason: String?
  public let location: String?
  public let reservationBytes: Int
  public let signingTime: Date

  public init(
    fieldName: String = "HiddenSignature1", pageIndex: Int = 0,
    rect: [Double] = [72, 72, 172, 104], reason: String? = nil, location: String? = nil,
    reservationBytes: Int = 16_384, signingTime: Date = Date()
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

/// SIG-07: hidden certificate signing. The cryptographic work stays in
/// PDFSigningWriter; this service first adds the invisible empty field, then
/// signs it as an existing field, so no visible appearance is ever authored for
/// a hidden signature. Visible certificate signing and graphical marks keep
/// their own APIs.
public enum PDFHiddenCertificateSigner {
  /// Sign an unsigned graph (full rewrite) with a hidden certificate signature.
  public static func sign(
    _ graph: PDFGraph, identity: SecIdentity, options: PDFHiddenCertificateSigningOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard options.pageIndex >= 0, options.pageIndex < pageIDs.count else {
      throw PDFError(.malformed, "The hidden signature page does not exist")
    }
    let command = PDFHiddenSignatureFieldCommand(
      pageID: pageIDs[options.pageIndex], rect: options.rect, fieldName: options.fieldName)
    try command.validate(in: graph)
    let prepared = try command.apply(to: graph)
    let signingOptions = PDFSigningOptions(
      fieldName: options.fieldName, pageIndex: options.pageIndex, rect: options.rect,
      reason: options.reason, location: options.location,
      reservationBytes: options.reservationBytes, signingTime: options.signingTime,
      existingFieldName: options.fieldName)
    return try PDFSigningWriter.sign(
      prepared, identity: identity, options: signingOptions, limits: limits)
  }
}
