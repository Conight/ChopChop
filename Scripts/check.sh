#!/bin/sh
# Use full Xcode even when xcode-select points at CommandLineTools.
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mode="${1:-unit}"
if [ "$#" -gt 0 ]; then shift; fi
. "$repo_root/Scripts/test-host-policy.sh"
if [ "$mode" != release ]; then chopchop_require_disposable_test_host; fi
derived_data="${CHOPCHOP_DERIVED_DATA:-$repo_root/DerivedData}"
# macOS can key a test host's Local Network rule by executable path, even
# with a stable development signature. Never rotate that path on a user's Mac.
if ! chopchop_is_disposable_test_host; then
    if [ "$derived_data" != "$repo_root/DerivedData" ] || [ -n "${XCODE_XCCONFIG_FILE:-}" ]; then
        echo "error: Local Dev builds must use $repo_root/DerivedData and the checked-in configuration to preserve their launch identity." >&2
        exit 2
    fi
    for argument in "$@"; do
        case "$argument" in
            -configuration|-derivedDataPath|-project|-workspace|-scheme|-target|-xcconfig|test|test-without-building|build-for-testing|archive|install|clean|\
            CODE_SIGN*=*|DEVELOPMENT_TEAM=*|CONFIGURATION*=*|*BUILD_DIR=*|*BUILD_ROOT=*|SYMROOT=*|OBJROOT=*|DSTROOT=*|TEST_HOST=*|TEST_TARGET_NAME=*|EXECUTABLE*=*|FULL_PRODUCT_NAME=*|PRODUCT_NAME=*|WRAPPER_NAME=*)
                echo 'error: Local Dev build arguments cannot override signing, configuration, product paths, or launch tests; use a disposable test host.' >&2
                exit 2 ;;
        esac
    done
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
    keyboard) set -- test \
        -only-testing:ChopChopUITests/ChopChopUITests/testCommandDeleteUsesConfirmationAndRemovesOnlySelectedTask \
        -only-testing:ChopChopUITests/ChopChopUITests/testCommandSelectAllAndDeleteRespectFilteredTaskList \
        -only-testing:ChopChopUITests/ChopChopUITests/testCommandFindAndTextDeletionDoNotRemoveSelectedDownload \
        -only-testing:ChopChopUITests/ChopChopUITests/testCommandPasteInTaskListOpensImportAndSheetKeepsTextShortcuts "$@" ;;
    all) set -- test "$@" ;;
    release) set -- build -configuration Release "$@" ;;
    *) echo 'Usage: Scripts/check.sh [unit|layout|release-unit|ui|keyboard|all|release] [xcodebuild options...]' >&2; exit 2 ;;
esac
. "$repo_root/Scripts/xcode-environment.sh"
. "$repo_root/Scripts/local-signing.sh"
exec /usr/bin/xcodebuild -project "$repo_root/ChopChop.xcodeproj" \
    -scheme "ChopChop Dev" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY="$signing_identity" CODE_SIGNING_REQUIRED=YES \
    CHOPCHOP_RELEASE_VERSION="${CHOPCHOP_RELEASE_VERSION:-development}" "$@"
