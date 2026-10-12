# Export fidelity

Exports create separate files and leave the source PDF unchanged. Fidelity varies by format; the app records limitations and refuses unsupported transformations rather than inventing content.

| Format | Output | Important limits |
| --- | --- | --- |
| Plain text | Supported decoded text in reading order | Unsupported font mappings and uncertain reading order can reduce coverage |
| Page images | PNG, JPEG, or TIFF rendered at the selected resolution | Appearance-oriented: tags, forms, links, and selectable text are not retained |
| HTML | Semantic content or rendered appearance with local assets | Reconstruction of complex layout is approximate; scripts are not emitted |
| DOCX | Reconstructed paragraphs, styled runs, tables, images, links, headers/footers, and sections | Not a perfect round trip; cannot reproduce all PDF typography, spacing, paint order, or layout |
| CSV / XLSX | Reviewed table cells, supported typed values, and spans | Detection is heuristic; review ambiguous tables before use; active formulas are not generated |
| Image extraction | Independently usable original bytes/pixels, or a labeled rendered reconstruction | Masks, transforms, unusual color spaces, and unsupported filters can require rendering |
| Attachments | Supported embedded files with safe destination names | Opening or executing an attachment remains a separate explicit action |
| Print / print PDF | Rendered pages at the selected size and range | May flatten appearances; interactive features and semantic structure are not preserved |

DOCX is reconstruction only, **never a perfect round trip**. Missing fonts can be substituted and low-confidence regions can become labeled images in appearance mode. Check the exported document in its intended application.

Image reconstructions use the selected DPI and are distinct from the original stored samples. CSV protects formula-looking text; XLSX writes literal cells rather than executable formulas.

For encrypted or signed input, respect the source document's permission and signature policy. Exports never silently remove protection or present a changed document as retaining its original digital signature.
