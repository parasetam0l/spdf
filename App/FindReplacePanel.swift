import MacServices
import PDFEditing
import SwiftUI

/// TXT-07: preview every match, its eligibility and the exact replacement
/// before the single undoable commit.
struct WorkspaceFindReplaceView: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Find and Replace").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { viewer.hideFindReplace() }
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close Find and Replace")
      }

      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Find").font(.caption).foregroundStyle(.secondary)
          TextField("Find in document", text: $viewer.searchText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { viewer.previewFindReplace() }
            .accessibilityLabel("Find text")
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Replace with").font(.caption).foregroundStyle(.secondary)
          TextField("Replacement", text: $viewer.replaceText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { viewer.previewFindReplace() }
            .accessibilityLabel("Replacement text")
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Scope").font(.caption).foregroundStyle(.secondary)
          Picker("Replace scope", selection: $viewer.findReplaceScope) {
            ForEach(FindReplaceScope.allCases, id: \.self) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .labelsHidden()
          .frame(width: 140)
          .accessibilityLabel("Replace scope")
        }
      }

      HStack(spacing: 16) {
        Toggle("Match case", isOn: $viewer.findReplaceCaseSensitive)
        Toggle("Whole word", isOn: $viewer.findReplaceWholeWord)
        Spacer()
        Button("Preview") { viewer.previewFindReplace() }
          .buttonStyle(.bordered)
          .disabled(viewer.searchText.isEmpty)
          .accessibilityLabel("Preview replacements")
      }

      if let error = viewer.findReplaceError {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Replace error")
      }

      if let preview = viewer.findReplacePreview {
        Text(preview.summary).font(.caption.weight(.medium))
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(preview.matches.enumerated()), id: \.offset) { _, match in
              matchRow(match)
              Divider()
            }
          }
        }
        .frame(minHeight: 140, maxHeight: 260)
        .accessibilityLabel("Replacement preview")
        HStack {
          Text("All eligible matches").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button {
            viewer.applyFindReplace()
          } label: {
            Text("Replace \(preview.eligibleCount)")
          }
          .buttonStyle(.borderedProminent)
          .disabled(preview.eligibleCount == 0 || !viewer.allowsContentEditing)
          .help(viewer.allowsContentEditing
            ? "Replace all eligible matches as one Undoable edit"
            : "Editing unavailable: \(viewer.editingRestrictionNotice ?? "this document is view-only.")")
          .accessibilityLabel("Replace eligible matches")
        }
      }

      if let result = viewer.findReplaceResult {
        Label(result.summary, systemImage: result.replacedCount > 0
          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(result.replacedCount > 0 ? .green : .secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Replacement result")
      }
    }
    .padding(16)
    .frame(minWidth: 620, minHeight: 360)
  }

  private func matchRow(_ match: FindReplaceMatch) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Page \(match.pageIndex + 1)").font(.caption2).foregroundStyle(.secondary)
        Text(match.text.isEmpty ? "(line boundary)" : match.text)
          .font(.caption)
          .lineLimit(2)
        Spacer()
        if match.eligibility.isEligible {
          Label("Replace", systemImage: "checkmark.circle")
            .font(.caption2)
            .foregroundStyle(.green)
        } else {
          Label("Skip", systemImage: "minus.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Text("→ \(match.replacement.isEmpty ? "(empty)" : match.replacement)")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      if let reason = match.eligibility.reason {
        Text(reason).font(.system(size: 10)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
