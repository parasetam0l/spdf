import Foundation
import PDFCore

/// One operand of a content-stream instruction with its byte span in the
/// decoded content bytes (`lowerBound..<upperBound`).
struct ContentOperand {
  let value: PDFValue
  let span: Range<Int>
}

/// One parsed content-stream instruction: operands followed by an operator,
/// with a span covering the exact original bytes. Unknown operators are kept
/// verbatim; inline images keep their payload opaque.
struct ContentInstruction {
  let operatorName: String
  let operands: [ContentOperand]
  let span: Range<Int>
  let isInlineImage: Bool
}

/// P13-001/P13-003/P13-004: byte-preserving content tokenizer. Operands are
/// parsed with the core syntax parser; everything else becomes an operator
/// token. Inline images are skipped conservatively so binary payloads can
/// never corrupt the instructions that follow.
enum ContentParser {
  static func instructions(in bytes: [UInt8], limits: PDFLimits = PDFLimits()) throws
    -> [ContentInstruction]
  {
    var parser = try PDFSyntaxParser(bytes: bytes, limits: limits)
    var instructions: [ContentInstruction] = []
    var operands: [ContentOperand] = []
    while true {
      try Task.checkCancellation()
      parser.skipTrivia()
      guard let byte = parser.peekByte else { break }
      guard instructions.count < limits.objects else {
        throw PDFError(.limitExceeded, "Content stream exceeds the configured instruction limit")
      }
      let start = parser.offset
      if startsOperand(byte) {
        let value = try parser.value()
        operands.append(ContentOperand(value: value, span: start..<parser.offset))
        continue
      }
      let word = String(decoding: try parser.word(maximum: limits.tokenBytes), as: UTF8.self)
      if word == "BI" {
        let end = try skipInlineImage(&parser, bytes: bytes, limits: limits)
        instructions.append(
          ContentInstruction(
            operatorName: word, operands: operands, span: start..<end, isInlineImage: true))
        operands.removeAll()
        continue
      }
      instructions.append(
        ContentInstruction(
          operatorName: word, operands: operands, span: start..<parser.offset,
          isInlineImage: false))
      operands.removeAll()
    }
    guard operands.isEmpty else {
      throw PDFError(.malformed, "Content stream ends with operands but no operator")
    }
    return instructions
  }

  /// First byte of a content operand token. Operators are bare words made of
  /// regular characters, so digits, signs, dots, and the operand delimiters
  /// identify operands unambiguously.
  static func startsOperand(_ byte: UInt8) -> Bool {
    if (48...57).contains(byte) { return true }  // digits
    switch byte {
    case 43, 45, 46: return true  // + - .
    case 47, 40, 60, 91, 123: return true  // / ( < [ {
    default: return false
    }
  }

  /// P13-020: skip an inline image from just after `BI` through `EI`.
  /// The image dictionary is parsed with the syntax parser; the binary
  /// payload is bounded and ends at the first `EI` preceded by whitespace
  /// and followed by whitespace, a delimiter, or end of data.
  private static func skipInlineImage(
    _ parser: inout PDFSyntaxParser, bytes: [UInt8], limits: PDFLimits
  ) throws -> Int {
    while true {
      try Task.checkCancellation()
      parser.skipTrivia()
      guard let byte = parser.peekByte else {
        throw PDFError(.malformed, "Inline image dictionary is unterminated")
      }
      if startsOperand(byte) {
        _ = try parser.value()
        continue
      }
      let word = try parser.word(maximum: limits.tokenBytes)
      if word == Array("ID".utf8) { break }
    }
    // A single whitespace byte separates ID from the binary payload.
    if let byte = parser.peekByte, PDFByteClassification.isWhitespace(byte) {
      try parser.setOffset(parser.offset + 1)
    }
    let payloadStart = parser.offset
    let window = min(bytes.count, payloadStart + limits.streamBytes)
    var position = payloadStart
    while position + 1 < window {
      try Task.checkCancellation()
      if bytes[position] == 69, bytes[position + 1] == 73,
        position > payloadStart, PDFByteClassification.isWhitespace(bytes[position - 1])
      {
        let after = position + 2
        if after >= bytes.count || PDFByteClassification.isWhitespace(bytes[after])
          || PDFByteClassification.isDelimiter(bytes[after])
        {
          try parser.setOffset(after)
          return after
        }
      }
      position += 1
    }
    throw PDFError(.malformed, "Inline image payload has no bounded EI marker")
  }
}
