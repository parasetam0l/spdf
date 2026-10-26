import Foundation
import PDFCore

/// EXP-04/EXP-05: the approved PDF-creation routes. The decision is explicit
/// per source kind: bounded Swift import where the app owns the layout, or a
/// user-directed local native-application/browser print handoff where another
/// application owns layout, fonts and links. No silent upload, embedded web
/// engine, Ghostscript or unapproved converter is ever used.
public enum SourceDocumentKind: String, Sendable, Equatable, CaseIterable {
  case docx
  case xlsx
  case pptx
  case rtf
  case html
  case plainText

  public var displayName: String {
    switch self {
    case .docx: return "Word document (.docx)"
    case .xlsx: return "Excel workbook (.xlsx)"
    case .pptx: return "PowerPoint presentation (.pptx)"
    case .rtf: return "Rich Text (.rtf)"
    case .html: return "Web page (.html)"
    case .plainText: return "Plain text"
    }
  }

  public var fileExtensions: [String] {
    switch self {
    case .docx: return ["docx", "doc"]
    case .xlsx: return ["xlsx", "xls"]
    case .pptx: return ["pptx", "ppt"]
    case .rtf: return ["rtf", "rtfd"]
    case .html: return ["html", "htm"]
    case .plainText: return ["txt", "text"]
    }
  }

  /// The route this project approves for the kind.
  public var approvedRoute: SourcePDFCreationRoute {
    switch self {
    case .docx, .xlsx, .pptx, .rtf:
      return .nativeApplicationHandoff
    case .html:
      return .browserPrintHandoff
    case .plainText:
      return .boundedSwiftImport
    }
  }
}

public enum SourcePDFCreationRoute: String, Sendable, Equatable {
  case boundedSwiftImport = "Bounded Swift import"
  case nativeApplicationHandoff = "Local native-application handoff"
  case browserPrintHandoff = "User-directed browser print handoff"
  case unsupported = "Unsupported source"
}

/// EXP-04/EXP-05: one decision, including exactly what is and is not claimed
/// to be preserved and what still requires the other application.
public struct SourcePDFCreationDecision: Sendable, Equatable {
  public let kind: SourceDocumentKind
  public let route: SourcePDFCreationRoute
  public let requiredApplications: [String]
  public let handoffSteps: [String]
  public let preserved: [String]
  public let notPreserved: [String]
  public let requiresAnotherApplication: [String]
  public let manualChecks: [String]
  public let disclosure: String

  /// These are invariants of the decision, not caller options.
  public var usesNetwork: Bool { false }
  public var usesEmbeddedWebView: Bool { false }
  public var usesUnauthorizedConverter: Bool { false }
  public var isBoundedConversion: Bool { route == .boundedSwiftImport }

  public init(
    kind: SourceDocumentKind, route: SourcePDFCreationRoute,
    requiredApplications: [String], handoffSteps: [String], preserved: [String],
    notPreserved: [String], requiresAnotherApplication: [String],
    manualChecks: [String], disclosure: String
  ) {
    self.kind = kind
    self.route = route
    self.requiredApplications = requiredApplications
    self.handoffSteps = handoffSteps
    self.preserved = preserved
    self.notPreserved = notPreserved
    self.requiresAnotherApplication = requiresAnotherApplication
    self.manualChecks = manualChecks
    self.disclosure = disclosure
  }
}

/// EXP-04/EXP-05: the decision catalog. Office and RTF sources are handed to a
/// local native application; HTML is printed from a user-chosen browser (no
/// embedded web view); plain text is the only bounded Swift import because the
/// app genuinely owns that layout. Layout/fonts/links/tags are never claimed
/// to be preserved by a converter that does not run the source application.
public enum SourcePDFCreationPolicy {
  public static let boundaryDisclosure = """
    Approved creation routes only: (1) bounded Swift import for plain text, where \
    this app owns pagination and layout; (2) a user-directed handoff to a locally \
    installed native application (word processor, spreadsheet, presentation or \
    rich-text editor) that prints/exports the source to PDF; (3) a user-directed \
    browser print/save-as-PDF handoff for HTML. sPDF never uploads the source, \
    never runs an embedded web view or browser engine, never invokes Ghostscript \
    or another unapproved converter, and never claims layout/fonts/links/tags \
    that the source application did not emit. Every handoff ends with a \
    verification report; visual layout fidelity remains a human check.
    """

  public static func decision(for kind: SourceDocumentKind) -> SourcePDFCreationDecision {
    switch kind {
    case .docx:
      return handoff(
        kind: kind,
        applications: ["Microsoft Word", "Apple Pages", "LibreOffice Writer"],
        subject: "the word processor",
        preserved: [
          "Text content and page order as rendered by the chosen word processor",
          "Layout, columns, headers/footers and fonts as rendered by that application",
          "Hyperlinks the word processor exports into the PDF",
          "Tags only when the word processor exports tagged PDF",
        ],
        notPreserved: [
          "The original DOCX editing structure and field semantics",
          "Layout fidelity beyond what the chosen application exports",
          "Tags are not added by sPDF when the exporter omits them",
        ],
        requiresAnother: [
          "layout, pagination, fonts and available tags come from the word processor",
          "link/annotation export depends on the word processor's save-as-PDF feature",
        ])
    case .xlsx:
      return handoff(
        kind: kind,
        applications: ["Microsoft Excel", "Apple Numbers", "LibreOffice Calc"],
        subject: "the spreadsheet application",
        preserved: [
          "Printed sheet content, page order and print area as configured in the app",
          "Cell values, formulas' displayed results and number formatting as printed",
          "Fonts and layout as rendered by that application",
          "Hyperlinks the spreadsheet application exports into the PDF",
        ],
        notPreserved: [
          "Workbook editing structure, formulas, hidden sheets and macros",
          "Interactive spreadsheet behavior; only the printed pages become PDF",
        ],
        requiresAnother: [
          "print area, page setup, layout and fonts come from the spreadsheet application",
        ])
    case .pptx:
      return handoff(
        kind: kind,
        applications: ["Microsoft PowerPoint", "Apple Keynote", "LibreOffice Impress"],
        subject: "the presentation application",
        preserved: [
          "Slides and their order as exported/printed by the chosen application",
          "Text, images, layout and fonts as rendered by that application",
          "Speaker notes only if the presentation application includes them in the export",
          "Hyperlinks the presentation application exports into the PDF",
        ],
        notPreserved: [
          "Animations, transitions, media playback and editing structure",
          "Notes/handouts layouts unless selected in the other application",
        ],
        requiresAnother: [
          "slide layout, fonts and export options come from the presentation application",
        ])
    case .rtf:
      return handoff(
        kind: kind,
        applications: ["Apple TextEdit", "Microsoft Word", "LibreOffice Writer"],
        subject: "the rich-text editor",
        preserved: [
          "Text, paragraph formatting, fonts and embedded images as rendered by the editor",
          "Page layout produced by that editor's print/save-as-PDF path",
          "Hyperlinks the editor exports into the PDF",
        ],
        notPreserved: [
          "Original RTF editing structure beyond the printed rendering",
          "Tags are not added by sPDF",
        ],
        requiresAnother: [
          "rich-text layout, fonts and link export come from the chosen editor",
        ])
    case .html:
      return SourcePDFCreationDecision(
        kind: kind, route: .browserPrintHandoff,
        requiredApplications: ["Safari", "Google Chrome", "Mozilla Firefox", "another installed browser"],
        handoffSteps: [
          "Open the local HTML file in the chosen browser (no upload; the file stays on this Mac).",
          "Choose File > Print (or the browser's Print command).",
          "Choose Save as PDF / Open in Preview and save the PDF locally.",
          "Run the verification step in sPDF and inspect page content and links visually.",
        ],
        preserved: [
          "Page content the browser prints (text, images, CSS layout as printed)",
          "Hyperlinks the browser emits as PDF link annotations (browser-dependent)",
          "Page breaks and print layout as produced by that browser",
        ],
        notPreserved: [
          "Interactive behavior, scripts, media playback and DOM state",
          "Links may be omitted by some browser print paths; they are not fabricated by sPDF",
          "Tags are only present when the browser exports them",
        ],
        requiresAnotherApplication: [
          "HTML/CSS layout, fonts and link export are produced by the chosen browser",
          "scripted or authenticated page state may require another application/manual workflow",
        ],
        manualChecks: [
          "Compare printed page content with the browser window",
          "Check that expected links were exported; if not, document the browser limitation",
        ],
        disclosure: """
          HTML-to-PDF uses a user-directed browser print handoff. sPDF does not embed \
          or run a web view/browser engine, does not upload the page and does not fetch \
          remote content itself. Layout and link preservation are the browser's output, \
          not an sPDF claim.
          """)
    case .plainText:
      return SourcePDFCreationDecision(
        kind: kind, route: .boundedSwiftImport,
        requiredApplications: [],
        handoffSteps: [
          "Choose the plain-text file in the creation panel.",
          "Choose page size, font size and margins; sPDF paginates with its own layout.",
          "Save the created PDF; it is ordinary editable page content.",
        ],
        preserved: [
          "Text content, paragraph order and simple line wrapping",
          "Pagination with the selected page size and margins",
          "Text remains editable in sPDF after creation",
        ],
        notPreserved: [
          "No links, tags, images or rich formatting are invented",
          "Complex typography and layout are not claimed",
        ],
        requiresAnotherApplication: [],
        manualChecks: ["Check pagination and line wrapping against the source text"],
        disclosure: """
          Plain text is the only bounded Swift import route: sPDF owns pagination and \
          layout, preserves the text content, and does not claim links, tags or rich \
          formatting it did not receive.
          """)
    }
  }

  public static var decisions: [SourcePDFCreationDecision] {
    SourceDocumentKind.allCases.map(decision(for:))
  }

  public static func decision(forFileURL url: URL) -> SourcePDFCreationDecision? {
    let ext = url.pathExtension.lowercased()
    guard let kind = SourceDocumentKind.allCases.first(where: {
      $0.fileExtensions.contains(ext)
    }) else { return nil }
    return decision(for: kind)
  }

  static func handoff(
    kind: SourceDocumentKind, applications: [String], subject: String,
    preserved: [String], notPreserved: [String], requiresAnother: [String]
  ) -> SourcePDFCreationDecision {
    SourcePDFCreationDecision(
      kind: kind, route: .nativeApplicationHandoff,
      requiredApplications: applications,
      handoffSteps: [
        "Open the source file locally in one of: \(applications.joined(separator: ", ")).",
        "Choose File > Print (or Export/Save as PDF) in \(subject).",
        "Save the PDF locally; do not use cloud conversion or web upload.",
        "Run the verification step in sPDF and inspect the result visually.",
      ],
      preserved: preserved, notPreserved: notPreserved,
      requiresAnotherApplication: requiresAnother,
      manualChecks: [
        "Compare page count, layout, fonts and page order with the source application",
        "Check links and tags that the source application was expected to export",
      ],
      disclosure: """
        \(kind.displayName) uses a local native-application handoff: the user prints or \
        exports it in a locally installed application. sPDF does not upload the source, \
        does not bundle an Office/browser engine and does not convert Office formats \
        itself. Preserved layout/fonts/links/tags are the chosen application's output.
        """)
  }
}

/// EXP-04/EXP-05: expectations for the post-handoff verification.
public struct SourcePDFCreationExpectations: Sendable, Equatable {
  public var requiresTextContent: Bool
  public var requiresLinks: Bool
  public var requiresStructureTags: Bool
  public var requiresEmbeddedFonts: Bool
  public var minimumPageCount: Int

  public init(
    requiresTextContent: Bool = true, requiresLinks: Bool = false,
    requiresStructureTags: Bool = false, requiresEmbeddedFonts: Bool = false,
    minimumPageCount: Int = 1
  ) {
    self.requiresTextContent = requiresTextContent
    self.requiresLinks = requiresLinks
    self.requiresStructureTags = requiresStructureTags
    self.requiresEmbeddedFonts = requiresEmbeddedFonts
    self.minimumPageCount = minimumPageCount
  }
}

public enum SourcePDFPreservationStatus: String, Sendable, Equatable {
  case verified = "Verified"
  case missing = "Missing"
  case notRequested = "Not requested"
  case notMachineVerifiable = "Not machine-verifiable"
}

/// EXP-04/EXP-05: a bounded verification report for handoff/bounded output.
/// Layout fidelity is deliberately not machine-verifiable.
public struct SourcePDFCreationVerification: Sendable, Equatable {
  public let kind: SourceDocumentKind
  public let route: SourcePDFCreationRoute
  public let pageCount: Int
  public let textCharacters: Int
  public let linkCount: Int
  public let fontCount: Int
  public let embeddedFontCount: Int
  public let hasStructureTags: Bool
  public let contentStatus: SourcePDFPreservationStatus
  public let linksStatus: SourcePDFPreservationStatus
  public let tagsStatus: SourcePDFPreservationStatus
  public let fontsStatus: SourcePDFPreservationStatus
  public let layoutStatus: SourcePDFPreservationStatus
  public let details: [String]

  public init(
    kind: SourceDocumentKind, route: SourcePDFCreationRoute, pageCount: Int,
    textCharacters: Int, linkCount: Int, fontCount: Int, embeddedFontCount: Int,
    hasStructureTags: Bool, contentStatus: SourcePDFPreservationStatus,
    linksStatus: SourcePDFPreservationStatus, tagsStatus: SourcePDFPreservationStatus,
    fontsStatus: SourcePDFPreservationStatus, layoutStatus: SourcePDFPreservationStatus,
    details: [String]
  ) {
    self.kind = kind
    self.route = route
    self.pageCount = pageCount
    self.textCharacters = textCharacters
    self.linkCount = linkCount
    self.fontCount = fontCount
    self.embeddedFontCount = embeddedFontCount
    self.hasStructureTags = hasStructureTags
    self.contentStatus = contentStatus
    self.linksStatus = linksStatus
    self.tagsStatus = tagsStatus
    self.fontsStatus = fontsStatus
    self.layoutStatus = layoutStatus
    self.details = details
  }

  public var isSatisfied: Bool {
    ![contentStatus, linksStatus, tagsStatus, fontsStatus].contains(.missing)
  }

  public var plainText: String {
    var lines = [
      "Source kind: \(kind.displayName) (\(route.rawValue))",
      "Pages: \(pageCount); text characters: \(textCharacters); links: \(linkCount); "
        + "fonts: \(fontCount) (\(embeddedFontCount) embedded); structure tags: "
        + "\(hasStructureTags ? "yes" : "no")",
      "Content: \(contentStatus.rawValue)",
      "Links: \(linksStatus.rawValue)",
      "Tags: \(tagsStatus.rawValue)",
      "Fonts: \(fontsStatus.rawValue)",
      "Layout: \(layoutStatus.rawValue)",
    ]
    lines.append(contentsOf: details.map { "  - \($0)" })
    lines.append(
      "Visual layout fidelity remains a human check; this report never claims it.")
    return lines.joined(separator: "\n")
  }
}

/// EXP-04/EXP-05: verification of a produced PDF file/data.
public enum SourcePDFCreationVerifier {
  public static func verify(
    _ data: Data, for kind: SourceDocumentKind,
    expectations: SourcePDFCreationExpectations = SourcePDFCreationExpectations(),
    limits: PDFLimits = PDFLimits()
  ) -> SourcePDFCreationVerification? {
    guard let parsed = try? PDFParser.parse(data, limits: limits) else { return nil }
    return verify(
      parsed.graph, for: kind, expectations: expectations, limits: limits)
  }

  public static func verify(
    _ graph: PDFGraph, for kind: SourceDocumentKind,
    expectations: SourcePDFCreationExpectations = SourcePDFCreationExpectations(),
    limits: PDFLimits = PDFLimits()
  ) -> SourcePDFCreationVerification {
    let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
    let text = pageIDs.isEmpty
      ? ""
      : (try? PDFTextExport.plainText(pageIDs: pageIDs, in: graph))
        .map { String(decoding: $0, as: UTF8.self) } ?? ""
    var links = 0
    for pageID in pageIDs {
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations
      where annotation.dictionary[PDFName("Subtype")] == .name(PDFName("Link")) {
        links += 1
      }
    }
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let embedded = fonts.filter(\.isEmbedded).count
    let tagged = hasStructureTags(in: graph)
    let contentStatus: SourcePDFPreservationStatus
    if !expectations.requiresTextContent {
      contentStatus = .notRequested
    } else {
      contentStatus = !text.isEmpty && pageIDs.count >= max(1, expectations.minimumPageCount)
        ? .verified : .missing
    }
    let linksStatus: SourcePDFPreservationStatus
    if !expectations.requiresLinks {
      linksStatus = .notRequested
    } else {
      linksStatus = links > 0 ? .verified : .missing
    }
    let tagsStatus: SourcePDFPreservationStatus
    if !expectations.requiresStructureTags {
      tagsStatus = .notRequested
    } else {
      tagsStatus = tagged ? .verified : .missing
    }
    let fontsStatus: SourcePDFPreservationStatus
    if !expectations.requiresEmbeddedFonts {
      fontsStatus = fonts.isEmpty ? .notRequested : (embedded > 0 ? .verified : .notRequested)
    } else {
      fontsStatus = embedded > 0 ? .verified : .missing
    }
    var details: [String] = []
    if expectations.requiresLinks && links == 0 {
      details.append(
        "No link annotations were exported; a browser or application may omit links — "
          + "document the limitation instead of fabricating links.")
    }
    if expectations.requiresStructureTags && !tagged {
      details.append("The output is untagged; tags were not invented by sPDF.")
    }
    if expectations.requiresEmbeddedFonts && embedded == 0 {
      details.append("No embedded fonts were found in the produced file.")
    }
    return SourcePDFCreationVerification(
      kind: kind, route: kind.approvedRoute, pageCount: pageIDs.count,
      textCharacters: text.count, linkCount: links, fontCount: fonts.count,
      embeddedFontCount: embedded, hasStructureTags: tagged,
      contentStatus: contentStatus, linksStatus: linksStatus, tagsStatus: tagsStatus,
      fontsStatus: fontsStatus, layoutStatus: .notMachineVerifiable, details: details)
  }

  static func hasStructureTags(in graph: PDFGraph) -> Bool {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { return false }
    return catalog[PDFName("StructTreeRoot")] != nil
  }
}

/// EXP-04: the only bounded Swift import path: plain text. Office formats are
/// never quietly "converted" here.
public enum SourcePDFBoundedCreation {
  public static func supports(_ kind: SourceDocumentKind) -> Bool {
    kind == .plainText
  }

  public static func make(
    text: String, layout: TextPDFCreation.PageLayout = .letter,
    fontSize: Double = 12, margins: Double = 36, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    try TextPDFCreation.make(
      text: text, layout: layout, fontSize: fontSize, margins: margins, limits: limits)
  }
}
