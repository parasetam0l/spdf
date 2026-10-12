#!/bin/bash
# Uploads sPDF's five Actions secrets with an ephemeral fine-grained token.
# Run interactively; passwords and token values are never command arguments.
set +x
set -euo pipefail
umask 077

root="$(cd "$(dirname "$0")/.." && pwd)"
repository="parasetam0l/spdf"
team="P7V7795SS9"
key_file="$root/Work/SparkleKeys/spdf-update-key"
validator="$root/Scripts/verify-ci-secrets.swift"

case "${1:-}" in
  --help|-h)
    printf 'Usage: bash Scripts/setup-ci-secrets.sh [certificate.p12]\n'
    printf '       bash Scripts/setup-ci-secrets.sh --check\n'
    exit 0
    ;;
esac
if (( $# > 1 )); then
  printf 'Pass only the .p12 file path (passwords are prompted privately).\n' >&2
  exit 1
fi
command -v gh >/dev/null || { printf 'Install GitHub CLI first: brew install gh\n' >&2; exit 1; }
swift "$validator" sparkle "$key_file" "$root/App/Info.plist" "$repository"
if [[ "${1:-}" == "--check" ]]; then
  printf 'Local prerequisites are ready. No GitHub login or secret upload was performed.\n'
  exit 0
fi
if [[ ! -t 0 || ! -t 1 ]]; then
  printf 'Run this script in your own interactive terminal to enter credentials privately.\n' >&2
  exit 1
fi

read_secret() {
  local variable="$1" prompt="$2"
  printf '%s' "$prompt" > /dev/tty
  IFS= read -r -s "$variable" < /dev/tty
  printf '\n' > /dev/tty
  if [[ -z "${!variable}" ]]; then
    printf 'A required credential was empty; nothing was uploaded.\n' >&2
    exit 1
  fi
}

config_dir="$(mktemp -d "${TMPDIR:-/tmp}/spdf-gh.XXXXXX")"
state_dir="$root/Work/CISetup"
mkdir -p "$state_dir"
state() { printf '%s\n' "$1" > "$state_dir/status.txt"; }
cleanup() {
  local result=$?
  if (( result != 0 )); then state failed; fi
  unset GH_TOKEN p12_password notary_apple_id notary_password
  rmdir "$config_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GH_CONFIG_DIR="$config_dir" GH_PROMPT_DISABLED=1 GH_PAGER=cat GH_NO_UPDATE_NOTIFIER=1
unset GH_DEBUG DEBUG

printf 'Target: %s\n' "$repository"
printf 'Token: fine-grained, Only select repositories → spdf, Secrets: Read and write.\n'
state awaiting-token
read_secret GH_TOKEN 'Paste the repository-scoped GitHub token (hidden): '
[[ "$GH_TOKEN" == github_pat_* ]] || {
  printf 'Use a fine-grained personal access token, rather than a classic token.\n' >&2
  exit 1
}
export GH_TOKEN
state checking-access
gh api "repos/$repository/actions/secrets/public-key" --silent

state awaiting-certificate
p12_file="${1:-}"
if [[ -z "$p12_file" ]]; then
  printf 'Developer ID .p12 file path: ' > /dev/tty
  IFS= read -r p12_file < /dev/tty
fi
case "$p12_file" in '~/'*) p12_file="$HOME/${p12_file:2}" ;; esac
[[ -f "$p12_file" && -r "$p12_file" ]] || {
  printf 'The .p12 file does not exist or cannot be read.\n' >&2
  exit 1
}
read_secret p12_password 'Password for the .p12 (hidden): '
printf '%s' "$p12_password" | swift "$validator" p12 "$p12_file" "$team"

state awaiting-notary-credentials
read_secret notary_apple_id 'Apple ID used for notarization (hidden): '
read_secret notary_password 'Apple app-specific notarization password (hidden): '

state uploading
printf 'Uploading the five Actions secrets to %s…\n' "$repository"
base64 < "$p12_file" | gh secret set DEVELOPER_ID_P12_BASE64 --repo "$repository" --app actions
printf '%s' "$p12_password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repository" --app actions
printf '%s' "$notary_apple_id" | gh secret set NOTARY_APPLE_ID --repo "$repository" --app actions
printf '%s' "$notary_password" | gh secret set NOTARY_PASSWORD --repo "$repository" --app actions
gh secret set SPARKLE_PRIVATE_KEY --repo "$repository" --app actions < "$key_file"

gh secret list --repo "$repository" --app actions --json name --jq '.[].name' > "$state_dir/secret-names.txt"
for name in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_APPLE_ID NOTARY_PASSWORD SPARKLE_PRIVATE_KEY; do
  found=false
  while IFS= read -r actual_name; do
    if [[ "$actual_name" == "$name" ]]; then found=true; break; fi
  done < "$state_dir/secret-names.txt"
  if [[ "$found" != true ]]; then
    printf 'GitHub did not list the expected secret: %s\n' "$name" >&2
    exit 1
  fi
done
state complete
printf 'Verified all five secret names on GitHub. No persistent gh login was saved.\n'
