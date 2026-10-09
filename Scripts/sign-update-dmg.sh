#!/bin/bash
# The only release step which needs the update signing secret.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: Scripts/sign-update-dmg.sh DMG OUTPUT_JSON' >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
signing_root="$(mktemp -d "${CHOPCHOP_VALIDATION_ROOT:-${TMPDIR:-/tmp}}/chopchop-sign-package.XXXXXX")"
mounted=false
cleanup() {
    if $mounted; then hdiutil detach "$signing_root/mount" -quiet || return; fi
    rm -rf "$signing_root"
}
trap cleanup EXIT
mkdir "$signing_root/mount"
hdiutil attach "$1" -readonly -nobrowse -noautoopen -mountpoint "$signing_root/mount" -quiet
mounted=true
CHOPCHOP_VALIDATION_ROOT="$signing_root" "$repo_root/Scripts/update-signing.sh" sign "$signing_root/mount/ChopChop.app" "$1" "$2"
