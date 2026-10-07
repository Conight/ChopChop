#!/usr/bin/env python3
"""Verify the app and installer service, and reject embedded engine payloads."""

import pathlib
import plistlib
import re
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def entitlements(path):
    data = output("codesign", "--display", "--entitlements", ":-", "--xml", str(path))
    return plistlib.loads(data) if data.strip() else {}


def verify(app):
    root = pathlib.Path(__file__).resolve().parent.parent
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "com.conight.ChopChop", "Unexpected app identifier")
    require("Aria2NextVersion" not in info, "App must not declare a bundled engine version")
    require(not list(app.rglob("aria2-next*")), "App contains an embedded engine payload")
    require(not list(app.rglob("*.xctest")), "Release contains an XCTest bundle")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    installer = app / "Contents/XPCServices/EngineInstaller.xpc"
    for binary, signed in [(app / "Contents/MacOS/ChopChop", app),
                           (installer / "Contents/MacOS/EngineInstaller", installer)]:
        require(output("lipo", "-archs", str(binary)).strip() == b"arm64", f"Not arm64-only: {binary}")
        details = subprocess.run(["codesign", "--display", "--verbose=4", str(signed)],
                                 check=True, capture_output=True).stderr.decode()
        require(re.search(r"^CodeDirectory .*flags=.*runtime", details, re.M), f"Hardened Runtime missing: {signed}")
    app_entitlements = entitlements(app)
    for key in ("app-sandbox", "network.client", "network.server", "files.user-selected.read-write",
                "files.downloads.read-write", "files.bookmarks.app-scope"):
        require(app_entitlements.get("com.apple.security." + key) is True, f"Missing entitlement: {key}")
    require(not app_entitlements.get("com.apple.security.get-task-allow"), "Release permits debugger injection")
    require(app_entitlements.get("com.apple.security.temporary-exception.files.home-relative-path.read-only") ==
            ["/Library/Containers/com.conight.ChopChop/Data/Library/Application Support/ChopChop/Engines/"],
            "Managed engine execution permission is missing or too broad")
    require(not entitlements(installer).get("com.apple.security.app-sandbox"), "Private installer must be able to sign downloaded engines")
    for name in ("Aria2Next-COPYING.txt", "Aria2Next-NOTICE.txt"):
        require((app / "Contents/Resources" / name).read_bytes() == (root / "Vendor/Aria2Next" / name).read_bytes(),
                f"Engine license notice differs: {name}")
    print(f"Verified ChopChop {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
          "no embedded engine, arm64, signatures, entitlements and notices.")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "Usage: Scripts/verify-release-app.py PATH.app")
        verify(pathlib.Path(sys.argv[1]).resolve())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
