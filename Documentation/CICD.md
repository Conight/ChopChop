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
- `keyboard-a` and `keyboard-b`: complementary sets of the existing 11 keyboard/window regressions. Each still runs **twice**, with native parallel testing disabled. The two sets run on different macOS hosts, so they do not compete for window focus or the pasteboard.
- `integration`: real HTTP/BitTorrent and HLS/DASH downloads, hardened Dev Release verification, and real updater/termination fixtures.

`Scripts/keyboard-tests.json` contains the shared selections. They were balanced using both iterations' measured durations: 256 seconds and 253 seconds of UI execution on the baseline runner. A regression test checks that their union is exactly the original selection, without duplicates. This splits execution across hosts rather than reducing coverage or repetitions.

`CI / test` remains the final check. It fails when any verification job fails, is cancelled, or is skipped. Superseded main/PR runs are still cancelled. A matrix failure does not cancel its siblings, preserving their diagnostics and allowing selective reruns.

Each lane installs only its required tools. Node is needed by `native`; FFmpeg is needed by `integration`. Test/tool versions and engine checksums remain pinned. No persistent DerivedData or executable cache is introduced. Each host starts with a clean build, and `-showBuildTimingSummary` supplies evidence for later compiler optimization.

`Scripts/verify.sh --lane NAME` exposes the same lanes on disposable hosts. Without `--lane`, it runs all coverage sequentially as before; `--package` still requires the full gate. The personal-Mac test-host policy and fixed local Dev build identity remain enforced.

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
