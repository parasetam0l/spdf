import Foundation
import PDFCore

// MARK: - RED-05 categories, findings, review

public enum RedactionHiddenDataCategory: String, Sendable, Equatable, CaseIterable {
  case documentInfo, xmpMetadata, pageMetadata, comments, links, formValues, xfaForms,
    attachments, actions, optionalContent, alternateText, ocrLayers, thumbnails,
    privateApplicationData, documentIdentifiers, unreachableObjects, earlierRevisions,
    signatures, encryption

  public var title: String {
    switch self {
    case .documentInfo: return "Document information"
    case .xmpMetadata: return "XMP metadata"
    case .pageMetadata: return "Page metadata"
    case .comments: return "Comments and annotations"
    case .links: return "Links"
    case .formValues: return "Form field values"
    case .xfaForms: return "XFA form data"
    case .attachments: return "Attachments"
    case .actions: return "Script/launch actions"
    case .optionalContent: return "Optional-content layers"
    case .alternateText: return "Alternate and actual text"
    case .ocrLayers: return "Generated OCR text layers"
    case .thumbnails: return "Page thumbnails"
    case .privateApplicationData: return "Private application data"
    case .documentIdentifiers: return "Document identifiers"
    case .unreachableObjects: return "Unreachable objects"
    case .earlierRevisions: return "Earlier revisions"
    case .signatures: return "Digital signatures"
    case .encryption: return "Encryption"
    }
  }
}

public struct RedactionHiddenDataFinding: Sendable, Equatable {
  public enum State: String, Sendable, Equatable { case present, uninspectable, protocolLimited }
  public let category: RedactionHiddenDataCategory
  public let state: State
  public let count: Int
  public let details: [String]

  public init(
    category: RedactionHiddenDataCategory, state: State = .present, count: Int,
    details: [String] = []
  ) {
    self.category = category
    self.state = state
    self.count = count
    self.details = details
  }

  public var summary: String {
    var text = "\(category.title): \(count)"
    if state == .uninspectable { text += " (uninspectable)" }
    if state == .protocolLimited { text += " (protocol-limited)" }
    return text
  }
}

public struct RedactionHiddenDataReview: Sendable, Equatable {
  public let findings: [RedactionHiddenDataFinding]
  public let pageCount: Int
  public let summary: String

  public var uninspectable: [String] {
    findings.filter { $0.state == .uninspectable }.map(\.category.title)
  }
  public var protocolLimited: [String] {
    findings.filter { $0.state == .protocolLimited }.map(\.category.title)
  }
  public var presentCategories: [RedactionHiddenDataCategory] {
    findings.filter { $0.count > 0 }.map(\.category)
  }
  public func count(_ category: RedactionHiddenDataCategory) -> Int {
    findings.first { $0.category == category }?.count ?? 0
  }
  public func details(_ category: RedactionHiddenDataCategory) -> [String] {
    findings.first { $0.category == category }?.details ?? []
  }

  public init(findings: [RedactionHiddenDataFinding], pageCount: Int, summary: String) {
    self.findings = findings
    self.pageCount = pageCount
    self.summary = summary
  }
}

// MARK: - RED-05 selective policy

public struct RedactionSanitizationPolicy: Sendable, Equatable {
  public var removeDocumentInfo: Bool
  public var removeXMPMetadata: Bool
  public var removePageMetadata: Bool
  public var removeComments: Bool
  public var keepLinks: Bool
  public var removeAttachments: Bool
  public var allowedAttachmentNames: Set<String>
  public var removeActions: Bool
  public var removeOptionalContent: Bool
  public var removeAlternateText: Bool
  public var clearFormValues: Bool
  public var removeXFA: Bool
  public var removeOCRLayers: Bool
  public var removePrivateApplicationData: Bool
  public var removeDocumentIdentifiers: Bool
  public var removeThumbnails: Bool
  public var removeUnreachableObjects: Bool

  public init(
    removeDocumentInfo: Bool = true, removeXMPMetadata: Bool = true,
    removePageMetadata: Bool = true, removeComments: Bool = true, keepLinks: Bool = true,
    removeAttachments: Bool = true, allowedAttachmentNames: Set<String> = [],
    removeActions: Bool = true, removeOptionalContent: Bool = true,
    removeAlternateText: Bool = true, clearFormValues: Bool = true,
    removeXFA: Bool = true, removeOCRLayers: Bool = true,
    removePrivateApplicationData: Bool = true, removeDocumentIdentifiers: Bool = true,
    removeThumbnails: Bool = true, removeUnreachableObjects: Bool = true
  ) {
    self.removeDocumentInfo = removeDocumentInfo
    self.removeXMPMetadata = removeXMPMetadata
    self.removePageMetadata = removePageMetadata
    self.removeComments = removeComments
    self.keepLinks = keepLinks
    self.removeAttachments = removeAttachments
    self.allowedAttachmentNames = allowedAttachmentNames
    self.removeActions = removeActions
    self.removeOptionalContent = removeOptionalContent
    self.removeAlternateText = removeAlternateText
    self.clearFormValues = clearFormValues
    self.removeXFA = removeXFA
    self.removeOCRLayers = removeOCRLayers
    self.removePrivateApplicationData = removePrivateApplicationData
    self.removeDocumentIdentifiers = removeDocumentIdentifiers
    self.removeThumbnails = removeThumbnails
    self.removeUnreachableObjects = removeUnreachableObjects
  }

  public static var secure: RedactionSanitizationPolicy { RedactionSanitizationPolicy() }

  public static var keepEverything: RedactionSanitizationPolicy {
    RedactionSanitizationPolicy(
      removeDocumentInfo: false, removeXMPMetadata: false, removePageMetadata: false,
      removeComments: false, removeAttachments: false, removeActions: false,
      removeOptionalContent: false, removeAlternateText: false, clearFormValues: false,
      removeXFA: false, removeOCRLayers: false, removePrivateApplicationData: false,
      removeDocumentIdentifiers: false, removeThumbnails: false,
      removeUnreachableObjects: false)
  }

  public var summary: String {
    var parts: [String] = []
    if removeDocumentInfo { parts.append("document info") }
    if removeXMPMetadata { parts.append("XMP") }
    if removePageMetadata { parts.append("page metadata") }
    if removeComments { parts.append("comments") }
    if !keepLinks { parts.append("links") }
    if removeAttachments { parts.append("attachments") }
    if removeActions { parts.append("actions") }
    if removeOptionalContent { parts.append("optional content") }
    if removeAlternateText { parts.append("alternate text") }
    if clearFormValues { parts.append("form values") }
    if removeXFA { parts.append("XFA") }
    if removeOCRLayers { parts.append("OCR layers") }
    if removePrivateApplicationData { parts.append("private data") }
    if removeDocumentIdentifiers { parts.append("identifiers") }
    if removeThumbnails { parts.append("thumbnails") }
    return parts.isEmpty ? "remove nothing" : "remove " + parts.joined(separator: ", ")
  }
}

// MARK: - RED-05 report

public struct RedactionSanitizationReport: Sendable, Equatable {
  public enum Outcome: String, Sendable, Equatable { case removed, kept, uninspectable, notPresent }

  public struct CategoryResult: Sendable, Equatable {
    public let category: RedactionHiddenDataCategory
    public let outcome: Outcome
    public let count: Int
    public let details: [String]

    public init(
      category: RedactionHiddenDataCategory, outcome: Outcome, count: Int, details: [String]
    ) {
      self.category = category
      self.outcome = outcome
      self.count = count
      self.details = details
    }
  }

  public let before: RedactionHiddenDataReview
  public let after: RedactionHiddenDataReview
  public let results: [CategoryResult]
  public let transformations: [String]
  public let uninspectable: [String]
  public let protocolLimited: [String]
  public let policy: RedactionSanitizationPolicy

  public init(
    before: RedactionHiddenDataReview, after: RedactionHiddenDataReview,
    results: [CategoryResult], transformations: [String], uninspectable: [String],
    protocolLimited: [String], policy: RedactionSanitizationPolicy
  ) {
    self.before = before
    self.after = after
    self.results = results
    self.transformations = transformations
    self.uninspectable = uninspectable
    self.protocolLimited = protocolLimited
    self.policy = policy
  }

  public var removed: [CategoryResult] { results.filter { $0.outcome == .removed } }
  public var kept: [CategoryResult] { results.filter { $0.outcome == .kept } }
  public var isFullySanitized: Bool { uninspectable.isEmpty && protocolLimited.isEmpty }

  public func outcome(_ category: RedactionHiddenDataCategory) -> Outcome {
    results.first { $0.category == category }?.outcome ?? .notPresent
  }

  public var summary: String {
    var lines = ["Sanitized copy: " + policy.summary]
    for result in results where result.outcome != .notPresent {
      lines.append("  \(result.outcome.rawValue): \(result.category.title) (\(result.count))")
    }
    if !uninspectable.isEmpty {
      lines.append("  uninspectable: " + uninspectable.joined(separator: "; "))
    }
    if !protocolLimited.isEmpty {
      lines.append("  protocol-limited: " + protocolLimited.joined(separator: "; "))
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - RED-05 inventory

public enum RedactionHiddenDataReviewer {}

extension RedactionHiddenDataReviewer {
  struct Snapshot {
    let pageIDs: [PDFObjectID]
    let infoKeys: [String]
    let xmpCount: Int
    let pageMetadataCount: Int
    let commentDetails: [String]
    let linkCount: Int
    let formValueDetails: [String]
    let xfaPresent: Bool
    let attachmentNames: [String]
    let actionDetails: [String]
    let ocgNames: [String]
    let formOCPaint: Bool
    let altDetails: [String]
    let ocrPageCount: Int
    let thumbnailCount: Int
    let privateDataCount: Int
    let hasIdentifier: Bool
    let unreachableCount: Int
    let earlierRevisions: Bool
    let signatureCount: Int
    let encrypted: Bool

    init(graph: PDFGraph, limits: PDFLimits, revisionCount: Int) throws {
      let pages = (try? PDFPageTree.pageIDs(in: graph)) ?? []
      pageIDs = pages
      let pageSet = Set(pages)
      let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: graph)
      var infoKeys: [String] = []
      if case .reference(let infoID)? = graph.trailer[PDFName("Info")],
        case .dictionary(let info)? = graph.objects[infoID]
      {
        infoKeys = info.keys.map { String(decoding: $0.bytes, as: UTF8.self) }.sorted()
      }
      self.infoKeys = infoKeys
      var xmpCount = 0
      var pageMetadataCount = 0
      var commentDetails: [String] = []
      var linkCount = 0
      var formValueDetails: [String] = []
      var attachmentNames: [String] = []
      var actionDetails: [String] = []
      var ocgNames: [String] = []
      var altDetails: [String] = []
      var privateDataCount = 0
      var thumbnailCount = 0
      var formOCPaint = false
      for (id, value) in graph.objects {
        var dictionary: [PDFName: PDFValue]?
        var stream: PDFStream?
        switch value {
        case .dictionary(let direct): dictionary = direct
        case .stream(let value): dictionary = value.dictionary; stream = value
        default: break
        }
        guard let dictionary else { continue }
        if dictionary[PDFName("Type")] == .name(PDFName("Metadata")) { xmpCount += 1 }
        if dictionary[PDFName("Type")] == .name(PDFName("OCG")) {
          if case .string(let data)? = dictionary[PDFName("Name")] {
            ocgNames.append(AnnotationText.decode(data))
          } else {
            ocgNames.append("unnamed layer \(id.number)")
          }
        }
        if dictionary[PDFName("PieceInfo")] != nil { privateDataCount += 1 }
        if dictionary[PDFName("LastModified")] != nil { privateDataCount += 1 }
        for key in [PDFName("Alt"), PDFName("ActualText")] {
          guard case .string(let data)? = dictionary[key] else { continue }
          let text = AnnotationText.decode(data)
          altDetails.append(text.isEmpty ? String(decoding: key.bytes, as: UTF8.self) : text)
        }
        if dictionary[PDFName("FT")] != nil {
          var hasValue = false
          for key in [PDFName("V"), PDFName("DV"), PDFName("RV")] {
            if let value = dictionary[key] {
              if case .null = value { continue }
              hasValue = true
            }
          }
          if hasValue {
            var name = "field \(id.number)"
            if case .string(let data)? = dictionary[PDFName("T")] {
              name = AnnotationText.decode(data)
            }
            formValueDetails.append(name)
          }
        }
        if dictionary[PDFName("Subtype")] == .name(PDFName("Form")), let stream,
          let decoded = try? PDFFilters.decoded(stream, limits: limits),
          String(decoding: decoded, as: UTF8.self).contains("/OC")
        {
          formOCPaint = true
        }
        if pageSet.contains(id) {
          if dictionary[PDFName("Metadata")] != nil { pageMetadataCount += 1 }
          if dictionary[PDFName("Thumb")] != nil { thumbnailCount += 1 }
        }
        if dictionary[PDFName("Type")] == .name(PDFName("Filespec")),
          case .string(let data)? = dictionary[PDFName("F")]
        {
          attachmentNames.append(AnnotationText.decode(data))
        }
        if dictionary[PDFName("S")] == .name(PDFName("JavaScript")) {
          actionDetails.append("JavaScript action")
        } else if dictionary[PDFName("S")] == .name(PDFName("Launch")) {
          actionDetails.append("Launch action")
        }
      }
      for pageID in pages {
        let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
        for annotation in annotations {
          if annotation.subtype == PDFName("Link") {
            linkCount += 1
          } else if annotation.subtype != PDFName("Widget") {
            let subtype = annotation.subtype.map {
              String(decoding: $0.bytes, as: UTF8.self)
            } ?? "annotation"
            commentDetails.append(subtype)
          }
        }
      }
      self.xmpCount = xmpCount
      self.pageMetadataCount = pageMetadataCount
      self.commentDetails = commentDetails
      self.linkCount = linkCount
      self.formValueDetails = formValueDetails
      self.xfaPresent = Self.hasXFA(in: graph)
      self.attachmentNames = Array(Set(attachmentNames)).sorted()
      self.actionDetails = actionDetails
      self.ocgNames = ocgNames
      self.formOCPaint = formOCPaint
      self.altDetails = altDetails
      self.ocrPageCount = pages.filter {
        OCRLayer.hasGeneratedLayer(in: graph, pageID: $0)
      }.count
      self.thumbnailCount = thumbnailCount
      self.privateDataCount = privateDataCount
      self.hasIdentifier = graph.trailer[PDFName("ID")] != nil
      self.unreachableCount = max(0, graph.objects.count - reachable.count)
      self.earlierRevisions = graph.trailer[PDFName("Prev")] != nil || revisionCount > 1
      self.signatureCount = (try? PDFSignatureInventory.signatures(in: graph))?.count ?? 0
      self.encrypted = graph.trailer[PDFName("Encrypt")] != nil
    }

    static func hasXFA(in graph: PDFGraph) -> Bool {
      guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(let catalog)? = graph.objects[rootID]
      else { return false }
      if case .dictionary(let acro)? = catalog[PDFName("AcroForm")] {
        return acro[PDFName("XFA")] != nil
      }
      if case .reference(let acroID)? = catalog[PDFName("AcroForm")],
        case .dictionary(let acro)? = graph.objects[acroID]
      {
        return acro[PDFName("XFA")] != nil
      }
      return false
    }

    var review: RedactionHiddenDataReview {
      func finding(
        _ category: RedactionHiddenDataCategory, _ count: Int, _ details: [String] = [],
        state: RedactionHiddenDataFinding.State = .present
      ) -> RedactionHiddenDataFinding {
        RedactionHiddenDataFinding(
          category: category, state: state, count: count, details: details)
      }
      var findings: [RedactionHiddenDataFinding] = [
        finding(.documentInfo, infoKeys.count, infoKeys),
        finding(.xmpMetadata, xmpCount),
        finding(.pageMetadata, pageMetadataCount),
        finding(.comments, commentDetails.count, Array(commentDetails.prefix(12))),
        finding(.links, linkCount),
        finding(.formValues, formValueDetails.count, Array(formValueDetails.prefix(12))),
        finding(.xfaForms, xfaPresent ? 1 : 0),
        finding(.attachments, attachmentNames.count, attachmentNames),
        finding(.actions, actionDetails.count, Array(actionDetails.prefix(12))),
        finding(
          .optionalContent, ocgNames.count + (formOCPaint ? 1 : 0),
          Array(ocgNames.prefix(12)) + (formOCPaint ? ["form XObject hidden-layer paint"] : []),
          state: formOCPaint ? .uninspectable : .present),
        finding(.alternateText, altDetails.count, Array(altDetails.prefix(12))),
        finding(.ocrLayers, ocrPageCount),
        finding(.thumbnails, thumbnailCount),
        finding(.privateApplicationData, privateDataCount),
        finding(.documentIdentifiers, hasIdentifier ? 1 : 0),
        finding(.unreachableObjects, unreachableCount),
        finding(.earlierRevisions, earlierRevisions ? 1 : 0),
        finding(.signatures, signatureCount),
        finding(.encryption, encrypted ? 1 : 0),
      ]
      findings.removeAll { $0.count == 0 && $0.state == .present }
      var lines = ["Retained data review: \(pageIDs.count) page(s)"]
      for finding in findings { lines.append("  " + finding.summary) }
      if findings.isEmpty { lines.append("  no reviewable retained data found") }
      return RedactionHiddenDataReview(
        findings: findings, pageCount: pageIDs.count, summary: lines.joined(separator: "\n"))
    }
  }

  public static func review(
    in graph: PDFGraph, limits: PDFLimits = PDFLimits(), revisionCount: Int = 1
  ) throws -> RedactionHiddenDataReview {
    try Snapshot(graph: graph, limits: limits, revisionCount: revisionCount).review
  }
}

// MARK: - RED-05 sanitizer

public enum RedactionSanitizer {
  public static func sanitize(
    in input: PDFGraph, policy: RedactionSanitizationPolicy,
    limits: PDFLimits = PDFLimits(), revisionCount: Int = 1
  ) throws -> (graph: PDFGraph, report: RedactionSanitizationReport) {
    if input.trailer[PDFName("Encrypt")] != nil {
      throw PDFError(.unsupported, "Encrypted documents must be unlocked before sanitization")
    }
    let signatures = (try? PDFSignatureInventory.signatures(in: input)) ?? []
    guard signatures.isEmpty else {
      throw PDFError(
        .unsupported,
        "This document is digitally signed; sanitizing it would invalidate the signature")
    }
    let before = try RedactionHiddenDataReviewer.review(
      in: input, limits: limits, revisionCount: revisionCount)
    var graph = input
    var transformations: [String] = []
    var uninspectable: [String] = []
    var protocolLimited: [String] = []

    if policy.removeDocumentInfo, graph.trailer[PDFName("Info")] != nil {
      graph.trailer[PDFName("Info")] = nil
      transformations.append("removed document information dictionary")
    }
    if policy.removeXMPMetadata || policy.removePageMetadata {
      let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
      var removed = 0
      if policy.removeXMPMetadata {
        for (id, value) in graph.objects {
          var dictionary: [PDFName: PDFValue]?
          if case .dictionary(let direct) = value { dictionary = direct }
          if case .stream(let stream) = value { dictionary = stream.dictionary }
          if dictionary?[PDFName("Type")] == .name(PDFName("Metadata")) {
            graph.objects[id] = nil
            removed += 1
          }
        }
        if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
          case .dictionary(var catalog)? = graph.objects[rootID]
        {
          catalog[PDFName("Metadata")] = nil
          graph.objects[rootID] = .dictionary(catalog)
        }
      }
      if policy.removePageMetadata {
        for pageID in pageIDs {
          guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
          if page[PDFName("Metadata")] != nil {
            page[PDFName("Metadata")] = nil
            graph.objects[pageID] = .dictionary(page)
            removed += 1
          }
        }
      }
      if removed > 0 { transformations.append("removed \(removed) metadata entries") }
    }
    if policy.removeAttachments {
      let embeddedIDs = SanitizerPass.embeddedFileIDs(in: graph)
      var removedIDs: Set<PDFObjectID> = []
      for id in embeddedIDs {
        let name = SanitizerPass.embeddedFileName(id: id, in: graph) ?? "unnamed"
        if !policy.allowedAttachmentNames.contains(name) { removedIDs.insert(id) }
      }
      if !removedIDs.isEmpty {
        var wrapperIDs: Set<PDFObjectID> = []
        for (id, value) in graph.objects {
          guard case .dictionary(let dictionary) = value,
            case .dictionary(let ef)? = dictionary[PDFName("EF")]
          else { continue }
          if ef.values.contains(where: { value in
            if case .reference(let target) = value { return removedIDs.contains(target) }
            return false
          }) { wrapperIDs.insert(id) }
        }
        let removed = removedIDs.union(wrapperIDs)
        for id in removed { graph.objects[id] = nil }
        SanitizerPass.removeReferences(to: removed, in: &graph)
        transformations.append("removed \(removedIDs.count) attachments/embedded files")
      }
    }
    if policy.removeActions {
      var removedActions = 0
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID]
      {
        for key in [PDFName("OpenAction"), PDFName("AA"), PDFName("JavaScript")]
        where catalog[key] != nil {
          catalog[key] = nil
          removedActions += 1
        }
        if case .dictionary(var names)? = catalog[PDFName("Names")] {
          if names[PDFName("JavaScript")] != nil {
            names[PDFName("JavaScript")] = nil
            removedActions += 1
          }
          catalog[PDFName("Names")] = names.isEmpty ? nil : .dictionary(names)
        }
        graph.objects[rootID] = .dictionary(catalog)
      }
      var unsafeActionIDs: Set<PDFObjectID> = []
      for (id, value) in graph.objects {
        guard case .dictionary(let dictionary) = value else { continue }
        if dictionary[PDFName("S")] == .name(PDFName("JavaScript"))
          || dictionary[PDFName("S")] == .name(PDFName("Launch"))
        { unsafeActionIDs.insert(id) }
      }
      for (id, value) in graph.objects where !unsafeActionIDs.contains(id) {
        guard case .dictionary(var dictionary) = value else { continue }
        var changed = false
        if let action = dictionary[PDFName("A")], isUnsafeAction(action, unsafe: unsafeActionIDs) {
          dictionary[PDFName("A")] = nil
          changed = true
        }
        if case .dictionary(var events)? = dictionary[PDFName("AA")] {
          for (event, eventAction) in events
          where isUnsafeAction(eventAction, unsafe: unsafeActionIDs) {
            events[event] = nil
            changed = true
          }
          dictionary[PDFName("AA")] = events.isEmpty ? nil : .dictionary(events)
        }
        if changed { graph.objects[id] = .dictionary(dictionary) }
      }
      if !unsafeActionIDs.isEmpty {
        for id in unsafeActionIDs { graph.objects[id] = nil }
        SanitizerPass.removeReferences(to: unsafeActionIDs, in: &graph)
        removedActions += unsafeActionIDs.count
      }
      if removedActions > 0 { transformations.append("removed \(removedActions) action entries") }
    }
    if policy.removeComments {
      let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
      var removedIDs: Set<PDFObjectID> = []
      for pageID in pageIDs {
        let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
        for annotation in annotations {
          if annotation.subtype == PDFName("Widget") { continue }
          if policy.keepLinks && annotation.subtype == PDFName("Link") { continue }
          if let objectID = annotation.objectID { removedIDs.insert(objectID) }
        }
      }
      if !removedIDs.isEmpty {
        var removedCount = 0
        for pageID in pageIDs {
          guard case .dictionary(var page)? = graph.objects[pageID],
            case .array(let annots)? = page[PDFName("Annots")]
          else { continue }
          let kept = annots.filter { value in
            if case .reference(let id) = value { return !removedIDs.contains(id) }
            return true
          }
          if kept.count != annots.count {
            removedCount += annots.count - kept.count
            page[PDFName("Annots")] = kept.isEmpty ? nil : .array(kept)
            graph.objects[pageID] = .dictionary(page)
          }
        }
        for id in removedIDs { graph.objects[id] = nil }
        SanitizerPass.removeReferences(to: removedIDs, in: &graph)
        if removedCount > 0 {
          transformations.append("removed \(removedCount) comment annotations")
        }
      }
    }
    if policy.removeOptionalContent {
      var ocgIDs: Set<PDFObjectID> = []
      for (id, value) in graph.objects {
        if case .dictionary(let dictionary) = value,
          dictionary[PDFName("Type")] == .name(PDFName("OCG"))
        { ocgIDs.insert(id) }
      }
      if !ocgIDs.isEmpty {
        let stripped = try stripOptionalContent(ocgIDs: ocgIDs, in: graph, limits: limits)
        graph = stripped.graph
        if !stripped.removedSections.isEmpty {
          transformations.append(
            "removed \(stripped.removedSections.count) optional-content marked sections")
        }
        uninspectable.append(contentsOf: stripped.uninspectable)
        for id in ocgIDs { graph.objects[id] = nil }
        SanitizerPass.removeReferences(to: ocgIDs, in: &graph)
      }
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID]
      {
        catalog[PDFName("OCProperties")] = nil
        graph.objects[rootID] = .dictionary(catalog)
      }
      for (id, value) in graph.objects {
        guard case .stream(let stream) = value,
          stream.dictionary[PDFName("Subtype")] == .name(PDFName("Form")),
          let decoded = try? PDFFilters.decoded(stream, limits: limits),
          String(decoding: decoded, as: UTF8.self).contains("/OC")
        else { continue }
        uninspectable.append(
          "form XObject \(id.number) paints optional-content marked content; it was retained")
      }
    }
    if policy.removeAlternateText {
      var removedAlt = 0
      for (id, value) in graph.objects {
        switch value {
        case .dictionary(var dictionary):
          var changed = false
          for key in [PDFName("Alt"), PDFName("ActualText")] where dictionary[key] != nil {
            dictionary[key] = nil
            changed = true
            removedAlt += 1
          }
          if changed { graph.objects[id] = .dictionary(dictionary) }
        case .stream(var stream):
          var changed = false
          for key in [PDFName("Alt"), PDFName("ActualText")]
          where stream.dictionary[key] != nil {
            stream.dictionary[key] = nil
            changed = true
            removedAlt += 1
          }
          if changed { graph.objects[id] = .stream(stream) }
        default:
          break
        }
      }
      if removedAlt > 0 {
        transformations.append("removed \(removedAlt) alternate/actual text entries")
      }
    }
    if policy.clearFormValues || policy.removeXFA {
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID]
      {
        var acroForm: [PDFName: PDFValue] = [:]
        if case .dictionary(let existing)? = catalog[PDFName("AcroForm")] {
          acroForm = existing
        } else if case .reference(let acroID)? = catalog[PDFName("AcroForm")],
          case .dictionary(let existing)? = graph.objects[acroID]
        {
          acroForm = existing
        }
        if acroForm[PDFName("XFA")] != nil {
          if policy.removeXFA {
            acroForm[PDFName("XFA")] = nil
            transformations.append("removed XFA form data")
          } else {
            protocolLimited.append("XFA form data retained")
          }
          catalog[PDFName("AcroForm")] = acroForm.isEmpty ? nil : .dictionary(acroForm)
          graph.objects[rootID] = .dictionary(catalog)
        }
      }
      if policy.clearFormValues {
        var cleared = 0
        for (id, value) in graph.objects {
          guard case .dictionary(var dictionary) = value,
            dictionary[PDFName("FT")] != nil
          else { continue }
          var changed = false
          for key in [PDFName("V"), PDFName("DV"), PDFName("RV")]
          where dictionary[key] != nil {
            dictionary[key] = nil
            changed = true
          }
          if changed {
            graph.objects[id] = .dictionary(dictionary)
            cleared += 1
          }
        }
        for (id, value) in graph.objects {
          if case .dictionary(var dictionary) = value,
            dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
          {
            dictionary[PDFName("AP")] = nil
            graph.objects[id] = .dictionary(dictionary)
          }
        }
        if cleared > 0 { transformations.append("cleared \(cleared) form field values") }
      }
    }
    if policy.removeOCRLayers {
      let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
      var removedLayers = 0
      for pageID in pageIDs where OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID) {
        try OCRLayer.removeLayer(pageID: pageID, in: &graph)
        removedLayers += 1
      }
      if removedLayers > 0 {
        transformations.append("removed \(removedLayers) generated OCR layers")
      }
    }
    if policy.removeThumbnails {
      let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
      var removedThumbs = 0
      for pageID in pageIDs {
        guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
        if page[PDFName("Thumb")] != nil {
          page[PDFName("Thumb")] = nil
          graph.objects[pageID] = .dictionary(page)
          removedThumbs += 1
        }
      }
      if removedThumbs > 0 { transformations.append("removed \(removedThumbs) page thumbnails") }
    }
    if policy.removePrivateApplicationData {
      var removedPrivate = 0
      for (id, value) in graph.objects {
        switch value {
        case .dictionary(var dictionary):
          var changed = false
          for key in [PDFName("PieceInfo"), PDFName("LastModified")]
          where dictionary[key] != nil {
            dictionary[key] = nil
            changed = true
            removedPrivate += 1
          }
          if changed { graph.objects[id] = .dictionary(dictionary) }
        case .stream(var stream):
          var changed = false
          for key in [PDFName("PieceInfo"), PDFName("LastModified")]
          where stream.dictionary[key] != nil {
            stream.dictionary[key] = nil
            changed = true
            removedPrivate += 1
          }
          if changed { graph.objects[id] = .stream(stream) }
        default:
          break
        }
      }
      if removedPrivate > 0 {
        transformations.append("removed \(removedPrivate) private data entries")
      }
    }
    if policy.removeDocumentIdentifiers, graph.trailer[PDFName("ID")] != nil {
      graph.trailer[PDFName("ID")] = nil
      transformations.append("removed document identifiers")
    }
    for key in [PDFName("Prev"), PDFName("XRefStm")] where graph.trailer[key] != nil {
      graph.trailer[key] = nil
    }
    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: graph)
    var pruned = 0
    for id in graph.objects.keys where !reachable.contains(id) {
      graph.objects[id] = nil
      pruned += 1
    }
    if pruned > 0 { transformations.append("pruned \(pruned) unreachable objects") }
    try graph.validate(limits: limits)
    let report = buildReport(
      graph: graph, policy: policy, before: before, transformations: transformations,
      uninspectable: uninspectable, protocolLimited: protocolLimited, limits: limits)
    return (graph, report)
  }

  static func isUnsafeAction(_ value: PDFValue, unsafe: Set<PDFObjectID>) -> Bool {
    switch value {
    case .reference(let id): return unsafe.contains(id)
    case .dictionary(let dictionary):
      return dictionary[PDFName("S")] == .name(PDFName("JavaScript"))
        || dictionary[PDFName("S")] == .name(PDFName("Launch"))
    default: return false
    }
  }

  struct OptionalContentStripping {
    var graph: PDFGraph
    var removedSections: [String] = []
    var uninspectable: [String] = []
  }

  static func stripOptionalContent(
    ocgIDs: Set<PDFObjectID>, in graph: PDFGraph, limits: PDFLimits
  ) throws -> OptionalContentStripping {
    var result = OptionalContentStripping(graph: graph)
    let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
    for pageID in pageIDs {
      let content: PageContent
      do {
        content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
      } catch {
        result.uninspectable.append("page \(pageID.number): content cannot be inspected")
        continue
      }
      guard content.segments.allSatisfy(\.isEditable) else {
        result.uninspectable.append(
          "page \(pageID.number): filtered content cannot be inspected for hidden layers")
        continue
      }
      var properties: [PDFName: PDFValue] = [:]
      func resolvedPropertyDictionary(_ value: PDFValue) -> [PDFName: PDFValue]? {
        switch value {
        case .dictionary(let dictionary): return dictionary
        case .reference(let id):
          if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
          if case .stream(let stream)? = graph.objects[id] { return stream.dictionary }
          return nil
        default: return nil
        }
      }
      if case .dictionary(let page)? = graph.objects[pageID] {
        if case .dictionary(let resources)? = page[PDFName("Resources")],
          case .dictionary(let props)? = resources[PDFName("Properties")]
        {
          properties = props
        } else if case .reference(let resourcesID)? = page[PDFName("Resources")],
          case .dictionary(let resources)? = graph.objects[resourcesID],
          case .dictionary(let props)? = resources[PDFName("Properties")]
        {
          properties = props
        }
      }
      var ranges: [Range<Int>] = []
      var stack: [(start: Int, removed: Bool)] = []
      for instruction in content.instructions {
        switch instruction.operatorName {
        case "BMC", "BDC":
          let start = instruction.operands.first?.span.lowerBound
            ?? instruction.span.lowerBound
          var targets: [PDFObjectID] = []
          var resolved = true
          if instruction.operatorName == "BDC" {
            if case .name(let propertyName)? = instruction.operands.last?.value {
              if let value = properties[propertyName],
                let property = resolvedPropertyDictionary(value)
              {
                targets = ocgTargets(property)
              } else {
                resolved = false
              }
            } else if let value = instruction.operands.last?.value,
              let property = resolvedPropertyDictionary(value)
            {
              targets = ocgTargets(property)
            }
          }
          let removed = resolved && !targets.isEmpty && targets.allSatisfy {
            ocgIDs.contains($0)
          }
          if !resolved {
            result.uninspectable.append(
              "page \(pageID.number): optional-content marked content with an unknown property")
          } else if !targets.isEmpty && !removed {
            result.uninspectable.append(
              "page \(pageID.number): marked content references a retained layer")
          }
          stack.append((start: start, removed: removed))
        case "EMC":
          guard let entry = stack.popLast() else { continue }
          if entry.removed { ranges.append(entry.start..<instruction.span.upperBound) }
        default:
          break
        }
      }
      if !stack.isEmpty {
        result.uninspectable.append(
          "page \(pageID.number): unbalanced optional-content marked content")
      }
      guard !ranges.isEmpty else { continue }
      let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
      var merged: [Range<Int>] = []
      for range in sorted {
        if let last = merged.last, range.lowerBound < last.upperBound {
          merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        } else {
          merged.append(range)
        }
      }
      result.graph = try content.replacing(
        ranges: merged.map { ($0, [UInt8]()) }, in: result.graph, limits: limits)
      result.removedSections.append(contentsOf: merged.map {
        "page \(pageID.number): \($0.count) bytes"
      })
    }
    return result
  }

  static func ocgTargets(_ property: [PDFName: PDFValue]) -> [PDFObjectID] {
    func ids(_ value: PDFValue?) -> [PDFObjectID] {
      switch value {
      case .reference(let id)?: return [id]
      case .array(let array)?:
        return array.compactMap {
          if case .reference(let id) = $0 { return id }
          return nil
        }
      default: return []
      }
    }
    if let ocgs = property[PDFName("OCGs")] { return ids(ocgs) }
    return ids(property[PDFName("OC")])
  }

  static func buildReport(
    graph: PDFGraph, policy: RedactionSanitizationPolicy,
    before: RedactionHiddenDataReview, transformations: [String],
    uninspectable: [String], protocolLimited: [String], limits: PDFLimits
  ) -> RedactionSanitizationReport {
    let after: RedactionHiddenDataReview
    do {
      after = try RedactionHiddenDataReviewer.review(in: graph, limits: limits)
    } catch {
      after = RedactionHiddenDataReview(
        findings: [], pageCount: before.pageCount, summary: "review unavailable")
    }
    func result(
      _ category: RedactionHiddenDataCategory
    ) -> RedactionSanitizationReport.CategoryResult {
      let old = before.count(category)
      let new = after.count(category)
      let details = before.details(category)
      if new < old {
        return .init(category: category, outcome: .removed, count: old - new, details: details)
      }
      if new > 0 {
        return .init(category: category, outcome: .kept, count: new, details: details)
      }
      return .init(category: category, outcome: .notPresent, count: 0, details: [])
    }
    let categories = RedactionHiddenDataCategory.allCases.filter { before.count($0) > 0 }
    return RedactionSanitizationReport(
      before: before, after: after, results: categories.map(result),
      transformations: transformations, uninspectable: uninspectable,
      protocolLimited: protocolLimited, policy: policy)
  }
}

// MARK: - RED-05 verification on the final saved bytes

public struct RedactionSanitizationVerification: Sendable, Equatable {
  public let passed: Bool
  public let issues: [String]
  public let checks: [String]
  public let survivingSeeds: [String]
  public let uninspectable: [String]

  public var summary: String {
    if passed { return "Sanitized output verified against the chosen policy." }
    return "Sanitized output needs attention: " + issues.joined(separator: "; ")
  }
}

public enum RedactionSanitizedOutputVerifier {
  public static func verify(
    data: Data, report: RedactionSanitizationReport, seeds: [String] = [],
    limits: PDFLimits = PDFLimits()
  ) -> RedactionSanitizationVerification {
    var issues: [String] = []
    var checks: [String] = []
    let parsed: ParsedPDF
    do {
      parsed = try PDFParser.parse(data, limits: limits)
    } catch {
      return RedactionSanitizationVerification(
        passed: false, issues: ["output does not parse"], checks: [],
        survivingSeeds: [], uninspectable: report.uninspectable)
    }
    checks.append("reparses as a valid PDF")
    if parsed.graph.trailer[PDFName("Prev")] != nil {
      issues.append("output retains an earlier-revision /Prev chain")
    } else {
      checks.append("single revision (no /Prev)")
    }
    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: parsed.graph)
    if reachable.count != parsed.graph.objects.count {
      issues.append("output contains unreachable objects")
    } else {
      checks.append("every object is reachable")
    }
    if let review = try? RedactionHiddenDataReviewer.review(in: parsed.graph, limits: limits) {
      if report.policy.removeDocumentInfo && review.count(.documentInfo) > 0 {
        issues.append("output retains document information")
      }
      if report.policy.removeXMPMetadata && review.count(.xmpMetadata) > 0 {
        issues.append("output retains XMP metadata")
      }
      if report.policy.removePageMetadata && review.count(.pageMetadata) > 0 {
        issues.append("output retains page metadata")
      }
      let keptNames = Set(report.policy.allowedAttachmentNames)
      let outputAttachments = Set(review.details(.attachments))
      if !outputAttachments.isSubset(of: keptNames) {
        issues.append("output retains an attachment outside the allow-list")
      }
      if report.policy.removeComments && review.count(.comments) > 0 {
        issues.append("output retains comments")
      }
      if report.policy.removeOptionalContent && review.count(.optionalContent) > 0 {
        issues.append("output retains optional-content layers or references")
      }
      if report.policy.removeAlternateText && review.count(.alternateText) > 0 {
        issues.append("output retains alternate/actual text")
      }
      if report.policy.clearFormValues && review.count(.formValues) > 0 {
        issues.append("output retains form field values")
      }
      if report.policy.removeOCRLayers && review.count(.ocrLayers) > 0 {
        issues.append("output retains generated OCR layers")
      }
      if report.policy.removeThumbnails && review.count(.thumbnails) > 0 {
        issues.append("output retains page thumbnails")
      }
      if report.policy.removePrivateApplicationData
        && review.count(.privateApplicationData) > 0
      {
        issues.append("output retains private application data")
      }
      if report.policy.removeDocumentIdentifiers && review.count(.documentIdentifiers) > 0 {
        issues.append("output retains document identifiers")
      }
      checks.append("policy categories re-inspected on the saved graph")
    }
    for note in report.uninspectable {
      issues.append("uninspectable retained data: " + note)
    }
    var survivingSeeds: [String] = []
    if !seeds.isEmpty {
      let locations = RedactionOutputInspector.locate(seeds: seeds, in: data, limits: limits)
      survivingSeeds = Array(Set(locations.map(\.seed))).sorted()
      for seed in survivingSeeds {
        issues.append("seed survives independent inspection: \(seed)")
      }
      checks.append("seed search over raw bytes, decoded streams, text and structure")
    }
    return RedactionSanitizationVerification(
      passed: issues.isEmpty, issues: issues, checks: checks,
      survivingSeeds: survivingSeeds, uninspectable: report.uninspectable)
  }
}

