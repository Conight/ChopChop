# ChopChop

A native Apple Silicon download manager for macOS, built with SwiftUI and powered by [Aria2 Next](https://github.com/AnInsomniacy/aria2-next).

[Download ChopChop](https://github.com/Conight/ChopChop/releases) · [Report an issue](https://github.com/Conight/ChopChop/issues) · [使用指南 / User Guide](Documentation/UserGuide.md)

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
4. Open ChopChop. On first launch, choose **Download and Start** to install Aria2 Next directly from its official release. Once installed, the engine starts automatically on subsequent launches.

These beta builds are ad-hoc signed and **not notarized by Apple**, matching the experimental distribution model used by [RemoteDock](https://github.com/Conight/RemoteDock). Gatekeeper may block a downloaded copy. After verifying its source and checksum, experienced testers can explicitly remove quarantine from this app:

```sh
xattr -dr com.apple.quarantine /Applications/ChopChop.app
open /Applications/ChopChop.app
```

Removing quarantine does not sign, notarize, or verify a download. Only do this for a copy whose origin and checksum you have checked.

## Features

- Simplified Chinese and English interfaces, including the browser extension and App Shortcuts.
- Separate ChopChop update checks with release notes and manual GitHub downloads.
- In-app help and previewable diagnostic export, with no automatic upload or download identifiers.

- Add individual links, batches, or mirrors; choose the destination and optional request settings.
- HTTP/HTTPS, SFTP, BitTorrent, magnet, ED2K, Metalink, and Thunder links through Aria2 Next.
- Pause, resume, inspect errors, or edit a failed download before adding it again.
- Persistent download history and stable dates, including when the engine is offline; clear records without deleting files.
- Engine starts automatically; restored downloads and BitTorrent seeding stay paused until you resume them.
- Measured byte or media-duration progress, with explicit metadata, verification, recording, and finalization states.
- Inspect HLS/DASH sources before downloading; select quality, audio, subtitles, MP4/MKV, or a time range. Record live streams and finish them into playable files.
- Send links and discover direct media sources with the bundled Chrome/Edge extension; review each import in ChopChop.
- Drag waiting tasks to reorder the engine queue, schedule a paused task to start, and apply daily bandwidth limits.
- Choose torrent files before downloading, then change file priorities, sequential mode, preview pieces, and sharing limits from task details.
- Repair task authentication, retry media with its saved progress, and replace same-origin links for paused tasks that have no partial data.
- Calculate or compare file checksums with progress and cancellation; recheck torrent pieces through the engine.
- App Shortcuts for adding links, pausing downloads, and getting a summary; Dock progress and native sharing for downloaded files.
- Drop download links or Torrent/Metalink files into the window; open files with ⌘O or from Finder, and receive Magnet/ED2K links. Every import opens for confirmation.
- Optional macOS notifications for completed background downloads, with persistent duplicate suppression and a shortcut back to the task.
- Native sidebar navigation, search, task details, keyboard shortcuts, and menu bar access.
- Configure connection limits, speed limits, proxies, trackers, and ED2K bootstrap sources.
- Automatic engine startup, background version checks, and manual updates inside Settings.
- Engine update progress, cancellation during download, checksum verification, and rollback if the replacement fails to start.

ChopChop registers as an available handler for Torrent/Metalink files and Magnet/ED2K links; it does not change existing default apps. Finder’s Open With → ChopChop opens supported files for review. Incoming file/link types can be enabled or disabled in Settings → Integrations; completion notifications are opt-in under General.

## Using the new features

- **Video:** Paste a direct `.m3u8` or `.mpd` address, then choose **Inspect Media**. For a manifest without a recognizable extension, choose HLS or DASH in **Download as**. Track selection happens before media payload transfer. This does not resolve arbitrary video-site pages or bypass protected streams; codecs are copied without transcoding.
- **Browser:** Enable **Settings → Integrations → Browser Integration**, export the extension, load its folder through Chrome/Edge's extension developer mode, and copy the pairing code into its settings. See [setup and permissions](BrowserExtension/README.md). Safari and browser-store distribution are not included.
- **Queue and schedule:** Reorder tasks in **Waiting**, or use **Move to Top of Queue**. In task details, expand **Scheduled Start**. Keep ChopChop running; restarting the app or engine disables scheduled starts until explicitly re-enabled. Daily bandwidth limits live in **Settings → Downloads**, use local time, and never resume tasks themselves.
- **Torrent:** Open **Files** in task details to set Skip/Normal/High/Top priorities, sequential download and sharing limits. **Network** shows native peer availability and tracker observations; use Refresh Details for fresh tracker status.
- **Repair:** Pause an HTTP/media task, then expand **Repair Connection** to update request authentication. Failed media can retry with its existing GID. Changing an address requires a paused, zero-byte, single-file HTTP task on the same origin. Other source changes use **Edit and Add Again**, which preserves partial files and creates a separate task.
- **Verify and share:** Under **Files**, completed files offer **Verify Checksum**, **Show in Finder**, and the macOS **Share** menu. SHA-256 is the default. Checksum calculation reads the file without modifying it.
- **Shortcuts:** Find **Add Download Links**, **Pause Downloads**, and **Get Download Summary** in the Shortcuts app. Add Download Links accepts text from an earlier action and opens the normal confirmation flow; it can be used in a shortcut configured to receive shared URLs. The Dock badge counts active/waiting transfers and only shows a progress bar when all included progress is known.

## Engine

ChopChop does not bundle an engine. On first launch it requires installation of **Aria2 Next**, downloaded directly from the [official upstream releases](https://github.com/AnInsomniacy/aria2-next/releases). The engine runs as a separate process and is stored in ChopChop's own application data directory; there is no installation-folder chooser. Click the **Engine** area in the sidebar to open its management page and update it manually.

The main app and engine use App Sandbox and Hardened Runtime. A private XPC installer service downloads, verifies, and signs official engine releases. The signed app bundle is not modified by an engine update.

Aria2 Next retains its upstream **GPL-2.0-or-later** license. Its notices are included in the app and in [Vendor/Aria2Next](Vendor/Aria2Next). Engine source is available from the upstream repository. Release downloads contain only the ChopChop DMG and its checksum; engine binaries and source archives are obtained from upstream.

## Build and test

Use **Xcode 27** and Swift 6 language mode. The app has no Swift Package Manager or CocoaPods dependencies.

```sh
Scripts/verify.sh
```

The shared CI/release gate checks localization, Swift/RPC and browser tests, Chinese layout, real HTTP/HLS/DASH downloads, and the hardened Release app. It uses one temporary directory and cleans it on exit. Tool versions are fixed in `Scripts/verification-tools.json`; see [Development and Engine Architecture](Documentation/Development.md) for setup, focused checks, and system-integration limitations. Open `ChopChop.xcodeproj` to develop in Xcode. Local builds use ad-hoc signing.

## Release packaging

Like RemoteDock, ChopChop publishes a DMG and SHA-256 checksum from an annotated version tag. The workflow runs the shared verification gate, builds an arm64 Release app, and verifies the final mounted DMG before publication. The complete tag is embedded for application update comparisons, including prerelease ordering.

```sh
# Python 3.10+ is required; python3.14 is preferred, or set PYTHON explicitly.
Scripts/create-dmg.sh
```

The packaging dependencies are version- and hash-pinned and installed into a temporary virtual environment. Finder layout metadata is generated with [dmgbuild](https://dmgbuild.readthedocs.io/), without UI automation. The script checks the app, XPC service, entitlements, signatures, architecture, notices, and Applications shortcut, and rejects any embedded engine payload.

Before a release, update `MARKETING_VERSION` in the app target to match the tag's base version. **All release titles and notes must be in English.** Save complete notes in `Documentation/Releases/<tag>.md` and commit them before creating the annotated tag:

```sh
git tag -a v0.0.1-beta.2 --cleanup=verbatim -F Documentation/Releases/v0.0.1-beta.2.md
git push origin v0.0.1-beta.2
```

Tags with a prerelease suffix are marked as GitHub pre-releases. The workflow requires the matching notes file and publishes it directly, preserving its Markdown headings. To correct an existing release, edit its GitHub notes and update the corresponding file without moving the published tag or replacing its assets. The workflow uses GitHub's [`xcode-27` Apple Silicon runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

Release files use names such as `ChopChop-v0.0.1-beta.2-macos-arm64.dmg` and `ChopChop-v0.0.1-beta.2-macos-arm64.dmg.sha256`.

## Copyright and third-party licenses

Copyright © 2026 Conight. No project-wide open-source license has been granted for ChopChop at this time. Third-party components retain their own licenses; see [Aria2 Next's license](Vendor/Aria2Next/Aria2Next-COPYING.txt) and [notices](Vendor/Aria2Next/Aria2Next-NOTICE.txt).
