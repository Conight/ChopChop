#!/bin/sh
# Shared by build, packaging, signing and standalone Swift verification tools.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    chopchop_selected_xcode="$(/usr/bin/xcode-select -p)"
    if [ -x "$chopchop_selected_xcode/usr/bin/xcodebuild" ]; then
        DEVELOPER_DIR="$chopchop_selected_xcode"
    else
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    echo 'error: Install Xcode 27 or set DEVELOPER_DIR to a full Xcode installation.' >&2
    exit 1
fi
export DEVELOPER_DIR
if [ "${1:-}" = --print-xcode-directory ]; then
    printf '%s\n' "$DEVELOPER_DIR"
fi
