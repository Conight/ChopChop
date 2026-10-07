#!/usr/bin/env python3
"""Download a pinned upstream test engine, then exercise it with local HTTP and disposable state.

No engine executable is kept in the repository or app. This CLI test runs a
temporary standalone copy; opt-in integration tests cover the app sandbox.
"""
import argparse
import hashlib
import http.server
import json
import pathlib
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = bytes(range(256)) * 32768
SECOND_PAYLOAD = b"a different same-name download\n" * 4096


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except ConnectionResetError:
            # Pausing a task deliberately closes its HTTP connection.
            pass

    def do_GET(self):
        payload = SECOND_PAYLOAD if self.path.startswith("/second") else PAYLOAD
        start, end = 0, len(payload) - 1
        requested_range = self.headers.get("Range")
        if requested_range:
            first, last = requested_range.removeprefix("bytes=").split("-", 1)
            start = int(first)
            if last:
                end = min(end, int(last))
        self.send_response(206 if requested_range else 200)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if requested_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
        self.end_headers()
        try:
            for offset in range(start, end + 1, 65536):
                self.wfile.write(payload[offset:min(offset + 65536, end + 1)])
                self.wfile.flush()
                time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for engine state")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-engine", type=pathlib.Path,
                        help="Also exercise migration from a saved 2.4.9 helper (only a temporary copy is re-signed)")
    previous_engine = parser.parse_args().previous_engine
    if previous_engine and not previous_engine.is_file():
        parser.error("--previous-engine must point to an existing executable")
    config = json.loads((ROOT / "Scripts/engine-test-release.json").read_text())
    version = config["version"]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    process = None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    token = uuid.uuid4().hex
    rpc_port = free_port()

    def rpc(method, *params):
        body = json.dumps({"jsonrpc": "2.0", "id": "smoke", "method": "aria2." + method,
                           "params": ["token:" + token, *params]}).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{rpc_port}/jsonrpc", data=body,
                                         headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=3) as response:
            result = json.load(response)
        if "error" in result:
            raise AssertionError(result["error"])
        return result["result"]

    with tempfile.TemporaryDirectory(prefix="chopchop-smoke-") as temporary:
        root = pathlib.Path(temporary)
        upstream = root / "upstream-engine"
        asset = f"aria2-next-{version}-macos-arm64"
        url = f"https://github.com/AnInsomniacy/aria2-next/releases/download/v{version}/{asset}"
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                        "--connect-timeout", "30", "--max-time", "180", url, "--output", str(upstream)], check=True)
        if hashlib.sha256(upstream.read_bytes()).hexdigest() != config["sha256"]:
            raise AssertionError("Upstream test engine SHA-256 differs from the pinned release")
        upstream.chmod(0o755)
        engine = root / "aria2-next"
        entitlements = root / "empty.plist"
        entitlements.write_bytes(plistlib.dumps({}))

        def install_test_copy(source):
            shutil.copy2(source, engine)
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                            "--entitlements", str(entitlements), str(engine)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        install_test_copy(previous_engine or upstream)
        downloads = root / "downloads"
        downloads.mkdir()
        session = root / "aria2.session"
        arguments = [str(engine), "--no-conf=true", "--enable-rpc=true", "--rpc-listen-all=false",
                     f"--rpc-listen-port={rpc_port}", f"--rpc-secret={token}",
                     f"--dir={downloads}", f"--state-dir={root / 'state'}",
                     f"--save-session={session}", "--save-session-interval=1",
                     "--state-save-interval=1", "--continue=true", "--split=1",
                     "--max-connection-per-server=1", "--enable-dht=false", "--bt-enable-lpd=false",
                     f"--listen-port={free_port()}", "--ed2k-listen-port=0", "--ed2k-udp-listen-port=0",
                     "--quiet=true", f"--log={root / 'engine.log'}"]

        def launch(resume=False):
            nonlocal process
            if resume and previous_engine:
                install_test_copy(upstream)
            launch_arguments = arguments
            if previous_engine and not resume:
                # 2.4.9 used per-file control data, predating the state database.
                launch_arguments = [arg for arg in arguments
                                    if not arg.startswith(("--state-dir=", "--state-save-interval="))]
            process = subprocess.Popen(launch_arguments + ([f"--input-file={session}"] if resume else []),
                                       cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

            def ready():
                if process.poll() is not None:
                    raise AssertionError(process.stderr.read().decode())
                try:
                    return rpc("getVersion")
                except (OSError, urllib.error.URLError):
                    return False

            result = wait_for(ready)
            assert result["version"] == ("2.4.9" if previous_engine and not resume else version), result

        def stop():
            rpc("shutdown")
            assert process.wait(timeout=10) == 0
            process.stderr.close()

        try:
            launch()
            url = f"http://127.0.0.1:{server.server_port}/payload.bin"
            gid = rpc("addUri", [url], {"out": "payload.bin"})
            wait_for(lambda: int(rpc("tellStatus", gid)["completedLength"]) >= 131072)
            rpc("forcePause", gid)
            wait_for(lambda: rpc("tellStatus", gid)["status"] == "paused")
            progress = int(rpc("tellStatus", gid)["completedLength"])
            assert 0 < progress < len(PAYLOAD)
            rpc("saveSession")
            assert f"gid={gid}" in session.read_text()
            stop()
            original_path = downloads / "payload.bin"
            original_partial = original_path.read_bytes()
            launch(resume=True)
            resumed = rpc("tellStatus", gid)
            if not previous_engine:
                assert int(resumed["completedLength"]) >= progress, resumed
            if resumed["status"] == "paused":
                rpc("unpause", gid)
            wait_for(lambda: rpc("tellStatus", gid)["status"] == "complete")
            downloaded = pathlib.Path(rpc("getFiles", gid)[0]["path"])
            expected = hashlib.sha256(PAYLOAD).digest()
            assert hashlib.sha256(downloaded.read_bytes()).digest() == expected
            if previous_engine:
                assert downloaded != original_path
                assert original_path.read_bytes() == original_partial
                print(f"PASS 2.4.9 migration: original GID retained; download restarted in {downloaded.name}; old partial unchanged")
            second = rpc("addUri", [f"http://127.0.0.1:{server.server_port}/second.bin"], {"out": "payload.bin"})
            wait_for(lambda: rpc("tellStatus", second)["status"] == "complete")
            second_path = pathlib.Path(rpc("getFiles", second)[0]["path"])
            assert second_path != downloaded
            assert second_path.read_bytes() == SECOND_PAYLOAD
            assert hashlib.sha256(downloaded.read_bytes()).digest() == expected
            stop()
            print(f"PASS Aria2 Next {version}: HTTP/RPC, pause, session/GID recovery, resume checksum, same-name isolation, shutdown")
        finally:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
