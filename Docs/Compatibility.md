# Compatibility and supported workflows

Rendering a PDF does not imply that every element can be edited. sPDF preserves unsupported content during unrelated operations and refuses transformations it cannot verify.

| Area | Supported behavior | Limits |
| --- | --- | --- |
| Reading | Native rendering, navigation, outlines, search, and selection | Owned extraction and selection do not cover every font or nested content stream |
| Existing text | Actual content edits for supported fonts and runs; paragraph reflow within supported regions | Arbitrary document reflow, composite-font geometry, and vertical text layout are not supported |
| Images and graphics | Placement edits, replacement/import, supported masks and transformations, added text and shapes | Uninspectable paint, unsupported codecs, and ambiguous shared resources can restrict an operation |
| Pages | Rotation, reorder, insertion, import, extraction, and deletion with reference checks | Complex destinations, forms, tags, and signed input may require refusal or explicit conflict handling |
| Review | Markup, notes, free text, shapes, ink, stamps, replies, and review state | Unsupported actions remain inert; drawn signatures are visible marks, not cryptographic signatures |
| Forms | Common AcroForm filling, appearances, authoring, field properties, and value exchange | XFA is not editable; document JavaScript is not executed |
| OCR | On-device recognition, searchable layers, correction, and scan cleanup | Recognition quality and available languages depend on Apple's services and the source image |
| Protected documents | Standard-security authentication and permission-aware editing/saving | Unsupported handlers refuse; signed/protected files never silently become unsigned or decrypted |
| Signatures | Inspection and supported signing from a keychain identity | Trust, timestamp, revocation, and long-term validation have distinct results and limits |
| Redaction | Supported content removal and separate sanitized copies | Any content that cannot be inspected and removed safely causes refusal |
| Tagged PDFs | Structure inspection and explicit supported repairs/edits | No blanket PDF/UA conformance claim |
| Exports | Text, images, HTML, DOCX, tables, attachments, and printing | See the fidelity limits in [Exports](Exports.md) |

The native app currently limits source snapshots to 256 MiB. Parsing, stream decoding, traversal, and export paths have separate bounded budgets. Larger or unsupported documents can fall back to restricted viewing.

Signed releases, clean installation, and Sparkle update behavior require live verification in addition to automated tests. These checks are still being completed for the first published build.
