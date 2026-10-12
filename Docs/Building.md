# Building sPDF Editor

Requirements: macOS 14 or later on Apple silicon, Xcode with Swift 6 support, and XcodeGen (`brew install xcodegen`).

```sh
git clone https://github.com/parasetam0l/spdf.git
cd spdf
bash Scripts/dev.sh build Debug
open "Work/Build/Build/Products/Debug/sPDF Editor.app"
bash Scripts/dev.sh test
bash Scripts/dev.sh smoke
bash Scripts/dev.sh build Release
```

Build outputs and caches stay under the ignored `Work/` directory. The build command regenerates `SPDF.xcodeproj` from `project.yml` when XcodeGen is installed. Local Debug and Release builds use ad-hoc signing and need no Apple distribution credentials.

The smoke check uses the Debug app and the synthetic fixtures in `Tests/Fixtures`. Regenerate those fixtures with `bash Scripts/dev.sh fixtures`.

Some tests use optional independent tools: qpdf, MuPDF (`mutool`), veraPDF, OpenSSL, Python, and macOS `textutil`, `unzip`, and Quick Look. They report or skip unavailable tools; installing them expands verification coverage. OCR recognition and display-dependent behavior can vary with the host environment.

For a Developer ID archive, `bash Scripts/dev.sh release` uses an installed signing identity. Set `SPDF_NOTARY_PROFILE` to an existing `notarytool` keychain profile to enable notarization and stapling. Distribution through GitHub Actions is described in [Releasing](Releasing.md).
