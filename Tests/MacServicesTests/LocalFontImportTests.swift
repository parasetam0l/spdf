import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

@testable import MacServices

/// FNT-01: the local licensed font import service. Files are inspected without
/// side effects, embedding eligibility is reported per face, a license assertion
/// gates the copy, and only the selected face's exact bytes are stored and
/// offered to the editor.
@Suite("Local licensed font import")
struct LocalFontImportTests {
  private var fixtureProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64)
      else { throw PDFError(.malformed, "Test font program is corrupt") }
      return program
    }
  }

  private var cffProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.cffProgramBase64)
      else { throw PDFError(.malformed, "Test CFF program is corrupt") }
      return program
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spdf-font-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ data: Data, as name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  @Test func inspectsSelectsAndInstallsOnlyAfterLicenseAssertion() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    let googleDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: googleDirectory) }
    let url = try write(try fixtureProgram, as: "DejaVuSans.ttf", in: input)

    let inspection = try LocalFontImport.inspect(fileAt: url)
    #expect(inspection.faces.count == 1)
    #expect(!inspection.isCollection)
    let face = try #require(inspection.preferredFace)
    #expect(face.isEligible)
    #expect(face.eligibility == .eligible)
    #expect(face.program == (try fixtureProgram))
    #expect(face.familyName.localizedCaseInsensitiveContains("DejaVu"))
    #expect(face.faceName.localizedCaseInsensitiveContains("DejaVu"))
    #expect(face.identifier.hasPrefix("import-"))
    #expect(face.faceIndex == 0)

    // No mutation without the user's license assertion.
    #expect(throws: LocalFontImportError.self) {
      _ = try LocalFontImport.install(face: face, accepting: false, from: url, in: store)
    }
    #expect(!FileManager.default.fileExists(
      atPath: store.appendingPathComponent(ImportedFontStore.manifestName).path))

    let font = try LocalFontImport.install(face: face, accepting: true, from: url, in: store)
    #expect(font.identifier == face.identifier)
    #expect(font.familyName == face.familyName)
    #expect(font.faceName == face.faceName)
    #expect(font.program == face.program)

    let records = ImportedFontStore.records(in: store)
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.identifier == face.identifier)
    #expect(record.programDigest == face.programDigest)
    #expect(record.faceIndex == 0)
    #expect(record.licenseAssertion.localizedCaseInsensitiveContains("DejaVuSans.ttf"))
    #expect(record.licenseAssertion.localizedCaseInsensitiveContains("embedding"))
    let storedFile = store.appendingPathComponent(record.fileName)
    #expect(FileManager.default.fileExists(atPath: storedFile.path))
    #expect(FontImportDigest.sha256Hex(try Data(contentsOf: storedFile)) == face.programDigest)

    let available = ImportedFontStore.availableFonts(in: store)
    #expect(available.map(\.identifier) == [face.identifier])
    #expect(available.first?.program == face.program)

    // Imported faces participate in the same accepted set the editor loads.
    let merged = ProvisionedFontStore.availableFonts(
      in: googleDirectory, importedDirectory: store)
    #expect(merged.contains { $0.identifier == face.identifier })

    // Installing the same face again replaces the record instead of stacking.
    _ = try LocalFontImport.install(face: face, accepting: true, from: url, in: store)
    #expect(ImportedFontStore.records(in: store).count == 1)
  }

  @Test func changedSourceFileAfterInspectionIsRefused() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    let url = try write(try fixtureProgram, as: "Font.ttf", in: input)
    let inspection = try LocalFontImport.inspect(fileAt: url)
    let face = try #require(inspection.preferredFace)

    // The file changes after the preview; importing the old face must refuse.
    let tiny = try TrueTypeSubsetter.subset(
      program: try fixtureProgram, unicodes: [0x41])
    try tiny.write(to: url)
    do {
      _ = try LocalFontImport.install(face: face, accepting: true, from: url, in: store)
      Issue.record("expected a changed-source refusal")
    } catch let error as LocalFontImportError {
      #expect(error == .changedSinceInspection)
    } catch {
      Issue.record("wrong error type \(error)")
    }
    #expect(ImportedFontStore.records(in: store).isEmpty)
  }

  @Test func changedStoredFileIsNotOfferedForWriting() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    let url = try write(try fixtureProgram, as: "Font.ttf", in: input)
    let inspection = try LocalFontImport.inspect(fileAt: url)
    let face = try #require(inspection.preferredFace)
    _ = try LocalFontImport.install(face: face, accepting: true, from: url, in: store)
    let record = try #require(ImportedFontStore.records(in: store).first)

    // Replace the stored bytes with another valid program: digest mismatch.
    let tiny = try TrueTypeSubsetter.subset(
      program: try fixtureProgram, unicodes: [0x41])
    try tiny.write(to: store.appendingPathComponent(record.fileName))
    #expect(ImportedFontStore.availableFonts(in: store).isEmpty)
  }

  @Test func symlinkOversizedAndNonFontInputsAreRefused() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let url = try write(try fixtureProgram, as: "Font.ttf", in: input)
    let link = input.appendingPathComponent("Link.ttf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    do {
      _ = try LocalFontImport.inspect(fileAt: link)
      Issue.record("expected a symlink refusal")
    } catch let error as LocalFontImportError {
      guard case .fileNotRegular = error else {
        Issue.record("wrong refusal \(error)")
        return
      }
    }

    #expect(throws: LocalFontImportError.self) {
      _ = try LocalFontImport.inspect(fileAt: url, limits: .init(maxFileBytes: 100))
    }
    let notAFont = try write(Data("not a font at all".utf8), as: "Text.ttf", in: input)
    #expect(throws: LocalFontImportError.self) {
      _ = try LocalFontImport.inspect(fileAt: notAFont)
    }
    #expect(throws: LocalFontImportError.self) {
      _ = try LocalFontImport.inspect(fileAt: URL(string: "https://example.com/font.ttf")!)
    }
  }

  @Test func cffFaceIsListedButRefusedWithReason() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    let url = try write(try cffProgram, as: "CFF.otf", in: input)
    let inspection = try LocalFontImport.inspect(fileAt: url)
    #expect(inspection.faces.count == 1)
    let face = try #require(inspection.faces.first)
    #expect(!face.isEligible)
    #expect(face.eligibility == .refused(.cffOutlines))
    #expect(inspection.preferredFace == nil)
    do {
      _ = try LocalFontImport.install(face: face, accepting: true, from: url, in: store)
      Issue.record("expected an ineligible-face refusal")
    } catch let error as LocalFontImportError {
      guard case .faceNotEligible = error else {
        Issue.record("wrong refusal \(error)")
        return
      }
    }
    #expect(ImportedFontStore.records(in: store).isEmpty)
  }

  @Test func collectionFaceSelectionStoresTheSelectedMember() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    let full = try fixtureProgram
    let tiny = try TrueTypeSubsetter.subset(program: full, unicodes: [0x41])
    let collection = try makeCollection([full, tiny])
    let url = try write(collection, as: "Collection.ttc", in: input)

    let inspection = try LocalFontImport.inspect(fileAt: url)
    #expect(inspection.isCollection)
    #expect(inspection.faces.count == 2)
    #expect(inspection.eligibleFaces.count == 2)
    let selected = try #require(inspection.faces.first { $0.faceIndex == 1 })
    let program = try TrueTypeInspector.inspect(selected.program)
    #expect(program.unicodeToGlyph[0x41] != nil)
    #expect(program.unicodeToGlyph[0x42] == nil)

    let font = try LocalFontImport.install(
      face: selected, accepting: true, from: url, in: store)
    #expect(font.identifier == selected.identifier)
    let record = try #require(ImportedFontStore.records(in: store).first)
    #expect(record.faceIndex == 1)
    #expect(record.programDigest == selected.programDigest)
    let available = try #require(ImportedFontStore.availableFonts(in: store).first)
    #expect(available.program == selected.program)
    let storedInspector = try TrueTypeInspector.inspect(available.program)
    #expect(storedInspector.unicodeToGlyph[0x41] != nil)
    #expect(storedInspector.unicodeToGlyph[0x42] == nil)
  }

  @Test func removalDeletesOnlyTheAcceptedEntry() throws {
    let input = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: input) }
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    let url = try write(try fixtureProgram, as: "Font.ttf", in: input)
    let inspection = try LocalFontImport.inspect(fileAt: url)
    let face = try #require(inspection.preferredFace)
    _ = try LocalFontImport.install(face: face, accepting: true, from: url, in: store)
    let record = try #require(ImportedFontStore.records(in: store).first)
    let storedFile = store.appendingPathComponent(record.fileName)
    #expect(FileManager.default.fileExists(atPath: storedFile.path))

    #expect(try ImportedFontStore.remove(identifier: face.identifier, in: store))
    #expect(ImportedFontStore.records(in: store).isEmpty)
    #expect(ImportedFontStore.availableFonts(in: store).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: storedFile.path))
    #expect(try ImportedFontStore.remove(identifier: face.identifier, in: store) == false)
  }

  @Test func corruptManifestIsIgnoredInsteadOfCrashing() throws {
    let store = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: store) }
    try Data("not json".utf8).write(
      to: store.appendingPathComponent(ImportedFontStore.manifestName))
    #expect(ImportedFontStore.records(in: store).isEmpty)
    #expect(ImportedFontStore.availableFonts(in: store).isEmpty)
  }

  // MARK: - Helpers

  /// Build a minimal valid TrueType collection from standalone sfnt programs.
  private func makeCollection(_ programs: [Data]) throws -> Data {
    func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
      Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
    }
    func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
      var value = 0
      for index in 0..<4 { value = value * 256 + Int(bytes[offset + index]) }
      return value
    }
    func writeU16(_ value: Int, _ out: inout [UInt8], _ offset: Int) {
      out[offset] = UInt8((value >> 8) & 0xFF)
      out[offset + 1] = UInt8(value & 0xFF)
    }
    func writeU32(_ value: Int, _ out: inout [UInt8], _ offset: Int) {
      out[offset] = UInt8((value >> 24) & 0xFF)
      out[offset + 1] = UInt8((value >> 16) & 0xFF)
      out[offset + 2] = UInt8((value >> 8) & 0xFF)
      out[offset + 3] = UInt8(value & 0xFF)
    }
    func appendU32(_ value: Int, _ out: inout [UInt8]) {
      out += [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
      ]
    }

    var out: [UInt8] = Array("ttcf".utf8)
    appendU32(0x0001_0000, &out)
    appendU32(programs.count, &out)
    let offsetsStart = out.count
    out += [UInt8](repeating: 0, count: programs.count * 4)
    var faceOffsets: [Int] = []
    for program in programs {
      let bytes = [UInt8](program)
      let sfnt = u32(bytes, 0)
      let tableCount = u16(bytes, 4)
      while out.count % 4 != 0 { out.append(0) }
      let faceStart = out.count
      faceOffsets.append(faceStart)
      out += [UInt8](repeating: 0, count: 12 + tableCount * 16)
      for index in 0..<tableCount {
        let base = 12 + index * 16
        let tag = Array(bytes[base..<(base + 4)])
        let checksum = u32(bytes, base + 4)
        let sourceOffset = u32(bytes, base + 8)
        let length = u32(bytes, base + 12)
        while out.count % 4 != 0 { out.append(0) }
        let absolute = out.count
        out += bytes[sourceOffset..<(sourceOffset + length)]
        let record = faceStart + 12 + index * 16
        out.replaceSubrange(record..<(record + 4), with: tag)
        writeU32(checksum, &out, record + 4)
        writeU32(absolute, &out, record + 8)
        writeU32(length, &out, record + 12)
      }
      writeU32(sfnt, &out, faceStart)
      writeU16(tableCount, &out, faceStart + 4)
    }
    for (index, offset) in faceOffsets.enumerated() {
      writeU32(offset, &out, offsetsStart + index * 4)
    }
    return Data(out)
  }
}
