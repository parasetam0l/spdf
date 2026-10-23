import Foundation
import PDFCore

/// SAF-03: shared checks for operations that write a derivative PDF. A
/// derivative is always a new file: writing over the open source would bypass
/// the verified save path and could strip protection or earlier state.
public enum DerivativeOutputPolicy {
  /// Rejects a destination that resolves to the open source file. The same
  /// path spelled with `..` or reached through a symbolic link is caught, as
  /// is a hard link to the same file.
  public static func validateDestination(_ destination: URL, source: URL?) throws {
    guard let source else { return }
    if isSameFile(destination, source) {
      throw PDFError(
        .unsupported,
        "Choose a different file; a derivative cannot overwrite the open source")
    }
  }

  public static func isSameFile(_ first: URL, _ second: URL) -> Bool {
    let a = first.standardizedFileURL.resolvingSymlinksInPath()
    let b = second.standardizedFileURL.resolvingSymlinksInPath()
    if a == b { return true }
    if let firstIdentity = identity(of: a), let secondIdentity = identity(of: b) {
      return firstIdentity.isEqual(secondIdentity)
    }
    return false
  }

  private static func identity(of url: URL) -> (any NSCopying & NSObjectProtocol)? {
    try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
  }
}
