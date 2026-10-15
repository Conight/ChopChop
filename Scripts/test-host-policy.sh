#!/bin/sh
# Source this before launching hosted tests or temporary network executables.
# A signature alone does not prevent macOS from recording each launch path.
chopchop_is_disposable_test_host() {
    [ "${CI:-false}" = true ] && [ "${GITHUB_ACTIONS:-false}" = true ] ||
        [ "${CHOPCHOP_DISPOSABLE_TEST_HOST:-0}" = 1 ]
}

chopchop_require_disposable_test_host() {
    if ! chopchop_is_disposable_test_host; then
        echo 'error: Hosted/network tests require a disposable CI host or VM; launching test apps can add persistent Local Network entries. Use GitHub Actions, or set CHOPCHOP_DISPOSABLE_TEST_HOST=1 only inside a disposable VM. For this Mac, build with Scripts/check.sh release and use the existing Release app path.' >&2
        return 2
    fi
}

if [ "${1:-}" = --require-disposable-host ]; then
    chopchop_require_disposable_test_host
fi
