# Menu bar transfer speeds

Reviewed against Apple's documentation on **2026-10-23**.

Settings → General → Menu bar display offers **Icon only**, **Speed only**, and **Icon and speed**. Show in menu bar controls visibility independently, so hiding and showing the item preserves the selected mode. Existing installations default to Icon only. The optional SwiftData raw value falls back to that mode when absent or unrecognized.

Speed modes show download above upload, with direction arrows and localized byte-per-second units. Compact labels use three significant digits and promote rounded values at unit boundaries; tooltips and accessibility retain the app's full localized rate descriptions. These are **ChopChop engine transfer rates**, including upload-only seeding, rather than whole-Mac network-interface measurements. A connected idle engine shows zero. A stopped engine or failed RPC refresh shows a dash in both directions.

## System menu bar scene

The application declares one [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) alongside its ordinary windows and uses `.menuBarExtraStyle(.window)`. Apple's documentation recommends this style for complex, data-rich extras containing standard controls. Its [WWDC introduction](https://developer.apple.com/videos/play/wwdc2022/10061/) describes using it alongside ordinary app scenes and while the app is not frontmost. The existing `MenuBarPanel` supplies its live transfer metrics, bandwidth controls and actions.

This replaces the manually managed `NSStatusItem` → `NSPopover` presenter. Removing its unconditional app activation alone did not fix the reported case: **another app occupies a native full-screen Space, its automatically hidden menu bar is revealed, and clicking ChopChop fails to show the panel**. The system menu bar scene now owns the window, anchor, presentation and dismissal. The app does not patch private popover windows, change its Dock activation policy, add artificial delays or create elevated overlay windows.

The insertion binding reads and writes `preferences.showMenuBar`, including system removal of the extra. It ignores writebacks matching the current preference: SwiftUI can report the current insertion value during scene updates, and saving that same value again would repeatedly invalidate the scene graph. The scene uses a constant false binding during hosted test automation, preserving the existing test isolation. The renderer, display-mode preference, transfer sampling and panel actions are independent of the presentation host. SwiftUI owns the item's placement persistence; the former custom `ChopChopMenuBar` AppKit autosave name is no longer used, so a person may need to reposition the new item once.

Show Downloads and Add use the existing window presenter to activate the app for an explicit window request. Settings activates the app after opening its window. Merely opening the menu bar panel does not explicitly activate the regular application.

## Label design and observation

- [Bjango's menu bar guidance](https://bjango.com/articles/designingmenubarextras/) describes the 22pt working area, 16pt icons and template tinting. [Stats' speed widget](https://github.com/exelban/stats/blob/master/Kit/Widgets/Speed.swift) provides an example of compact two-row typography. ChopChop uses a 16pt brand icon and draws both speed rows together in a 20pt template image, keeping the entire label centered.
- [Monospaced system digits](https://developer.apple.com/documentation/appkit/nsfont/monospaceddigitsystemfont(ofsize:weight:)) prevent numbers changing glyph widths. Separate direction, number and unit columns reserve the width needed by compact localized counts and units. Regular-weight digits and slightly smaller units reduce visual weight. Core Text glyph bounds center each row's actual artwork. These typography choices are app decisions, not a layout prescribed by Apple.
- The [resolution-independent NSImage drawing handler](https://developer.apple.com/documentation/appkit/nsimage/init(size:flipped:drawinghandler:)) captures immutable drawing inputs and produces a template for the system tint. The SwiftUI label exposes the app name, full live rate accessibility value and tooltip in all display modes.
- `MenuBarStatusLabel` reads a snapshot of the same observable `DownloadStore` used by in-app metrics. SwiftUI tracks the properties read by the snapshot. Icon-only and hidden modes do not read changing rates. The former manual observation adapter, queued callbacks and generation bookkeeping have been removed with their presenter.

## Refresh and ownership

`ChopChopApp.swift` includes `ChopChopMenuBarScene` alongside its ordinary windows. `MenuBarStatus.swift` owns that scene, its visibility binding, presentation snapshot, observed label and template composition. `MenuBarPanel.swift` owns the panel's contents. `PreferencesStore.swift` owns the mode enum; `PersistentSettingsStore.swift` owns disk persistence. General settings and settings search expose the same preference.

There is no second timer, RPC client or network monitor. The existing engine polling policy uses one-second sampling for active transfers while visible speed text is requested, including when the Downloads window is closed. Icon-only/hidden modes retain the existing background cadence; idle reconciliation and failure backoff remain unchanged. Changing menu-bar preferences wakes the existing poll loop to apply the new cadence.

## Verification

Regressions cover idempotent system insertion writebacks, settings-to-scene visibility changes, disk reopen and unknown/missing mode defaults, migration from an older SwiftData schema, global download/upload rates, idle versus disconnected output, negative-rate clamping, and visibility/mode gating. Image tests verify template rendering, the system's maximum artwork height, fixed width across byte-unit boundaries and centered visible artwork at 1× and 2×, without exporting screenshot files. The obsolete custom-presenter lifecycle tests were removed with that implementation. Refresh-policy checks preserve background, idle and failure behavior. The settings UI regression exercises all three picker choices and preserves the selection across hiding/showing.

Hosted native/UI tests run only on CI or a disposable VM. Personal Macs build and launch the fixed-path, development-signed Dev app for manual testing. Build success alone does not establish WindowServer behavior. Check the normal Dev app in these actual scenarios:

1. Put another app in native full screen, reveal the top menu bar and click ChopChop. Confirm the panel appears over that app without switching to the desktop.
2. Use the limit menu and buttons; dismiss with Escape, an outside click and a second click on the icon. Open it repeatedly.
3. Explicitly open Downloads and Settings from the panel, including after the Downloads window has been closed or minimized.
4. Repeat in ChopChop's own full-screen window and on a second display's full-screen Space.

On 2026-10-23, the user confirmed that the updated Dev panel opens normally from the revealed menu bar while another app is in native full screen. This verifies the reported failure scenario with the system menu bar scene.
