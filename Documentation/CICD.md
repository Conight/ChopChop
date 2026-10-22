# CI/CD performance and release verification

Reviewed against the current GitHub Actions and Apple Xcode documentation on **2026-10-22**.

## Measured bottleneck

The successful beta.21 source verification ([CI run 39775879248](https://github.com/Conight/ChopChop/actions/runs/39775879248)) occupied one macOS runner for **21 minutes 52 seconds**. Its main verification step took 20 minutes 56 seconds. Logs show:

| Work | Measured duration |
| --- | ---: |
| Cold build, preparation and repeated keyboard/window tests | about 10 minutes |
| 477 English Swift tests (472 passed, five opt-in cases skipped) | 3 minutes 5 seconds of test execution |
| Chinese layout tests | 1 minute 57 seconds of test execution |
| Real HTTP/BitTorrent tests | about 1 minute 47 seconds |
| Real HLS/DASH tests | about 43 seconds |
| Hardened Dev Release build | about 1 minute 25 seconds |
| Updater/termination integration | about 1 minute 23 seconds |
| Tool setup / result upload | 36 seconds / seven seconds |

The tag's [release run](https://github.com/Conight/ChopChop/actions/runs/39775889898) repeated the entire suite for the same commit, then archived and checked the Distribution DMG. Serial test execution and duplicated verification dominate; dependency installation and uploads are smaller contributors.

## Implementation

`.github/workflows/verification.yml` provides one reusable gate. A small Ubuntu policy job validates workflows with checksum-pinned actionlint and exercises the release gate's trust/coverage rules. Four independent `xcode-27` jobs then run:

- `native`: localization/boundary/domain/fixture/browser checks, the complete English Swift suite, and Chinese layouts.
- `keyboard-a` and `keyboard-b`: complementary sets of 11 keyboard/window regressions, each run once with native parallel testing disabled. The two sets run on different macOS hosts, so they do not compete for window focus or the pasteboard.
- `integration`: real HTTP/BitTorrent and HLS/DASH downloads, hardened Dev Release verification, and real updater/termination fixtures.

`Scripts/keyboard-tests.json` contains the shared selections. They were initially balanced using the baseline durations. A regression test checks that their union contains every selected scenario, without duplicates. Repetition is now an explicit diagnostic option; state-transition coverage belongs inside the regression itself.

`CI / test` remains the final check. It fails when any verification job fails, is cancelled, or is skipped. Superseded main/PR runs are still cancelled. A matrix failure does not cancel its siblings, preserving their diagnostics and allowing selective reruns.

Each lane installs only its required tools. Node is needed by `native`; FFmpeg is needed by `integration`. Test/tool versions and engine checksums remain pinned. No persistent DerivedData or executable cache is introduced. Each host starts with a clean build, and `-showBuildTimingSummary` supplies evidence for later compiler optimization.

`Scripts/verify.sh --lane NAME` exposes the same lanes on disposable hosts. The separate `ui` lane runs the complete UI suite and is available through `gh workflow run ci.yml --ref main -f suite=ui`. Manual runs cannot be used as release proof; normal push/PR and release fallback always use the complete four-lane verification gate. Without `--lane`, it runs all coverage sequentially as before; `--package` still requires the full gate. The personal-Mac test-host policy and fixed local Dev build identity remain enforced.

## Test design audit

The first CI optimization changed scheduling. A subsequent audit inspected the native/UI test sources and per-case execution times, including [run 39792531102](https://github.com/Conight/ChopChop/actions/runs/39792531102). Its native lane took 7m10s, and UI lanes took 7m03s / 6m31s. The English suite itself took 183.3 seconds; Chinese layouts took 113.7 seconds. The tests, not tool installation, contained avoidable work:

| Design problem | Evidence | Replacement |
| --- | --- | --- |
| Screenshot export mixed with geometry assertions | Settings case took 44.1s English / 42.8s Chinese, recreated each pane separately for top/bottom, slept 650ms, and encoded multiple PNGs with no baseline comparison | Explicit geometry contracts, one mounted pane for both scroll positions, AppKit layout, no PNG output |
| Frame sampling used to infer that a window never moved | Screen-edge case took about 27.5s per language, sampling 30 frames on opening and 30 on closing for every permutation | Observe all move/resize notifications throughout presentation and dismissal; retain final sidebar/panel geometry assertions |
| Expensive rendering used as synchronization | Transfer-row case took 14.1s; every data sample slept 150ms and rasterized the view | Drain observation work and request layout; retain every rate, size, protocol and phase boundary assertion |
| Preview output presented as regression coverage | Hover/discovery/shared-transfer previews had no relevant behavioral assertion; two update-view cases only checked the assigned window size | Remove these cases and the opt-in full preview exporter; retain actual hover hit-testing, discovery state, transfer formatting, update progress/control and final-paragraph assertions |
| Broad UI repetition substituted for a specific failure contract | All 11 scenarios ran twice; the launch case already performs four explicit exit/relaunch transitions inside each execution | One execution per scenario, with repetitions available for diagnosis and existing state transitions intact |
| Locator fallback delays and hidden selector failures | Helpers tried several element types/labels with one-second waits; Settings opening first waited two seconds for a window expected to be absent | One accessibility-ID query with a readiness assertion at the call site; use the Settings shortcut directly |

The audit covers the entire native suite, the UI harness and the real integration scripts. Fast domain, persistence, RPC-envelope, retry, privacy, cancellation and service tests retain their assertions. Most already use injected clients, fixed dates or controlled continuations. There is no evidence that replacing the download engine, migrating every test framework, or splitting production modules would fix the measured cost, so those changes are not justified by this investigation.

The removed cases are `testExportDesignPreviews`, `testPieceGridHoverEdgesAndIdleAppearance`, `testTorrentDiscoveryShowsConnectionsAndKeepsRetryVisibleInCompactSheet`, `testNetworkAndListRenderSharedTransferSamples`, `testUpdateWindowRendersLongNotesAtMinimumSizeInBothAppearances`, `testDownloadedInstallerLayoutFitsMinimumWindow`, `testEngineVersionPickerFitsCompactSetupAndSettings`, and `testManagedEngineSettingsFitRunningPendingRestartAndFailureStates`. The last two repeated generic fixture checks without asserting the state named by the test. Picker size stability remains tested through refresh; release-list selection, settings application, update failure and retry remain covered by dedicated service tests. The background-download termination preference check moved to `MacIntegrationTests` so it isn't repeated for localization. The empty UI launch test class was removed.

All native tests were inventoried by their assertions and the slowest cases were inspected against the logs. The layout synchronization infrastructure has regressions of its own: changed model widths must be visible before geometry is read, and a move followed immediately by restoration must still be observed. These protect against replacing a slow test with a fast false positive. Actual progress-animation sampling and pixel assertions remain where elapsed time or pixels are the behavior being checked.

Validation and measured timings are recorded after the refactored suite runs on disposable CI. A smaller test count is not itself a performance or quality claim; removed weak checks and retained behavior are documented above.

Current Apple documentation recommends removing the smallest relevant coupling to enable focused tests, rather than broad speculative rewrites. Apple's test-architecture guidance separates fast rules, subsystem integration and a small end-to-end layer. Its reliability guidance prefers awaited work to guessed delays and treats repetition as a deliberate reliability/diagnostic choice. AppKit explicitly supports requesting layout before examining geometry:

- [Apple: updating an existing codebase to accommodate unit tests](https://developer.apple.com/documentation/xcode/updating-your-existing-codebase-to-accommodate-unit-tests)
- [Apple: Testing Tips & Tricks](https://developer.apple.com/videos/play/wwdc2018/417/)
- [Apple: author fast and reliable tests](https://developer.apple.com/videos/play/wwdc2022/110361/)
- [Apple: NSView.layoutSubtreeIfNeeded](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded())

## Release promotion

The release starts with a read-only Ubuntu job, not an idle macOS runner. `Scripts/ci_gate.py` searches the repository's `ci.yml` workflow for **the exact checked-out commit**, an event of `push`, and branch `main`. It also verifies the repository/head repository, workflow path, current run record, paginated job history with the latest execution of each job, every required lane, and the successful final `test` check.

- A successful complete run is reused.
- An in-progress run is awaited for at most 30 minutes.
- If no matching run appears within a one-minute registration grace, or the run was cancelled/skipped, the same reusable verification gate runs independently.
- A failed/incomplete result, API failure, or wait timeout blocks publication.

Fallback verification and packaging check out the resolved commit explicitly. An annotated release tag must still point to that commit, have committed English notes, and match the actual Distribution marketing version. The release rebuilds Distribution from source, checks the application and mounted DMG, packages the extension, verifies checksums, and signs the update manifest in its existing isolated secret-bearing step.

Only **verification evidence** is reused. No PR-produced executable, CI artifact, cache, or download output is promoted into the signing job. An arbitrary successful workflow, another SHA, a fork, a PR run, a missing lane, or an older successful run shadowed by a newer failed attempt cannot authorize a release.

Use `gh workflow run release.yml --ref main` for a packaging rehearsal. It checks/waits for the same main commit's CI, generates a distinct `v<marketing-version>-ci.<run-number>` package, verifies the mounted DMG and checksums, and retains the outputs for three days. This dispatch path **does not access the update signing key or publish a GitHub Release**. The public version/build and existing releases are unchanged.

## Measurement and expected improvement

Every verification phase writes `timings.tsv`, a live log group and a GitHub job summary, including its exit status. Xcode additionally reports build-task timings. Logs, results and screenshots are retained for seven days in separately named lane artifacts, with compression level 1 for mixed text/xcresult content. Rehearsal DMGs use level 0 because further compression adds little value.

Based on the baseline, the expected critical path is roughly **6–8 minutes for CI**, followed by approximately **2–3 minutes for packaging** when exact-SHA CI is already successful. These are estimates, not a promised SLA: runner allocation, cold builds and UI timings vary. Compare the complete workflow's elapsed time and lane summaries after the first optimized run; do not add together parallel jobs' durations. Total runner minutes and artifact size should also be observed. Four simultaneous Mac jobs leave headroom under the usual five-Mac account limit.

## Official sources

- [GitHub: matrix job variations and failure handling](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations)
- [GitHub: reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [GitHub: current concurrency limits](https://docs.github.com/en/actions/reference/limits)
- [GitHub: workflow-job REST API and rerun history](https://docs.github.com/en/rest/actions/workflow-jobs)
- [GitHub: workflow-run REST API and filters](https://docs.github.com/en/rest/actions/workflow-runs?apiVersion=2026-03-10)
- [GitHub: privileged workflow_run warning](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run). This implementation avoids a new privileged `workflow_run` trigger and does not execute downloaded CI artifacts.
- [GitHub: cache versus artifact guidance and cache trust](https://docs.github.com/en/actions/concepts/workflows-and-actions/dependency-caching)
- [actions/upload-artifact: compression controls](https://github.com/actions/upload-artifact#altering-compressions-level-speed-v-size)
- [Apple: measure before optimizing builds; build timing summaries](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds)
- [Apple: parallel testing options](https://help.apple.com/xcode/mac/current/en.lproj/dev6061748b5.html)
- [Apple: separating build-for-testing and test-without-building](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions). Cross-host test-bundle transfer is a possible later optimization if cold builds become the dominant measured cost; this change keeps independent clean builds.
