#!/bin/sh
# Source from developer checks. Ad-hoc signatures change identity with every
# build and can leave permanent duplicate Local Network privacy entries.
if [ "${CI:-false}" = true ]; then
    default_signing_identity=-
else
    default_signing_identity='Apple Development'
fi
signing_identity="${CHOPCHOP_CODE_SIGN_IDENTITY:-$default_signing_identity}"
if [ "$signing_identity" = - ]; then
    if ! { [ "${CI:-false}" = true ] && [ "${GITHUB_ACTIONS:-false}" = true ]; } && [ "${CHOPCHOP_DISPOSABLE_TEST_HOST:-0}" != 1 ]; then
        echo 'error: Ad-hoc local test builds create unstable privacy identities. Use Apple Development; reserve CI=true for disposable CI hosts/VMs.' >&2
        exit 1
    fi
    echo 'note: Ad-hoc signing selected; run network tests only on a disposable CI host/VM.' >&2
fi

if [ "${1:-}" = --print-identity ]; then
    printf '%s\n' "$signing_identity"
fi
