#!/bin/sh
set -eu

engine_path="$1"
expected_version="$2"
expected_sha="$3"

if [ ! -x "$engine_path" ]; then
    echo "error: Aria2 Next helper is missing or not executable: $engine_path" >&2
    exit 1
fi

actual_sha="$(/usr/bin/shasum -a 256 "$engine_path" | /usr/bin/awk '{print $1}')"
if [ "$actual_sha" != "$expected_sha" ]; then
    echo 'error: Aria2 Next bundled SHA-256 mismatch. Use Scripts/update-aria2-next.sh.' >&2
    exit 1
fi

/usr/bin/codesign --verify --strict "$engine_path"
# The release helper must run without Homebrew or other local dylibs.
if /usr/bin/otool -L "$engine_path" | /usr/bin/awk 'NR > 1 {print $1}' | \
    /usr/bin/grep -Ev '^(/usr/lib/|/System/Library/)'; then
    echo 'error: Aria2 Next references a non-system dynamic library.' >&2
    exit 1
fi

architectures="$(/usr/bin/lipo -archs "$engine_path")"
if [ "$architectures" != "arm64" ]; then
    echo "error: Aria2 Next must contain only arm64, found: $architectures" >&2
    exit 1
fi

if ! /usr/bin/strings "$engine_path" | /usr/bin/grep -Fxq "aria2-next/$expected_version"; then
    echo "error: Aria2 Next helper does not contain expected version $expected_version." >&2
    exit 1
fi

entitlements_file="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$entitlements_file"' EXIT
/usr/bin/codesign -d --entitlements :- --xml "$engine_path" > "$entitlements_file" 2>/dev/null

app_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements_file" 2>/dev/null || true)"
inherit_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.inherit' "$entitlements_file" 2>/dev/null || true)"
if [ "$app_sandbox" != "true" ] || [ "$inherit_sandbox" != "true" ]; then
    echo "error: Aria2 Next must be pre-signed with app-sandbox and inherit entitlements." >&2
    exit 1
fi
