# sPDF Editor

A native macOS PDF editor built in Swift. Read, edit, annotate, and export documents while keeping document processing on your Mac.

sPDF uses its own PDF core for parsing, edits, and verified saves. Apple's frameworks provide the native interface, rendering, typography, and on-device OCR; Sparkle provides application updates.

## Features

- Edit supported existing text and image placements, with undo and redo.
- Organize pages: rotate, reorder, import, extract, insert, and delete.
- Add text, graphics, annotations, comments, and drawn signatures.
- Fill and author common AcroForm fields.
- Add searchable text to scanned pages using on-device OCR.
- Create redacted and sanitized copies with explicit checks.
- Inspect protected and signed documents, compare PDFs, and optimize copies.
- Export text, images, HTML, DOCX, tables as CSV/XLSX, and print-ready PDFs.

Support depends on a document's fonts, structure, security settings, and content. Unsupported edits are refused with a reason. DOCX export reconstructs content and is **not a perfect round trip**. See the [compatibility guide](Docs/Compatibility.md) and [export guide](Docs/Exports.md).

## Requirements

- macOS 14 or later on Apple silicon.
- Xcode with Swift 6 support to build from source.
- XcodeGen for generating the Xcode project: `brew install xcodegen`.

## Build and run

```sh
git clone https://github.com/parasetam0l/spdf.git
cd spdf
bash Scripts/dev.sh build Debug
open "Work/Build/Build/Products/Debug/sPDF Editor.app"
```

Run the tests and native document smoke check:

```sh
bash Scripts/dev.sh test
bash Scripts/dev.sh smoke
```

See [Building](Docs/Building.md) for Release builds and optional verification tools, and the [daily-use guide](Docs/Daily-Use.md) for common workflows.

## Downloads and updates

Published builds appear under [Releases](https://github.com/parasetam0l/spdf/releases). Development builds are available from source while signed release and update validation is completed.

Release builds use Sparkle to check the published release feed. Automatic checking is opt-in; installation requires your confirmation. Debug builds do not check for updates. See [Updates](Docs/Updates.md).

## Privacy and document safety

Document processing is local. Document scripts and embedded executable actions are not run. Optional network access serves app updates, explicitly requested font downloads, and explicitly requested certificate validation.

Untouched documents retain their exact source bytes. Edited saves are verified before replacement. Redaction and sanitization write separate derivatives that remove earlier revisions; an ordinary incremental save is not sanitization. See [Hardening](Docs/Hardening.md).

## License

First-party source is licensed under the [MIT License](LICENSE). Third-party software and test assets retain their own licenses; see [Licenses](Docs/Licenses.md) and [Third-party notices](Docs/ThirdPartyNotices.md).
