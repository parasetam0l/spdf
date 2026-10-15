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

`bash Scripts/dev.sh termination-smoke` drives native document save/cancel panels and real OCR/export workers on disposable copies under `Work/Termination`. Diagnostic launches ignore macOS window restoration for that process; saved user preferences remain intact. The report describes the tested scope and does not install an update payload.

`bash Scripts/dev.sh relaunch-smoke` captures approved file bookmarks and view metadata, then restores them in a separate Debug process. It checks renamed files, view/Settings state, one-use consumption and protected-file policy on disposable copies under `Work/Relaunch`.

`bash Scripts/dev.sh workspace-smoke` checks New PDF, real page-text creation, a native save, Undo/Redo, independent untitled recovery keys, all sidebar modes, window resizing and auxiliary-window closure. It writes disposable output under `Work/WorkspaceSmoke`. It also checks non-mutating text-block selection, selected-block dragging/cancellation, double-click typing, refusal to save an unfinished native IME composition, and a complete paragraph edit with narrower wrapping, movement, saved native line positions, one-step Undo/Redo and reselection. Character-formatting checks cover selected-word family/bold/italic/size/color, native shortcuts, formatting Undo/Redo, exact saved box width and explicit blank paragraphs. These regressions also run in the full native smoke check. For lifetime diagnostics, run it with `NSZombieEnabled=YES`.

Some tests use optional independent tools: qpdf, MuPDF (`mutool`), veraPDF, OpenSSL, Python, and macOS `textutil`, `unzip`, and Quick Look. They report or skip unavailable tools; installing them expands verification coverage. OCR recognition and display-dependent behavior can vary with the host environment.

Real Vision throughput/concurrency is an opt-in measurement for a host with a working recognition service. Hosted runners can stall in this benchmark. Routine tests retain OCR transforms, rasterization, progress, cancellation and tolerant Vision recognition checks. To include the throughput benchmark locally:

```sh
SPDF_RUN_VISION_BENCHMARKS=1 bash Scripts/dev.sh test --no-parallel
```

For a Developer ID archive, `bash Scripts/dev.sh release` uses an installed signing identity. Set `SPDF_NOTARY_PROFILE` to an existing `notarytool` keychain profile to enable notarization and stapling. Distribution through GitHub Actions is described in [Releasing](Releasing.md).

## Native workspace measurements

The opt-in probe generates synthetic documents, exposes a native window, and records display-linked scrolling, 200-field/1,000-comment sidebar actions, layout/draw costs, and verified Undo:

```sh
"Work/Build/Build/Products/Debug/sPDF Editor.app/Contents/MacOS/sPDF Editor" \
  --measure-workspace Work/WorkspaceMetrics
```

Results and generated inputs stay in that output directory. The probe does not start update checks. Callback timing measures the current display cadence; it is distinct from a GPU-presented-frame count. A virtual machine's display and results should be identified as virtual.

For optimized measurements, use a Developer ID-signed Release build with all nested Sparkle code signed with the same identity. A hardened ad-hoc Release may fail library validation; Debug is the credential-free local run path. Distribution signing/notarization is covered in [Releasing](Releasing.md).
