#!/usr/bin/env python3
"""Verify the app and installer service, and reject embedded engine payloads."""

import base64
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys

from release_config import load, info as configuration_info


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
    configuration = load()
    expected_identifier = configuration["CHOPCHOP_APP_IDENTIFIER"]
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == expected_identifier, "Unexpected app identifier")
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
            [f"/Library/Containers/{expected_identifier}/Data/Library/Application Support/ChopChop/Engines/"],
            "Managed engine execution permission is missing or too broad")
    require(not entitlements(installer).get("com.apple.security.app-sandbox"), "Private installer must be able to sign downloaded engines")
    for name in ("Aria2Next-COPYING.txt", "Aria2Next-NOTICE.txt"):
        require((app / "Contents/Resources" / name).read_bytes() == (root / "Vendor/Aria2Next" / name).read_bytes(),
                f"Engine license notice differs: {name}")
    installer_info = plistlib.loads((installer / "Contents/Info.plist").read_bytes())
    require(installer_info["CFBundleIdentifier"] == expected_identifier + ".EngineInstaller", "Unexpected installer identifier")
    for field, value in configuration_info(configuration).items():
        require(info.get(field) == value and installer_info.get(field) == value, f"Release configuration differs: {field}")
    update_key = info.get("ChopChopUpdatePublicKey", "")
    require(update_key == configuration["CHOPCHOP_UPDATE_PUBLIC_KEY"], "Update public key does not match build configuration")
    if update_key:
        require(len(base64.b64decode(update_key, validate=True)) == 32, "Invalid update verification public key")
    tag = info.get("ChopChopReleaseVersion")
    expected_tag = os.environ.get("CHOPCHOP_RELEASE_VERSION", "development")
    require(tag == expected_tag, "Full release tag is missing or does not match the build")
    if tag != "development":
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", tag), "Invalid full release tag")
        require(tag[1:].split("-")[0] == info["CFBundleShortVersionString"], "Release tag and app version differ")
    for language in ("en", "zh-Hans"):
        for bundle in (app, installer):
            resources = bundle / "Contents/Resources" / (language + ".lproj")
            require((resources / "Localizable.strings").exists(), f"Missing localization: {resources}")
        require((app / "Contents/Resources" / (language + ".lproj") / "AppShortcuts.strings").exists(), "Missing shortcut localization")
    extension = app / "Contents/Resources/BrowserExtension"
    manifest = json.loads((extension / "manifest.json").read_text())
    require(manifest.get("default_locale") == "en", "Browser extension fallback locale is missing")
    require(manifest["manifest_version"] == 3, "Browser extension must use Manifest V3")
    require(manifest["host_permissions"] == ["http://127.0.0.1/*"], "Browser extension host access is too broad")
    for name in ("manifest.json", "core.js", "background.js", "popup.js", "popup.html", "options.js", "options.html", "style.css", "i18n.js", "_locales/en/messages.json", "_locales/zh_CN/messages.json"):
        require((extension / name).read_bytes() == (root / "BrowserExtension" / name).read_bytes(),
                f"Bundled browser extension differs: {name}")
    metadata = json.loads((app / "Contents/Resources/Metadata.appintents/extract.actionsdata").read_text())
    actions = metadata.get("actions", {})
    for name in ("AddDownloadLinksIntent", "PauseDownloadsIntent", "DownloadSummaryIntent"):
        require(any(name in key for key in actions), f"App Intent metadata missing: {name}")
    print(f"Verified ChopChop {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
          "no embedded engine, arm64, signatures, entitlements and notices.")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "Usage: Scripts/verify-release-app.py PATH.app")
        verify(pathlib.Path(sys.argv[1]).resolve())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
