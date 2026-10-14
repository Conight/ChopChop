#!/usr/bin/env python3
"""Remove only sandbox test folders identified by host PIDs in this run's logs.

Also unregister this run's temporary apps before its build directory is removed.
Does not inspect or remove installed applications or production support directories.
"""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

from release_config import load

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=pathlib.Path, help='Directory containing this run\'s logs')
parser.add_argument('--derived-data', type=pathlib.Path, help='Actual Xcode build directory, if separate from the logs')
args = parser.parse_args()
root = args.root.resolve()
if not root.is_dir() or root == pathlib.Path('/') or root == pathlib.Path.home():
    sys.exit('Expected a dedicated verification directory')

pids = set()
for log in root.glob('*.log'):
    pids.update(re.findall(r'\bChopChop\[(\d+):', log.read_text(errors='replace')))
identifier = load()['CHOPCHOP_APP_IDENTIFIER'] + '.dev'
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
derived_data = (args.derived_data or pathlib.Path(os.environ.get('CHOPCHOP_DERIVED_DATA', root / 'DerivedData'))).resolve()
products = derived_data / 'Build/Products'
unregistered = 0
already_absent = 0
failed = 0
if register.is_file():
    # Only direct Xcode products with our identifiers; never follow links to an
    # installed app or walk an arbitrary directory looking for app bundles.
    for app in products.glob('*/*.app'):
        if app.is_symlink() or not app.resolve().is_relative_to(products):
            continue
        try:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        except (OSError, ValueError):
            continue
        if info.get('CFBundleIdentifier') not in (identifier, identifier + 'UITests.xctrunner'):
            continue
        result = subprocess.run([str(register), '-u', str(app)], check=False, capture_output=True)
        if result.returncode == 0:
            unregistered += 1
        elif re.search(rb': -10814(?:\r?\n|$)', result.stderr):
            # kLSApplicationNotFoundErr: an unlaunched XCTest runner may never
            # have been registered. There is no registration left to remove.
            already_absent += 1
        else:
            failed += 1
            print(f'Could not unregister {app}', file=sys.stderr)
print(f'Cleaned {removed} isolated test support directories; unregistered {unregistered} temporary apps ({already_absent} already absent, {failed} failures).')
print('Launch Services cleanup does not reset Local Network privacy records.')
if failed:
    sys.exit(1)
