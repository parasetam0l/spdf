#!/bin/bash
#
# Builds the installer DMG: the app plus an Applications link so the user
# can drag-install. The DMG is not signed here; the release workflow signs,
# notarizes, and staples it afterwards. No Python or Finder scripting is
# involved, so it also works on CI runners.
#
# Usage: Scripts/make-dmg.sh <sPDF Editor.app> <output.dmg> [volume name]

set -euo pipefail

usage="usage: make-dmg.sh <sPDF Editor.app> <output.dmg> [volume name]"
APP="${1:?$usage}"
DMG="${2:?$usage}"
VOLUME_NAME="${3:-sPDF Editor}"

[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root"
ditto "$APP" "$work/root/$(basename "$APP")"
ln -s /Applications "$work/root/Applications"

rm -f "$DMG"
if diskutil image create from --volumeName "$VOLUME_NAME" --format UDZO "$work/root" "$DMG" >/dev/null 2>&1; then
    :
else
    # Fall back to hdiutil on systems without `diskutil image create` (still
    # functional, but deprecated on macOS 27 and later).
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$work/root" -ov -format UDZO "$DMG" >/dev/null
fi
echo "Built $DMG"
