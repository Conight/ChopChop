#!/usr/bin/env bash
# Archive and package an Apple Silicon release without interacting with Finder.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_root/build/distribution"
app_path=""
dmg_name=""
python_bin="${PYTHON:-python3}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|--output-dir|--dmg-name)
            [[ $# -ge 2 ]] || { echo "error: $1 requires a value" >&2; exit 2; }
            case "$1" in
                --app) app_path="$2" ;;
                --output-dir) output_dir="$2" ;;
                --dmg-name) dmg_name="$2" ;;
            esac
            shift 2 ;;
        -h|--help)
            echo 'Usage: Scripts/create-dmg.sh [--app PATH.app] [--output-dir PATH] [--dmg-name NAME]'
            echo 'Requires Xcode 27 and Python 3.10+. Builds Release unless --app is supplied.'
            exit 0 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done
"$python_bin" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required; set PYTHON to its path"'
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/chopchop-dmg.XXXXXX")"
mount_point=""
cleanup() {
    if [[ -n "$mount_point" ]]; then hdiutil detach "$mount_point" -quiet || true; fi
    rm -rf "$temp_dir"
}
trap cleanup EXIT
if [[ -z "$app_path" ]]; then
    xcodebuild -project "$repo_root/ChopChop.xcodeproj" -scheme ChopChop \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$repo_root/build/ReleaseDerivedData" \
        -archivePath "$temp_dir/ChopChop.xcarchive" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 archive
    app_path="$temp_dir/ChopChop.xcarchive/Products/Applications/ChopChop.app"
fi
[[ -d "$app_path" && "$(basename "$app_path")" == ChopChop.app ]] || { echo 'error: expected ChopChop.app' >&2; exit 1; }
app_path="$(cd "$app_path" && pwd)"
"$python_bin" "$repo_root/Scripts/verify-release-app.py" "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
dmg_name="${dmg_name:-ChopChop-v$version-macos-arm64}"
[[ "$dmg_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { echo 'error: invalid DMG name' >&2; exit 2; }
final_dmg="$output_dir/$dmg_name.dmg"
[[ ! -e "$final_dmg" ]] || { echo "error: refusing to overwrite $final_dmg" >&2; exit 1; }

"$python_bin" -m venv "$temp_dir/venv"
"$temp_dir/venv/bin/python" -m pip install --disable-pip-version-check --require-hashes \
    -r "$repo_root/Scripts/Packaging/requirements.txt"
xcrun swift "$repo_root/Scripts/Packaging/DMGBackground.swift" "$temp_dir/background.png"
"$temp_dir/venv/bin/dmgbuild" -s "$repo_root/Scripts/Packaging/dmg-settings.py" \
    -D app="$app_path" -D background="$temp_dir/background.png" ChopChop "$temp_dir/$dmg_name.dmg"
hdiutil verify "$temp_dir/$dmg_name.dmg" -quiet
mount_point="$temp_dir/verify"
mkdir "$mount_point"
hdiutil attach "$temp_dir/$dmg_name.dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount_point" -quiet
"$python_bin" "$repo_root/Scripts/verify-release-app.py" "$mount_point/ChopChop.app"
[[ "$(readlink "$mount_point/Applications")" == /Applications ]] || { echo 'error: Applications link missing' >&2; exit 1; }
"$temp_dir/venv/bin/python" - "$mount_point" <<'PY'
from pathlib import Path
from ds_store import DSStore
import sys
root = Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'r') as store:
    assert store['ChopChop.app']['Iloc'] == (150, 178), 'App icon placement missing'
    assert store['Applications']['Iloc'] == (410, 178), 'Applications icon placement missing'
    assert store['.']['icvp']['backgroundType'] == 2, 'DMG background missing'
print('Verified drag-to-Applications layout metadata.')
PY
hdiutil detach "$mount_point" -quiet
mount_point=""
mv "$temp_dir/$dmg_name.dmg" "$final_dmg"
(cd "$output_dir" && shasum -a 256 "$dmg_name.dmg" > "$dmg_name.dmg.sha256")
echo "Created $final_dmg and SHA-256 checksum."
