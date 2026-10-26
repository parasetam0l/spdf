# Changelog

All notable changes to sPDF Editor are recorded here. Version 1.0.0 is the first
feature-complete release of the native macOS editor.

## 1.0.0 — 2026-10-26

### Editing and documents

- Native PDF viewing, navigation, text selection and search.
- Direct page text editing with paragraph reconstruction, formatting, lists and
  verified saves; image placement/editing and vector object transforms.
- Page organization: rotate, reorder, insert, extract, delete, crop, split,
  combine, headers/footers, page numbering, watermarks and Bates numbering.
- Document metadata, attachments, bookmarks, compare-with-document and repair.

### Forms, review and accessibility

- AcroForm filling, authoring and field properties; form responses, rules,
  portability and lifecycle qualification.
- Markup, notes, free text, shapes, ink and stamps with printable review
  summaries, comparison reports and review-table exports.
- Tagged-PDF structure editing, reading order, accessible validation and
  assisted tagging.
- On-device OCR with searchable layers, suspect-word review and scan cleanup.

### Security and signatures

- Standard-security authentication with permission-aware editing and saving.
- Redaction review, search-based redaction, sanitized verified copies and
  hidden-data inspection.
- Local certificate signing, certification/FieldMDP, timestamp/OCSP/CRL
  evidence, signing identities and long-term-validation inspection.

### Production output

- Preflight with configurable rule sets, staged fixups and exportable reports.
- Declared PDF/A-1b/A-2b/A-3b conversion (validated with veraPDF on the saved
  bytes), declared PDF/X-4 and PDF/X-1a:2003 export (validated with qpdf).
- Colour-managed conversion, separation/overprint preview, prepress inspection,
  quality optimization and advanced print plans.

### Exports and automation

- Text, images, HTML, DOCX, tables (CSV/XLSX), PowerPoint (PPTX) and print
  exports; selection/range export and a conversion job center.
- Declared automation profile shared by a CLI, Shortcuts/App Intents and
  AppleScript; batch recipes, watched folders and portable recipe import/export.

### Platform and release

- Native macOS 14+ application for Apple silicon, hardened runtime, Developer ID
  signing and notarization, Sparkle-based explicit updates, and an in-app Help
  window with guides, shortcuts and known exclusions.

See the compatibility guide for declared supported profiles and limits. This
project does not claim Acrobat Pro parity: hosted review, remote signing
services, cloud storage, enterprise services, other platforms, AI/design
generation and automatic linked cross-page reflow are explicit exclusions in
this release.
