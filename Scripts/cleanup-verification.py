#!/usr/bin/env python3
"""Remove only sandbox test folders identified by host PIDs in this run's logs.

Also unregister this run's temporary apps before its build directory is removed.
Does not inspect or remove installed applications or production support directories.
"""
import pathlib
import re
import shutil
import subprocess
import sys

from release_config import load

root = pathlib.Path(sys.argv[1]).resolve()
if not root.is_dir() or root == pathlib.Path('/') or root == pathlib.Path.home():
    sys.exit('Expected a dedicated verification directory')

pids = set()
for log in root.glob('*.log'):
    pids.update(re.findall(r'\bChopChop\[(\d+):', log.read_text(errors='replace')))
identifier = load()['CHOPCHOP_APP_IDENTIFIER']
temporary_bases = [pathlib.Path.home() / f'Library/Containers/{identifier}/Data/tmp']
try:
    temporary_bases.append(pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip()))
except subprocess.CalledProcessError:
    pass
removed = 0
for base in temporary_bases:
    for pid in pids:
        folder = base / f'ChopChopAutomation-{pid}'
        if folder.is_dir() and not folder.is_symlink():
            shutil.rmtree(folder)
            removed += 1
register = pathlib.Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
if register.is_file():
    for app in (root / 'DerivedData').rglob('*.app'):
        if app.name == 'ChopChop.app' and app.resolve().is_relative_to(root):
            subprocess.run([str(register), '-u', str(app)], check=False, capture_output=True)
print(f'Cleaned {removed} isolated test support directories and unregistered temporary apps.')
