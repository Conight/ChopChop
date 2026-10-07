# Development and Engine Architecture

Native Apple Silicon download manager built with SwiftUI, SwiftData and a separately downloaded Aria2 Next engine.

## Build and test

- Xcode 27, Swift 6 language mode (tested with Swift 6.4).
- macOS deployment target: 26.5. SDK: the installed macOS SDK, currently 27.0.
- The helper is arm64 only. There are no Swift Package Manager or CocoaPods dependencies.

Open `ChopChop.xcodeproj`, or run:

```sh
Scripts/check.sh unit       # Unit and RPC regression tests
Scripts/check.sh release-unit # Optimized unit tests with test-only injection enabled
Scripts/check.sh ui         # UI tests; requires an unlocked desktop
Scripts/check.sh all        # Both suites
Scripts/check.sh release    # Release build
python3 Scripts/smoke-aria2-next.py
```

`check.sh` honors `DEVELOPER_DIR` and otherwise finds full Xcode, including when `xcode-select` points to Command Line Tools. Local checks use ad-hoc signing and produce `DerivedData/`; set `CHOPCHOP_DERIVED_DATA` to change the location. Additional arguments are passed to `xcodebuild`. Distribution still requires the appropriate signing identity and notarization.

`release-unit` enables testability and debugger injection and disables hardened runtime only for that ad-hoc test invocation. `release` keeps hardened runtime and the distribution configuration's injection restriction. Run test suites sequentially: hosted unit tests and UI tests launch the same application identifier.

The Python smoke test downloads a pinned official engine into temporary storage, verifies its SHA-256, and then uses a loopback HTTP server and temporary files. It checks real engine downloads, pause, restart with the original GID and saved progress, final SHA-256, same-name file protection and clean shutdown. It re-signs a **temporary copy** of the helper for standalone execution; the opt-in integration tests verify the downloaded engine inside the app sandbox. No engine executable is tracked in the current source tree or included in build products.

## Engine startup and installation

At launch ChopChop checks for a usable managed engine, generates and persists a secure RPC token if needed, and starts the engine automatically. Existing token and download-folder settings are preserved. The sidebar shows checking, installation, startup, running, and failure states. Tracker and ED2K network maintenance runs after startup instead of delaying it.

A missing engine opens a required installation sheet with **Download and Start**, retry on failure, and quit. Installation is automatic into the app's own data directory:

```text
~/Library/Containers/com.conight.ChopChop/Data/Library/Application Support/ChopChop/Engines/<installation UUID>/aria2-next
```

There is no folder chooser. The embedded `EngineInstaller.xpc` service downloads only an official stable Apple Silicon release, verifies SHA-256, applies sandbox inheritance signing, and writes a fresh installation folder. The parent app verifies that the engine executes inside its sandbox before atomically recording the active installation. Failed attempts do not replace the existing installation or modify the signed `.app` bundle. The active managed installation is the only engine used; there is no embedded fallback.

The private installer runs on demand without App Sandbox; the main app and running engine remain sandboxed. It checks the caller against the containing app's code-signing requirement, accepts only canonical release versions and the app's own `ChopChop/Engines` folder, and requires no administrator privileges. Directory access is shared with an implicit URL bookmark. This follows Apple's [XPC service separation](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html) and [cross-process bookmark](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) mechanisms.

A background GitHub check runs on each app launch. Newer stable releases appear as `2.8.5 → 2.8.6` in the sidebar's Engine row, without a startup alert. The whole Engine/Status area always opens ChopChop's Engine settings, including when no update is available or Settings was previously showing another pane. Offline or rate-limited checks never block a usable local engine.

A compact `↑ New` badge appears at the lower right of the Engine area while an update is available, and hides during installation or once updated. Its subtle tint follows the system accent color; the text, arrow, tooltip, and accessibility hint also convey the update without relying on color. It supports light/dark appearances, increased contrast, and reduced transparency, following Apple's [color guidance](https://developer.apple.com/design/human-interface-guidelines/color). The status row keeps a stable height and shows a concise state, with the running process ID available in its tooltip when no update is pending.

Engine settings offers a manual check and an **Update to …** button with progress and retryable inline errors. The current engine keeps running while the new binary downloads and verifies. ChopChop then saves the session, stops the engine, snapshots its session/recovery state, and starts the replacement. Only successful RPC startup commits the new installation; a failed replacement restores the previous engine and runtime state. An intentionally stopped engine stays stopped. Quitting cancels an in-progress update. Updating never opens a browser or asks for a destination folder.

Engine installation and updates use a native linear progress bar in a consistent location, following Apple's [progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) and [feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) guidance. A session-level download delegate reports measured bytes, total size, percentage and speed over XPC. Unknown totals and verification/restart stages stay indeterminate; there is no invented overall percentage. The sidebar mirrors progress. Cancel is available before the current engine is stopped; a retry starts the download again. Failure feedback names the stage, preserves the installed version and offers an inline retry.

App Sandbox does not automatically permit executing a new binary in Application Support. The app includes a narrowly scoped read-only [home-relative path exception](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html) for its own container's `ChopChop/Engines/` directory. The macOS sandbox grants execution for that specific exception; the app and helper retain App Sandbox and Hardened Runtime. Without it, a normal Release app can read the downloaded file but `Process.run()` misleadingly reports that it does not exist. XCTest's additional execution permissions can conceal this failure.

After building Release, run `Scripts/verify-engine-installation.sh /path/to/Release/ChopChop.app` to test the actual Release entitlements without XCTest or UI interaction. The probe downloads and runs a verified engine in the production installation directory, then removes only its new staging folder. It never activates the engine, changes the installed-engine manifest, or interrupts the running engine. The script signs an isolated copy with the built app's entitlements and Hardened Runtime.

For a real installation and RPC verification without UI automation:

```sh
TEST_RUNNER_CHOPCHOP_TEST_ENGINE_DOWNLOAD=1 Scripts/check.sh unit \
  -only-testing:ChopChopTests/ManagedEngineTests/testAutomaticInstallAndRPCStartupInsideSandbox \
  -only-testing:ChopChopTests/ManagedEngineTests/testManualUpgradeFrom285ThroughSandboxedStore
```

These opt-in tests download official engines into isolated test storage and verify authenticated RPC from the sandboxed host. They cover both first installation and a real 2.8.5-to-latest manual update through the application store. The default unit suite tests startup, token persistence, required installation/retry, offline checking, update reminders, release/checksum validation, installer boundary checks, and cancellation without a network download.

## Updating the download engine

The application resolves the latest stable release from the official upstream repository when installing or checking for updates. Its version display comes only from the verified managed installation; an empty installation shows “Unavailable”. App builds do not download or pin an engine version.

`Scripts/engine-test-release.json` pins an upstream version and SHA-256 **only for the CLI smoke test**. Update this metadata when adopting a new integration-test baseline, then run `python3 Scripts/smoke-aria2-next.py`. The executable is fetched into a temporary directory and removed at the end of the test. The engine's libraries (including libcurl, OpenSSL and libtorrent) remain part of the upstream executable.

`Scripts/verify-release-app.py` rejects an embedded engine or a bundled-engine version key. The release workflow publishes only the DMG and its checksum; it does not download or mirror engine source.

## Persistent data and recovery

Production data stays in the app sandbox's Application Support directory:

- `ChopChop/aria2.session`: unfinished tasks and their GIDs.
- `ChopChop/aria2.log`: engine diagnostics.
- `aria2-next/`: engine recovery databases and protocol state.

Keep the session and recovery state together. Aria2 Next 2.8.3 and later require matching task recovery records for stream resume; adding the same URL as a new task is not a substitute for restoring its original session. Existing files follow the engine's collision policy. See the [upstream migration note](https://github.com/AnInsomniacy/aria2-next/releases/tag/v2.8.3).

On the first engine launch after a version change, ChopChop copies any nonempty existing session into `ChopChop/Session Backups/` before the engine can rewrite it and shows the backup location. HTTP tasks migrated from 2.4.9 may restart from zero; their old partial files are preserved. The backup retains the original task list for rollback with the old engine. Normal 2.8.6-to-2.8.6 restart recovery is covered by the smoke test.

To repeat the legacy migration check with a saved 2.4.9 helper, run `python3 Scripts/smoke-aria2-next.py --previous-engine /path/to/old/aria2-next`. It verifies that the migrated task keeps its GID, completes under a new filename and leaves the old partial's bytes unchanged.

Automation uses in-memory settings and per-process temporary engine state. Development machine settings under `.codex/`, Xcode user state and build outputs are ignored by Git.

## Upgrade references

- [Aria2 Next 2.8.6 release](https://github.com/AnInsomniacy/aria2-next/releases/tag/v2.8.6)
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)

The deployment target remains 26.5 because this update does not require a macOS 27-only API. Runtime verification for this upgrade was performed on macOS 27.0.1; macOS 26.5 runtime verification requires a separate machine or VM.

Dependency-upgrade baseline on 2026-10-07: 126 unit tests passed in both Debug and optimized Release test configurations; all 15 UI cases passed, including targeted reruns after test metadata and migration changes. The native engine smoke tests passed for both current-version recovery and 2.4.9 migration. The normal hardened Release application also built and passed recursive code-signature verification.

Automatic-startup validation on 2026-10-07: the Debug unit run passed 136 tests with the live download test skipped; that live test passed separately. All 137 tests passed in optimized Release, including the actual XPC download, automatic installation, restored installation record, sandbox launch and authenticated RPC check. Further UI automation was not run at the user's request.


## macOS design review (2026-10-07)

The Add Download sheet uses a content-sized 560-point layout with a native multiline text editor, a single quiet protocol/link-count label, and an AppKit path control for the destination. Advanced options are collapsed by default and use aligned persistent labels for download controls and HTTP request fields; Cookie and Authorization use secure fields. The scrolling body has a bounded height, while Cancel and the primary action remain reachable. Submission is guarded against repeated clicks, and recoverable errors appear inline. This follows Apple's [sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields), and [disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) guidance. Offscreen previews cover empty input, single and multiple links, advanced options, and torrent selection in addition to system appearance variants.

The interface follows the current Apple HIG for [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [lists and selection](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [settings](https://developer.apple.com/design/human-interface-guidelines/settings), and [sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).

- Download rows use a native selectable List with system focus/selection, keyboard navigation, context actions, and stable geometry. Details can be closed without losing the selected download. Search has a dedicated empty-results state and clears selections hidden by a new filter.
- The toolbar uses the native window title, grouped actions, and a Details toggle. File, View, and Downloads menus expose the corresponding commands. New Download uses Command–Shift–N, Paste Download Link uses Command–Shift–V, Refresh uses Command–R, and Details uses Command–Option–I; the standard text-editing Paste shortcut remains intact.
- Content panels use semantic opaque surfaces and contrast-aware borders. Native navigation and toolbars supply their own platform materials. Status text uses semantic foreground colors; color and symbols supplement the labels.
- The main window supports 900×600 content sizing, with a compact summary and sidebar footer. Settings uses regular system controls, a narrower sidebar, and General as its default pane. The Engine status area still opens the Engine pane directly.
- The Add Download sheet has one Cancel action, Return/Escape shortcuts, and a native DisclosureGroup for advanced options. Task rows no longer resize or spring-animate when selected.
- Launch-at-login, automatic file revealing, and overwrite-confirmation switches were hidden because their backing behavior is not implemented. Protocol association and browser integration panes describe their actual availability instead of exposing ineffective switches. Existing stored preferences remain intact. The background-download window-close preference now controls application termination.

`TEST_RUNNER_CHOPCHOP_DESIGN_RENDER=1 Scripts/check.sh unit -only-testing:ChopChopTests/DesignPreviewTests` renders main, compact, settings, details, sheet, and empty-search layouts in isolated offscreen windows. These exports inspect content geometry; native toolbar/vibrancy compositing requires an actual displayed window and is not represented faithfully by AppKit bitmap caching. This does not drive the app with clicks or keyboard events.
