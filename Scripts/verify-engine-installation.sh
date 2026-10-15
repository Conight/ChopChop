#!/bin/sh
# Opt-in live regression check. No UI automation; never replaces the active engine.
# Pass an optimized Dev app. XCTest's extra entitlements can mask process-exec failures.
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/Scripts/test-host-policy.sh"
chopchop_require_disposable_test_host
release_app="${1:?Usage: Scripts/verify-engine-installation.sh '/path/to/Release/ChopChop Dev.app'}"
python_bin="${PYTHON:-python3}"
expected_identifier="$("$python_bin" -c 'import sys; sys.path.insert(0, sys.argv[1]); from release_config import load; print(load()["CHOPCHOP_APP_IDENTIFIER"])' "$repo_root/Scripts").dev"
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$release_app/Contents/Info.plist")"
development="$(/usr/libexec/PlistBuddy -c 'Print :ChopChopDevelopmentBuild' "$release_app/Contents/Info.plist" 2>/dev/null || printf false)"
[ "$actual_identifier" = "$expected_identifier" ] && [ "$development" = true ] || {
    echo 'error: Live probes require ChopChop Dev; the production container must not be used for testing.' >&2
    exit 1
}
test -d "$release_app/Contents/XPCServices/EngineInstaller.xpc"
probe_dir="$(/usr/bin/mktemp -d /tmp/chopchop-engine-probe.XXXXXX)"
trap '/bin/rm -rf "$probe_dir"' EXIT
. "$repo_root/Scripts/xcode-environment.sh"
. "$repo_root/Scripts/local-signing.sh"
/usr/bin/ditto "$release_app" "$probe_dir/ChopChop.app"
/usr/bin/codesign -d --entitlements :- --xml "$release_app" > "$probe_dir/entitlements.plist" 2>/dev/null
/usr/bin/xcrun swiftc -O -parse-as-library -o "$probe_dir/ChopChop" \
    "$repo_root/Scripts/EngineInstallationProbe.swift" \
    "$repo_root/ChopChop/ReleaseConfiguration.swift" "$repo_root/ChopChop/AppVersion.swift" \
    "$repo_root/ChopChop/AppUpdatePackage.swift" \
    "$repo_root/ChopChop/EngineStorage.swift" "$repo_root/ChopChop/EngineRelease.swift" "$repo_root/ChopChop/EngineDownload.swift" \
    "$repo_root/ChopChop/EngineInstallerProtocol.swift" "$repo_root/ChopChop/EngineInstallerRequest.swift" \
    "$repo_root/ChopChop/EngineInstallation.swift"
/usr/bin/ditto "$probe_dir/ChopChop" "$probe_dir/ChopChop.app/Contents/MacOS/ChopChop"
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none --options runtime \
    --entitlements "$probe_dir/entitlements.plist" "$probe_dir/ChopChop.app"
/usr/bin/codesign --verify --deep --strict "$probe_dir/ChopChop.app"
"$probe_dir/ChopChop.app/Contents/MacOS/ChopChop"
