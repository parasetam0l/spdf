# Document safety and hardening

sPDF bounds parsing, decoding, graph traversal, and transformations. Unsupported or hostile input must either produce a valid result or an explicit error. Automated coverage is evidence for these paths, not a guarantee that no defect remains.

## Adversarial-input coverage

Deterministic tests cover lexical syntax, nesting, cross-reference data, object streams, streams, content instructions, fonts, images, annotations, tags, encryption, and signatures. They exercise truncation, cycles, dangling references, expansion limits, malformed lengths, unsupported codecs, and invalid signature ranges.

Small synthetic regression inputs live under `Tests/Fixtures/Malformed`. New failures should be minimized before being added; personal documents and credentials must stay outside source control.

## Sensitive data

Document scripts and executable actions are not run. Diagnostics exclude document contents and credentials. Passwords are not logged; per-document keychain retention is opt-in. Recovery follows the document's protection policy.

Untouched documents preserve exact source bytes. Edited saves are staged and verified before destination replacement. Redaction and sanitization use separate derivatives that remove historical revisions and unsupported sensitive copies; an ordinary incremental save retains previous revisions.

## Release corpus gate

Before publishing a build:

1. Run `bash Scripts/dev.sh test`.
2. Build Debug and run `bash Scripts/dev.sh smoke`.
3. Reopen saved derivatives in independent readers where available.
4. Exercise representative documents across producer versions, fonts, forms, protection, scans, and large-document workflows.
5. Validate signatures, notarization, installation, rollback, and updates on a clean installed copy.

Keep private corpus files under the ignored `Work/` directory or outside the repository. Record failures without publishing personal document data. Interactive usability, performance, and real update installation need separate live checks.
