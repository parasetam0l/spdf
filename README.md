# sPDF Editor

A native macOS PDF editor built in Swift. Read, edit, annotate, and export documents while keeping document processing on your Mac.

sPDF uses its own PDF core for parsing, edits, and verified saves. Apple's frameworks provide the native interface, rendering, typography, and on-device OCR; Sparkle provides application updates.

**Version 1.0.0** is the first feature-complete release. See the [changelog](CHANGELOG.md) for the full feature set and the [compatibility guide](Docs/Compatibility.md) for the declared supported profiles and limits.

## Features

- Edit supported text directly on the page, drag text blocks, adjust size/color, and undo or redo changes.
- Edit supported image placements, vector objects and page organization (rotate, reorder, crop, split, combine, headers/footers, numbering, watermarks, Bates).
- Add text, graphics, annotations, comments, links and drawn signatures; review with summaries and comparison reports.
- Fill, author and validate AcroForm fields; collect form responses and export tables.
- Add searchable text to scanned pages using on-device OCR with suspect-word review and scan cleanup.
- Create redacted and sanitized copies with explicit checks, hidden-data inspection and verified derivatives.
- Sign with local Keychain/Secure Enclave identities, certify documents, inspect timestamp/revocation evidence and long-term-validation records.
- Tagged-PDF structure editing, reading order, accessibility validation and assisted tagging.
- Production output: preflight and staged fixups, declared PDF/A and PDF/X subsets, colour-managed conversion, separation/overprint preview, quality optimization and advanced print plans.
- Export text, images, HTML, DOCX, tables as CSV/XLSX, PowerPoint (PPTX), selection/range exports and batch conversion jobs.
- Automation through a declared CLI, Shortcuts/App Intents, AppleScript, batch recipes and watched folders.
- In-app Help window with shortcuts, supported workflows and known exclusions.

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

Signed and notarized builds appear under [Releases](https://github.com/parasetam0l/spdf/releases). The first 1.0.0 build installs with a normal drag to Applications; update acceptance on an installed copy is verified as part of the release review.

Release builds use Sparkle to check the published release feed. Automatic checking is opt-in; installation requires your confirmation. Debug builds do not check for updates. See [Updates](Docs/Updates.md).

## Privacy and document safety

Document processing is local. Document scripts and embedded executable actions are not run. Optional network access serves app updates, explicitly requested font downloads, and explicitly requested certificate validation.

Untouched documents retain their exact source bytes. Edited saves are verified before replacement. Redaction and sanitization write separate derivatives that remove earlier revisions; an ordinary incremental save is not sanitization. See [Hardening](Docs/Hardening.md).

## License

First-party source is licensed under the [MIT License](LICENSE). Third-party software and test assets retain their own licenses; see [Licenses](Docs/Licenses.md) and [Third-party notices](Docs/ThirdPartyNotices.md).
