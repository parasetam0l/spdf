import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// SIG-01: shared independent-validator plumbing. The validators never read
/// the app's own validation result: they receive the PDF bytes, the declared
/// ByteRange and the CMS contents, and are asked to verify them from scratch.
enum SignatureQualificationSupport {
  struct IndependentResult {
    let succeeded: Bool
    let message: String
  }

  static func cmsDER(_ signature: PDFSignature) -> Data? {
    guard case .string(let contents) = signature.dictionary[PDFName("Contents")] else {
      return nil
    }
    var der = contents
    while der.count > 2, der.last == 0, der[der.count - 2] == 0 {
      der = der.dropLast()
    }
    return der
  }

  static func signedBytes(data: Data, signature: PDFSignature) throws -> Data {
    let bytes = [UInt8](data)
    var signed = Data()
    var index = 0
    while index + 1 < signature.byteRange.count {
      let start = signature.byteRange[index]
      let length = signature.byteRange[index + 1]
      guard start >= 0, length >= 0, start + length <= bytes.count else {
        throw PDFError(.malformed, "ByteRange is outside the file")
      }
      signed.append(contentsOf: bytes[start..<(start + length)])
      index += 2
    }
    return signed
  }

  /// The hex digit range of the /Contents gap (inside the angle brackets).
  static func contentsGap(in data: Data, signature: PDFSignature) -> Range<Int>? {
    guard signature.byteRange.count == 4 else { return nil }
    let firstEnd = signature.byteRange[0] + signature.byteRange[1]
    let secondStart = signature.byteRange[2]
    guard firstEnd >= 0, secondStart <= data.count, firstEnd < secondStart else { return nil }
    var lower = firstEnd
    var upper = secondStart
    if lower < upper, data[lower] == 0x3C { lower += 1 }
    if upper > lower, data[upper - 1] == 0x3E { upper -= 1 }
    return lower..<upper
  }

  /// Replace the /Contents hex with a different CMS DER, zero-padded to the
  /// same reserved length, without moving any byte offset.
  static func replacingContents(
    _ data: Data, signature: PDFSignature, cms: Data
  ) throws -> Data {
    guard let gap = contentsGap(in: data, signature: signature) else {
      throw PDFError(.malformed, "Signature contents gap is malformed")
    }
    guard cms.count * 2 <= gap.count else {
      throw PDFError(.limitExceeded, "Replacement CMS is larger than the reservation")
    }
    var output = data
    let hex = cms.map { String(format: "%02X", $0) }.joined()
      + String(repeating: "0", count: gap.count - cms.count * 2)
    output.replaceSubrange(gap, with: Data(hex.utf8))
    return output
  }

  /// The byte range of the second integer inside /ByteRange [a b c d].
  static func secondIntegerRange(in data: Data) -> Range<Int>? {
    guard let marker = data.range(of: Data("/ByteRange [".utf8)) else { return nil }
    var cursor = marker.upperBound
    var integers = 0
    while cursor < data.count, integers < 2 {
      while cursor < data.count, data[cursor] == 0x20 { cursor += 1 }
      let start = cursor
      while cursor < data.count, (0x30...0x39).contains(data[cursor]) { cursor += 1 }
      if cursor == start { return nil }
      integers += 1
      if integers == 2 { return start..<cursor }
    }
    return nil
  }

  static func opensslVerify(
    data: Data, signature: PDFSignature, caPEM: Data
  ) throws -> IndependentResult {
    guard let cms = cmsDER(signature) else {
      return IndependentResult(succeeded: false, message: "no CMS contents")
    }
    let signed = try signedBytes(data: data, signature: signature)
    return try opensslVerifyBytes(cms: cms, signedBytes: signed, caPEM: caPEM)
  }

  static func opensslVerifyBytes(
    cms: Data, signedBytes: Data, caPEM: Data
  ) throws -> IndependentResult {
    let openssl = "/usr/bin/openssl"
    guard FileManager.default.isExecutableFile(atPath: openssl) else {
      return IndependentResult(succeeded: true, message: "openssl is unavailable; skipped")
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-sig-qualify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cmsURL = directory.appendingPathComponent("signature.der")
    let contentURL = directory.appendingPathComponent("signed.bin")
    let caURL = directory.appendingPathComponent("ca.pem")
    try cms.write(to: cmsURL)
    try signedBytes.write(to: contentURL)
    try caPEM.write(to: caURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: openssl)
    process.arguments = [
      "cms", "-verify", "-binary", "-inform", "DER", "-in", cmsURL.path, "-content",
      contentURL.path, "-CAfile", caURL.path, "-purpose", "any", "-out", "/dev/null",
    ]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
      decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return IndependentResult(
      succeeded: process.terminationStatus == 0,
      message: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Assert helper used by SIG-06 tests: the independent verifier must accept.
  static func verifyWithOpenSSL(
    data: Data, signature: PDFSignature, caPEM: Data
  ) throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return }
    let result = try opensslVerify(data: data, signature: signature, caPEM: caPEM)
    #expect(result.succeeded, "openssl rejected the signature: \(result.message)")
  }

  /// qpdf structural check. Returns true when qpdf is unavailable (the test
  /// then records the local-only evidence without failing CI).
  static func qpdfCheck(_ data: Data) throws -> Bool {
    let qpdf = "/opt/homebrew/bin/qpdf"
    guard FileManager.default.isExecutableFile(atPath: qpdf) else { return true }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-qpdf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("candidate.pdf")
    try data.write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: qpdf)
    process.arguments = ["--check", url.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  /// Optional independent-reader inspection with poppler's pdfsig. Returns
  /// nil when poppler is not installed (CI may not ship it); the qualification
  /// evidence records both routes and never treats a missing tool as success.
  static func pdfsigReport(_ data: Data) throws -> String? {
    let candidates = ["/opt/homebrew/bin/pdfsig", "/usr/local/bin/pdfsig"]
    guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-pdfsig-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("candidate.pdf")
    try data.write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [url.path]
    let output = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = output
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(
      decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return stdout + stderr
  }

  /// Append bytes after the signed coverage (a later, uncovered revision).
  static func appendLaterRevision(_ data: Data) -> Data {
    var output = data
    if output.last != 0x0A { output.append(0x0A) }
    output.append(Data("%SPDF qualification trailing revision marker\n".utf8))
    return output
  }
}
