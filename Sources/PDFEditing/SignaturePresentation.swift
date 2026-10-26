import Foundation
import PDFCore

/// SIG-07: how a signature is presented to the reader. A visible certificate
/// signature paints a widget appearance; a hidden certificate signature carries
/// the same cryptographic evidence without any visible rectangle. Neither is
/// ever a substitute for a drawn/typed signature mark, which is only ink.
public enum PDFSignaturePresentationMode: String, Sendable, Equatable, CaseIterable {
  case visibleAppearance = "Visible appearance"
  case hiddenCertificate = "Hidden certificate"

  public var title: String { rawValue }

  /// One-line distinction used by the signing UI, reports and documentation.
  public var disclosure: String {
    switch self {
    case .visibleAppearance:
      return "Visible certificate signature: a cryptographic signature with a painted field appearance."
    case .hiddenCertificate:
      return "Hidden certificate signature: a cryptographic signature with no visible appearance. "
        + "It is not an ink or drawn signature."
    }
  }
}

/// SIG-07: the presentation of one signed field, classified from the widget, not
/// from the signer or from validation.
public enum PDFCertificateSignatureVisibility: String, Sendable, Equatable {
  case visible = "Visible"
  case hidden = "Hidden"
}

/// SIG-07: one certificate signature with its presentation. `reason` explains
/// why an apparently present field is classified as hidden.
public struct PDFCertificateSignaturePresentation: Sendable, Equatable {
  public let fieldName: String
  public let visibility: PDFCertificateSignatureVisibility
  public let pageIndex: Int?
  public let rect: [Double]?
  public let signerName: String?
  public let reason: String?
  public let isCertification: Bool

  public init(
    fieldName: String, visibility: PDFCertificateSignatureVisibility,
    pageIndex: Int?, rect: [Double]?, signerName: String?, reason: String?,
    isCertification: Bool
  ) {
    self.fieldName = fieldName
    self.visibility = visibility
    self.pageIndex = pageIndex
    self.rect = rect
    self.signerName = signerName
    self.reason = reason
    self.isCertification = isCertification
  }

  public var disclosure: String {
    switch visibility {
    case .visible:
      return "Visible certificate signature: cryptographic evidence plus a visible field appearance."
    case .hidden:
      return "Hidden certificate signature: cryptographic evidence only; nothing is drawn on the page."
    }
  }

  public var summaryLine: String {
    let signer = signerName.map { " — \($0)" } ?? ""
    let suffix = reason.map { " (\($0))" } ?? ""
    return "\(visibility.rawValue) certificate signature “\(fieldName)”\(signer)\(suffix)"
  }
}

/// SIG-07: one drawn/typed signature mark. SPDFGraphicalSignature annotations
/// are visual marks and never digital signatures.
public struct PDFGraphicalSignatureMark: Sendable, Equatable {
  public let annotationID: PDFObjectID?
  public let pageIndex: Int
  public let rect: [Double]?
  public let contents: String?
  public let subject: String?
  public let author: String?

  public init(
    annotationID: PDFObjectID?, pageIndex: Int, rect: [Double]?, contents: String?,
    subject: String?, author: String?
  ) {
    self.annotationID = annotationID
    self.pageIndex = pageIndex
    self.rect = rect
    self.contents = contents
    self.subject = subject
    self.author = author
  }

  public static let disclosure = "Visible signature mark — not a digital signature."

  public var summaryLine: String {
    let subjectText = subject.map { " (\($0))" } ?? ""
    return "Visible signature mark on page \(pageIndex + 1)\(subjectText) — not a digital signature"
  }
}

/// SIG-07: the complete presentation inventory of a document. Cryptographic
/// signatures and visual marks are kept in separate collections so a report,
/// menu or panel cannot present one as the other.
public struct PDFSignaturePresentationReport: Sendable, Equatable {
  public let certificateSignatures: [PDFCertificateSignaturePresentation]
  public let graphicalMarks: [PDFGraphicalSignatureMark]

  public init(
    certificateSignatures: [PDFCertificateSignaturePresentation],
    graphicalMarks: [PDFGraphicalSignatureMark]
  ) {
    self.certificateSignatures = certificateSignatures
    self.graphicalMarks = graphicalMarks
  }

  public var visibleCertificateSignatures: [PDFCertificateSignaturePresentation] {
    certificateSignatures.filter { $0.visibility == .visible }
  }
  public var hiddenCertificateSignatures: [PDFCertificateSignaturePresentation] {
    certificateSignatures.filter { $0.visibility == .hidden }
  }
  public var certificateSignatureCount: Int { certificateSignatures.count }
  public var visibleCertificateCount: Int { visibleCertificateSignatures.count }
  public var hiddenCertificateCount: Int { hiddenCertificateSignatures.count }
  public var graphicalMarkCount: Int { graphicalMarks.count }

  /// True only when cryptographic signature evidence is present. Drawn/typed
  /// marks alone never make this true.
  public var isCryptographicallySigned: Bool { !certificateSignatures.isEmpty }
  /// True when the document carries only visual signature marks.
  public var hasOnlyVisibleSignatureMarks: Bool {
    certificateSignatures.isEmpty && !graphicalMarks.isEmpty
  }

  /// UI/report lines. Every line keeps the cryptographic/mark distinction.
  public var summaryLines: [String] {
    var lines: [String] = []
    if certificateSignatures.isEmpty {
      lines.append("No certificate signatures (cryptographic evidence) were found.")
    } else {
      lines.append(
        "Certificate signatures: \(certificateSignatureCount) "
          + "(visible: \(visibleCertificateCount), hidden: \(hiddenCertificateCount))")
      lines.append(contentsOf: certificateSignatures.map(\.summaryLine))
    }
    if graphicalMarks.isEmpty {
      lines.append("No visible signature marks were found.")
    } else {
      lines.append(
        "Visible signature marks (not digital signatures): \(graphicalMarkCount)")
      lines.append(contentsOf: graphicalMarks.map(\.summaryLine))
    }
    return lines
  }

  /// Warnings for the UI and report footer.
  public var warnings: [String] {
    var warnings: [String] = []
    if !graphicalMarks.isEmpty && certificateSignatures.isEmpty {
      warnings.append(
        "This document has visible signature marks but no certificate signature; "
          + "the marks do not authenticate the document.")
    }
    if hiddenCertificateCount > 0 && visibleCertificateCount == 0 {
      warnings.append(
        "Certificate signatures are present without a visible appearance; "
          + "check the signature panel, not the page, to see them.")
    }
    return warnings
  }

  /// Plain-text report for menus, alerts, documentation and tests.
  public var plainText: String {
    (summaryLines + warnings).joined(separator: "\n")
  }
}

/// SIG-07: bounded presentation audit. Classification reads the widget shape
/// (rectangle, appearance, annotation flags) and the app's own mark annotations;
/// it deliberately does not infer anything from the signature dictionary.
public enum PDFSignaturePresentationAudit {
  public static func report(
    in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PDFSignaturePresentationReport {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let fields = try PDFSignatureFieldInventory.fields(in: graph, limits: limits)
    var signatures: [PDFCertificateSignaturePresentation] = []
    for field in fields where field.isSigned {
      let visibility = visibility(of: field, in: graph)
      signatures.append(
        PDFCertificateSignaturePresentation(
          fieldName: field.name, visibility: visibility.value, pageIndex: field.pageIndex,
          rect: field.rect, signerName: field.signature?.name,
          reason: visibility.reason,
          isCertification: field.docMDPPermission != nil
            || field.signature?.docMDPPermission != nil))
    }
    var marks: [PDFGraphicalSignatureMark] = []
    for (pageIndex, pageID) in pageIDs.enumerated() {
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations {
        guard annotation.dictionary[PDFName("Name")]
          == .name(PDFName("SPDFGraphicalSignature"))
        else { continue }
        marks.append(
          PDFGraphicalSignatureMark(
            annotationID: annotation.objectID, pageIndex: pageIndex,
            rect: rectValue(annotation.dictionary[PDFName("Rect")], in: graph),
            contents: textValue(annotation.dictionary[PDFName("Contents")], in: graph),
            subject: textValue(annotation.dictionary[PDFName("Subj")], in: graph),
            author: textValue(annotation.dictionary[PDFName("T")], in: graph)))
      }
    }
    return PDFSignaturePresentationReport(
      certificateSignatures: signatures, graphicalMarks: marks)
  }

  /// Whether a signature field currently paints a visible appearance. A missing
  /// widget, zero-area rectangle, missing normal appearance or a hidden/NoView
  /// annotation flag all mean the signature is hidden.
  public static func visibility(
    of field: PDFSignatureFieldInfo, in graph: PDFGraph
  ) -> (value: PDFCertificateSignatureVisibility, reason: String?) {
    guard let widgetID = field.widgetID else {
      return (.hidden, "the field has no widget")
    }
    guard case .dictionary(let widget)? = graph.objects[widgetID] else {
      return (.hidden, "the widget is missing")
    }
    if let flags = integerValue(widget[PDFName("F")]),
      flags & 0x01 != 0 || flags & 0x02 != 0 || flags & 0x20 != 0
    {
      return (.hidden, "the annotation has a hidden, invisible or NoView flag")
    }
    guard let rect = rectValue(widget[PDFName("Rect")], in: graph), rect.count == 4 else {
      return (.hidden, "the widget has no usable rectangle")
    }
    guard rect[2] - rect[0] > 0, rect[3] - rect[1] > 0 else {
      return (.hidden, "the widget rectangle has no area")
    }
    guard field.pageIndex != nil else {
      return (.hidden, "the widget is not attached to a page")
    }
    guard hasNormalAppearance(widget[PDFName("AP")], in: graph) else {
      return (.hidden, "the widget has no normal appearance")
    }
    return (.visible, nil)
  }

  static func hasNormalAppearance(_ value: PDFValue?, in graph: PDFGraph) -> Bool {
    guard case .dictionary(let appearance)? = resolved(value, in: graph) else { return false }
    switch appearance[PDFName("N")] {
    case .stream?: return true
    case .dictionary?: return true
    case .reference(let id)?:
      if case .stream? = graph.objects[id] { return true }
      if case .dictionary? = graph.objects[id] { return true }
      return false
    default:
      return false
    }
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    switch value {
    case .reference(let id)?: return graph.objects[id]
    default: return value
    }
  }

  static func rectValue(_ value: PDFValue?, in graph: PDFGraph) -> [Double]? {
    guard case .array(let array)? = resolved(value, in: graph), array.count == 4 else {
      return nil
    }
    var rect: [Double] = []
    for item in array {
      switch resolved(item, in: graph) {
      case .real(let number)?: rect.append(number)
      case .integer(let number)?: rect.append(Double(number))
      default: return nil
      }
    }
    return rect
  }

  static func integerValue(_ value: PDFValue?) -> Int? {
    switch value {
    case .integer(let number)?: return Int(number)
    default: return nil
    }
  }

  static func textValue(_ value: PDFValue?, in graph: PDFGraph) -> String? {
    switch resolved(value, in: graph) {
    case .string(let data)?:
      return AnnotationText.decode(data)
    case .name(let name)?:
      return String(decoding: name.bytes, as: UTF8.self)
    default:
      return nil
    }
  }
}
