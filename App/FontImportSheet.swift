import AppKit
import MacServices
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// FNT-01: the user-facing import sheet for a locally licensed font file.
/// The sheet shows every face in the chosen file with its embedding
/// eligibility, requires an explicit license statement, and imports only the
/// selected face. It also lists previously imported faces and lets the user
/// remove one.
struct FontImportSheet: View {
  /// Set when the sheet is hosted in a plain window instead of a SwiftUI
  /// presentation; SwiftUI sheets use the environment dismiss action.
  var onClose: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var fileURL: URL?
  @State private var inspection: LocalFontFileInspection?
  @State private var selectedFaceIndex: Int?
  @State private var licenseAccepted = false
  @State private var message: String?
  @State private var importedRecords: [ImportedFontRecord] = []
  @State private var isWorking = false

  private var selectedFace: LocalFontFace? {
    guard let inspection, let selectedFaceIndex else { return nil }
    return inspection.faces.first { $0.faceIndex == selectedFaceIndex }
  }

  private var canImport: Bool {
    selectedFace?.isEligible == true && licenseAccepted && !isWorking
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import Licensed Font")
        .font(.headline)
      Text(
        "Choose a font file you are licensed to embed. The app inspects each face, shows whether it can be subset-embedded, and never downloads or bundles a font."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Button("Choose Font File…") { chooseFile() }
          .accessibilityLabel("Choose a licensed font file")
        if let fileName = fileURL?.lastPathComponent {
          Text(fileName)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        if isWorking { ProgressView().controlSize(.small) }
      }

      if let inspection {
        VStack(alignment: .leading, spacing: 4) {
          Text("Faces in this file")
            .font(.subheadline.weight(.semibold))
          ForEach(inspection.faces) { face in
            faceRow(face)
          }
        }
        if inspection.isCollection {
          Text(
            "This is a font collection. Each face is embedded separately, so only the face you select is written into the PDF."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let selectedFace, selectedFace.isEligible {
        Toggle(
          "I have a license for this font that permits embedding it in PDF documents.",
          isOn: $licenseAccepted
        )
        .toggleStyle(.checkbox)
        .font(.caption)
        .accessibilityLabel("Confirm font license for embedding")
        Text(
          "The app does not verify licenses. This statement is recorded locally with the exact font bytes you import."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Font import status")
      }

      HStack {
        Button("Import Selected Face") { importSelectedFace() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canImport)
        Spacer()
        Button("Close") { close() }
      }

      Divider()

      VStack(alignment: .leading, spacing: 4) {
        Text("Imported Fonts")
          .font(.subheadline.weight(.semibold))
        if importedRecords.isEmpty {
          Text("No licensed font file has been imported yet.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          ForEach(importedRecords, id: \.identifier) { record in
            HStack(spacing: 8) {
              Text(record.faceName)
                .font(.caption)
              Text(record.familyName)
                .font(.caption2)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Remove") { remove(record) }
                .buttonStyle(.borderless)
                .font(.caption2)
                .accessibilityLabel("Remove imported font \(record.faceName)")
            }
          }
        }
      }
    }
    .padding(20)
    .frame(minWidth: 520, idealWidth: 560, maxWidth: 640)
    .onAppear { refreshImportedRecords() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Import Licensed Font")
  }

  @ViewBuilder
  private func faceRow(_ face: LocalFontFace) -> some View {
    Button {
      selectedFaceIndex = face.faceIndex
      licenseAccepted = false
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(
          systemName: selectedFaceIndex == face.faceIndex ? "largecircle.fill.circle" : "circle"
        )
        .foregroundStyle(face.isEligible ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(face.faceName)
              .font(.caption)
            Text(face.isBold ? "Bold" : "Regular")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Text(face.isItalic ? "Italic" : "")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Text(face.eligibilityLabel)
            .font(.caption2)
            .foregroundStyle(face.isEligible ? .green : .orange)
            .fixedSize(horizontal: false, vertical: true)
          if let note = face.variableFontNote {
            Text(note)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Text("\(face.program.count / 1_024) KB")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(face.faceName), \(face.eligibilityLabel)")
    .accessibilityAddTraits(selectedFaceIndex == face.faceIndex ? [.isSelected] : [])
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a TrueType, OpenType or font collection file you are licensed to embed."
    panel.allowedContentTypes = [.font, .data]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let result = try LocalFontImport.inspect(fileAt: url)
      inspection = result
      fileURL = url
      selectedFaceIndex = result.preferredFace?.faceIndex
      licenseAccepted = false
      if result.eligibleFaces.isEmpty {
        message = "This font file has no face that can be subset-embedded for editing."
      } else {
        message = nil
      }
    } catch {
      inspection = nil
      selectedFaceIndex = nil
      fileURL = nil
      message = error.localizedDescription
    }
  }

  private func importSelectedFace() {
    guard let url = fileURL, let face = selectedFace, face.isEligible, licenseAccepted else {
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      let font = try LocalFontImport.install(
        face: face, accepting: true, from: url)
      message =
        "Imported “\(font.faceName)”. It is now available for embedded text in this app."
      licenseAccepted = false
      refreshImportedRecords()
    } catch {
      message = error.localizedDescription
    }
  }

  private func remove(_ record: ImportedFontRecord) {
    do {
      _ = try ImportedFontStore.remove(identifier: record.identifier)
      message = nil
      refreshImportedRecords()
    } catch {
      message = error.localizedDescription
    }
  }

  private func refreshImportedRecords() {
    importedRecords = ImportedFontStore.records()
  }

  private func close() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }
}
