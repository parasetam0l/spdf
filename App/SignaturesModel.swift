import Combine
import Foundation
import PDFEditing

/// P30-015: the signatures sidebar state. Each entry carries the inventory
/// and the separate cryptographic/trust/change statuses.
final class SignaturesModel: ObservableObject {
  struct Entry: Identifiable {
    let id: String
    let signature: PDFSignature
    let validation: PDFSignatureValidation
  }

  @Published var entries: [Entry] = []
}
