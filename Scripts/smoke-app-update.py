#!/usr/bin/env python3
"""Isolated updater integration: signed fixture apps, detached worker, local HTTP. No UI input."""
import contextlib
import hashlib
import json
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parent.parent
ENV = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], env=ENV, check=True, **kwargs)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        try:
            if self.path == '/checksum':
                data = (hashlib.sha256(b'A' * 1048576).hexdigest() + '  ChopChop-v1.0.0-beta.2-macos-arm64.dmg\n').encode()
                self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
                return
            self.send_response(404 if self.path == '/not-found' else 200)
            size = 1048576
            if self.path == '/chunked': self.send_header('Transfer-Encoding', 'chunked')
            else: self.send_header('Content-Length', str(size + 1 if self.path == '/oversized' else size))
            self.end_headers()
            for n in range(16 if self.path != '/short' else 2):
                chunk = b'A' * 65536
                self.wfile.write((b'10000\r\n' + chunk + b'\r\n') if self.path == '/chunked' else chunk)
                self.wfile.flush()
                if self.path in ('/slow', '/paced'): time.sleep(.1)
            if self.path == '/chunked': self.wfile.write(b'0\r\n\r\n')
        except (BrokenPipeError, ConnectionResetError): pass

@contextlib.contextmanager
def workspace():
    with tempfile.TemporaryDirectory(prefix='app-update-smoke-', dir=os.environ.get('CHOPCHOP_VALIDATION_ROOT')) as temp:
        yield Path(temp).resolve()

def main():
    with workspace() as root:
        # Use exactly the shared production implementation; no network or installer substitutes.
        sources = ['AppVersion', 'AppUpdatePackage', 'AppUpdateTransfer', 'AppUpdateInstallation', 'EngineRelease', 'EngineDownload']
        run('xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', root/'cache',
            *(REPO/'ChopChop'/f'{name}.swift' for name in sources), REPO/'Scripts/AppUpdateSmoke.swift', '-o', root/'smoke')
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try: run(root/'smoke', 'transfer', f'http://127.0.0.1:{server.server_port}', root)
        finally: server.shutdown(); server.server_close()
        if requested := os.environ.get('CHOPCHOP_VERIFY_RELEASE_DOWNLOAD'):
            release = json.loads(requested)
            run(root/'smoke', 'download-release', release['version'], release['size'], release['sha256'], root/'published-release')
        fixture_source = root/'fixture.swift'
        fixture_source.write_text('import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.prohibited)\napp.run()\n')
        run('xcrun', 'swiftc', '-module-cache-path', root/'cache', fixture_source, '-o', root/'fixture')
        failing_source = root/'failing.swift'; failing_source.write_text('import Darwin\nexit(1)\n')
        run('xcrun', 'swiftc', '-module-cache-path', root/'cache', failing_source, '-o', root/'failing')
        helper = Path(os.environ['CHOPCHOP_DERIVED_DATA'])/'Build/Products/Release/ChopChop.app/Contents/XPCServices/EngineInstaller.xpc'
        if not helper.exists(): raise RuntimeError('Build Release before running updater smoke tests')
        for mode in ('success', 'rollback', 'tamper', 'resume', 'waiting', 'worker', 'worker-failure'):
            case = root/mode; case.mkdir()
            public_key = run(root/'smoke', 'key', case/'key', capture_output=True, text=True).stdout.strip()
            for version, app in [('1.0.0-beta.1', case/'ChopChop.app'), ('1.0.0-beta.2', case/'.ChopChop-update-00000000-0000-4000-8000-000000000001/ChopChop.app')]:
                (app/'Contents/MacOS').mkdir(parents=True)
                (app/'Contents/Resources').mkdir()
                shutil.copy2(root/('failing' if mode == 'worker-failure' and version.endswith('2') else 'fixture'), app/'Contents/MacOS/ChopChop')
                shutil.copytree(helper, app/'Contents/XPCServices/EngineInstaller.xpc')
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.conight.ChopChop', CFBundleExecutable='ChopChop', CFBundleName='ChopChop Update Test', CFBundlePackageType='APPL', CFBundleVersion='2' if version.endswith('2') else '1', CFBundleShortVersionString='1.0.0', ChopChopReleaseVersion='v'+version, ChopChopUpdatePublicKey=public_key, LSMinimumSystemVersion='26.5', LSUIElement=True)))
                run('codesign', '--force', '--sign', '-', '--options', 'runtime', app, capture_output=True)
            (case/'user-data').write_text('untouched')
            try: run(root/'smoke', mode, case, timeout=90)
            finally:
                subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(case/'ChopChop.app')], capture_output=True)
        payload = root/'payload'; payload.mkdir()
        shutil.copytree(root/'success/ChopChop.app', payload/'ChopChop.app')
        dmg = root/'ChopChop-v1.0.0-beta.2-macos-arm64.dmg'
        manifest = root/'ChopChop-v1.0.0-beta.2-update.json'
        run('hdiutil', 'create', '-srcfolder', payload, '-format', 'UDZO', dmg, capture_output=True)
        signing_env = dict(ENV, CHOPCHOP_UPDATE_PRIVATE_KEY=(root/'success/key').read_text(), CHOPCHOP_VALIDATION_ROOT=str(root))
        subprocess.run([str(REPO/'Scripts/sign-update-dmg.sh'), str(dmg), str(manifest)], env=signing_env, check=True)
        run(root/'smoke', 'verify-signed', root/'success/key', manifest, dmg)
        print('App updater integration passed; disposable files removed.')

if __name__ == '__main__': main()
