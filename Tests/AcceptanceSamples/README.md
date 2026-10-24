# Licensed acceptance samples

These samples qualify workflow families that are absent from the 17-document
owner-supplied corpus. They are **not** private-corpus credit and do not replace
owner UX/release acceptance.

The private corpus denominator and its recorded failures stay unchanged:
17 files, 16 distinct byte strings. Its manifest remains under ignored
`Work/Corpus/`. This directory contains no private document content.

## Scope

| Workflow | Sample | License |
| --- | --- | --- |
| Forms | `Tests/Fixtures/form-pages.pdf` | MIT, sPDF-generated |
| Encryption | `Tests/Fixtures/Encrypted/aes-256-r6.pdf` | Apache-2.0, pdf.js test vector |
| Signatures | `Tests/Fixtures/Signed/signed-one-page.pdf` | MIT, project-generated test signature |
| OCR layer | `Tests/Fixtures/scanned-page.pdf` | MIT, sPDF-generated |
| Complex scripts | `Tests/Fixtures/multilingual-pages.pdf` | Bitstream Vera/DejaVu |
| Tagged accessibility | `Tests/Fixtures/tagged-pages.pdf` | MIT, sPDF-generated |

The manifest records, for each sample, its named task, expected content or
appearance change, output evidence and explicit unsupported boundary. A change
to an expected result or boundary requires updating the manifest and the
private acceptance record in the same change.

## Run

```bash
bash Scripts/dev.sh test --filter AcceptanceSampleTests
```

The tests are deterministic and CI-safe. They do not use the network, the
owner's private corpus, OCR recognition, or external validators. Auxiliary
independent checks (PDFKit, veraPDF, qpdf, mutool) remain separate evidence and
are not implied by a passing sample.

## Boundaries

- No claim of real-world representativeness from synthetic fixtures.
- No private-corpus denominator change, no reopening of recorded refusals.
- No PDF/UA, OCR-accuracy, signature-trust/revocation or encryption-recovery
  claim beyond the manifest boundary for each sample.
