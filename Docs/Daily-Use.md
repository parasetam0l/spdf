# Daily-use guide

## Create, open and read

Choose **New PDF** in the Welcome window or File menu (Command-N) to create an untitled blank PDF. **Add Text** starts active: click the page and type directly on it. Return starts another line; **Done** or Command-Return adds the real page content. Escape cancels the pending text. After Done, Edit PDF becomes active so you can select and move the new text. Save (Command-S) names and writes the new document. Settings (Command-comma) selects A4 or US Letter, portrait or landscape, and the default page layout.

Open a PDF with File → Open or Finder. Use the View menu for fit-page, fit-width, actual size and page navigation. Locked documents remain restricted until you use Tools → Security → Unlock Document. Sidebar panels share the resizable document workspace; switching panels preserves the window size.

Use Command-F to open Find. Enter a phrase and press Return to search, then use Previous Match or Next Match to move through the results. Editing the phrase shows “Return to search” until you submit the new query.

## Edit text and images

Click **Edit PDF** in the command bar (or Control-Command-2). Click a supported text block to select it; dragging the block moves it. Double-click the selected text or choose **Edit Text** in the Text properties panel to place a caret and type directly on the page. While typing, drag the blue move grip to reposition the block. Arrow keys on the selected block or grip move one point, or ten with Shift.

The Text properties panel shows the source font and lets you change size, color and position in page points. For supported standard-font text, it also offers Helvetica, Times and Courier, with Bold (Command-B) and Italic (Command-I). Select characters while typing to format just those characters. With no character selection, the controls set the style for subsequent typing; with the whole box selected, they format the entire box. Mixed selections are identified in the panel. These changes appear on the page before you commit. Use the Text properties button beside Find to show or hide the panel; compact windows open it as a popover. Page navigation and zoom stay in the bottom bar. The left navigation tabs switch between pages, comments and forms; its More menu opens the other panels.

Supported multi-line paragraphs select as one object. Type to wrap within the paragraph width; drag the handle on its right edge or change **Width** in Text properties to reflow the words. Return inserts a line break in a paragraph. Saved paragraph lines use the native editor’s actual positions. sPDF also retains its authored box width, soft wrapping and explicit paragraph breaks when reopening, including mixed standard-font spans. Formatting has native Undo/Redo while typing; the complete committed edit is one document Undo. Nearby short labels, different styles and uncertain paragraph boundaries remain separate blocks.

**Done** or Command-Return commits the selected block. Return commits while typing in a single existing line. Escape discards its pending changes. Cut, Copy and Paste use the standard Command-X/C/V shortcuts while typing. Pasted text adopts the current text style. Save commits pending text before writing; closing with changed text prompts to save. Command-Z first undoes typing while the caret is active; committed text and movement use document Undo/Redo. Zooming, scrolling and resizing keep the editor attached to the page.

Direct editing currently supports simple-font, horizontal text with ordinary character spacing on unrotated pages. Automatic paragraph grouping additionally requires one consistent standard PDF font (Helvetica, Times or Courier and their variants), regular left-aligned lines, individual text-show instructions and a matching native wrapping layout. Paragraphs do not flow onto other pages or move surrounding objects. Foreign mixed-style paragraphs, clipped or transformed text, special spacing and uncertain paragraph boundaries retain the more limited block editing path. The new font controls use standard PDF fonts and refuse characters they cannot represent; they do not embed arbitrary system fonts. Reflow Paragraph remains available within its separate font and region limits. Image-only scans need OCR before text can be selected; complex fonts may remain read-only.

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
