# Daily-use guide

## Create, open and read

Choose **New PDF** in the Welcome window or File menu (Command-N) to create an untitled blank PDF. **Add Text** starts active: click the page and type directly on it. Return starts another line; **Done** or Command-Return adds the real page content. Escape cancels the pending text. Save (Command-S) names and writes the new document. Settings (Command-comma) selects A4 or US Letter, portrait or landscape, and the default page layout.

Open a PDF with File → Open or Finder. Use the View menu for fit-page, fit-width, actual size and page navigation. Locked documents remain restricted until you use Tools → Security → Unlock Document. Sidebar panels share the resizable document workspace; switching panels preserves the window size.

Use Command-F to open Find. Enter a phrase and press Return to search, then use Previous Match or Next Match to move through the results.

## Edit text and images

Click **Edit PDF** in the toolbar (or Control-Command-2). Drag a supported text block to move it. Click it to place a caret directly on the page, then type or select characters as usual. While editing, drag the blue move grip beside the text to reposition the whole block; arrow keys on the grip move one point, or ten with Shift. The toolbar shows the source font, text size and color. Changes appear on the page before you commit.

**Done**, Return or Command-Return commits an existing block. Escape discards its pending changes. Save commits pending text before writing; closing with changed text prompts to save. Command-Z first undoes typing while the caret is active; committed text and movement use document Undo/Redo. Zooming, scrolling and resizing keep the editor attached to the page.

Direct editing currently supports simple-font, horizontal text with ordinary character spacing on unrotated pages, one PDF text-show block at a time. It preserves surrounding page content and does not reflow neighboring blocks. Rotated, skewed, specially spaced or otherwise unsupported text produces a refusal. Reflow Paragraph remains available for longer replacements within its font and region limits. Image-only scans need OCR before text can be selected; complex fonts may remain read-only.

Switch back with **Select** (Control-Command-1). In Select mode, dragging a graphic only selects it and never dirties the document. Click **Images** (Control-Command-4) to move or resize supported app-created graphics; handles and keyboard nudging work only there. For supported images already in the PDF, right-click the image to rotate, scale, or replace it. Shared resources and unsupported content produce explicit choices or refusal reasons.

## Annotate, fill forms, and organize pages

Click **Comments** for Highlight, Add Note and Draw controls. The comments sidebar supports navigation, replies, and review state. The Edit and Annotate menus retain advanced annotation commands and drawn signatures. Common form fields can be filled in the page or Forms sidebar; press Return to commit a text value. Form properties and authoring commands are available in the Form menu.

Click **Pages** for Organize Pages, Insert Blank Page and Rotate Right. The Page menu includes importing, reordering, rotation and deletion. Operations that would damage references are refused or require a supported resolution.

## OCR and exports

OCR in the Annotate menu uses on-device recognition to add searchable text to scans. Tools → Review Tables shows detected cells before CSV or XLSX export. File → Export groups text, page images, HTML, DOCX, table, attachment and printed PDF exports; [Exports](Exports.md) explains their fidelity limits. Tools groups comparison, optimization, repair, security and print-production commands.

## Save and recover

Save writes a verified result and preserves original bytes for an untouched document. Edited saves use an incremental revision where eligible, with a verified rewrite when necessary. Protected documents retain their protection policy.

Redaction and sanitization require a separate derivative that removes old revisions. Do not treat a covering annotation or ordinary Save as secure removal. Preserve a backup before an unfamiliar or destructive transformation.

Recovery data stays local. Use sPDF Editor → Check for Updates for a manual release check. Settings contains the automatic-check preference. See [Updates](Updates.md) for installation, unsaved-work handling and guidance for older versions.
