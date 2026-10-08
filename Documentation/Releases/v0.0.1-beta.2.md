ChopChop 0.0.1-beta.2

This beta improves download reliability and recovery, refreshes the native macOS interface, and adds Simplified Chinese, media downloads, browser capture, and more complete BitTorrent controls.

### What's new

- **Reliable downloads:** Task history, added dates, and errors are stored independently and remain available while the engine is offline. After restarting ChopChop, unfinished downloads and BitTorrent seeding stay paused until you resume them.
- **Clearer progress:** Separate states identify metadata retrieval, downloading, verification, live recording, and final packaging. Downloads with unknown sizes and media tasks show the progress available for their transfer type.
- **BitTorrent controls:** Select files before downloading; manage file priorities, sequential downloading, and seeding limits; inspect piece completion, peer connections, and download/upload speeds. New tasks use dedicated folders, save available torrent metadata, and support Show in Finder.
- **Media downloads:** Add direct HLS/DASH URLs and choose video quality, audio tracks, subtitles, output format, and time range. Live recording supports explicit completion and final packaging.
- **Imports and browser capture:** Drop links or Torrent/Metalink files, receive Magnet/ED2K links, and export and pair the Chrome/Edge extension from Settings. Imports open a confirmation window before being added.
- **Task management:** Reorder the queue, schedule downloads, apply scheduled speed limits, repair authentication, verify files, and use native sharing and Shortcuts. Completion notifications can be enabled when needed.
- **Languages, updates, and feedback:** The app and extension support English and Simplified Chinese and follow the system/browser language. ChopChop now has its own update checks, help links, and diagnostic reports that you can preview before exporting.
- **Native interface:** Redesigned Add Download, Settings, task rows, and detail windows. The sidebar stays visible, All Downloads is the default destination, and Today has been removed. Click a task to expand its summary or press Space to open details. Detail windows use a unified titlebar and native equal-width capsule tabs, with subtle curves that follow the system accent color.
- **Protocols and storage:** SFTP is identified correctly, FTP input is no longer accepted, and the default download location, BitTorrent folders, and Show in Finder behavior have been corrected.

### Installation

Requires **Apple Silicon** and **macOS 26.5 or later**. Runtime validation uses macOS 27.0.1; macOS 26.5 has not been tested on a separate machine.

Download the DMG and checksum, verify the file, then open the image and drag ChopChop into Applications:

```sh
shasum -a 256 -c ChopChop-v0.0.1-beta.2-macos-arm64.dmg.sha256
```

The build remains **ad-hoc signed and not notarized by Apple**. See the [installation instructions](https://github.com/Conight/ChopChop#install) for the existing installation requirements.

### Validation and limitations

- The release gate covers Swift/RPC and migration tests, English/Chinese layout checks, browser extension tests, real isolated HTTP/HLS/DASH downloads, and Release/DMG signature, entitlement, checksum and layout verification. It does not simulate user input.
- The default gate leaves live installer/update tests and the full design-export fixture opt-in; these are reported as skips.
- Browser setup still requires exporting/loading and pairing the extension. Safari extensions are not included.
- Media input accepts direct manifests; arbitrary video-page extraction and protected-stream bypass are not provided.
- App updates open a GitHub Release for manual installation; the app does not replace itself.
- macOS 26.5 runtime, VoiceOver interaction and live system contrast/transparency changes remain unverified. Some native effects cannot be reproduced accurately by offscreen snapshots.
- This is an early beta; Intel Macs are not supported.

Release assets contain only the **ChopChop DMG and SHA-256 checksum**. Aria2 Next is installed separately from its [official upstream releases](https://github.com/AnInsomniacy/aria2-next/releases); no engine binary or source archive is bundled in this release. Its GPL-2.0-or-later license and notices are included in the app.
