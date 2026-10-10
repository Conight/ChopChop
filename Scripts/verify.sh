#!/usr/bin/env bash
# Shared CI/release gate. All disposable products live beneath one owned directory.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [[ $# != 0 && !( "${1:-}" == --package && $# == 3 ) ]]; then
    echo 'Usage: Scripts/verify.sh [--package OUTPUT_DIRECTORY DMG_NAME]' >&2
    exit 2
fi
export PYTHON="${PYTHON:-$(command -v python3.14 || command -v python3)}"
owns_validation_root=false
if [[ -n "${CHOPCHOP_VALIDATION_ROOT:-}" ]]; then
    validation_root="$CHOPCHOP_VALIDATION_ROOT"
    mkdir -p "$validation_root"
else
    # XPC may report /private-prefixed bundle paths for temporary-directory aliases.
    # Use a regular writable location, as required by the production installer.
    mkdir -p "$HOME/Library/Caches"
    validation_root="$(mktemp -d "$HOME/Library/Caches/chopchop-verification.XXXXXX")"
    owns_validation_root=true
fi
cleanup() {
    "$PYTHON" Scripts/cleanup-verification.py "$validation_root" || true
    if $owns_validation_root; then rm -rf "$validation_root"; fi
}
trap cleanup EXIT
export TMPDIR="$validation_root/tmp/"
export CHOPCHOP_DERIVED_DATA="$validation_root/DerivedData"
mkdir -p "$TMPDIR"
"$PYTHON" - <<'PY'
import json, re, subprocess, sys
from pathlib import Path
versions = json.loads(Path('Scripts/verification-tools.json').read_text())
for tool, expected in versions.items():
    executable = sys.executable if tool == 'python' else tool
    result = subprocess.run([executable, '--version' if tool in ('node', 'python') else '-version'], check=True, capture_output=True, text=True)
    actual = re.search(r'\d+\.\d+\.\d+', result.stdout).group()
    if actual != expected:
        raise SystemExit(f'{tool} {expected} required; found {actual}. See Documentation/Development.md.')
PY
"$PYTHON" Scripts/check-localizations.py
"$PYTHON" Scripts/test_release_config.py
"$PYTHON" Scripts/test_engine_fixture.py
node --test Scripts/test-browser-extension.mjs
Scripts/check.sh unit -testLanguage en -testRegion US 2>&1 | tee "$validation_root/unit.log"
Scripts/check.sh layout -testLanguage zh-Hans -testRegion CN 2>&1 | tee "$validation_root/layout.log"
"$PYTHON" Scripts/smoke-aria2-next.py
"$PYTHON" Scripts/smoke-media.py
Scripts/check.sh release
CHOPCHOP_VALIDATION_ROOT="$validation_root" "$PYTHON" Scripts/smoke-app-update.py
app="$CHOPCHOP_DERIVED_DATA/Build/Products/Release/ChopChop.app"
"$PYTHON" Scripts/verify-release-app.py "$app"
if [[ "${1:-}" == --package && $# == 3 ]]; then
    Scripts/create-dmg.sh --app "$app" --output-dir "$2" --dmg-name "$3"
fi
