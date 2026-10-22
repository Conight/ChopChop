#!/usr/bin/env python3
"""Compile/run pure Foundation policy checks: no app, XCTest host, or network use."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
environment = dict(os.environ)
environment["DEVELOPER_DIR"] = subprocess.check_output(["sh", str(ROOT / "Scripts/xcode-environment.sh"), "--print-xcode-directory"], text=True, env=environment).strip()
with tempfile.TemporaryDirectory(prefix='chopchop-domain-checks-') as directory:
    executable = str(Path(directory) / 'domain-checks')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(ROOT / 'ChopChop/BrowserReceipts.swift'), str(ROOT / 'ChopChop/EffectiveBandwidth.swift'),
                    str(ROOT / 'Scripts/DomainPolicyChecks.swift'), '-o', executable], check=True, env=environment)
    subprocess.run([executable], check=True, env=environment)
