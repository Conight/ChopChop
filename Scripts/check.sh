#!/bin/sh
# Use full Xcode even when xcode-select points at CommandLineTools.
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/Scripts/xcode-environment.sh"

mode="${1:-unit}"
if [ "$#" -gt 0 ]; then shift; fi
derived_data="${CHOPCHOP_DERIVED_DATA:-$repo_root/DerivedData}"
# macOS can key a test host's Local Network rule by executable path, even
# with a stable development signature. Never rotate that path on a user's Mac.
if [ "$mode" != release ] && [ "${CI:-false}" != true ] && [ "$derived_data" != "$repo_root/DerivedData" ]; then
    echo "error: Local tests must use $repo_root/DerivedData to keep their network permission identity stable. Custom build directories are supported for release builds and CI." >&2
    exit 2
fi
# Test entry points must never select the production identity, even by accident.
expect_configuration=false
for argument in "$@"; do
    if $expect_configuration; then
        case "$argument" in Debug|Release) ;; *) echo 'error: Local checks only support Dev Debug/Release; use create-dmg.sh for Distribution.' >&2; exit 2 ;; esac
        expect_configuration=false
    fi
    case "$argument" in
        -configuration) expect_configuration=true ;;
        CHOPCHOP_APP_IDENTIFIER=*|PRODUCT_BUNDLE_IDENTIFIER=*|CHOPCHOP_PRODUCT_NAME=*|CHOPCHOP_INFO_PLIST=*|INFOPLIST_FILE=*)
            echo 'error: Do not override app identity in local checks; configure the fork in Configuration/Release.xcconfig.' >&2; exit 2 ;;
    esac
done
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
. "$repo_root/Scripts/local-signing.sh"
exec /usr/bin/xcodebuild -project "$repo_root/ChopChop.xcodeproj" \
    -scheme "ChopChop Dev" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY="$signing_identity" CODE_SIGNING_REQUIRED=YES \
    CHOPCHOP_RELEASE_VERSION="${CHOPCHOP_RELEASE_VERSION:-development}" "$@"
