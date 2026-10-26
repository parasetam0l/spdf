import Foundation
import PDFCore

/// SPC-04: explicit PostScript/EPS/Distiller scope decision.
///
/// No owned PostScript interpreter is implemented and no Ghostscript or
/// Distiller-style engine is embedded. PostScript/EPS input therefore remains
/// an explicit replacement exception: the app detects it, refuses conversion
/// with a user-facing disclosure, and asks for a PDF produced by an external
/// approved workflow. This file intentionally provides no conversion API.
public enum PostScriptFormat: String, Sendable, Equatable {
  case postScript
  case eps
  case pdf
  case unknown
}

public struct PostScriptDetection: Sendable, Equatable {
  public let format: PostScriptFormat
  public let header: String?
  public let boundingBox: [Double]?
  public let pageCountHint: Int?
  public let isDSCConforming: Bool
  public let hasEPSPreview: Bool
  public let warnings: [String]
}

public enum PostScriptScopeDecision: String, Sendable, Equatable {
  case notPostScript
  case explicitReplacementException
}

public struct PostScriptConversionDecision: Sendable, Equatable {
  public let outcome: PostScriptScopeDecision
  public let format: PostScriptFormat
  public let allowed: Bool
  public let reason: String
  public let disclosure: String
  public let approvedLocalCapabilities: [String]
  public let excludedEngines: [String]

  public func report() -> String {
    var lines = [
      "PostScript/EPS scope — " + outcome.rawValue + " (" + format.rawValue + ")"
    ]
    lines.append("  Conversion allowed: " + (allowed ? "yes" : "no"))
    lines.append("  " + reason)
    lines.append("  " + disclosure)
    lines.append("  Approved local capabilities: " + approvedLocalCapabilities.joined(separator: ", "))
    lines.append("  Explicitly excluded engines: " + excludedEngines.joined(separator: ", "))
    return lines.joined(separator: "\n")
  }
}

public enum PostScriptScope {
  public static let profile =
    "Explicit replacement exception: no PostScript interpreter is owned or embedded. "
    + "PostScript/EPS file import and Distiller-style job processing are not implemented; "
    + "no Ghostscript or equivalent forbidden engine is linked or invoked. Users must "
    + "supply PDF produced by an approved external workflow."

  public static let excludedEngines = ["Ghostscript", "Adobe Distiller", "other PostScript interpreters"]

  static let maximumDetectionBytes = 1_048_576

  public static func detect(_ data: Data) -> PostScriptDetection {
    let bytes = data.prefix(maximumDetectionBytes)
    let text = String(decoding: bytes, as: UTF8.self)
    let leading = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
    let headerLine = leading.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
      .map(String.init)
    let header = headerLine?.trimmingCharacters(in: .whitespacesAndNewlines)
    var warnings: [String] = []
    let lower = text.lowercased()
    var format: PostScriptFormat = .unknown
    if header?.hasPrefix("%PDF-") == true {
      format = .pdf
    } else if header?.hasPrefix("%!PS") == true {
      if text.contains("%%BoundingBox:") || lower.contains("epsf") {
        format = .eps
      } else {
        format = .postScript
      }
    } else if text.contains("%!PS-Adobe") && text.contains("%%BoundingBox:") {
      format = .eps
      warnings.append("PostScript header is not at the start of the data.")
    } else if let header, !header.isEmpty {
      warnings.append("The data does not have a recognised PostScript or PDF header.")
    }
    let boundingBox = parseBoundingBox(text)
    let pageCount = parsePageCount(text)
    let dsc = text.contains("%%EndComments") || text.contains("%%Pages:")
      || header?.hasPrefix("%!PS-Adobe") == true
    let preview = text.contains("%%BeginPreview")
    if format == .eps, boundingBox == nil {
      warnings.append("EPS data has no readable %%BoundingBox.")
    }
    if format == .postScript, boundingBox != nil {
      warnings.append("PostScript data carries a BoundingBox; classify it as EPS if it is an EPS file.")
    }
    if !dsc, format != .pdf, format != .unknown {
      warnings.append("PostScript data is not DSC-conforming; conversion would be unsafe anyway.")
    }
    return PostScriptDetection(
      format: format, header: header, boundingBox: boundingBox, pageCountHint: pageCount,
      isDSCConforming: dsc, hasEPSPreview: preview, warnings: warnings.sorted())
  }

  public static func decision(for detection: PostScriptDetection) -> PostScriptConversionDecision {
    switch detection.format {
    case .pdf:
      return PostScriptConversionDecision(
        outcome: .notPostScript, format: .pdf, allowed: false,
        reason: "The data is PDF, not PostScript; use the normal PDF import path.",
        disclosure: "No PostScript conversion is involved.",
        approvedLocalCapabilities: ["PDF parsing and rendering"], excludedEngines: excludedEngines)
    case .unknown:
      return PostScriptConversionDecision(
        outcome: .notPostScript, format: .unknown, allowed: false,
        reason: "The data is not recognised as PostScript, EPS or PDF.",
        disclosure: "No conversion is attempted for unknown data.",
        approvedLocalCapabilities: ["PDF parsing and rendering"], excludedEngines: excludedEngines)
    case .postScript, .eps:
      return PostScriptConversionDecision(
        outcome: .explicitReplacementException, format: detection.format, allowed: false,
        reason: "PostScript/EPS conversion is not implemented: the project does not own a "
          + "PostScript interpreter and must not quietly embed Ghostscript or a forbidden engine.",
        disclosure: "This remains an explicit replacement exception. Convert the file to PDF "
          + "with an approved external workflow before importing; the app will not invoke a "
          + "hidden interpreter.",
        approvedLocalCapabilities: ["PDF parsing and rendering"],
        excludedEngines: excludedEngines)
    }
  }

  public static func report(for data: Data) -> String {
    let detection = detect(data)
    var lines = [decision(for: detection).report()]
    lines.append("  Detection: DSC=" + String(detection.isDSCConforming)
      + ", preview=" + String(detection.hasEPSPreview)
      + ", pages=" + (detection.pageCountHint.map(String.init) ?? "unknown"))
    if let box = detection.boundingBox {
      lines.append("  BoundingBox: " + box.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
    for warning in detection.warnings { lines.append("  Warning: " + warning) }
    lines.append("Profile: " + profile)
    return lines.joined(separator: "\n")
  }

  static func parseBoundingBox(_ text: String) -> [Double]? {
    for key in ["%%HiResBoundingBox:", "%%BoundingBox:"] {
      guard let range = text.range(of: key) else { continue }
      let line = text[range.upperBound...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
      let numbers = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        .compactMap { Double($0) }
      if numbers.count >= 4 {
        return Array(numbers.prefix(4))
      }
    }
    return nil
  }

  static func parsePageCount(_ text: String) -> Int? {
    guard let range = text.range(of: "%%Pages:") else { return nil }
    let line = text[range.upperBound...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    return Int(line.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
