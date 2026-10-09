#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
signing_work="$(mktemp -d "${CHOPCHOP_VALIDATION_ROOT:-${TMPDIR:-/tmp}}/chopchop-signing.XXXXXX")"
trap 'rm -rf "$signing_work"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$signing_work/cache" \
    "$repo_root/ChopChop/AppVersion.swift" "$repo_root/ChopChop/AppUpdatePackage.swift" \
    "$repo_root/Scripts/AppUpdateSigning.swift" -o "$signing_work/sign-update"
exec_status=0
"$signing_work/sign-update" "$@" || exec_status=$?
exit "$exec_status"
