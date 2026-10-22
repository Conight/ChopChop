#!/usr/bin/env python3
"""Produce a deterministic source-only MV3 ZIP for Chrome/Edge store review."""
import argparse, hashlib, json, zipfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--output-dir', type=Path, default=ROOT / 'build/browser-extension')
args = p.parse_args()
source = ROOT / 'BrowserExtension'
manifest = json.loads((source / 'manifest.json').read_text())
assert manifest['manifest_version'] == 3
assert manifest['host_permissions'] == ['http://127.0.0.1/*']
assert 'cookies' not in manifest['permissions']
files = sorted(f for f in source.rglob('*') if f.is_file() and f.suffix in ('.json', '.js', '.html', '.css', '.png') and f.name != 'package.json')
assert all(not f.is_symlink() and f.stat().st_size <= 1024 * 1024 for f in files)
args.output_dir.mkdir(parents=True, exist_ok=True)
target = args.output_dir / f'ChopChop-Extension-{manifest["version"]}.zip'
with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for f in files:
        info = zipfile.ZipInfo(f.relative_to(source).as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o100644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, f.read_bytes())
checksum = hashlib.sha256(target.read_bytes()).hexdigest()
target.with_suffix('.zip.sha256').write_text(f'{checksum}  {target.name}\n')
print(target)
