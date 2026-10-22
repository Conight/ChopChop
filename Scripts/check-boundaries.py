#!/usr/bin/env python3
"""Keep domain policies, platform transport, and new views independently reviewable."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
policies = ('DownloadActivity.swift', 'EffectiveBandwidth.swift', 'BrowserReceipts.swift', 'TrackerSources.swift', 'TrackerDiagnostics.swift')
errors = []
for name in policies:
    text = (ROOT / 'ChopChop' / name).read_text()
    if re.search(r'^import (SwiftUI|AppKit|Combine|AppIntents)\b', text, re.M):
        errors.append(f'{name}: domain policy imports a UI framework')
for name in ('DownloadActivityView.swift', 'TemporaryBandwidthView.swift', 'TrackerDiagnosticsView.swift'):
    text = (ROOT / 'ChopChop' / name).read_text().split('extension DownloadStore {')[0]
    if re.search(r'\b(Aria2RPCClient|URLSession|FileManager)\b|engineController\.client\(', text):
        errors.append(f'{name}: view bypasses the application service')
for name in ('DownloadStoreBrowser.swift', 'DownloadStoreSubmission.swift'):
    if re.search(r'^import (SwiftUI|AppKit)\b', (ROOT / 'ChopChop' / name).read_text(), re.M):
        errors.append(f'{name}: application service imports a UI framework')
if errors:
    raise SystemExit('\n'.join(errors))
print('Domain, application-service and view boundaries passed.')
