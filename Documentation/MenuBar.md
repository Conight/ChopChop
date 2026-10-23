# Menu bar transfer speeds

Reviewed against Apple's current documentation on **2026-10-23**.

Settings → General → Menu bar display offers **Icon only**, **Speed only**, and **Icon and speed**. The existing Show in menu bar switch controls visibility independently, so hiding and showing the item preserves the selected mode. Existing installations default to Icon only. The optional SwiftData raw value also falls back to that mode when absent or unrecognized.

Speed modes show download above upload, with direction arrows and localized byte-per-second units. These are **ChopChop engine transfer rates**, including upload-only seeding; they are not whole-Mac network-interface measurements. A connected idle engine shows zero. A stopped engine or failed RPC refresh shows a dash in both directions, rather than continuing to show a previous successful sample. The tooltip and accessibility value use the full localized direction names.

## Official guidance and implementation choices

- [Apple's menu bar HIG](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras) reserves limited space for extras, lets people choose visibility, recommends template symbols for system appearance, and warns that the system can hide extras. The app keeps its existing visibility setting and template icon; Downloads and Settings remain accessible through ordinary windows and commands.
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) explicitly supports customizing its native button. [Its length property](https://developer.apple.com/documentation/appkit/nsstatusitem/length) supports both a fixed width and the system square length. The implementation retains the native status item and button, reuses that same item when modes change, and records its autosave name for position restoration.
- [Monospaced system digits](https://developer.apple.com/documentation/appkit/nsfont/monospaceddigitsystemfont(ofsize:weight:)) prevent numbers changing glyph widths. The two compact rows use right-aligned tab stops and reserve a width derived from localized counts and byte units. This two-row arrangement, typography, default mode and fixed width are implementation choices, not a layout prescribed by Apple. Actual native-button geometry is tested without exporting images.
- [AppKit accessibility values](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/setaccessibilityvalue(_:)) expose the live rates alongside the app label, including in speed-only mode. The status button retains native click, keyboard and highlighting behavior.
- [Observation tracking](https://developer.apple.com/documentation/observation/withobservationtracking(_:onchange:)) follows the same DownloadStore properties as the in-app metrics. The adapter reads committed values on the next main-actor turn, re-arms tracking and ignores callbacks from a replaced store. Hidden and icon-only modes do not observe changing speed samples. Equal snapshots do not repaint the button.

The HIG generally prefers a menu when an extra opens. Apple's [MenuBarExtra documentation](https://developer.apple.com/documentation/swiftui/menubarextra) explicitly allows a window-style surface for complex, data-rich controls. The existing panel includes live transfers, progress, bandwidth controls and actions, so it retains its popover. This feature does not require replacing the established AppKit integration with a SwiftUI scene.

## Refresh and ownership

`MenuBarStatus.swift` owns the presentation snapshot, observation adapter, native button formatting and status-item/popover lifecycle. `PreferencesStore.swift` owns the mode enum; `PersistentSettingsStore.swift` owns disk persistence. General settings and settings search expose the same preference.

There is no second timer, RPC client or network monitor. The existing engine polling policy uses one-second sampling for active transfers while visible speed text is requested, including when the Downloads window is closed. Icon-only/hidden modes retain the existing background cadence; idle reconciliation and failure backoff remain unchanged. Changing menu-bar preferences wakes the existing poll loop to apply the new cadence.

## Verification

Focused regressions verify disk reopen and unknown/missing mode defaults, migration from an older SwiftData schema, global download/upload rates, idle versus disconnected output, negative-rate clamping, preference/connection observation, recovery, removal and queued callbacks from replaced stores. A scoped native status item verifies all three modes, template images, accessibility values and two-row fit across byte-unit boundaries without screenshots. The refresh-policy checks preserve background, idle and failure behavior. A UI regression exercises all three picker choices and verifies that hiding and showing the item retains the selection. Existing Chinese and English settings layouts and the complete shared CI gate also run.
