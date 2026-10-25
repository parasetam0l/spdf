import CoreGraphics
import Foundation
import PDFCore
import PDFEditing
import Vision

/// OCR-03: one word inside a recognized line, with the recognizer's own
/// confidence and normalized image box. Vision supplies these; recognizers
/// that do not override the word detail leave the array empty and the review
/// falls back to proportional word boxes inside the line.
public struct OCRWordObservation: Sendable, Equatable {
  public let text: String
  public let confidence: Double
  /// Vision-normalized box (origin at the bottom-left of the rendered image).
  public let boundingBox: CGRect

  public init(text: String, confidence: Double, boundingBox: CGRect) {
    self.text = text
    self.confidence = confidence
    self.boundingBox = boundingBox
  }
}

/// OCR-03: a word mapped into unrotated page space, ready for the review
/// overlay and the persisted review record.
public struct OCRTextWord: Sendable, Equatable {
  public let text: String
  public let rect: [Double]
  public let confidence: Double

  public init(text: String, rect: [Double], confidence: Double) {
    self.text = text
    self.rect = rect
    self.confidence = confidence
  }
}

extension VisionTextRecognizer {
  /// Word ranges and boxes from the same recognized candidate that produced
  /// the line. Empty when the candidate exposes no word ranges.
  static func reviewWordObservations(for candidate: VNRecognizedText) -> [OCRWordObservation] {
    let string = candidate.string
    var words: [OCRWordObservation] = []
    string.enumerateSubstrings(
      in: string.startIndex..<string.endIndex, options: .byWords
    ) { substring, range, _, _ in
      guard let substring, !substring.isEmpty,
        let box = try? candidate.boundingBox(for: range)
      else { return }
      words.append(
        OCRWordObservation(
          text: substring, confidence: Double(candidate.confidence),
          boundingBox: box.boundingBox))
    }
    return words
  }
}
