# Licenses and attribution

First-party source and original synthetic assets are licensed under the [MIT License](../LICENSE).

| Component | License | Use |
| --- | --- | --- |
| Sparkle 2.10.0 | MIT and the bundled upstream notices | Linked updater dependency; full notices in [ThirdPartyNotices](ThirdPartyNotices.md) |
| Mozilla PDF.js encrypted test vectors | Apache 2.0 | Test-only fixtures; license under `Tests/Fixtures/Encrypted/LICENSE` |
| DejaVu Sans test subsets | Bitstream Vera / DejaVu terms | Test-only embedded font subsets; full text under `Tests/Fixtures/DejaVu-LICENSE.txt` |
| Apple frameworks | Supplied by macOS and Xcode | Native UI, rendering, typography, OCR, cryptography, and compression |

Test fixtures and development tools are not packaged into the application. Their provenance is recorded in `Tests/Fixtures/Manifest.md`.

The app does not bundle downloaded Google Fonts. Font provisioning uses official endpoints only on user action, shows the applicable license, and installs into the user's font directory after the user accepts it. Only unchanged app-installed TrueType files with embedding permission are offered for inline PDF editing; selected glyphs are embedded as subsets. Fonts embedded in a user's document retain their own rights and restrictions.

Third-party materials retain their original terms; the project's MIT license does not replace them.
