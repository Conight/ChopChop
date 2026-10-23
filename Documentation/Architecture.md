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

`BitTorrentClientIdentity` in `EngineSettings.swift` owns the BT identity. It derives `ChopChop/<version>` from the embedded release tag (or the marketing version with a `-dev` suffix), independently of localization and the ordinary HTTP User-Agent. Engine startup and global option updates send `bt-user-agent` and the `ChopChop-` peer-ID prefix; libtorrent generates the remaining 11 bytes of each 20-byte peer ID. Settings displays the same model. No identity is copied into persistent user settings.

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
| `DownloadFileRemoval.swift` | Safe, idempotent user-file and companion-file removal planning |
| `DownloadFileSafety.swift` | Completed torrent payload checks, persistent safety holds and guarded resume |
| `DownloadTaskRPCOperations.swift` | Task removal and result cleanup against the Engine |
| `DownloadPowerAssertion.swift` | IOKit assertion ownership for preventing idle sleep |

`DownloadStore` coordinates observable UI state and these services. Network clients, filesystem rules and platform resource ownership belong in their own modules. Source organization does not change the SwiftData schema or the Engine RPC identifiers.

`EngineSettingsApplication` records accepted live defaults and the startup configuration separately from persisted preferences. `DownloadStoreEngineSettings` owns the session-bound reconciliation worker and inline failure state. Views consume its pending-restart reasons rather than treating a generic Apply action as proof that every preference is active. The bandwidth clock remains the sole owner of effective global caps.

TLS trust belongs to the supported engine's native Apple SecTrust backend. `EngineSettings` enables certificate checking and leaves CA-file overrides unset. A static PEM bundle is not equivalent to macOS trust evaluation; do not introduce one in startup, task defaults or media requests. `engine_tls_fixture.py` verifies this contract against the real engine using isolated HTTPS and a temporary localhost-only trust anchor on disposable test hosts.

`DownloadStore` and `AppUpdateCoordinator` use Observation. SwiftUI receives them through `Environment`, keeps owned instances in `State`, and creates editable bindings with `Bindable`; a view subscribes to the properties it actually reads. AppKit's Dock, menu-bar visibility and notification navigation retain explicit event streams, delivered after the corresponding state is committed. Polling must not broadcast changes to unrelated settings, draft editors or window navigation. See Apple's [Observation migration guide](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro).

## Download list presentation

The add-download sheet keeps a 180-point artwork column throughout source entry, advanced options, media inspection and torrent file selection. Scrollable content fills the proposed height while the title and actions stay at its edges. `.presentationSizing(.fitted)` supplies the compact initial ideal size; the content also fills the user's resized sheet when its stage changes. Native sheets retain ownership of resizing and placement.

`TorrentFileKind` classifies metadata paths using Uniform Type Identifiers and extensions for formats without consistent system registration. Whole-torrent selection shortcuts clear the search and replace the draft selection, while individual files and mixed folder checkboxes remain adjustable. No payload files are read and no Engine file priorities change until the user confirms. Available file types and the folder tree are refreshed only when the file list changes.

`DownloadCanvas` owns the native List's selection, contextual menu and primary action. A single click only selects; the selection-aware `contextMenu(forSelectionType:menu:primaryAction:)` API handles a double-click to pause or resume one task. Space opens the independent details panel. Task settings remain in that panel and are reachable through shared contextual commands.

`DownloadTaskRow` supplies a flat content layout, native file icons and trailing controls for the state-appropriate action, details and removal. Row commands target that row's task through `DownloadActionContext.listTask`; contextual menus can explicitly supply the full selection. `DownloadTaskTransferSummary` gives download speed, torrent upload speed and ETA independent positions. Narrow lists place the summary across the row below the filename, rather than inside the fixed-width progress column; wider lists keep ETA beneath the two rates. Apple's [`ViewThatFits`](https://developer.apple.com/documentation/swiftui/viewthatfits) stacks metrics if their intrinsic widths exceed the available space. Zero torrent upload remains visible so polling does not swap ETA and upload into the same position. List owns its background, selection highlight and separators. `DownloadListTaskDisplay` supplies compact progress text and distinguishes completed tasks and seeding from in-progress transfers. `DownloadListPresentation` keeps stable observable row identities so polling only publishes changed task snapshots. `TaskBandwidthView` owns the task speed-limit editor; it no longer lives inside an expanding list row.

Each `DownloadRowState` separates its live task snapshot from an equatable `DownloadRowPresentation` containing the name, phase, controls and error/schedule help. Progress and rate children observe the live snapshot; the outer row only observes the presentation. Transfer ticks therefore do not invalidate the filename, controls or native tooltip. The tooltip describes the task without duplicating rapidly changing counters. List still paints the native selection background; the row supplies semantic primary/secondary foreground levels based on selection, list focus and key-window state, so live child updates retain the correct contrast.

`DownloadListPresentation.orderedRows` changes only with task membership/order. Filtering, waiting-queue ordering, badges and total-size summaries read structural presentations; the selected inspector reads only its selected row's live snapshot. Sidebar and menu-bar transfer metrics have their own view boundaries, separate from navigation and engine controls. `MenuBarStatus.swift` owns status-item presentation and its observation lifecycle; its three display modes reuse engine samples and the native AppKit button. See [menu bar behavior and official guidance](MenuBar.md). Dock progress updates existing AppKit views rather than rebuilding their hierarchy.

`TransferDetailMonitor` retains the last successful snapshot while retrying or inactive, with an explicit last-updated timestamp and availability feedback. Cancellation and generation checks prevent an older fetch from replacing newer data; a different task or engine session clears the snapshot. File tables, like peer tables, retain their current order while values update and reorder on an explicit sort/refresh request. Native control bridges compare labels, values and selection before setting them.

`TaskDetailsPresentation` explicitly makes the native details panel key when opening or bringing it forward, including reuse of an existing panel. Closing returns focus to the owning window and its saved responder. The panel handles preview navigation without retaining keyboard focus in the list. AppKit supplies the panel's active appearance. See Apple's [`makeKeyAndOrderFront(_:)`](https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront(_:)) and [`orderFront(_:)`](https://developer.apple.com/documentation/appkit/nswindow/orderfront(_:)) documentation.

The row's details button toggles the shared panel: it closes an already presented task or selects and shows the requested task. It rechecks live state at dispatch, including whether the task still exists. Row equality includes the task's details visibility so native help and accessibility labels switch between Show Details and Hide Details. Explicit Show Details, speed-limit and schedule commands keep their open/navigate behavior.

Every task row retains its progress track, including completed tasks and seeds. The progress column is 180 points wide in both compact and regular layouts, independent of filename length. Names and secondary text truncate inside the remaining identity column. Native help covers the full row rectangle, including gaps and progress/transfer text, and shows the full name, phase, progress, size and applicable ETA, error or schedule. Only action buttons override this with their own command help. Completed downloads and seeds show full progress, while metadata, verification and unknown totals retain indeterminate progress.

## Verification and tooling

- `Scripts/xcode-environment.sh` selects full Xcode consistently for builds, packaging, signing and standalone Swift probes. An explicit `DEVELOPER_DIR` takes precedence.
- `Scripts/engine_fixture.py` downloads and verifies the pinned Engine in `Scripts/engine-test-release.json` for both HTTP/RPC and media tests. Invalid or interrupted downloads are removed. This fixed test release is intentionally separate from the app's latest-release discovery.
- `Scripts/verification-tools.json` pins Python, Node and FFmpeg versions for the shared verification gate and CI setup.
- `Scripts/verify.sh` runs the configuration checks, Swift tests, browser tests, real Engine/media integration, Release verification and isolated updater tests. Disposable products belong under one validation directory and are cleaned after the run.
- `Scripts/smoke-app-update.py` tests kernel exit observation without a main run loop, timeout safety and exit races. Its signed fixture app also calls the actual embedded XPC service to launch the worker before asynchronously quitting; launching the worker directly from the test driver does not reproduce the same process relationship.

## Browser receipts, bandwidth and observed activity

`BrowserReceipts` owns bounded admission identities and credential-origin validation. `BrowserCaptureServer` authenticates loopback transport and exposes import/receipt operations. `DownloadStoreBrowser` connects receipts to the existing import coordinator; `DownloadStoreSubmission` owns shared draft submission for native, browser and Shortcuts entry points. Views never submit directly to the engine. The v2 capability handshake runs before any download payload is sent; writes use v2 endpoints that older v1 apps cannot accept. Legacy v1 link import remains available for older extensions. A receipt is committed before input is enqueued. Late or interrupted writes remain unknown rather than being replayed; an explicit missing receipt is different from a connection failure. Request IDs are bound to the original draft/owner, so closing a sheet cannot attach a late response to another import. Provisional media/torrent metadata is not reported as a confirmed browser download.

`EffectiveBandwidth` owns daily windows, temporary caps and effective limits; the existing plan clock remains the only live writer of global transfer caps. Temporary caps take the minimum nonzero effective cap and cannot raise another limit. The saved optional `temporaryBandwidthData` contains the user settings and expiration. Its absence loads defaults; an expired cap does not reactivate on restart. This adds no automatic resume behavior.

`TrackerDiagnostics` keeps per-source successful snapshots, managed public-list ownership, explicit exclusions and route-scoped connection evidence. Sources are bounded to 32, with at most 2048 cached candidate entries shared across them (maximum 512 per source). Up to 64 managed endpoints are selected with host diversity and a small unmeasured allocation. HTTP reachability is not announce success. Unsupported proxy routes never fall back to direct probes; UDP probing is skipped with a configured proxy. Public supplements are added only when the engine positively reports `privateTorrent=false`; new metadata requests explicitly suppress inherited global trackers. Task snapshots retain only SHA-256 address fingerprints, bound to the torrent hash, for positively app-added supplements. Replacement may retire those supplements while retaining original/manual/unknown entries; legacy unowned addresses are never guessed. Original torrent/magnet trackers remain engine-owned.

`DownloadActivity` is part of the existing Codable task snapshot, not a new SwiftData entity. New optional snapshot keys decode with defaults. It retains 256 state observations and at most 96 chart samples per task, compacting to 72 while preserving endpoints, peaks and recent state boundaries. Summary counters are independent of chart compaction. Reconnects, clock discontinuities and long observation gaps are represented explicitly; average speed covers observed active intervals, not reconstructed historical traffic. `DownloadActivityView` renders the disclosure in Details → Overview.

`Scripts/check-boundaries.py` checks the new policy/application/view import boundaries. `Scripts/test-domain-policies.py` compiles and executes the actual Foundation-only receipt and bandwidth sources without launching an application or using a network connection. Hosted XCTest, UI and real-network checks still require the disposable test host described in Development.md.

## Test composition

`Configuration/UITestScenario.swift` is compiled into the app and UI runner as their shared launch protocol. The app composition root constructs fresh-install, installed-empty and installed-task stores explicitly. `DownloadStore` accepts an optional initial installation snapshot through initialization (production defaults to no snapshot and unchecked setup); it owns subsequent setup transitions and does not read UI fixture flags or construct sample tasks. Fixtures are deterministic and do not launch an engine. UI shard inventory must cover every test class/method exactly once.
