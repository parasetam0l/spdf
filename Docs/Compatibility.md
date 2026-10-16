# Compatibility and supported workflows

Rendering a PDF does not imply that every element can be edited. sPDF preserves unsupported content during unrelated operations and refuses transformations it cannot verify.

| Area | Supported behavior | Limits |
| --- | --- | --- |
| Reading | Native rendering, navigation, outlines, search, and selection | Owned extraction and selection do not cover every font or nested content stream |
| Existing text | Direct page caret, block dragging, character formatting and saved authoring boxes; verified paragraph reconstruction with mixed styles, supported embedded TrueType fonts, horizontal Identity-H subsets and bounded spacing adjustments | See [Daily Use](Daily-Use.md) for the supported paragraph profile. Clipping, complex shaping, CFF fonts, rotated/skewed text and uncertain layout remain restricted. New font choices are Helvetica, Times and Courier; arbitrary system-font embedding, document-wide reflow and vertical layout are not provided |
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

Untouched documents retain their original bytes. Eligible edits to classic cross-reference files use incremental saves. Sources using cross-reference streams use a verified full rewrite when edited, so the saved document remains readable in Apple's renderer. Unsupported signatures and protection states retain their separate save restrictions.

Signed releases, clean installation, and Sparkle update behavior require live verification in addition to automated tests.
