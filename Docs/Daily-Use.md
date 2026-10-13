# Daily-use guide

## Open and read

Open a PDF with File → Open or Finder. Use the View menu for fit-page, fit-width, actual size, page navigation, and outlines. Locked documents remain restricted until you use File → Unlock Document.

Use Command-F to open Find. Enter a phrase and press Return to search, then use Previous Match or Next Match to move through the results.

## Edit text and images

Choose Annotate → Text Edit Tool (Control-Command-2), then click a supported text run to edit its actual content. Return commits the edit; undo and redo use the Edit menu. Reflow Paragraph supports longer replacements within its stated font and region limits.

Switch back with Annotate → Select Tool (Control-Command-1). Graphics added by sPDF can be selected, moved, and resized with handles. For supported images already in the PDF, right-click the image to rotate, scale, or replace it. Shared resources and unsupported content produce explicit choices or refusal reasons.

## Annotate, fill forms, and organize pages

Use the Edit and Annotate menus for markup, notes, text boxes, shapes, ink, and drawn signatures. The comments sidebar supports navigation, replies, and review state. Common form fields can be filled in the page or Forms sidebar; press Return to commit a text value. Form properties and authoring commands are available through the menus.

Use the page organizer for supported page reordering, rotation, insertion, import, extraction, and deletion. Operations that would damage references are refused or require a supported resolution.

## OCR and exports

OCR uses on-device recognition to add searchable text to scans. Review Tables shows detected cells before CSV or XLSX export. Other export commands create text, page images, HTML, DOCX, attachments, or printed PDFs; [Exports](Exports.md) explains their fidelity limits.

## Save and recover

Save writes a verified result and preserves original bytes for an untouched document. Edited saves use an incremental revision where eligible, with a verified rewrite when necessary. Protected documents retain their protection policy.

Redaction and sanitization require a separate derivative that removes old revisions. Do not treat a covering annotation or ordinary Save as secure removal. Preserve a backup before an unfamiliar or destructive transformation.

Recovery data stays local. Update installation and relaunch are still undergoing live validation; resolve unsaved work before installing a development preview update.
