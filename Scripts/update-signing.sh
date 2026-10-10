#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
configuration="$repo_root/Configuration/Release.xcconfig"
if [ "${1:-}" = --configuration ]; then
    [ "$#" -ge 3 ] || { echo 'Expected --configuration PATH COMMAND' >&2; exit 2; }
    configuration="$2"
    shift 2
fi
. "$repo_root/Scripts/xcode-environment.sh"
signing_work="$(mktemp -d "${CHOPCHOP_VALIDATION_ROOT:-${TMPDIR:-/tmp}}/chopchop-signing.XXXXXX")"
trap 'rm -rf "$signing_work"' EXIT
python3 "$repo_root/Scripts/release_config.py" --configuration "$configuration" --info-json > "$signing_work/configuration.json"
xcrun swiftc -parse-as-library -module-cache-path "$signing_work/cache" \
    "$repo_root/ChopChop/ReleaseConfiguration.swift" "$repo_root/ChopChop/AppVersion.swift" "$repo_root/ChopChop/AppUpdatePackage.swift" \
    "$repo_root/Scripts/AppUpdateSigning.swift" -o "$signing_work/sign-update"
exec_status=0
"$signing_work/sign-update" "$signing_work/configuration.json" "$@" || exec_status=$?
exit "$exec_status"
