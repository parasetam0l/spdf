import Foundation
import MacServices

/// P43-002/P43-004: the fonts this document uses with their provisioning
/// status. Missing and commercially licensed fonts are surfaced, never
/// silently substituted.
final class FontsModel: ObservableObject {
  @Published var entries: [FontStatus] = []
  @Published var isBusy = false
  @Published var message: String?

  var missingCount: Int { entries.filter { $0.needsProvisioning }.count }
  var paidCount: Int { entries.filter { $0.font.mayBeCommerciallyLicensed }.count }

  func update(with statuses: [FontStatus]) {
    entries = statuses
  }
}
