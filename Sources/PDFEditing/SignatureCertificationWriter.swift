import Foundation
import PDFCore
import Security

/// SIG-04: writes a signature that also authors the DocMDP certification and/or
/// FieldMDP field lock that restricts later changes. The cryptographic profile
/// is the existing `PDFSigningWriter` pipeline: this writer only transforms the
/// prepared graph before it is serialized and signed.
///
/// A request that is outside `PDFSignatureAuthoring.declaredLimits` throws
/// before any bytes are produced; it is never written half-signed or with the
/// transform silently dropped.
public enum PDFSignatureAuthoringWriter {
  /// Sign a graph as the first signature, authoring the certification and/or
  /// field lock inside that revision (full rewrite).
  public static func sign(
    _ graph: PDFGraph, identity: SecIdentity, options: PDFSigningOptions,
    authoring: PDFSignatureAuthoring, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    if authoring == .plain {
      return try PDFSigningWriter.sign(graph, identity: identity, options: options, limits: limits)
    }
    if (try? PDFSignatureInventory.signatures(in: graph, limits: limits)).map({ !$0.isEmpty })
      == true
    {
      throw PDFError(
        .unsupported,
        "This document is already signed; add the signature as an incremental update")
    }
    guard graph.trailer[PDFName("Encrypt")] == nil else {
      throw PDFError(.unsupported, "Signing encrypted documents is not supported")
    }
    try authoring.validate(in: graph, limits: limits)
    let preparedGraph = Self.normalizedFormGraph(graph)
    var plan = try PDFSigningWriter.prepare(
      preparedGraph, identity: identity, options: options, limits: limits)
    try PDFSignatureAuthoringInjection.inject(
      into: &plan.graph, signatureID: plan.signatureID, widgetID: plan.widgetID,
      options: options, authoring: authoring, limits: limits)
    let data = try PDFWriter.serialize(plan.graph, limits: limits)
    return try embedded(
      data, signatureID: plan.signatureID, identity: identity, options: options, limits: limits)
  }

  /// Append a signed revision to an existing file, authoring the certification
  /// (only when it is the first signature) and/or a FieldMDP lock inside that
  /// revision. The original bytes are preserved exactly.
  public static func signIncremental(
    _ source: ParsedPDF, identity: SecIdentity, options: PDFSigningOptions,
    authoring: PDFSignatureAuthoring, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    if authoring == .plain {
      return try PDFSigningWriter.signIncremental(
        source, identity: identity, options: options, limits: limits)
    }
    guard source.graph.trailer[PDFName("Encrypt")] == nil else {
      throw PDFError(.unsupported, "Signing encrypted documents is not supported")
    }
    try authoring.validate(in: source.graph, limits: limits)
    let target: PDFSignatureSigningTarget = options.existingFieldName.map {
      .existingField(name: $0)
    } ?? .newField(name: options.fieldName)
    if case .refused(let reason) = try PDFSignatureSigningPolicy.decision(
      in: source.graph, target: target, limits: limits)
    {
      throw PDFError(.unsupported, reason)
    }
    let preparedGraph = Self.normalizedFormGraph(source.graph)
    var plan = try PDFSigningWriter.prepare(
      preparedGraph, identity: identity, options: options, limits: limits)
    try PDFSignatureAuthoringInjection.inject(
      into: &plan.graph, signatureID: plan.signatureID, widgetID: plan.widgetID,
      options: options, authoring: authoring, limits: limits)
    let output = try incrementalRevision(from: source, to: plan, limits: limits)
    return try embedded(
      output, signatureID: plan.signatureID, identity: identity, options: options,
      limits: limits)
  }

  /// The single seam to the shared CMS embedding/self-verification pipeline.
  /// SIG-02/03 (in progress) changes `PDFSigningWriter.embed` to take a
  /// `timestamp:` argument and return `PDFSigningOutcome`; at merge only this
  /// helper changes:
  ///   try PDFSigningWriter.embed(
  ///     data, signatureID: signatureID, identity: identity, options: options,
  ///     timestamp: nil, limits: limits).data
  private static func embedded(
    _ data: Data, signatureID: PDFObjectID, identity: SecIdentity,
    options: PDFSigningOptions, limits: PDFLimits
  ) throws -> Data {
    try PDFSigningWriter.embed(
      data, signatureID: signatureID, identity: identity, options: options, limits: limits)
  }

  /// The shared new-field preparation treats an inline AcroForm as absent and
  /// replaces it with an empty indirect dictionary, which would drop the
  /// document's existing form fields. Normalize an inline AcroForm to an
  /// indirect object first so the prepared graph keeps every field; an
  /// already-indirect or absent AcroForm is left for the shared preparation.
  private static func normalizedFormGraph(_ graph: PDFGraph) -> PDFGraph {
    var graph = graph
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID],
      case .dictionary(let acroForm)? = catalog[PDFName("AcroForm")]
    else { return graph }
    let acroFormID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[acroFormID] = .dictionary(acroForm)
    catalog[PDFName("AcroForm")] = .reference(acroFormID)
    graph.objects[rootID] = .dictionary(catalog)
    return graph
  }

  /// Append one classic incremental revision for the prepared graph. This is
  /// the same append shape as `PDFSigningWriter.signIncremental`; the changed
  /// set is derived from the prepared graph so authored catalog/field
  /// changes cannot be omitted from the signed revision.
  private static func incrementalRevision(
    from source: ParsedPDF, to plan: PDFSigningWriter.Plan, limits: PDFLimits
  ) throws -> Data {
    let previousStartXRef = try PDFSigningWriter.finalStartXRef(in: source.source)
    var changedIDs = Set<PDFObjectID>()
    for (id, value) in plan.graph.objects where source.graph.objects[id] != value {
      changedIDs.insert(id)
    }
    changedIDs.formUnion(plan.changedIDs)
    let ids = changedIDs.sorted()

    var output = source.source
    if output.last != 0x0A { output.append(0x0A) }
    let baseLength = output.count
    var body = Data()
    var offsets: [PDFObjectID: Int] = [:]
    for id in ids {
      guard let value = plan.graph.objects[id] else { continue }
      offsets[id] = baseLength + body.count
      body.append(Data("\(id.number) \(id.generation) obj\n".utf8))
      body.append(try PDFWriter.serializedValue(value, limits: limits))
      body.append(Data("\nendobj\n".utf8))
    }
    let xrefOffset = baseLength + body.count
    var table = "xref\n0 1\n0000000000 65535 f \n"
    for id in ids {
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
    return output
  }
}

/// Places the authored transform dictionaries into the prepared graph. Every
/// mutation is a declared a-priori limit checked by `PDFSignatureAuthoring`;
/// this seam only refuses an unprepared or already-transformed signature.
private enum PDFSignatureAuthoringInjection {
  static func inject(
    into graph: inout PDFGraph, signatureID: PDFObjectID, widgetID: PDFObjectID,
    options: PDFSigningOptions, authoring: PDFSignatureAuthoring, limits: PDFLimits
  ) throws {
    try addSignatureTransforms(into: &graph, signatureID: signatureID, authoring: authoring)
    if let permission = authoring.certificationPermission {
      try addCatalogPermission(permission, signatureID: signatureID, into: &graph)
    }
    if let lock = authoring.fieldLock {
      try addFieldLock(
        lock, signatureFieldName: options.fieldName, fallbackWidgetID: widgetID,
        into: &graph, limits: limits)
    }
  }

  private static func addSignatureTransforms(
    into graph: inout PDFGraph, signatureID: PDFObjectID, authoring: PDFSignatureAuthoring
  ) throws {
    guard case .dictionary(var signatureDictionary)? = graph.objects[signatureID] else {
      throw PDFError(.malformed, "The prepared signature dictionary is missing")
    }
    var references: [PDFValue] = []
    if case .array(let existing)? = signatureDictionary[PDFName("Reference")] {
      for reference in existing {
        if case .dictionary(let dictionary) = reference {
          let method = dictionary[PDFName("TransformMethod")]
          if method == .name(PDFName("DocMDP")) || method == .name(PDFName("FieldMDP")) {
            throw PDFError(
              .unsupported,
              "The prepared signature already declares a DocMDP or FieldMDP transform")
          }
        }
        references.append(reference)
      }
    }
    if let permission = authoring.certificationPermission {
      references.append(docMDPReference(permission))
    }
    if let lock = authoring.fieldLock {
      references.append(fieldMDPReference(lock))
    }
    guard !references.isEmpty else { return }
    signatureDictionary[PDFName("Reference")] = .array(references)
    graph.objects[signatureID] = .dictionary(signatureDictionary)
  }

  /// The catalog /Perms /DocMDP reference is what readers use to recognize a
  /// certification signature. Existing unrelated /Perms entries are kept.
  private static func addCatalogPermission(
    _ permission: PDFDocMDPPermission, signatureID: PDFObjectID, into graph: inout PDFGraph
  ) throws {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The document catalog is missing") }
    switch catalog[PDFName("Perms")] {
    case nil:
      catalog[PDFName("Perms")] = .dictionary([
        PDFName("DocMDP"): .reference(signatureID)
      ])
      graph.objects[catalogID] = .dictionary(catalog)
    case .dictionary(var permissions)?:
      guard permissions[PDFName("DocMDP")] == nil else {
        throw PDFError(
          .unsupported, "The document catalog already declares a DocMDP permission")
      }
      permissions[PDFName("DocMDP")] = .reference(signatureID)
      catalog[PDFName("Perms")] = .dictionary(permissions)
      graph.objects[catalogID] = .dictionary(catalog)
    case .reference(let permissionsID)?:
      guard case .dictionary(var permissions)? = graph.objects[permissionsID] else {
        throw PDFError(.unsupported, "The catalog /Perms entry is not a dictionary")
      }
      guard permissions[PDFName("DocMDP")] == nil else {
        throw PDFError(
          .unsupported, "The document catalog already declares a DocMDP permission")
      }
      permissions[PDFName("DocMDP")] = .reference(signatureID)
      graph.objects[permissionsID] = .dictionary(permissions)
    default:
      throw PDFError(.unsupported, "The catalog /Perms entry has an unsupported type")
    }
  }

  /// The field-level /Lock dictionary documents the lock for form readers;
  /// the signature /Reference FieldMDP transform is what sPDF's own policy
  /// enforces. Writing both keeps the two views coherent.
  private static func addFieldLock(
    _ lock: PDFSignatureFieldLock, signatureFieldName: String,
    fallbackWidgetID: PDFObjectID, into graph: inout PDFGraph, limits: PDFLimits
  ) throws {
    let fields = (try? PDFSignatureFieldInventory.fields(in: graph, limits: limits)) ?? []
    guard let field = fields.first(where: { $0.name == signatureFieldName }) else {
      throw PDFError(
        .malformed, "The signed signature field was not found after preparation")
    }
    let targetID = field.fieldID ?? field.widgetID ?? fallbackWidgetID
    guard case .dictionary(var dictionary)? = graph.objects[targetID] else {
      throw PDFError(.malformed, "The signature field dictionary is missing")
    }
    var lockDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("SigFieldLock")),
      PDFName("Action"): .name(PDFName(lock.action.rawValue)),
    ]
    if !lock.fields.isEmpty {
      lockDictionary[PDFName("Fields")] = .array(
        lock.fields.map { .string(Data($0.utf8)) })
    }
    dictionary[PDFName("Lock")] = .dictionary(lockDictionary)
    graph.objects[targetID] = .dictionary(dictionary)
  }

  private static func docMDPReference(_ permission: PDFDocMDPPermission) -> PDFValue {
    .dictionary([
      PDFName("Type"): .name(PDFName("SigRef")),
      PDFName("TransformMethod"): .name(PDFName("DocMDP")),
      PDFName("TransformParams"): .dictionary([
        PDFName("Type"): .name(PDFName("TransformParams")),
        PDFName("P"): .integer(Int64(permission.rawValue)),
        PDFName("V"): .name(PDFName("1.2")),
      ]),
    ])
  }

  private static func fieldMDPReference(_ lock: PDFSignatureFieldLock) -> PDFValue {
    var parameters: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("TransformParams")),
      PDFName("Action"): .name(PDFName(lock.action.rawValue)),
      PDFName("V"): .name(PDFName("1.2")),
    ]
    if !lock.fields.isEmpty {
      parameters[PDFName("Fields")] = .array(lock.fields.map { .string(Data($0.utf8)) })
    }
    return .dictionary([
      PDFName("Type"): .name(PDFName("SigRef")),
      PDFName("TransformMethod"): .name(PDFName("FieldMDP")),
      PDFName("DigestMethod"): .name(PDFName("SHA256")),
      PDFName("TransformParams"): .dictionary(parameters),
    ])
  }
}
