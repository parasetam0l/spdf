import MacServices
import PDFCore
import PDFEditing
import SwiftUI

/// P24: a forms sidebar listing canonical AcroForm fields with inline
/// editors. Unsupported fields (signature, push button, choice) are shown
/// with an explicit limitation instead of pretending to be editable.
struct FormsPanel: View {
  let fields: [FormField]
  let orphanedWidgetCount: Int
  var onSubmitText: (String, String) -> Void
  var onDraftText: (String, String) -> Void
  var onToggle: (String, Bool) -> Void
  var onSelectChoice: (String, String) -> Void
  var onSelect: (FormField) -> Void

  var body: some View {
    if fields.isEmpty && orphanedWidgetCount == 0 {
      ContentUnavailableView(
        "No Form Fields", systemImage: "list.bullet.rectangle",
        description: Text("This document has no AcroForm fields."))
    } else {
      VStack(alignment: .leading, spacing: 0) {
        if orphanedWidgetCount > 0 {
          Text(
            "\(orphanedWidgetCount) orphaned widget\(orphanedWidgetCount == 1 ? "" : "s") "
              + "are not linked to a field and cannot be edited."
          )
          .font(.caption2).foregroundStyle(.secondary)
          .padding(8)
          Divider()
        }
        List {
          ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            row(field)
          }
        }
        .listStyle(.inset)
      }
    }
  }

  @ViewBuilder private func row(_ field: FormField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: Self.icon(for: field))
          .foregroundStyle(.secondary).frame(width: 18)
        Text(field.name.isEmpty ? "(unnamed)" : field.name)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if field.isRequired {
          Text("Required").font(.caption2).foregroundStyle(.orange)
        }
        if field.isReadOnly {
          Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button {
          onSelect(field)
        } label: {
          Image(systemName: "arrow.right.circle")
        }
        .buttonStyle(.borderless)
        .help("Show on the page")
      }
      switch field.kind {
      case .text:
        FormTextFieldRow(field: field, onSubmit: onSubmitText, onDraft: onDraftText)
          .id("\(field.name)-\(field.stringValue ?? "")")
      case .button where !field.isPushButton:
        FormToggleRow(field: field, onToggle: onToggle)
          .id("\(field.name)-\(field.isChecked)")
      case .choice:
        FormChoiceRow(field: field, onSelect: onSelectChoice)
          .id("\(field.name)-\(field.stringValue ?? "")")
      case .signature:
        Text("Signature fields cannot be filled yet.")
          .font(.caption2).foregroundStyle(.secondary)
      case .button:
        Text("Push buttons are not executed by this app.")
          .font(.caption2).foregroundStyle(.secondary)
      default:
        Text("This field type is not editable yet.")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  static func icon(for field: FormField) -> String {
    switch field.kind {
    case .text: return field.isMultiline ? "text.alignleft" : "character.cursor.ibeam"
    case .button: return field.isPushButton ? "button.horizontal" : "checkmark.square"
    case .choice: return "list.bullet"
    case .signature: return "signature"
    case .unknown: return "questionmark.square"
    }
  }
}

private struct FormTextFieldRow: View {
  let field: FormField
  var onSubmit: (String, String) -> Void
  var onDraft: (String, String) -> Void
  @State private var text: String

  init(
    field: FormField, onSubmit: @escaping (String, String) -> Void,
    onDraft: @escaping (String, String) -> Void
  ) {
    self.field = field
    self.onSubmit = onSubmit
    self.onDraft = onDraft
    _text = State(initialValue: field.stringValue ?? "")
  }

  var body: some View {
    TextField("Value", text: $text)
      .textFieldStyle(.roundedBorder)
      .font(.callout)
      .disabled(field.isReadOnly)
      .onSubmit { onSubmit(field.name, text) }
      .onChange(of: text) { _, value in onDraft(field.name, value) }
      .accessibilityLabel("Field \(field.name)")
  }
}

private struct FormToggleRow: View {
  let field: FormField
  var onToggle: (String, Bool) -> Void

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { field.isChecked },
        set: { onToggle(field.name, $0) }
      )
    ) {
      Text(field.isChecked ? "On" : "Off").font(.caption)
    }
    .disabled(field.isReadOnly)
    .accessibilityLabel("Field \(field.name)")
  }
}

/// P24-015: a menu of display values that submits the option's export value.
private struct FormChoiceRow: View {
  let field: FormField
  var onSelect: (String, String) -> Void

  var body: some View {
    Menu {
      ForEach(Array(field.options.enumerated()), id: \.offset) { _, option in
        Button(option.display) { onSelect(field.name, option.export) }
      }
    } label: {
      HStack {
        Text(field.selectedOption?.display ?? field.stringValue ?? "Choose…")
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.up.chevron.down").font(.caption2)
      }
      .foregroundStyle(.primary)
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .disabled(field.isReadOnly || field.options.isEmpty)
    .accessibilityLabel("Field \(field.name)")
  }
}
