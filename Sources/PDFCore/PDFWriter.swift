import Foundation

public enum PDFWriter {
  public static func originalBytes(of source: PDFSource) -> Data { source.data }
  public static func originalBytes(of document: ParsedPDF) -> Data { document.source }

  /// P09-018: choose the save mode before any output bytes are produced.
  /// The untouched fast path returns exact original bytes; edited documents
  /// can append an incremental revision when a saved base is available, and
  /// otherwise use the validated full rewrite.
  public static func plan(
    current: PDFGraph?, original: PDFGraph?, baseAvailable: Bool = false
  ) -> PDFSavePlan {
    if let current, let original, current != original {
      return PDFSavePlan(mode: baseAvailable ? .incrementalUpdate : .fullRewrite)
    }
    return PDFSavePlan(mode: .originalBytes)
  }

  /// P09-019: append one incremental revision that shadows only changed or
  /// deleted objects. The base revision bytes are retained exactly, the new
  /// cross-reference section chains through /Prev, and the result is
  /// reparsed and compared against `updated` before it is returned.
  public static func incrementalUpdate(
    from original: ParsedPDF, to updated: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    try Task.checkCancellation()
    try updated.validate(limits: limits)
    for key in ["Encrypt", "Prev", "XRefStm"] where updated.trailer[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "Incremental output needs a dedicated policy for this trailer state")
    }
    // The same eligibility rules as a full rewrite: signatures, linearized
    // inputs, and protected documents must not be updated silently.
    for value in updated.objects.values {
      try requireRewriteEligibility(value, depth: 0, limits: limits)
    }

    let previousStartXRef = try finalStartXRef(in: original.source)
    var output = original.source
    if output.last != 0x0A { output.append(0x0A) }
    let baseLength = output.count

    var changedIDs: [PDFObjectID] = []
    var deletedIDs: [PDFObjectID] = []
    for (id, value) in updated.objects where original.graph.objects[id] != value {
      guard id.number > 0, id.number <= limits.objects, (0...65_535).contains(id.generation)
      else { throw PDFError(.malformed, "Invalid incremental object identity") }
      changedIDs.append(id)
    }
    for id in original.graph.objects.keys where updated.objects[id] == nil {
      deletedIDs.append(id)
    }
    changedIDs.sort()
    deletedIDs.sort()

    var serializer = PDFObjectSerializer(limits: limits)
    var offsets: [PDFObjectID: Int] = [:]
    for id in changedIDs {
      try Task.checkCancellation()
      offsets[id] = baseLength + serializer.data.count
      try serializer.append("\(id.number) \(id.generation) obj\n")
      try serializer.value(updated.objects[id]!, depth: 0)
      try serializer.append("\nendobj\n")
    }
    let xrefOffset = baseLength + serializer.data.count

    var table = "xref\n0 1\n0000000000 65535 f \n"
    for id in changedIDs {
      guard let offset = offsets[id], offset <= 9_999_999_999 else {
        throw PDFError(.limitExceeded, "Incremental offset exceeds classic table capacity")
      }
      table += "\(id.number) 1\n"
      table += String(format: "%010lld %05d n \n", Int64(offset), id.generation)
    }
    for id in deletedIDs {
      let nextGeneration = min(65_535, id.generation + 1)
      table += "\(id.number) 1\n"
      table += String(format: "%010d %05d f \n", 0, nextGeneration)
    }

    var trailer = updated.trailer
    let highestNumber = max(
      updated.objects.keys.map(\.number).max() ?? 0,
      deletedIDs.map(\.number).max() ?? 0)
    trailer[PDFName("Size")] = .integer(Int64(highestNumber) + 1)
    trailer[PDFName("Prev")] = .integer(Int64(previousStartXRef))

    var trailerSerializer = PDFObjectSerializer(limits: limits)
    try trailerSerializer.value(.dictionary(trailer), depth: 0)
    try serializer.append(Data(table.utf8))
    try serializer.append(Data("trailer\n".utf8))
    try serializer.append(trailerSerializer.data)
    try serializer.append(Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))

    output.append(serializer.data)
    var normalized = updated
    normalized.trailer[PDFName("Size")] = .integer(Int64(highestNumber) + 1)
    let reparsed = try PDFParser.parse(output, limits: limits)
    guard reparsed.graph == normalized else {
      throw PDFError(.malformed, "Incremental output failed verification against the updated graph")
    }
    return output
  }

  /// Byte offset of the newest startxref pointer in a validated source.
  static func finalStartXRef(in source: Data) throws -> Int {
    let bytes = Array(source)
    guard
      let marker = source.range(of: Data("startxref".utf8), options: .backwards)
    else { throw PDFError(.malformed, "Missing final cross-reference pointer") }
    var cursor = try ByteCursor(bytes, offset: marker.upperBound)
    let offset = try cursor.integer()
    guard offset > 0, offset < bytes.count else {
      throw PDFError(.malformed, "Final cross-reference pointer is outside the file")
    }
    return offset
  }

  /// Serialize a single value (including streams with an exact Length) using
  /// the writer's byte-correct rules. Used by fixtures and diagnostics; the
  /// graph-writing entry point remains `write(_:limits:)`.
  public static func serializedValue(_ value: PDFValue, limits: PDFLimits = PDFLimits()) throws
    -> Data
  {
    var serializer = PDFObjectSerializer(limits: limits)
    try serializer.value(value, depth: 0)
    return serializer.data
  }

  /// Full rewrite for the initial classic, unencrypted, unsigned core profile.
  /// Retains every supplied object; this is not a sanitization/redaction operation.
  public static func write(_ graph: PDFGraph, limits: PDFLimits = PDFLimits()) throws -> Data {
    try requireFullRewriteEligibility(graph, limits: limits)
    return try serialize(graph, limits: limits)
  }

  /// P09-023: drop unreferenced linearization parameter dictionaries so a
  /// linearized file can be rewritten without carrying stale fast-web-view
  /// hints. Linearization dictionaries are found by file position, never by
  /// reference; a referenced `/Linearized` dictionary is kept (and still
  /// refused by eligibility) rather than silently unlinked. Returns the
  /// cleaned graph and whether anything was dropped.
  public static func droppingLinearization(_ graph: PDFGraph) -> (graph: PDFGraph, dropped: Bool) {
    var referenced = Set<PDFObjectID>()
    func collect(_ value: PDFValue) {
      switch value {
      case .reference(let id):
        referenced.insert(id)
      case .array(let values):
        values.forEach(collect)
      case .dictionary(let dictionary):
        dictionary.values.forEach(collect)
      case .stream(let stream):
        stream.dictionary.values.forEach(collect)
      default:
        break
      }
    }
    graph.objects.values.forEach(collect)
    graph.trailer.values.forEach(collect)
    var cleaned = graph
    var dropped = false
    for (id, value) in graph.objects {
      guard case .dictionary(let dictionary) = value,
        dictionary[PDFName("Linearized")] != nil,
        !referenced.contains(id)
      else { continue }
      cleaned.objects[id] = nil
      dropped = true
    }
    return (cleaned, dropped)
  }

  /// Full rewrite that drops stale linearization hints first when asked.
  /// The default still refuses linearized input so callers opt into the
  /// (safe, standards-blessed) hint removal explicitly.
  public static func write(
    _ graph: PDFGraph, droppingLinearization dropLinear: Bool,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    var graph = graph
    if dropLinear {
      graph = droppingLinearization(graph).graph
    }
    return try write(graph, limits: limits)
  }

  /// P28-019: authorized password removal. The graph must be an unlocked
  /// (decrypted) graph; the /Encrypt trailer entry and the encryption
  /// dictionary object are dropped and nothing else changes.
  public static func removingEncryption(_ graph: PDFGraph) throws -> PDFGraph {
    guard case .reference(let encryptID)? = graph.trailer[PDFName("Encrypt")] else {
      throw PDFError(.unsupported, "The graph is not an unlocked protected graph")
    }
    var plain = graph
    plain.objects[encryptID] = nil
    plain.trailer[PDFName("Encrypt")] = nil
    return plain
  }

  /// P28-016/P28-017/P28-018/P28-019: full rewrite with AES-256 (V5/R6)
  /// encryption, or a plain rewrite when `encryption` is nil (authorized
  /// password removal). The input graph must be unencrypted; the encrypted
  /// output carries a fresh /ID and a verified /Encrypt dictionary. Weak
  /// profiles are not writable by design.
  public static func write(
    _ graph: PDFGraph, encryption: PDFEncryptionOptions?, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    guard let encryption else { return try write(graph, limits: limits) }
    try Task.checkCancellation()
    try requireFullRewriteEligibility(graph, limits: limits)
    let output = try PDFEncryptionOutput.make(options: encryption)
    var encrypted = graph
    for (id, value) in graph.objects {
      encrypted.objects[id] = try output.encryptObject(value, id: id)
    }
    let encryptID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    encrypted.objects[encryptID] = .dictionary(output.encryptDictionary)
    encrypted.trailer[PDFName("Encrypt")] = .reference(encryptID)
    encrypted.trailer[PDFName("ID")] = .array([
      .string(output.fileID), .string(output.fileID),
    ])
    return try serialize(encrypted, limits: limits)
  }

  /// Shared eligibility checks for full rewrites.
  private static func requireFullRewriteEligibility(_ graph: PDFGraph, limits: PDFLimits) throws {
    try Task.checkCancellation()
    guard (0...7).map({ "1.\($0)" }).contains(graph.version) else {
      throw PDFError(.unsupported, "Unsupported output PDF version")
    }
    guard !graph.objects.isEmpty, graph.objects.count <= limits.objects else {
      throw PDFError(.limitExceeded, "Output object count exceeds the configured limit")
    }
    for key in ["Encrypt", "Prev", "XRefStm"] where graph.trailer[PDFName(key)] != nil {
      throw PDFError(
        .unsupported, "Protected or revision-dependent output needs a dedicated save mode")
    }
    try PDFGraphValidation.validateReferences(in: graph, limits: limits)
    _ = try PDFGraphValidation.pages(in: graph, limits: limits)
    for value in graph.objects.values {
      try requireRewriteEligibility(value, depth: 0, limits: limits)
    }
  }

  /// Serialize a validated graph as a classic full rewrite. The caller owns
  /// eligibility; encrypted output and signing pass their transformed graphs
  /// here (P28/P30).
  public static func serialize(
    _ graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    try Task.checkCancellation()
    var serializer = PDFObjectSerializer(limits: limits)
    try serializer.append("%PDF-\(graph.version)\n")
    try serializer.append(Data([37, 226, 227, 207, 211, 10]))
    var offsets: [PDFObjectID: Int] = [:]
    var numbers: Set<Int> = []
    for id in graph.objects.keys.sorted() {
      try Task.checkCancellation()
      guard id.number > 0, id.number <= limits.objects,
        (0...65_535).contains(id.generation), numbers.insert(id.number).inserted
      else { throw PDFError(.malformed, "Invalid or conflicting output object identity") }
      offsets[id] = serializer.data.count
      try serializer.append("\(id.number) \(id.generation) obj\n")
      try serializer.value(graph.objects[id]!, depth: 0)
      try serializer.append("\nendobj\n")
    }
    let xrefOffset = serializer.data.count
    try serializer.append("xref\n0 1\n0000000000 65535 f \n")
    // Sparse subsections avoid allocating a table up to an arbitrary object number.
    for id in graph.objects.keys.sorted() {
      guard let offset = offsets[id], offset <= 9_999_999_999 else {
        throw PDFError(.limitExceeded, "Output offset exceeds classic cross-reference capacity")
      }
      try serializer.append("\(id.number) 1\n")
      let row = String(format: "%010lld %05d n \n", Int64(offset), id.generation)
      try serializer.append(row)
    }
    var trailer = graph.trailer
    trailer[PDFName("Size")] = .integer(Int64(numbers.max()!) + 1)
    try serializer.append("trailer\n")
    try serializer.value(.dictionary(trailer), depth: 0)
    try serializer.append("\nstartxref\n\(xrefOffset)\n%%EOF\n")
    return serializer.data
  }

  /// P31-008: compressed-object output for PDF 1.5+ documents. Non-stream
  /// objects that the trailer does not reference are packed into Flate object
  /// streams, and the cross-reference becomes a stream. Streams and
  /// trailer-referenced objects stay top-level. The output is reparsed and
  /// compared against the graph before it is returned.
  public static func writeCompressed(
    _ graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    try requireFullRewriteEligibility(graph, limits: limits)
    return try writeCompressedEligible(graph, limits: limits)
  }

  /// Compressed-object output that drops stale linearization hints first
  /// when asked; see `write(_:droppingLinearization:limits:)`.
  public static func writeCompressed(
    _ graph: PDFGraph, droppingLinearization dropLinear: Bool,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    var graph = graph
    if dropLinear {
      graph = droppingLinearization(graph).graph
    }
    try requireFullRewriteEligibility(graph, limits: limits)
    return try writeCompressedEligible(graph, limits: limits)
  }

  private static func writeCompressedEligible(
    _ graph: PDFGraph, limits: PDFLimits
  ) throws -> Data {
    let version = graph.version
    guard version == "2.0" || ["1.5", "1.6", "1.7"].contains(version) else {
      throw PDFError(.unsupported, "Compressed-object output needs PDF 1.5 or later")
    }
    let trailerReferenced = Set(
      graph.trailer.values.compactMap { value -> PDFObjectID? in
        if case .reference(let id) = value { return id }
        return nil
      })
    var topLevel: [PDFObjectID] = []
    var compressible: [PDFObjectID] = []
    for (id, value) in graph.objects.sorted(by: { $0.key < $1.key }) {
      if case .stream = value {
        topLevel.append(id)
      } else if trailerReferenced.contains(id) {
        topLevel.append(id)
      } else {
        compressible.append(id)
      }
    }

    struct ObjectStreamPlan {
      let id: PDFObjectID
      let value: PDFValue
      let memberIndexes: [Int: Int]
    }
    var plans: [ObjectStreamPlan] = []
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let chunkSize = 200
    var chunkStart = 0
    while chunkStart < compressible.count {
      let chunk = Array(compressible[chunkStart..<min(chunkStart + chunkSize, compressible.count)])
      var header = ""
      var bodies = Data()
      var indexes: [Int: Int] = [:]
      for (index, id) in chunk.enumerated() {
        guard let value = graph.objects[id] else { continue }
        let body = try serializedValue(value, limits: limits)
        header += "\(id.number) \(bodies.count) "
        indexes[id.number] = index
        bodies.append(body)
        bodies.append(0x0A)
      }
      let first = header.utf8.count
      let decoded = Data(header.utf8) + bodies
      let compressed = try PDFFilters.encodeFlate(decoded, limits: limits)
      let dictionary: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("ObjStm")),
        PDFName("N"): .integer(Int64(chunk.count)),
        PDFName("First"): .integer(Int64(first)),
        PDFName("Filter"): .name(PDFName("FlateDecode")),
        PDFName("Length"): .integer(Int64(compressed.count)),
      ]
      plans.append(
        ObjectStreamPlan(
          id: PDFObjectID(nextNumber), value: .stream(PDFStream(dictionary: dictionary, bytes: compressed)),
          memberIndexes: indexes))
      nextNumber += 1
      chunkStart += chunkSize
    }
    let xrefID = PDFObjectID(nextNumber)

    var serializer = PDFObjectSerializer(limits: limits)
    try serializer.append("%PDF-\(graph.version)\n")
    try serializer.append(Data([37, 226, 227, 207, 211, 10]))
    var offsets: [PDFObjectID: Int] = [:]
    for id in topLevel {
      guard let value = graph.objects[id] else { continue }
      offsets[id] = serializer.data.count
      try serializer.append("\(id.number) \(id.generation) obj\n")
      try serializer.value(value, depth: 0)
      try serializer.append("\nendobj\n")
    }
    for plan in plans {
      offsets[plan.id] = serializer.data.count
      try serializer.append("\(plan.id.number) 0 obj\n")
      try serializer.value(plan.value, depth: 0)
      try serializer.append("\nendobj\n")
    }
    let xrefOffset = serializer.data.count

    let size = nextNumber + 1
    var compressedByNumber: [Int: (stream: Int, index: Int)] = [:]
    for plan in plans {
      for (number, index) in plan.memberIndexes {
        compressedByNumber[number] = (plan.id.number, index)
      }
    }
    var topLevelByNumber: [Int: PDFObjectID] = [:]
    for id in topLevel { topLevelByNumber[id.number] = id }
    for plan in plans {
      topLevelByNumber[plan.id.number] = plan.id
      offsets[plan.id] = offsets[plan.id] ?? 0
    }
    topLevelByNumber[xrefID.number] = xrefID
    offsets[xrefID] = xrefOffset
    let freeNumbers = (1..<size).filter {
      topLevelByNumber[$0] == nil && compressedByNumber[$0] == nil
    }
    var nextFree: [Int: Int] = [:]
    for (index, number) in freeNumbers.enumerated() {
      nextFree[number] = index + 1 < freeNumbers.count ? freeNumbers[index + 1] : 0
    }

    var entries = Data()
    func appendEntry(_ type: UInt8, _ second: Int, _ third: Int) {
      entries.append(type)
      entries.append(UInt8((second >> 24) & 0xFF))
      entries.append(UInt8((second >> 16) & 0xFF))
      entries.append(UInt8((second >> 8) & 0xFF))
      entries.append(UInt8(second & 0xFF))
      entries.append(UInt8((third >> 8) & 0xFF))
      entries.append(UInt8(third & 0xFF))
    }
    for number in 0..<size {
      if number == 0 {
        appendEntry(0, nextFree[0] ?? 0, 65_535)
      } else if let id = topLevelByNumber[number], let offset = offsets[id] {
        appendEntry(1, offset, id.generation)
      } else if let compressed = compressedByNumber[number] {
        appendEntry(2, compressed.stream, compressed.index)
      } else {
        appendEntry(0, nextFree[number] ?? 0, 65_535)
      }
    }
    let compressedEntries = try PDFFilters.encodeFlate(entries, limits: limits)
    var xrefDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("XRef")),
      PDFName("Size"): .integer(Int64(size)),
      PDFName("W"): .array([.integer(1), .integer(4), .integer(2)]),
      PDFName("Index"): .array([.integer(0), .integer(Int64(size))]),
      PDFName("Filter"): .name(PDFName("FlateDecode")),
      PDFName("Length"): .integer(Int64(compressedEntries.count)),
    ]
    for key in ["Root", "Info", "ID"] {
      if let value = graph.trailer[PDFName(key)] { xrefDictionary[PDFName(key)] = value }
    }
    try serializer.append("\(xrefID.number) 0 obj\n")
    try serializer.value(
      .stream(PDFStream(dictionary: xrefDictionary, bytes: compressedEntries)), depth: 0)
    try serializer.append("\nendobj\n")
    try serializer.append("startxref\n\(xrefOffset)\n%%EOF\n")

    let output = serializer.data
    let reparsed = try PDFParser.parse(output, limits: limits)
    var expected = graph
    if let size = reparsed.graph.trailer[PDFName("Size")] {
      expected.trailer[PDFName("Size")] = size
    }
    for (id, value) in expected.objects {
      guard reparsed.graph.objects[id] == value else {
        throw PDFError(
          .malformed, "Compressed-object output failed verification against the graph")
      }
    }
    // The only extra objects are the container streams this writer added.
    for (id, value) in reparsed.graph.objects where expected.objects[id] == nil {
      guard case .stream(let stream) = value,
        stream.dictionary[PDFName("Type")] == .name(PDFName("ObjStm"))
          || stream.dictionary[PDFName("Type")] == .name(PDFName("XRef"))
      else {
        throw PDFError(
          .malformed, "Compressed-object output contains unexpected objects")
      }
    }
    return output
  }

  private static func requireRewriteEligibility(_ value: PDFValue, depth: Int, limits: PDFLimits)
    throws
  {
    try Task.checkCancellation()
    guard depth <= limits.nesting else {
      throw PDFError(.limitExceeded, "Output exceeds the nesting limit")
    }
    switch value {
    case .dictionary(let dictionary):
      // Signed documents carry a signature dictionary (/Type /Sig with
      // /ByteRange); an empty signature *field* (/FT /Sig without a value) is
      // ordinary form content and may be rewritten.
      guard dictionary[PDFName("ByteRange")] == nil,
        dictionary[PDFName("Type")] != .name(PDFName("Sig")),
        dictionary[PDFName("Linearized")] == nil
      else {
        throw PDFError(.unsupported, "Signed or linearized output needs a dedicated save policy")
      }
      for value in dictionary.values {
        try requireRewriteEligibility(value, depth: depth + 1, limits: limits)
      }
    case .array(let values):
      for value in values { try requireRewriteEligibility(value, depth: depth + 1, limits: limits) }
    case .stream(let stream):
      try requireRewriteEligibility(
        .dictionary(stream.dictionary), depth: depth + 1, limits: limits)
    default: break
    }
  }
}

struct PDFObjectSerializer {
  var data = Data()
  let limits: PDFLimits
  private static let hex = Array("0123456789ABCDEF".utf8)

  mutating func append(_ text: String) throws { try append(Data(text.utf8)) }

  mutating func append(_ bytes: Data) throws {
    guard bytes.count <= limits.fileBytes - data.count else {
      throw PDFError(.limitExceeded, "Serialized output exceeds the configured byte limit")
    }
    data.append(bytes)
  }

  mutating func value(_ value: PDFValue, depth: Int) throws {
    try Task.checkCancellation()
    guard depth <= limits.nesting else {
      throw PDFError(.limitExceeded, "Output exceeds the nesting limit")
    }
    switch value {
    case .null: try append("null")
    case .boolean(let boolean): try append(boolean ? "true" : "false")
    case .integer(let integer): try append(String(integer))
    case .real(let real): try append(try Self.realToken(real))
    case .name(let name):
      guard name.bytes.count <= limits.tokenBytes else {
        throw PDFError(.limitExceeded, "Output name exceeds the token limit")
      }
      try append("/")
      for byte in name.bytes {
        if (33...126).contains(byte), !ByteCursor.isDelimiter(byte), byte != 35 {
          try append(Data([byte]))
        } else {
          try append(Data([35, Self.hex[Int(byte >> 4)], Self.hex[Int(byte & 15)]]))
        }
      }
    case .string(let bytes):
      guard bytes.count <= limits.tokenBytes else {
        throw PDFError(.limitExceeded, "Output string exceeds the token limit")
      }
      try append("<")
      for byte in bytes {
        try append(Data([Self.hex[Int(byte >> 4)], Self.hex[Int(byte & 15)]]))
      }
      try append(">")
    case .array(let values):
      guard values.count <= limits.objects else {
        throw PDFError(.limitExceeded, "Output array exceeds the item limit")
      }
      try append("[")
      for (index, item) in values.enumerated() {
        if index != 0 { try append(" ") }
        try self.value(item, depth: depth + 1)
      }
      try append("]")
    case .dictionary(let dictionary):
      guard dictionary.count <= limits.objects else {
        throw PDFError(.limitExceeded, "Output dictionary exceeds the entry limit")
      }
      try append("<<")
      for key in dictionary.keys.sorted() {
        try append("\n")
        try self.value(.name(key), depth: depth + 1)
        try append(" ")
        try self.value(dictionary[key]!, depth: depth + 1)
      }
      try append("\n>>")
    case .reference(let id):
      guard id.number > 0, id.number <= limits.objects, (0...65_535).contains(id.generation) else {
        throw PDFError(.malformed, "Invalid output reference")
      }
      try append("\(id.number) \(id.generation) R")
    case .stream(let stream):
      guard stream.bytes.count <= limits.streamBytes else {
        throw PDFError(.limitExceeded, "Output stream exceeds the configured limit")
      }
      var dictionary = stream.dictionary
      dictionary[PDFName("Length")] = .integer(Int64(stream.bytes.count))
      try self.value(.dictionary(dictionary), depth: depth + 1)
      try append("\nstream\n")
      try append(stream.bytes)
      try append("\nendstream")
    }
  }

  /// Expand Swift's shortest decimal form so PDF never receives exponent notation.
  static func realToken(_ value: Double) throws -> String {
    guard value.isFinite else { throw PDFError(.malformed, "Non-finite PDF real") }
    let text = String(value)
    guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
    let negative = text.first == "-"
    let mantissa = String(text[..<e]).trimmingCharacters(in: CharacterSet(charactersIn: "-+"))
    let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let digits = pieces.joined()
    guard let exponent = Int(text[text.index(after: e)...]) else {
      throw PDFError(.malformed, "Invalid real exponent")
    }
    let decimalPosition = pieces[0].count + exponent
    let expanded: String
    if decimalPosition <= 0 {
      expanded = "0." + String(repeating: "0", count: -decimalPosition) + digits
    } else if decimalPosition >= digits.count {
      expanded = digits + String(repeating: "0", count: decimalPosition - digits.count) + ".0"
    } else {
      let index = digits.index(digits.startIndex, offsetBy: decimalPosition)
      expanded = String(digits[..<index]) + "." + String(digits[index...])
    }
    return (negative ? "-" : "") + expanded
  }
}
