import Foundation
import PDFCore

// MARK: - Representative signing workflows

/// SIG-05: one representative signing persona. `postCertificationChanges`
/// lists the changes this persona may make *after* a document is certified
/// under the workflow's permission; it is empty for roles that only read or
/// that finish their work before certification.
public struct PDFSigningPersona: Sendable, Equatable {
  public let id: String
  public let title: String
  public let summary: String
  /// True only for the persona that may author the first certification
  /// signature under the declared profile.
  public let canCertify: Bool
  public let postCertificationChanges: [PDFCertificationChange]

  public init(
    id: String, title: String, summary: String, canCertify: Bool,
    postCertificationChanges: [PDFCertificationChange]
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.canCertify = canCertify
    self.postCertificationChanges = postCertificationChanges
  }
}

/// SIG-05: one representative team review/approval/publish workflow, with the
/// certification choice it uses, the steps each persona follows, the changes
/// each signer is allowed to make, and its remaining gaps.
public struct PDFSigningWorkflow: Sendable, Equatable {
  public let id: String
  public let title: String
  public let summary: String
  public let personaIDs: [String]
  public let certificationPermission: PDFDocMDPPermission?
  /// A representative FieldMDP choice for this workflow, when it uses one.
  public let fieldLockExample: PDFSignatureFieldLock?
  public let steps: [String]
  public let signerChanges: [String]
  public let limitations: [String]

  public init(
    id: String, title: String, summary: String, personaIDs: [String],
    certificationPermission: PDFDocMDPPermission?,
    fieldLockExample: PDFSignatureFieldLock?, steps: [String],
    signerChanges: [String], limitations: [String]
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.personaIDs = personaIDs
    self.certificationPermission = certificationPermission
    self.fieldLockExample = fieldLockExample
    self.steps = steps
    self.signerChanges = signerChanges
    self.limitations = limitations
  }
}

/// SIG-05: the declared, testable description of representative signing
/// workflows. It is the single source for the certification UI and the
/// private SESSION evidence, so a workflow cannot drift away from the
/// documented boundary without a test failing.
public enum PDFSigningWorkflowGuide {
  public static let personas: [PDFSigningPersona] = [
    PDFSigningPersona(
      id: "document-author", title: "Document author",
      summary:
        "Prepares the content and decides whether to certify. Only the author/publisher "
          + "may author a certification signature, and only as the document's first signature.",
      canCertify: true, postCertificationChanges: []),
    PDFSigningPersona(
      id: "reviewer", title: "Reviewer",
      summary:
        "Reviews content and leaves comments or annotations. A P3 certification allows "
          + "annotations; sPDF validates and reports later review changes.",
      canCertify: false, postCertificationChanges: [.addAnnotations]),
    PDFSigningPersona(
      id: "approver", title: "Approver",
      summary:
        "Confirms fields and signs an existing signature field. P2 and P3 allow filling "
          + "existing fields and signing; FieldMDP locks are enforced before signing.",
      canCertify: false,
      postCertificationChanges: [.fillExistingFormFields, .signExistingSignatureFields]),
    PDFSigningPersona(
      id: "publisher", title: "Publisher",
      summary:
        "Owns distribution: certifies with P2 plus FieldMDP for controlled countersigning, "
          + "or with P1 when the file must not change again, then distributes the signed bytes.",
      canCertify: true, postCertificationChanges: []),
    PDFSigningPersona(
      id: "recipient", title: "Recipient",
      summary:
        "Opens the distributed file and validates cryptography, trust, certification and "
          + "the revision chain offline. Never changes the certified bytes.",
      canCertify: false, postCertificationChanges: []),
  ]

  public static let workflows: [PDFSigningWorkflow] = [
    PDFSigningWorkflow(
      id: "individual-signoff", title: "Individual sign-off",
      summary:
        "One author signs a finished document and a recipient verifies it offline. No "
          + "certification is declared, so later changes are detected and reported, "
          + "not restricted.",
      personaIDs: ["document-author", "recipient"],
      certificationPermission: nil, fieldLockExample: nil,
      steps: [
        "Finish every content edit and save the document before signing.",
        "Choose Sign Document, pick a keychain identity and write the signed copy.",
        "sPDF appends one signature revision; the pre-signature bytes stay unchanged.",
        "The recipient validates the signature offline and inspects later revisions.",
      ],
      signerChanges: [
        "The signer adds one signature revision; earlier bytes are preserved exactly.",
        "Without a certification signature, readers allow later edits but flag them as "
          + "unsigned changes to the signed revision.",
      ],
      limitations: [
        "No timestamp, revocation or long-term validation evidence is attached.",
        "sPDF blocks content editing on signed files; all edits must precede the signature.",
      ]),
    PDFSigningWorkflow(
      id: "review-approve", title: "Team review and approval",
      summary:
        "An author certifies P3 as the first signature so reviewers may comment and "
          + "approvers may fill existing fields and sign existing signature fields.",
      personaIDs: ["document-author", "reviewer", "approver", "recipient"],
      certificationPermission: .formFillSignAndAnnotate, fieldLockExample: nil,
      steps: [
        "The author finalizes the document, then certifies it with P3 as the first signature.",
        "Optionally author a FieldMDP lock for fields that later signers must not change.",
        "Reviewers add comments/annotations; P3 permits them, and sPDF reports the later "
          + "revision change list.",
        "Approvers fill existing permitted fields and sign existing signature fields "
          + "incrementally; each signature covers the whole file so far.",
        "The recipient validates the certification and every signature, then reviews the "
          + "changes between revisions.",
      ],
      signerChanges: [
        "Author: all content changes before certifying; afterwards only the P3 allowance "
          + "is within the declaration.",
        "Reviewer: annotations/comments only (P3).",
        "Approver: filling existing fields and signing existing signature fields; "
          + "FieldMDP locks are enforced.",
        "Recipient: no changes; validates the certified revision chain.",
      ],
      limitations: [
        "sPDF does not yet author incremental annotations or form values on already-signed "
          + "bytes; those changes must happen before certification or in a reader that "
          + "supports the P3 allowance.",
        "sPDF classifies later revisions but does not cryptographically prove that every "
          + "change stayed within P3.",
        "No timestamps, revocation checks or long-term evidence.",
      ]),
    PDFSigningWorkflow(
      id: "controlled-publish", title: "Controlled countersigning and publish",
      summary:
        "An author or publisher certifies P2 with FieldMDP locks so only named approval "
          + "signatures can be added; final distribution uses P1 instead when no later "
          + "signature is wanted.",
      personaIDs: ["publisher", "approver", "recipient"],
      certificationPermission: .formFillAndSign,
      fieldLockExample: PDFSignatureFieldLock(
        action: .include, fields: ["ApprovalSignature", "Amount"]),
      steps: [
        "Decide whether any later signature is needed: if not, certify P1; if "
          + "countersigning is needed, certify P2.",
        "For P2, author a FieldMDP lock (Include the fields that may change or Exclude the "
          + "fields that must stay untouched) so the permitted path is explicit.",
        "Approvers sign only the permitted existing signature fields; sPDF refuses any "
          + "target covered by the lock before writing a signature.",
        "The publisher validates the certified file and each revision, then distributes "
          + "the final bytes.",
      ],
      signerChanges: [
        "Publisher/author: content changes before certification; the P1 or P2 choice fixes "
          + "what later signers may do.",
        "Approver: sign an existing signature field only when the P2 permission and the "
          + "FieldMDP lock allow it.",
        "Recipient: no changes; validates the P2/P1 certification and the revision chain.",
      ],
      limitations: [
        "P1 allows no later signature; choose it only when the certified file is final.",
        "sPDF refuses to replace an existing /Perms /DocMDP declaration or to certify "
          + "after any signature.",
        "FieldMDP locks must name existing form fields at authoring time.",
        "Enforcement covers signatures sPDF adds; other tools' edits are only detected as "
          + "later revisions.",
      ]),
  ]

  /// The exact profile, limits and gaps behind the workflows above. This is
  /// user-facing copy in the certification panel and the private SESSION
  /// evidence; no item may claim a capability the implementation refuses.
  public static let declaredBoundaries: [String] = [
    "DocMDP certification can be authored only as the first signature of an unsigned, "
      + "unencrypted document.",
    "At most one certification and one /Perms /DocMDP declaration are authored; an "
      + "existing declaration is never replaced.",
    "FieldMDP authoring supports All, Include and Exclude with 1...256 existing form "
      + "fields, each at most 256 UTF-8 bytes; All takes no names.",
    "The certification signature carries /Reference /DocMDP with /P 1...3 and /V /1.2; "
      + "the catalog carries /Perms /DocMDP pointing at that signature.",
    "FieldMDP authoring writes both the signature's /Reference FieldMDP transform "
      + "(/DigestMethod /SHA256) and the signature field's /Lock dictionary.",
    "Every authored transform is inside the signature revision: covered bytes are never "
      + "rewritten after signing.",
    "sPDF's incremental-signature policy additionally permits creating a new signature "
      + "field under P3; that is an sPDF profile extension, not a standard P3 allowance, "
      + "and the certification authoring UI does not offer it as a later change.",
    "Authoring does not add RFC 3161 timestamps, revocation evidence, PAdES/DSS data, "
      + "/UR usage rights, XFA support or encryption handling.",
    "Incremental signing starts from saved bytes; a dirty unsigned document is signed "
      + "through a full rewrite instead.",
    "Certificate trust is evaluated offline against explicit anchors or the system trust "
      + "store; required revocation is not checked.",
    "DocMDP/FieldMDP enforcement applies to signatures sPDF adds. Other tools' later "
      + "edits are detected and classified as revision changes, not prevented.",
    "Form filling of permitted fields on already-signed files is blocked by sPDF's "
      + "signed-byte save policy today; only the incremental signature path is available.",
  ]

  public static let remainingGaps: [String] = [
    "Timestamp creation and validation (roadmap SIG-02).",
    "OCSP/CRL revocation validation (roadmap SIG-03).",
    "Long-term validation data and archival timestamps (the roadmap's long-term "
      + "evidence row).",
    "Incremental annotation and form-value authoring on already-signed bytes; sPDF "
      + "reports such changes when another reader makes them.",
    "Certification/FieldMDP entry points are not wired into the Security menu; the "
      + "SESSION evidence lists the exact hooks.",
    "No cryptographic per-change proof that a later revision stayed within the declared "
      + "permission; sPDF classifies revisions instead.",
    "Single contents-gap ByteRange, SHA-256 generation only, detached "
      + "adbe.pkcs7.detached CMS profile.",
    "No certificate-file import or hardware-token identities (roadmap SIG-07).",
    "Encrypted documents cannot be signed or certified incrementally.",
  ]

  public static func persona(id: String) -> PDFSigningPersona? {
    personas.first { $0.id == id }
  }

  public static func workflow(id: String) -> PDFSigningWorkflow? {
    workflows.first { $0.id == id }
  }

  /// The personas participating in a workflow, in declared order.
  public static func personas(for workflow: PDFSigningWorkflow) -> [PDFSigningPersona] {
    workflow.personaIDs.compactMap(persona(id:))
  }
}
