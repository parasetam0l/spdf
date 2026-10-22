#!/bin/bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$task_root"
mkdir -p Work/ModuleCache Work/SwiftPMCache Work/SwiftPMConfig Work/SwiftPMSecurity
export CLANG_MODULE_CACHE_PATH="$task_root/Work/ModuleCache"
package_options=(--disable-sandbox --scratch-path Work/SwiftPM --cache-path Work/SwiftPMCache --config-path Work/SwiftPMConfig --security-path Work/SwiftPMSecurity)

case "${1:-}" in
  test)
    shift
    swift test "${package_options[@]}" "$@"
    ;;
  fixtures)
    swift run "${package_options[@]}" spdf-fixtures Tests/Fixtures
    ;;
  build)
    configuration="${2:-Debug}"
    if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
      printf 'Configuration must be Debug or Release.\n' >&2
      exit 2
    fi
    if command -v xcodegen >/dev/null 2>&1; then
      xcodegen generate
    elif [[ -f SPDF.xcodeproj/project.pbxproj ]]; then
      printf 'xcodegen not found; building the existing SPDF.xcodeproj.\n' >&2
    else
      printf 'xcodegen is required to generate SPDF.xcodeproj.\n' >&2
      exit 2
    fi
    xcodebuild -quiet -project SPDF.xcodeproj -scheme SPDF \
      -configuration "$configuration" -destination 'generic/platform=macOS' \
      -derivedDataPath Work/Build -clonedSourcePackagesDirPath Work/XcodePackages \
      ARCHS=arm64 build
    printf 'Built: %s/Work/Build/Build/Products/%s/sPDF Editor.app\n' "$task_root" "$configuration"
    ;;
  smoke)
    app="$task_root/Work/Build/Build/Products/Debug/sPDF Editor.app/Contents/MacOS/sPDF Editor"
    if [[ ! -x "$app" ]]; then
      printf 'Build the Debug app first: bash Scripts/dev.sh build Debug\n' >&2
      exit 2
    fi
    "$app" --smoke-test "$task_root/Tests/Fixtures" "$task_root/Work/Smoke" \
      -ApplePersistenceIgnoreState YES
    ;;
  relaunch-smoke)
    app="$task_root/Work/Build/Build/Products/Debug/sPDF Editor.app/Contents/MacOS/sPDF Editor"
    if [[ ! -x "$app" ]]; then
      printf 'Build the Debug app first: bash Scripts/dev.sh build Debug\n' >&2
      exit 2
    fi
    output="$task_root/Work/Relaunch"
    # Reusing a previous completed diagnostic must not consume its pending state.
    mkdir -p "$output"
    if [[ -f "$output/State/UpdateRelaunch/pending.json" ]]; then
      mv "$output/State/UpdateRelaunch/pending.json" "$output/State/UpdateRelaunch/previous-diagnostic.json"
    fi
    "$app" --test-relaunch capture "$task_root/Tests/Fixtures" "$output" -ApplePersistenceIgnoreState YES
    mv -f "$output/second.pdf" "$output/renamed.pdf"
    "$app" --test-relaunch restore "$task_root/Tests/Fixtures" "$output" -ApplePersistenceIgnoreState YES
    ;;
  workspace-smoke)
    app="$task_root/Work/Build/Build/Products/Debug/sPDF Editor.app/Contents/MacOS/sPDF Editor"
    "$app" --test-workspace "$task_root/Work/WorkspaceSmoke" -ApplePersistenceIgnoreState YES
    ;;
  termination-smoke)
    app="$task_root/Work/Build/Build/Products/Debug/sPDF Editor.app/Contents/MacOS/sPDF Editor"
    if [[ ! -x "$app" ]]; then
      printf 'Build the Debug app first: bash Scripts/dev.sh build Debug\n' >&2
      exit 2
    fi
    "$app" --test-termination "$task_root/Tests/Fixtures" "$task_root/Work/Termination" \
      -ApplePersistenceIgnoreState YES
    ;;
  recovery-crash-smoke)
    app="$task_root/Work/Build/Build/Products/Debug/sPDF Editor.app/Contents/MacOS/sPDF Editor"
    if [[ ! -x "$app" ]]; then
      printf 'Build the Debug app first: bash Scripts/dev.sh build Debug\n' >&2
      exit 2
    fi
    output="${2:-}"
    if [[ -z "$output" || -e "$output" ]]; then
      printf 'Pass a new, unused output directory for this disposable recovery check.\n' >&2
      exit 2
    fi
    mkdir -p "$output"
    "$app" --test-recovery-seed "$task_root/Tests/Fixtures" "$output" \
      -ApplePersistenceIgnoreState YES
    cmp "$task_root/Tests/Fixtures/one-page.pdf" "$output/source.pdf"
    "$app" --test-recovery-resume "$output" -ApplePersistenceIgnoreState YES
    qpdf --check "$output/expected.pdf"
    qpdf --check "$output/restored.pdf"
    ;;
  release)
    if [[ "$(uname -m)" != arm64 ]]; then
      printf 'The signed release path currently targets Apple Silicon only.\n' >&2
      exit 2
    fi
    archive="$task_root/Work/Release/SPDF.xcarchive"
    profile="${SPDF_NOTARY_PROFILE:-}"
    rm -rf "$archive"
    mkdir -p "$task_root/Work/Release"
    xcodebuild -quiet -project SPDF.xcodeproj -scheme SPDF \
      -configuration Release -destination 'generic/platform=macOS' \
      -archivePath "$archive" -derivedDataPath Work/Build \
      -clonedSourcePackagesDirPath Work/XcodePackages ARCHS=arm64 \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application" \
      DEVELOPMENT_TEAM="${SPDF_TEAM_ID:-P7V7795SS9}" \
      OTHER_CODE_SIGN_FLAGS="--timestamp" \
      archive
    app="$archive/Products/Applications/sPDF Editor.app"
    codesign --verify --deep --strict "$app"
    if [[ -n "$profile" ]]; then
      payload="$task_root/Work/Release/notarize.zip"
      rm -f "$payload"
      ditto -c -k --keepParent "$app" "$payload"
      xcrun notarytool submit "$payload" --keychain-profile "$profile" --wait
      rm -f "$payload"
      xcrun stapler staple "$app"
      xcrun stapler validate "$app"
    else
      printf 'SPDF_NOTARY_PROFILE is not set; exporting a Developer ID-signed app without notarization.\n' >&2
      printf 'One-time setup: xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id P7V7795SS9\n' >&2
    fi
    spctl -a -vvv --type execute "$app" 2>&1 || true
    final="$task_root/Work/Release/sPDF Editor.app"
    rm -rf "$final"
    ditto "$app" "$final"
    rm -f "$task_root/Work/Release/sPDF Editor.zip"
    ditto -c -k --keepParent "$final" "$task_root/Work/Release/sPDF Editor.zip"
    printf 'Signed app: %s\n' "$final"
    if [[ -n "$profile" ]]; then
      printf 'Notarized and stapled: yes\n'
    else
      printf 'Notarized and stapled: no (configure SPDF_NOTARY_PROFILE to enable)\n'
    fi
    ;;
  *)
    printf 'Usage: bash Scripts/dev.sh {test|fixtures|build [Debug|Release]|smoke|workspace-smoke|termination-smoke|relaunch-smoke|release}\n' >&2
    exit 2
    ;;
esac
