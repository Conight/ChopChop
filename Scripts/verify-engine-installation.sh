#!/bin/sh
# Opt-in live regression check. No UI automation; never replaces the active engine.
# Pass a freshly built Release app. XCTest's extra entitlements can mask process-exec failures.
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
release_app="${1:?Usage: Scripts/verify-engine-installation.sh /path/to/Release/ChopChop.app}"
test -d "$release_app/Contents/XPCServices/EngineInstaller.xpc"
probe_dir="$(/usr/bin/mktemp -d /tmp/chopchop-engine-probe.XXXXXX)"
trap '/bin/rm -rf "$probe_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/usr/bin/ditto "$release_app" "$probe_dir/ChopChop.app"
/usr/bin/codesign -d --entitlements :- --xml "$release_app" > "$probe_dir/entitlements.plist" 2>/dev/null
/usr/bin/xcrun swiftc -O -parse-as-library -o "$probe_dir/ChopChop" \
    "$repo_root/Scripts/EngineInstallationProbe.swift" \
    "$repo_root/ChopChop/EngineRelease.swift" "$repo_root/ChopChop/EngineDownload.swift" \
    "$repo_root/ChopChop/EngineInstallerProtocol.swift" "$repo_root/ChopChop/EngineInstallerRequest.swift" \
    "$repo_root/ChopChop/EngineInstallation.swift"
/usr/bin/ditto "$probe_dir/ChopChop" "$probe_dir/ChopChop.app/Contents/MacOS/ChopChop"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$probe_dir/entitlements.plist" "$probe_dir/ChopChop.app"
/usr/bin/codesign --verify --deep --strict "$probe_dir/ChopChop.app"
"$probe_dir/ChopChop.app/Contents/MacOS/ChopChop"
