import PDFCore
import PDFEditing
import SwiftUI

/// P33-006/P33-007: the structure inspector with presentation roles, reading
/// order, and detected reference issues.
struct StructurePanel: View {
  let model: StructureModel
  var canEditContent = true
  var editingRestrictionNotice: String?
  var onSelect: (Int) -> Void
  var onEditRole: (PDFObjectID, String) -> Void
  var onEditAltText: (PDFObjectID) -> Void
  var onMarkArtifact: (PDFObjectID) -> Void
  var onSuggestTags: () -> Void
  var onAcceptSuggestion: (UUID) -> Void
  var onRejectSuggestion: (UUID) -> Void
  var onApplySuggestions: () -> Void
  var onDiscardSuggestions: () -> Void

  private static let commonRoles = [
    "H1", "H2", "H3", "P", "Span", "Figure", "Link", "Form", "L", "LI", "Table", "TR", "TH",
    "TD", "Sect", "Div", "Artifact",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Structure")
          .font(.headline)
        Spacer()
        if let language = model.language {
          Text(language).font(.caption).foregroundStyle(.secondary)
        }
        Button {
          onSuggestTags()
        } label: {
          Label("Suggest Tags", systemImage: "wand.and.stars")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Suggest structure tags for untagged content (requires review)")
        .accessibilityLabel("Suggest structure tags")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
      if !model.isTagged && model.review == nil {
        ContentUnavailableView(
          "Untagged Document", systemImage: "tag.slash",
          description: Text("This document has no structure tree or MarkInfo. Use Suggest Tags to review assisted tagging suggestions."))
      } else {
        List {
          if !model.issues.isEmpty {
            Section("Issues (\(model.issues.count))") {
              ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 2) {
                  Text(issue.kind.rawValue).font(.caption.weight(.semibold))
                  Text(issue.message).font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
          }
          if let review = model.review {
            Section("Suggested Tags (unconfirmed)") {
              if review.suggestions.isEmpty {
                Text("No untagged content was found on these pages.")
                  .font(.caption).foregroundStyle(.secondary)
              }
              ForEach(review.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 3) {
                  HStack(spacing: 6) {
                    Text(suggestion.label).font(.caption.weight(.semibold))
                    Text("\(Int((suggestion.confidence * 100).rounded()))%")
                      .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if review.status(of: suggestion.id) == .accepted {
                      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if review.status(of: suggestion.id) == .rejected {
                      Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }
                  }
                  Text(suggestion.snippet).font(.caption2).lineLimit(2)
                  Text(suggestion.reason).font(.caption2).foregroundStyle(.tertiary)
                  Text("visual-order guess; p\(suggestion.pageIndex + 1)")
                    .font(.caption2).foregroundStyle(.tertiary)
                  HStack(spacing: 8) {
                    Button("Accept") { onAcceptSuggestion(suggestion.id) }
                      .buttonStyle(.borderless).font(.caption)
                      .accessibilityLabel("Accept suggestion: \(suggestion.label)")
                    Button("Reject") { onRejectSuggestion(suggestion.id) }
                      .buttonStyle(.borderless).font(.caption)
                      .accessibilityLabel("Reject suggestion: \(suggestion.label)")
                  }
                }
                .padding(.vertical, 2)
              }
              HStack {
                Button("Apply Accepted") { onApplySuggestions() }
                  .disabled(!canEditContent || review.accepted.isEmpty)
                  .help(editingRestrictionNotice ?? "Apply accepted structure suggestions")
                Button("Discard") { onDiscardSuggestions() }
              }
              .font(.caption)
            }
          }
          if !model.isTagged && !model.entries.isEmpty {
            Section("Reading Order") {
              ForEach(model.entries) { entry in
              Button {
                if let pageIndex = entry.element.pageIndex { onSelect(pageIndex) }
              } label: {
                HStack(spacing: 6) {
                  Text(entry.element.presentationRole)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                  Text(entry.element.role)
                    .font(.caption.monospaced())
                  if let alt = entry.element.alt {
                    Text("alt: \(alt)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  }
                  if let title = entry.element.title {
                    Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer()
                  if let pageIndex = entry.element.pageIndex {
                    Text("p\(pageIndex + 1)").font(.caption2).foregroundStyle(.tertiary)
                  }
                }
                .padding(.leading, CGFloat(entry.depth) * 10)
              }
              .buttonStyle(.plain)
              .contextMenu {
                if let objectID = entry.element.objectID {
                  Menu("Set Role") {
                    ForEach(Self.commonRoles, id: \.self) { role in
                      Button(role) { onEditRole(objectID, role) }
                    }
                  }
                  .disabled(!canEditContent)
                  .help(editingRestrictionNotice ?? "Change this structure element's role")
                  Button("Edit Alternate Text…") { onEditAltText(objectID) }
                    .disabled(!canEditContent || entry.element.role != "Figure")
                    .help(editingRestrictionNotice ?? "Edit this figure's alternate text")
                  Button("Mark as Artifact") { onMarkArtifact(objectID) }
                    .disabled(!canEditContent || entry.element.role == "Artifact")
                    .help(editingRestrictionNotice ?? "Mark this element as an artifact")
                }
              }
            }
          }
          }
        }
      }
    }
    .frame(minWidth: 240, idealWidth: 300, maxWidth: 460)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Structure")
  }
}
