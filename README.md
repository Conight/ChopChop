# ChopChop

A native Apple Silicon download manager for macOS, built with SwiftUI and powered by [Aria2 Next](https://github.com/AnInsomniacy/aria2-next).

[Download ChopChop](https://github.com/Conight/ChopChop/releases) · [Report an issue](https://github.com/Conight/ChopChop/issues)

## Requirements

- macOS 26.5 or later
- A Mac with Apple Silicon (arm64)

ChopChop is an early-stage project. Beta releases are intended for testing; data formats and behavior may change. Current runtime verification uses macOS 27.0.1. The macOS 26.5 deployment target has not yet been tested on a separate machine.

## Install

1. Download the `.dmg` and its `.dmg.sha256` file from [GitHub Releases](https://github.com/Conight/ChopChop/releases).
2. In the download directory, verify the checksum:

   ```sh
   shasum -a 256 -c ChopChop-*.dmg.sha256
   ```

3. Open the disk image and drag **ChopChop.app** into **Applications**.
4. Open ChopChop. The download engine starts automatically.

These beta builds are ad-hoc signed and **not notarized by Apple**, matching the experimental distribution model used by [RemoteDock](https://github.com/Conight/RemoteDock). Gatekeeper may block a downloaded copy. After verifying its source and checksum, experienced testers can explicitly remove quarantine from this app:

```sh
xattr -dr com.apple.quarantine /Applications/ChopChop.app
open /Applications/ChopChop.app
```

Removing quarantine does not sign, notarize, or verify a download. Only do this for a copy whose origin and checksum you have checked.

## Features

- Add individual links, batches, or mirrors; choose the destination and optional request settings.
- HTTP/HTTPS, FTP, BitTorrent, magnet, ED2K, Metalink, and Thunder links through Aria2 Next.
- Pause, resume, retry, and inspect downloads, with persistent session recovery.
- Choose individual torrent files before downloading.
- Native sidebar navigation, search, task details, keyboard shortcuts, and menu bar access.
- Configure connection limits, speed limits, proxies, trackers, and ED2K bootstrap sources.
- Automatic engine startup, background version checks, and manual updates inside Settings.
- Engine update progress, cancellation during download, checksum verification, and rollback if the replacement fails to start.

Browser capture and system protocol association are not implemented yet. Their settings panes describe their availability.

## Engine

The app bundles **Aria2 Next 2.8.6** as a separately executed helper. Engine updates are downloaded into ChopChop's own application data directory; there is no installation-folder chooser. Click the **Engine** area in the sidebar to open its management page.

The main app and engine use App Sandbox and Hardened Runtime. A private XPC installer service downloads, verifies, and signs official engine releases. The signed app bundle is not modified by an engine update.

Aria2 Next retains its upstream **GPL-2.0-or-later** license. Its notices are included in the app and in [Vendor/Aria2Next](Vendor/Aria2Next). Each binary release also includes the pinned upstream engine source archive and its checksum.

## Build and test

Use **Xcode 27** and Swift 6 language mode. The app has no Swift Package Manager or CocoaPods dependencies.

```sh
Scripts/check.sh unit
Scripts/check.sh release
python3 Scripts/smoke-aria2-next.py
```

Open `ChopChop.xcodeproj` to develop in Xcode. Local command-line builds use ad-hoc signing. See [Development and Engine Architecture](Documentation/Development.md) for engine installation, RPC, recovery, opt-in integration tests, and design verification.

## Release packaging

Like RemoteDock, ChopChop publishes a DMG and SHA-256 checksum from an annotated version tag. The workflow runs unit tests and a real engine download/resume check, builds an arm64 Release archive, and verifies the final mounted DMG before publication.

```sh
# Python 3.10+ is required for packaging. Set PYTHON if python3 is older.
Scripts/create-dmg.sh
```

The packaging dependencies are version- and hash-pinned and installed into a temporary virtual environment. Finder layout metadata is generated with [dmgbuild](https://dmgbuild.readthedocs.io/), without UI automation. The script checks the app, engine, XPC service, entitlements, signatures, architecture, license notices, and Applications shortcut.

Before a release, update `MARKETING_VERSION` in the app target to match the tag's base version. Write complete release notes in an annotated tag:

```sh
git tag -a v0.0.1-beta.1
git push origin v0.0.1-beta.1
```

Tags with a prerelease suffix are marked as GitHub pre-releases. Release notes come from the tag message. The workflow uses GitHub's [`xcode-27` Apple Silicon runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

Release files use names such as `ChopChop-v0.0.1-beta.1-macos-arm64.dmg` and `ChopChop-v0.0.1-beta.1-macos-arm64.dmg.sha256`.

## Copyright and third-party licenses

Copyright © 2026 Conight. No project-wide open-source license has been granted for ChopChop at this time. Third-party components retain their own licenses; see [Aria2 Next's license](Vendor/Aria2Next/Aria2Next-COPYING.txt) and [notices](Vendor/Aria2Next/Aria2Next-NOTICE.txt).
