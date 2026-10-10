#!/bin/sh
# Use full Xcode even when xcode-select points at CommandLineTools.
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/Scripts/xcode-environment.sh"

mode="${1:-unit}"
if [ "$#" -gt 0 ]; then shift; fi
case "$mode" in
    unit) set -- test -only-testing:ChopChopTests "$@" ;;
    layout) set -- test -only-testing:ChopChopTests/DesignPreviewTests "$@" ;;
    release-unit) set -- test -configuration Release -only-testing:ChopChopTests \
        ENABLE_TESTABILITY=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES ENABLE_HARDENED_RUNTIME=NO "$@" ;;
    ui) set -- test -only-testing:ChopChopUITests "$@" ;;
    all) set -- test "$@" ;;
    release) set -- build -configuration Release "$@" ;;
    *) echo 'Usage: Scripts/check.sh [unit|layout|release-unit|ui|all|release] [xcodebuild options...]' >&2; exit 2 ;;
esac
exec /usr/bin/xcodebuild -project "$repo_root/ChopChop.xcodeproj" \
    -scheme ChopChop -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${CHOPCHOP_DERIVED_DATA:-$repo_root/DerivedData}" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
    CHOPCHOP_RELEASE_VERSION="${CHOPCHOP_RELEASE_VERSION:-development}" "$@"
