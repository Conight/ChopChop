#!/usr/bin/env bash
# The same coverage runs sequentially on a VM or in four isolated CI lanes.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
. "$repo_root/Scripts/test-host-policy.sh"
chopchop_require_disposable_test_host
lane=all
package_dir=""
dmg_name=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lane) [[ $# -ge 2 ]] || exit 2; lane="$2"; shift 2 ;;
        --package) [[ $# -ge 3 ]] || exit 2; package_dir="$2"; dmg_name="$3"; shift 3 ;;
        *) echo 'Usage: Scripts/verify.sh [--lane native|keyboard-a|keyboard-b|integration] [--package OUTPUT_DIRECTORY DMG_NAME]' >&2; exit 2 ;;
    esac
done
case "$lane" in all|native|keyboard-a|keyboard-b|integration) ;; *) echo 'Invalid verification lane' >&2; exit 2 ;; esac
[[ -z "$package_dir" || "$lane" == all ]] || { echo '--package requires the complete verification gate' >&2; exit 2; }
export PYTHON="${PYTHON:-$(command -v python3.14 || command -v python3)}"
owns_validation_root=false
if [[ -n "${CHOPCHOP_VALIDATION_ROOT:-}" ]]; then
    validation_root="$CHOPCHOP_VALIDATION_ROOT"
    mkdir -p "$validation_root"
else
    mkdir -p "$HOME/Library/Caches"
    validation_root="$(mktemp -d "$HOME/Library/Caches/chopchop-verification.XXXXXX")"
    owns_validation_root=true
fi
export TMPDIR="$validation_root/tmp/"
export CHOPCHOP_DERIVED_DATA="$validation_root/DerivedData"
test_derived_data="$CHOPCHOP_DERIVED_DATA"
if [[ "${CI:-false}" != true ]]; then test_derived_data="$repo_root/DerivedData"; fi
mkdir -p "$TMPDIR"
test_results="${CHOPCHOP_TEST_RESULTS_DIR:-$validation_root/results}"
mkdir -p "$test_results"
timings="$test_results/timings.tsv"
printf 'Stage\tSeconds\tExit status\n' > "$timings"
cleanup() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            printf '### Verification: %s\n\n| Stage | Seconds | Exit status |\n|---|---:|---:|\n' "$lane"
            tail -n +2 "$timings" | while IFS=$'\t' read -r stage seconds status; do
                printf '| %s | %s | %s |\n' "$stage" "$seconds" "$status"
            done
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    "$PYTHON" Scripts/cleanup-verification.py "$validation_root" || true
    if [[ "$test_derived_data" != "$CHOPCHOP_DERIVED_DATA" ]]; then
        "$PYTHON" Scripts/cleanup-verification.py "$validation_root" --derived-data "$test_derived_data" || true
    fi
    if $owns_validation_root; then rm -rf "$validation_root"; fi
}
trap cleanup EXIT
stage() {
    local label="$1" started=$SECONDS status=0
    shift
    printf '::group::%s\n' "$label"
    "$@" || status=$?
    printf '%s\t%s\t%s\n' "$label" "$((SECONDS - started))" "$status" >> "$timings"
    printf '::endgroup::\n'
    return "$status"
}
# Install/check only the tools a lane actually uses.
"$PYTHON" - "$lane" <<'PYVERSIONS'
import json, re, subprocess, sys
from pathlib import Path
lane = sys.argv[1]
tools = ['python']
if lane in ('all', 'native'): tools += ['node']
if lane in ('all', 'integration'): tools += ['ffmpeg', 'ffprobe']
versions = json.loads(Path('Scripts/verification-tools.json').read_text())
for tool in tools:
    executable = sys.executable if tool == 'python' else tool
    result = subprocess.run([executable, '--version' if tool in ('node', 'python') else '-version'], check=True, capture_output=True, text=True)
    actual = re.search(r'\d+\.\d+\.\d+', result.stdout).group()
    if actual != versions[tool]:
        raise SystemExit(f'{tool} {versions[tool]} required; found {actual}. See Documentation/Development.md.')
PYVERSIONS
if [[ "$lane" == all || "$lane" == native ]]; then
    stage localizations "$PYTHON" Scripts/check-localizations.py
    stage boundaries "$PYTHON" Scripts/check-boundaries.py
    stage domain-policies "$PYTHON" Scripts/test-domain-policies.py
    stage release-configuration "$PYTHON" Scripts/test_release_config.py
    stage engine-fixtures "$PYTHON" Scripts/test_engine_fixture.py
    stage media-fixtures "$PYTHON" Scripts/test_media_fixture.py
    stage local-host-policy "$PYTHON" Scripts/test_local_test_policy.py
    stage ci-policy "$PYTHON" Scripts/test_ci_policy.py
    stage browser-extension node --test Scripts/test-browser-extension.mjs
    CHOPCHOP_DERIVED_DATA="$test_derived_data" stage unit Scripts/check.sh unit -testLanguage en -testRegion US -resultBundlePath "$test_results/unit.xcresult" 2>&1 | tee "$validation_root/unit.log" "$test_results/unit.log"
    CHOPCHOP_DERIVED_DATA="$test_derived_data" stage layout Scripts/check.sh layout -testLanguage zh-Hans -testRegion CN -resultBundlePath "$test_results/layout.xcresult" 2>&1 | tee "$validation_root/layout.log" "$test_results/layout.log"
fi
if [[ "$lane" == all || "$lane" == keyboard-* ]]; then
    keyboard_mode="$lane"
    if [[ "$lane" == all ]]; then keyboard_mode=keyboard; fi
    # Each shard keeps both iterations. Separate hosts avoid macOS focus races.
    CHOPCHOP_DERIVED_DATA="$test_derived_data" stage "$keyboard_mode" Scripts/check.sh "$keyboard_mode" -testLanguage en -testRegion US -parallel-testing-enabled NO -test-iterations 2 -resultBundlePath "$test_results/keyboard.xcresult" 2>&1 | tee "$validation_root/keyboard.log" "$test_results/keyboard.log"
fi
if [[ "$lane" == all || "$lane" == integration ]]; then
    stage http-bittorrent "$PYTHON" -u Scripts/smoke-aria2-next.py
    stage media "$PYTHON" -u Scripts/smoke-media.py
    stage release Scripts/check.sh release
    stage updater "$PYTHON" -u Scripts/smoke-app-update.py
    stage release-bundle "$PYTHON" Scripts/verify-release-app.py --development "$CHOPCHOP_DERIVED_DATA/Build/Products/Release/ChopChop Dev.app"
fi
if [[ -n "$package_dir" ]]; then
    stage dmg Scripts/create-dmg.sh --output-dir "$package_dir" --dmg-name "$dmg_name"
fi
