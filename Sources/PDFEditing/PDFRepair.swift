import Foundation
import PDFCore

/// P38-019/P38-020/P38-021/P38-022: conservative repair of a damaged document.
/// Objects are kept byte-verbatim; the cross-reference is rebuilt by scanning
/// object headers and the trailer is reused when present (otherwise
/// reconstructed from the catalog). The original bytes are never modified and
/// the repaired graph is a separate derivative whose editing stays gated until
/// it fully validates.
public struct PDFRepairReport: Sendable, Equatable {
  public enum Action: String, Sendable, Equatable {
    /// The cross-reference was rebuilt from scanned object headers.
    case rebuiltCrossReference
    /// The trailer was reconstructed from the catalog object.
    case reconstructedTrailer
    /// Bytes after the last object were discarded.
    case discardedTrailingBytes
    /// A stream's declared /Length was invalid and its payload was recovered
    /// from the actual bytes (bounded).
    case recoveredStreamLength
  }

  public let actions: [Action]
  public let objectCount: Int
  public let notes: [String]
  /// P04-017: typed warnings with object identity and byte spans. Notes stay
  /// human-readable; diagnostics carry the machine-usable form.
  public let diagnostics: [PDFDiagnostic]
  /// P38-022: true only when the repaired document fully validates; otherwise
  /// content edits stay gated.
  public let editSafe: Bool

  public init(
    actions: [Action], objectCount: Int, notes: [String], editSafe: Bool,
    diagnostics: [PDFDiagnostic] = []
  ) {
    self.actions = actions
    self.objectCount = objectCount
    self.notes = notes
    self.editSafe = editSafe
    self.diagnostics = diagnostics
  }

  public var wasRepaired: Bool { !actions.isEmpty }

  public func report() -> String {
    var lines = [
      "Repair report — \(objectCount) object\(objectCount == 1 ? "" : "s"), "
        + (wasRepaired ? "repaired" : "no repair needed")
    ]
    for action in actions {
      lines.append("  action: \(action.rawValue)")
    }
    lines.append(
      editSafe
        ? "Editing: enabled (the repaired graph fully validates)."
        : "Editing: gated (the repaired graph does not fully validate; edits stay disabled).")
    for note in notes {
      lines.append("  note: \(note)")
    }
    return lines.joined(separator: "\n")
  }
}

public enum PDFRepair {
  /// P38-019/P38-021: repair `data` conservatively. The returned bytes are a
  /// separate derivative; `data` itself is never modified. `data` is nil when
  /// repair cannot produce a valid document (no silent guess).
  public static func repair(
    _ data: Data, budget: HardeningBudget = .untrusted
  ) -> (data: Data?, graph: PDFGraph?, report: PDFRepairReport) {
    // A document that parses is returned unchanged with a clean report.
    if let parsed = try? PDFParser.parse(data, limits: budget.limits) {
      let sanity = PDFSanityReport.check(
        parsed.graph, pageIDs: parsed.pageIDs, budget: budget)
      let editSafe = !sanity.isSuspicious
      return (
        data, parsed.graph,
        PDFRepairReport(
          actions: [], objectCount: parsed.graph.objects.count,
          notes: sanity.isSuspicious ? [sanity.report()] : [], editSafe: editSafe,
          diagnostics: parsed.diagnostics)
      )
    }
    guard data.count <= budget.limits.fileBytes else {
      return (
        nil, nil,
        PDFRepairReport(
          actions: [], objectCount: 0,
          notes: ["The file exceeds the configured size budget."], editSafe: false)
      )
    }

    // Scan for object headers: `N G obj`. P06-023: the scan covers at
    // most the first scanBytes, so triage on hostile inputs stays bounded.
    var objects: [(number: Int, generation: Int, offset: Int)] = []
    let bytes = [UInt8](data)
    let scanEnd = min(bytes.count, budget.scanBytes)
    var index = 0
    while index < scanEnd, objects.count < budget.limits.objects {
      guard bytes[index].isASCIIDigit else {
        index += 1
        continue
      }
      let headerStart = index
      var number = 0
      while index < bytes.count, bytes[index].isASCIIDigit {
        number = min(number * 10 + Int(bytes[index] - 48), Int.max / 10)
        index += 1
      }
      guard index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 else {
        continue
      }
      while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
      var generation = 0
      let generationStart = index
      while index < bytes.count, bytes[index].isASCIIDigit {
        generation = min(generation * 10 + Int(bytes[index] - 48), 65_535)
        index += 1
      }
      guard index > generationStart else { continue }
      while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
      guard index + 2 < bytes.count, bytes[index] == 0x6F, bytes[index + 1] == 0x62,
        bytes[index + 2] == 0x6A
      else { continue }
      index += 3
      guard index >= bytes.count || bytes[index] == 0x0A || bytes[index] == 0x0D
        || bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x3C
        || bytes[index] == 0x5B || bytes[index] == 0x2F
      else { continue }
      // Later definitions win (incremental updates).
      if let existing = objects.firstIndex(where: { $0.number == number }) {
        objects[existing] = (number, generation, headerStart)
      } else {
        objects.append((number, generation, headerStart))
      }
    }
    var scanNotes: [String] = []
    var scanDiagnostics: [PDFDiagnostic] = []
    if scanEnd < bytes.count {
      scanNotes.append(
        "Header scan covered the first \(scanEnd) of \(bytes.count) bytes (scan budget); headers beyond it were not considered.")
      scanDiagnostics.append(
        PDFDiagnostic(
          severity: .warning, operation: "repair",
          span: PDFSourceSpan(start: scanEnd, end: bytes.count),
          message: "Header scan covered the first \(scanEnd) of \(bytes.count) bytes (scan budget)."))
    }
    guard !objects.isEmpty else {
      return (
        nil, nil,
        PDFRepairReport(
          actions: [], objectCount: 0,
          notes: scanNotes + [
            "No object headers were found; the file is not a repairable PDF."
          ],
          editSafe: false, diagnostics: scanDiagnostics)
      )
    }
    objects.sort { $0.offset < $1.offset }

    var actions: [PDFRepairReport.Action] = [.rebuiltCrossReference]
    var notes: [String] = []
    var diagnostics: [PDFDiagnostic] = scanDiagnostics

    // P38-020: audit declared stream lengths against the actual payload bytes
    // before rebuilding, and record the provenance.
    var recoveredLengths = 0
    for (position, object) in objects.enumerated() {
      let end = position + 1 < objects.count ? objects[position + 1].offset : bytes.count
      guard object.offset < end else { continue }
      let mismatches = streamLengthMismatches(
        in: data.subdata(in: object.offset..<end))
      guard mismatches > 0 else { continue }
      recoveredLengths += mismatches
      diagnostics.append(
        PDFDiagnostic(
          severity: .warning, operation: "repair",
          object: PDFObjectID(object.number, generation: object.generation),
          span: PDFSourceSpan(start: object.offset, end: end),
          message: "Declared /Length does not match the payload; the actual bytes are authoritative."))
    }
    if recoveredLengths > 0 {
      actions.append(.recoveredStreamLength)
      notes.append(
        "\(recoveredLengths) stream\(recoveredLengths == 1 ? "" : "s") declared a /Length that does not match the payload; the actual bytes are authoritative.")
    }

    // Reuse the last trailer dictionary when one is present.
    var trailerDictionary: Data?
    if let trailerRange = data.range(of: Data("trailer".utf8), options: .backwards) {
      let after = trailerRange.upperBound
      var depth = 0
      var start: Int?
      var cursor = after
      while cursor < data.count {
        let byte = data[data.startIndex + cursor]
        if byte == 0x3C, cursor + 1 < data.count, data[data.startIndex + cursor + 1] == 0x3C {
          if start == nil { start = cursor }
          depth += 1
          cursor += 2
          continue
        }
        if byte == 0x3E, cursor + 1 < data.count, data[data.startIndex + cursor + 1] == 0x3E {
          depth -= 1
          cursor += 2
          if depth == 0, let start {
            trailerDictionary = data.subdata(
              in: (data.startIndex + start)..<(data.startIndex + cursor))
            break
          }
          continue
        }
        cursor += 1
      }
    }
    if trailerDictionary == nil {
      actions.append(.reconstructedTrailer)
      notes.append("No trailer dictionary was found; it was reconstructed from the catalog object.")
    }

    // Rebuild the file: header, object bodies verbatim, fresh xref, trailer.
    var repaired = Data("%PDF-1.7\n".utf8)
    repaired.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
    var offsets: [Int: Int] = [:]
    var highest = 0
    for object in objects {
      highest = max(highest, object.number)
    }
    for (position, object) in objects.enumerated() {
      let end = position + 1 < objects.count ? objects[position + 1].offset : bytes.count
      guard object.offset < end else { continue }
      var slice = data.subdata(in: object.offset..<end)
      if let range = slice.range(of: Data("endobj".utf8), options: .backwards) {
        let trimmed = range.upperBound
        if trimmed < slice.count, position == objects.count - 1 {
          actions.append(.discardedTrailingBytes)
          notes.append(
            "\(slice.count - trimmed) bytes after the last object were discarded.")
        }
        slice = slice.prefix(trimmed)
      }
      offsets[object.number] = repaired.count
      repaired.append(slice)
      repaired.append(0x0A)
    }
    let xrefOffset = repaired.count
    repaired.append(Data("xref\n0 \(highest + 1)\n".utf8))
    repaired.append(Data("0000000000 65535 f \n".utf8))
    for number in 1...max(highest, 1) {
      if let offset = offsets[number] {
        repaired.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
      } else {
        repaired.append(Data("0000000000 65535 f \n".utf8))
      }
    }
    if let trailerDictionary {
      // The rebuilt table has `highest + 1` entries; the reused trailer's
      // /Size must agree with it.
      let adjusted = Self.adjustingTrailerSize(
        trailerDictionary, size: highest + 1)
      repaired.append(Data("trailer\n".utf8))
      repaired.append(adjusted)
      repaired.append(0x0A)
    } else {
      let root = catalogObjectNumber(in: repaired)
      guard let root else {
        return (
          nil, nil,
          PDFRepairReport(
            actions: actions, objectCount: objects.count,
            notes: scanNotes + notes + ["No catalog object was found; repair refused."], editSafe: false,
            diagnostics: diagnostics)
        )
      }
      repaired.append(
        Data("trailer\n<< /Size \(highest + 1) /Root \(root) 0 R >>\n".utf8))
    }
    repaired.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))

    let reparsedAttempt = try? PDFParser.parse(repaired, limits: budget.limits)
    guard let reparsed = reparsedAttempt else {
      var failureNotes = notes
      do {
        _ = try PDFParser.parse(repaired, limits: budget.limits)
      } catch {
        failureNotes.append("Reparse error: \(error)")
      }
      return (
        nil, nil,
        PDFRepairReport(
          actions: actions, objectCount: objects.count,
          notes: scanNotes + failureNotes + ["The rebuilt document does not parse; repair refused."],
          editSafe: false, diagnostics: diagnostics)
      )
    }
    let sanity = PDFSanityReport.check(
      reparsed.graph, pageIDs: reparsed.pageIDs, budget: budget)
    var editSafe = !sanity.isSuspicious
    if (try? reparsed.graph.validate()) == nil {
      editSafe = false
      notes.append("The repaired graph does not fully validate.")
    }
    if sanity.isSuspicious {
      notes.append(sanity.report())
    }
    return (
      repaired, reparsed.graph,
      PDFRepairReport(
        actions: actions, objectCount: objects.count,
        notes: scanNotes + notes, editSafe: editSafe, diagnostics: diagnostics)
    )
  }

  /// Rewrites a trailer dictionary's `/Size` to the rebuilt value (adding it
  /// when absent), leaving every other entry verbatim.
  static func adjustingTrailerSize(_ dictionary: Data, size: Int) -> Data {
    var text = String(decoding: dictionary, as: UTF8.self)
    if let range = text.range(of: "/Size \\d+", options: .regularExpression) {
      text.replaceSubrange(range, with: "/Size \(size)")
      return Data(text.utf8)
    }
    // Insert /Size right after the opening `<<`.
    if let range = text.range(of: "<<") {
      text.insert(contentsOf: " /Size \(size)", at: range.upperBound)
      return Data(text.utf8)
    }
    return Data("<< /Size \(size) >>".utf8)
  }

  /// P38-020: how many streams in one object body declare a /Length that does
  /// not match the actual `stream`/`endstream` payload.
  static func streamLengthMismatches(in body: Data) -> Int {
    let text = String(decoding: body, as: UTF8.self)
    var mismatches = 0
    var searchStart = text.startIndex
    while let streamRange = text.range(of: "stream", range: searchStart..<text.endIndex) {
      // The declared length comes from the dictionary text before the keyword.
      let prefix = text[text.startIndex..<streamRange.lowerBound]
      var declared: Int?
      if let lengthRange = prefix.range(of: "/Length ", options: .backwards) {
        let digits = prefix[lengthRange.upperBound...].prefix { $0.isNumber }
        declared = Int(digits)
      }
      // The payload starts after the keyword's end-of-line.
      var payloadStart = streamRange.upperBound
      if payloadStart < text.endIndex, text[payloadStart] == "\r" { payloadStart = text.index(after: payloadStart) }
      if payloadStart < text.endIndex, text[payloadStart] == "\n" { payloadStart = text.index(after: payloadStart) }
      guard let endStreamRange = text.range(
        of: "endstream", range: payloadStart..<text.endIndex)
      else { break }
      var payloadEnd = endStreamRange.lowerBound
      // The EOL before `endstream` is not part of the payload.
      if payloadEnd > payloadStart, text[text.index(before: payloadEnd)] == "\n" {
        payloadEnd = text.index(before: payloadEnd)
      }
      if payloadEnd > payloadStart, text[text.index(before: payloadEnd)] == "\r" {
        payloadEnd = text.index(before: payloadEnd)
      }
      let actual = text.distance(from: payloadStart, to: payloadEnd)
      if let declared, declared != actual { mismatches += 1 }
      searchStart = endStreamRange.upperBound
    }
    return mismatches
  }

  /// The object number of the catalog in a rebuilt file (for a reconstructed
  /// trailer).
  static func catalogObjectNumber(in data: Data) -> Int? {
    let text = String(decoding: data, as: UTF8.self)
    guard let range = text.range(of: "/Type /Catalog") else { return nil }
    let prefix = text[text.startIndex..<range.lowerBound]
    guard let objectRange = prefix.range(of: " obj", options: .backwards) else { return nil }
    let header = prefix[prefix.startIndex..<objectRange.lowerBound]
    guard let numberRange = header.range(of: "\\d+", options: .regularExpression) else {
      return nil
    }
    return Int(header[numberRange])
  }
}

extension UInt8 {
  fileprivate var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }
}
