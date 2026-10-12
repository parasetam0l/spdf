#!/bin/bash
#
# Submits a zip, dmg, or pkg to Apple's notary service and waits for the
# verdict; prints the submission id and Apple's log and fails when the
# verdict is not Accepted. The JSON verdict is checked by release-tools so
# no Python is involved.
#
# Usage: Scripts/notarize.sh <file>
# Environment: NOTARY_APPLE_ID, NOTARY_PASSWORD (an app-specific password),
#   TEAM_ID (defaults to SPDF_TEAM_ID or P7V7795SS9), RELEASE_TOOLS_BIN
#   (the built release-tools executable).

set -euo pipefail

FILE="${1:?usage: notarize.sh <file>}"
TEAM_ID="${TEAM_ID:-${SPDF_TEAM_ID:-P7V7795SS9}}"
tools="${RELEASE_TOOLS_BIN:?RELEASE_TOOLS_BIN must point at the built release-tools executable}"
: "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is not set}"
: "${NOTARY_PASSWORD:?NOTARY_PASSWORD is not set}"

credentials=(--apple-id "$NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")
verdict="$(mktemp)"
trap 'rm -f "$verdict"' EXIT

echo "Notarizing $(basename "$FILE")..."
result="$(xcrun notarytool submit "$FILE" "${credentials[@]}" --wait --timeout 30m --output-format json)"
printf '%s\n' "$result" > "$verdict"
printf '%s\n' "$result"

if ! check_output="$("$tools" notary-check "$verdict")"; then
    submission="${check_output#id=}"
    submission="${submission%% *}"
    if [[ -n "$submission" ]]; then
        echo "Notary log for submission $submission:"
        xcrun notarytool log "$submission" "${credentials[@]}" || true
    fi
    exit 1
fi
echo "Notarized: $(basename "$FILE")"
