#!/usr/bin/env python3
"""Lint Actions expressions and shell snippets with a pinned, verified actionlint."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
configuration = json.loads((ROOT / 'Scripts/actionlint-release.json').read_text())
machine = {'x86_64': 'amd64', 'arm64': 'arm64', 'aarch64': 'arm64'}.get(platform.machine())
target = f'{platform.system().lower()}_{machine}'
if target not in configuration['sha256']:
    raise SystemExit('Workflow lint supports the Linux CI runner and Apple Silicon development host')
filename = f'actionlint_{configuration["version"]}_{target}.tar.gz'
with tempfile.TemporaryDirectory(prefix='chopchop-workflow-lint-') as directory:
    archive = Path(directory) / filename
    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2',
                    '--max-time', '60', f'https://github.com/rhysd/actionlint/releases/download/v{configuration["version"]}/{filename}',
                    '--output', str(archive)], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != configuration['sha256'][target]:
        raise SystemExit('actionlint SHA-256 differs from the pinned release')
    with tarfile.open(archive) as package:
        data = package.extractfile('actionlint').read()
    executable = Path(directory) / 'actionlint'
    executable.write_bytes(data)
    executable.chmod(0o755)
    subprocess.run([str(executable), '-shellcheck=', '-pyflakes='], cwd=ROOT, check=True)
print('Workflow structure and expressions passed actionlint.')
