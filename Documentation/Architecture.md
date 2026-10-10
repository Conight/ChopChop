# Code and configuration ownership

Use the module that owns a behavior when changing a shared value. Avoid copying a URL, path rule or default into a view, service or verification script.

## Configuration and persistent layout

| Owner | Responsibility |
| --- | --- |
| [`Configuration/Release.xcconfig`](../Configuration/Release.xcconfig) | App release repository, application identity and update public key; see [fork setup](ReleaseConfiguration.md) |
| [`EngineDistribution`](../ChopChop/EngineRelease.swift) | Canonical upstream Engine API, release pages, binary and checksum asset names |
| [`EngineStorage`](../ChopChop/EngineStorage.swift) | Installed engine manifest and executables, session, version marker, log, recovery state and backup directories |
| [`AppUpdateStorage`](../ChopChop/AppUpdateStorage.swift) | Download cache, installation staging names, worker files and directory ownership validation |
| [`EngineSettings`](../ChopChop/EngineSettings.swift) | Engine defaults and option conversion; add-download drafts and disk settings derive their defaults from this type |
| [`PreferencesStore`](../ChopChop/PreferencesStore.swift) | App preferences, bookmark helpers and legacy preference keys; disk persistence remains in `PersistentSettingsStore` |
| [`AppWindowID`](../ChopChop/AppSupport.swift) | SwiftUI scene identifiers and the native downloads window identifier used for reopening |
| [`AppTermination`](../ChopChop/AppTermination.swift) | Programmatic quit scheduling, duplicate-request suppression and asynchronous cleanup before replying to AppKit |
| [`AppUpdateInstallation`](../ChopChop/AppUpdateInstallation.swift) | Authenticated installer jobs, kernel process-exit observation, atomic replacement, launch verification and rollback |

`EngineStorage` takes an explicit support directory so startup, install activation, rollback and torrent metadata access calculate the same paths. It does not relocate user data. Session names, SwiftData entities, raw enum values, preference keys and document identifiers are persistent contracts, even when their source files move.

The updater has two separate locations: downloaded installers in the app cache, and verified replacement staging beside the installed App for atomic replacement. Directory checks require both the owned prefix and a complete UUID. Recovery, cleanup and the worker use the same check.

Before acknowledging readiness, the detached installer registers `EVFILT_PROC` / `NOTE_EXIT` through `kqueue` for the authenticated parent PID. It waits for that process's actual exit using a monotonic deadline. `NSRunningApplication` verifies the initial app identity, but its termination state is not the installation gate: Launch Services can retain the quitting app while its XPC service or installer child is alive. Registration errors fail closed, except `ESRCH` when the parent has already exited; the worker never force-quits the app. Launch Services still verifies that the replacement finished launching. See Apple's [`kqueue` process filter documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kqueue.2.html).

Programmatic quit actions call `AppTermination.request()`. AppKit's `terminateLater` runs a modal event loop; invoking `NSApp.terminate` directly inside a MainActor task keeps the main dispatch queue occupied and can prevent the asynchronous cleanup task from running. Scheduling the selector on the common run-loop modes releases the originating task first. The delegate retains the normal `terminateLater`/reply contract for native Quit and system termination requests. See Apple's [`terminate(_:)`](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)) and [`perform(_:with:afterDelay:inModes:)`](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/perform(_:with:afterdelay:inmodes:)) documentation.

## Domain models and operations

| Source | Responsibility |
| --- | --- |
| `DownloadModels.swift` | Tasks, files, statuses, protocol labels, selection snapshots and speed samples |
| `DownloadDraft.swift` | Input parsing, per-download options, validation and file category rules |
| `TrackerSources.swift` | Tracker source catalog, parsing, validation, fetch results and fetching |
| `ED2KBootstrap.swift` | ED2K bootstrap validation, fetching and local cache |
| `ED2KSearch.swift` | Search options, results and temporary search state |
| `SystemProxy.swift` | System proxy discovery and conversion |
| `Formatting.swift` | Shared string and localized byte formatting |
| `DownloadFileRemoval.swift` | Safe user-file and companion-file removal planning |
| `DownloadTaskRPCOperations.swift` | Task removal and result cleanup against the Engine |
| `DownloadPowerAssertion.swift` | IOKit assertion ownership for preventing idle sleep |

`DownloadStore` coordinates observable UI state and these services. Network clients, filesystem rules and platform resource ownership belong in their own modules. Source organization does not change the SwiftData schema or the Engine RPC identifiers.

## Download list presentation

`DownloadCanvas` owns the native List's selection, contextual menu and primary action. A single click only selects; the selection-aware `contextMenu(forSelectionType:menu:primaryAction:)` API handles a double-click to pause or resume one task. Space opens the independent details panel. Task settings remain in that panel and are reachable through shared contextual commands.

`DownloadTaskRow` supplies a flat content layout, native file icons and trailing controls for the state-appropriate action, details and removal. Row commands target that row's task through `DownloadActionContext.listTask`; contextual menus can explicitly supply the full selection. Narrow lists place transfer rates beneath progress to preserve filename and button space. List owns its background, selection highlight and separators. `DownloadListTaskDisplay` supplies compact progress text and distinguishes completed tasks and seeding from in-progress transfers. `DownloadListPresentation` keeps stable observable row identities so polling only publishes changed task snapshots. `TaskBandwidthView` owns the task speed-limit editor; it no longer lives inside an expanding list row.

## Verification and tooling

- `Scripts/xcode-environment.sh` selects full Xcode consistently for builds, packaging, signing and standalone Swift probes. An explicit `DEVELOPER_DIR` takes precedence.
- `Scripts/engine_fixture.py` downloads and verifies the pinned Engine in `Scripts/engine-test-release.json` for both HTTP/RPC and media tests. Invalid or interrupted downloads are removed. This fixed test release is intentionally separate from the app's latest-release discovery.
- `Scripts/verification-tools.json` pins Python, Node and FFmpeg versions for the shared verification gate and CI setup.
- `Scripts/verify.sh` runs the configuration checks, Swift tests, browser tests, real Engine/media integration, Release verification and isolated updater tests. Disposable products belong under one validation directory and are cleaned after the run.
- `Scripts/smoke-app-update.py` tests kernel exit observation without a main run loop, timeout safety and exit races. Its signed fixture app also calls the actual embedded XPC service to launch the worker before asynchronously quitting; launching the worker directly from the test driver does not reproduce the same process relationship.
