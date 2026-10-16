import Foundation
import PDFCore
import PDFFixtures

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: spdf-fixtures <output-directory>\n".utf8))
  exit(2)
}
do {
  let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let fixtures = [
    ("one-page.pdf", try PDFFixtures.onePage()),
    ("three-pages.pdf", try PDFFixtures.threePages()),
    ("opaque-bytes.pdf", try PDFFixtures.opaqueBytes()),
    ("xref-streams.pdf", try PDFFixtures.xrefStreamPages()),
    ("xref-hybrid.pdf", try PDFFixtures.hybridReferencePages()),
    ("incremental-update.pdf", try PDFFixtures.incrementalUpdate()),
    ("text-edit.pdf", try PDFFixtures.textEditPages()),
    ("text-widths.pdf", try PDFFixtures.textWidthsPages()),
    ("image-pages.pdf", try PDFFixtures.imagePages()),
    ("form-pages.pdf", try PDFFixtures.formPages()),
    ("tagged-pages.pdf", try PDFFixtures.taggedPages()),
    ("attachment-pages.pdf", try PDFFixtures.attachmentPages()),
    ("font-embedded.pdf", try PDFFixtures.fontEmbeddedPages()),
    ("imported-paragraph.pdf", try PDFFixtures.importedParagraphPages()),
    ("font-subset.pdf", try PDFFixtures.fontSubsetPages()),
    ("redaction-pages.pdf", try PDFFixtures.redactionPages()),
    ("cropped-pages.pdf", try PDFFixtures.croppedPages()),
    ("transformed-text.pdf", try PDFFixtures.transformedTextPages()),
    ("masked-images.pdf", try PDFFixtures.maskedImagePages()),
    ("form-xobjects.pdf", try PDFFixtures.formXObjectPages()),
    ("annotation-pages.pdf", try PDFFixtures.annotationPages()),
    ("scanned-page.pdf", try PDFFixtures.scannedPages()),
  ]
  for (name, data) in fixtures {
    let parsed = try PDFParser.parse(data)
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    print("\(name): \(parsed.pageCount) pages, \(data.count) bytes; core verified")
  }
} catch {
  FileHandle.standardError.write(
    Data("Fixture generation failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
