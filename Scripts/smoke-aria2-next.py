#!/usr/bin/env python3
"""Download a pinned upstream test engine, then exercise it with local HTTP and disposable state.

No engine executable is kept in the repository or app. This CLI test runs a
temporary standalone copy; opt-in integration tests cover the app sandbox.
"""
import argparse
import base64
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

from engine_fixture import download_engine


PAYLOAD = bytes(range(256)) * 32768
SECOND_PAYLOAD = b"a different same-name download\n" * 4096


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    request_count = 0

    def handle(self):
        try:
            super().handle()
        except ConnectionResetError:
            # Pausing a task deliberately closes its HTTP connection.
            pass

    def do_GET(self):
        Handler.request_count += 1
        if self.path.startswith("/auth") and (self.headers.get("Authorization") != "Bearer updated" or self.headers.get("Cookie") != "session=new"):
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
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


def bencode(value):
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    return b"d" + b"".join(bencode(key) + bencode(value[key]) for key in sorted(value)) + b"e"


def verify_magnet_file_selection(engine, root, shared_piece=False):
    """Two loopback engines exchange generated metadata; no public swarm or user files."""
    fixture = root / ('magnet-shared-piece' if shared_piece else 'magnet-selection')
    fixture.mkdir()
    processes = []
    token = uuid.uuid4().hex
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def start(name):
        folder = fixture / name
        folder.mkdir()
        rpc_port, peer_port = free_port(), free_port()
        log = open(folder / 'engine.log', 'wb')
        process = subprocess.Popen([
            str(engine), '--no-conf=true', '--enable-rpc=true', '--rpc-listen-all=false',
            f'--rpc-listen-port={rpc_port}', f'--rpc-secret={token}', f'--listen-port={peer_port}',
            f'--dir={folder}', f'--state-dir={folder / "state"}', '--enable-dht=false',
            '--bt-enable-lpd=false', '--enable-peer-exchange=false', '--ed2k-listen-port=0',
            '--ed2k-udp-listen-port=0', '--quiet=true', '--seed-ratio=0', '--pause=true',
            f'--save-session={folder / "session"}'
        ], stdout=log, stderr=log)
        processes.append((process, log))

        def rpc(method, *params):
            body = json.dumps({'jsonrpc': '2.0', 'id': 'magnet-selection', 'method': 'aria2.' + method,
                               'params': ['token:' + token, *params]}).encode()
            request = urllib.request.Request(f'http://127.0.0.1:{rpc_port}/jsonrpc', data=body,
                                              headers={'Content-Type': 'application/json'})
            with opener.open(request, timeout=3) as response:
                result = json.load(response)
            if 'error' in result: raise AssertionError(result['error'])
            return result['result']

        def ready():
            if process.poll() is not None: raise AssertionError((folder / 'engine.log').read_text())
            try: return rpc('getVersion')
            except (OSError, urllib.error.URLError): return False
        wait_for(ready)
        return rpc, folder, peer_port

    try:
        seeder, seed_dir, seed_port = start('seed')
        receiver, receive_dir, _ = start('receive')
        content = seed_dir / 'Fixture'; content.mkdir()
        wanted = b'wanted payload\n' * 65536
        skipped = b'x' * 2001 if shared_piece else b'skipped payload\n' * 65536
        (content / 'wanted.bin').write_bytes(wanted)
        (content / 'skipped.bin').write_bytes(skipped)
        payloads = [(b'skipped.bin', skipped), (b'wanted.bin', wanted)] if shared_piece else [(b'wanted.bin', wanted), (b'skipped.bin', skipped)]
        wanted_index, skipped_index = (1, 0) if shared_piece else (0, 1)
        data = b''.join(payload for _, payload in payloads)
        piece_size = 16384
        info = {b'name': b'Fixture', b'piece length': piece_size,
                b'pieces': b''.join(hashlib.sha1(data[i:i+piece_size]).digest() for i in range(0,len(data),piece_size)),
                b'files': [{b'length': len(payload), b'path': [name]} for name, payload in payloads]}
        torrent = bencode({b'info': info})
        seed = seeder('addTorrent', base64.b64encode(torrent).decode(), [],
                      {'dir': str(seed_dir), 'pause': 'false', 'seed-ratio': '0'})
        wait_for(lambda: seeder('tellStatus', seed).get('seeder') == 'true', timeout=20)
        info_hash = hashlib.sha1(bencode(info)).hexdigest()
        magnet = f'magnet:?xt=urn:btih:{info_hash}&dn=Fixture&x.pe=127.0.0.1:{seed_port}'
        began = time.monotonic()
        task_folder = receive_dir / 'Fixture Downloads'; task_folder.mkdir()
        gid = receiver('addUri', [magnet], {'pause': 'false', 'pause-metadata': 'true', 'dir': str(task_folder)})
        status = wait_for(lambda: (s if (s := receiver('tellStatus', gid)).get('bittorrent',{}).get('fileSelectionState') == 'awaiting' else None), timeout=30)
        assert status['gid'] == gid and status['status'] == 'paused', status
        assert not status.get('followedBy'), status
        files = receiver('getFiles', gid)
        assert len(files) == 2 and all(int(f['completedLength']) == 0 for f in files), files
        time.sleep(0.5)
        assert int(receiver('tellStatus', gid)['completedLength']) == 0
        # The authoritative selection state and file list exist before any payload.
        elapsed = time.monotonic() - began
        receiver('changeOption', gid, {'select-file': str(wanted_index + 1),
                                     'bt-file-priority': ','.join(f'{i+1}={"normal" if i == wanted_index else "off"}' for i in range(2))})
        receiver('changeOption', gid, {'max-download-limit': '128K', 'max-upload-limit': '64K'})
        receiver('unpause', gid)
        live_peers = wait_for(lambda: [p for p in receiver('getPeers', gid) if int(p.get('downloadSpeed', '0')) > 0], timeout=30)
        peer = live_peers[0]
        for key in ('peerClientName', 'state', 'progress', 'transport', 'encryption', 'incoming',
                    'sources', 'downloadSpeed', 'uploadSpeed', 'downloaded', 'uploaded', 'amChoking', 'peerChoking'):
            assert key in peer, (key, peer)
        assert peer['state'] == 'connected' and float(peer['progress']) == 1
        wait_for(lambda: any(int(p.get('uploadSpeed', '0')) > 0 for p in seeder('getPeers', seed)), timeout=10)
        assert int(receiver('getOption', gid)['max-upload-limit']) == 65536
        receiver('saveSession')
        assert 'max-upload-limit=65536' in (receive_dir / 'session').read_text()
        receiver('changeOption', gid, {'max-download-limit': '0', 'max-upload-limit': '0'})
        assert receiver('getOption', gid)['max-upload-limit'] == '0'
        wait_for(lambda: int(receiver('getFiles', gid)[wanted_index]['completedLength']) == len(wanted), timeout=30)
        def reported_pieces():
            snapshot = receiver('tellStatus', gid)
            return snapshot if any(bytes.fromhex(snapshot.get('bitfield', ''))) else None
        state = wait_for(reported_pieces, timeout=6)
        receiver('forcePause', gid)
        bits = bytes.fromhex(state['bitfield'])
        count = int(state['numPieces'])
        completed = sum(bool(bits[i // 8] & (0x80 >> (i % 8))) for i in range(count))
        assert count == (len(data) + piece_size - 1) // piece_size
        assert int(state['pieceLength']) == piece_size and completed > 0, (state['pieceLength'], piece_size, completed, state['bitfield'])
        assert sum(int(f['length']) for f in state['files']) == len(data)
        assert int(state['totalLength']) == len(wanted), 'Selected length must not be used as torrent span'
        assert receiver('tellStatus', gid)['status'] == 'paused'
        # getPeers can retain cached observations after pause; the app hides them using tellStatus.
        print('PASS BT telemetry: full bitfield, selected vs full length, connected peer fields, bidirectional rates, live persisted upload cap')
        files = receiver('getFiles', gid)
        assert pathlib.Path(files[wanted_index]['path']).read_bytes() == wanted
        assert pathlib.Path(files[wanted_index]['path']).is_relative_to(task_folder)
        assert files[skipped_index]['selected'] == 'false', files
        assert not pathlib.Path(files[skipped_index]['path']).exists(), files
        assert int(files[skipped_index]['completedLength']) == (len(skipped) if shared_piece else 0), files
        print(f'PASS Magnet metadata: same GID, {elapsed:.1f}s loopback discovery, no payload before selection; '
              f'{"shared-piece bytes counted but skipped file NOT created" if shared_piece else "only selected file downloaded"}')
    finally:
        for process, log in processes:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-engine", type=pathlib.Path,
                        help="Also exercise migration from a saved 2.4.9 helper (only a temporary copy is re-signed)")
    previous_engine = parser.parse_args().previous_engine
    if previous_engine and not previous_engine.is_file():
        parser.error("--previous-engine must point to an existing executable")
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
        try:
            with opener.open(request, timeout=3) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            raise AssertionError(f"{method}: {error.read().decode()}") from error
        if "error" in result:
            raise AssertionError(result["error"])
        return result["result"]

    with tempfile.TemporaryDirectory(prefix="chopchop-smoke-") as temporary:
        root = pathlib.Path(temporary)
        upstream = root / "upstream-engine"
        version = download_engine(upstream)
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
                     "--quiet=true", "--pause=true", f"--log={root / 'engine.log'}"]

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
            if not resume and not previous_engine:
                print("Engine capabilities:", json.dumps(result))

        def stop():
            rpc("shutdown")
            assert process.wait(timeout=10) == 0
            process.stderr.close()

        try:
            launch()
            url = f"http://127.0.0.1:{server.server_port}/payload.bin"
            gid = rpc("addUri", [url], {"out": "payload.bin", "pause": "false"})
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
            assert resumed["status"] == "paused", resumed
            request_count = Handler.request_count
            time.sleep(0.5)
            assert Handler.request_count == request_count, "Restored task made an HTTP request before resume"
            rpc("unpause", gid)
            wait_for(lambda: rpc("tellStatus", gid)["status"] == "complete")
            downloaded = pathlib.Path(rpc("getFiles", gid)[0]["path"])
            expected = hashlib.sha256(PAYLOAD).digest()
            assert hashlib.sha256(downloaded.read_bytes()).digest() == expected
            if previous_engine:
                assert downloaded != original_path
                assert original_path.read_bytes() == original_partial
                print(f"PASS 2.4.9 migration: original GID retained; download restarted in {downloaded.name}; old partial unchanged")
            # A range-capable local server exposes actual per-stream rates, not configured maxima.
            connections_gid = rpc("addUri", [url], {"out": "connections.bin", "pause": "false", "split": "4",
                                   "max-connection-per-server": "4", "min-split-size": "1M", "max-download-limit": "512K"})
            wait_for(lambda: rpc("tellStatus", connections_gid)['status'] == 'active')
            streams = wait_for(lambda: [s for f in rpc("getServers", connections_gid)
                                       for s in f['servers'] if int(s['downloadSpeed']) > 0], timeout=10)
            assert len(streams) == 1, '2.8.6 libcurl exposes an aggregate server record, not individual streams'
            assert streams[0]['currentUri'].startswith(f"http://127.0.0.1:{server.server_port}/")
            connection_count = int(rpc("tellStatus", connections_gid)['connections'])
            assert connection_count > 0
            rpc("changeOption", connections_gid, {"max-download-limit": "0"})
            wait_for(lambda: rpc("tellStatus", connections_gid)['status'] == 'complete')
            assert (downloads / 'connections.bin').read_bytes() == PAYLOAD
            print(f'PASS HTTP telemetry: {connection_count} reported connections, one aggregate server rate (not per-stream); downloaded bytes verified')
            second = rpc("addUri", [f"http://127.0.0.1:{server.server_port}/second.bin"], {"out": "payload.bin", "pause": "false"})
            wait_for(lambda: rpc("tellStatus", second)["status"] == "complete")
            second_path = pathlib.Path(rpc("getFiles", second)[0]["path"])
            assert second_path != downloaded
            assert second_path.read_bytes() == SECOND_PAYLOAD
            assert hashlib.sha256(downloaded.read_bytes()).digest() == expected
            if not previous_engine:
                # Opening a local Metalink submits captured bytes and returns every child GID.
                metalink = (f'<metalink xmlns="urn:ietf:params:xml:ns:metalink">'
                            f'<file name="import-one.bin"><size>{len(SECOND_PAYLOAD)}</size>'
                            f'<hash type="sha-256">{hashlib.sha256(SECOND_PAYLOAD).hexdigest()}</hash>'
                            f'<url>http://127.0.0.1:{server.server_port}/second-one.bin</url></file>'
                            f'<file name="import-two.bin"><size>{len(SECOND_PAYLOAD)}</size>'
                            f'<url>http://127.0.0.1:{server.server_port}/second-two.bin</url></file>'
                            f'</metalink>').encode()
                imported = rpc("addMetalink", base64.b64encode(metalink).decode(), {"pause": "false"})
                assert len(imported) == 2 and len(set(imported)) == 2, imported
                for imported_gid in imported:
                    wait_for(lambda: rpc("tellStatus", imported_gid)["status"] == "complete")
                    assert pathlib.Path(rpc("getFiles", imported_gid)[0]["path"]).read_bytes() == SECOND_PAYLOAD
                print("PASS Metalink import: captured document bytes, multiple GIDs, local HTTP payloads verified")
                # Crash with an active task whose explicit pause=false is saved in the session.
                active = rpc("addUri", [url], {"out": "crash.bin", "pause": "false", "max-download-limit": "512K"})
                wait_for(lambda: int(rpc("tellStatus", active)["completedLength"]) >= 2 * 1048576)
                rpc("changeGlobalOption", {"max-concurrent-downloads": "1"})
                queued = rpc("addUri", [url], {"out": "queued.bin", "pause": "false"})
                paused = rpc("addUri", [url], {"out": "paused.bin", "pause": "true"})
                assert rpc("tellStatus", queued)["status"] == "waiting"
                rpc("saveSession")
                time.sleep(1.2)  # Allow the engine's native checkpoint interval to persist.
                process.kill()
                process.wait(timeout=10)
                process.stderr.close()
                request_count = Handler.request_count
                launch(resume=True)
                restored = rpc("tellStatus", active)
                assert restored["status"] == "paused", restored
                assert rpc("tellStatus", queued)["status"] == "paused"
                assert rpc("tellStatus", paused)["status"] == "paused"
                assert int(restored["completedLength"]) > 0, restored
                time.sleep(0.5)
                assert Handler.request_count == request_count, "Crash recovery transferred before resume"
                rpc("changeOption", active, {"max-download-limit": "0"})
                rpc("unpause", active)
                wait_for(lambda: rpc("tellStatus", active)["status"] == "complete")
                assert hashlib.sha256(pathlib.Path(rpc("getFiles", active)[0]["path"]).read_bytes()).digest() == expected
                print("PASS crash recovery: original GID, persisted progress, no requests before manual resume")
                repaired = rpc("addUri", [url + "?expired=1"], {"out": "repaired.bin", "pause": "true"})
                fresh = f"http://127.0.0.1:{server.server_address[1]}/auth"
                old = [entry["uri"] for entry in rpc("getUris", repaired)]
                assert rpc("changeUri", repaired, 1, old, [fresh], 0)[1] == 1
                rpc("changeOption", repaired, {"header": "Authorization: Bearer updated\nCookie: session=new"})
                assert "Bearer updated" in rpc("getOption", repaired)["header"]
                rpc("unpause", repaired)
                wait_for(lambda: rpc("tellStatus", repaired)["status"] == "complete")
                assert hashlib.sha256((downloads / "repaired.bin").read_bytes()).digest() == expected
                print("PASS connection repair: zero-byte URL replacement, updated authentication, same GID and correct payload")
                seed_data = PAYLOAD[:32768]
                (downloads / "seed.bin").write_bytes(seed_data)
                torrent = bencode({b"info": {b"name": b"seed.bin", b"length": len(seed_data),
                    b"piece length": 16384, b"pieces": b"".join(hashlib.sha1(seed_data[i:i + 16384]).digest()
                                                              for i in range(0, len(seed_data), 16384))}})
                seeder = rpc("addTorrent", base64.b64encode(torrent).decode(), [], {
                    "pause": "true", "force-save": "true", "check-integrity": "true", "seed-ratio": "0", "seed-time": "60"})
                assert rpc("tellStatus", seeder)["status"] == "paused"
                assert rpc("tellStatus", seeder)["uploadSpeed"] == "0"
                rpc("changeOption", seeder, {"select-file": "1", "bt-file-priority": "1=top",
                    "force-sequential": "true", "bt-first-last-piece-first": "true", "seed-ratio": "2", "seed-time": "60"})
                torrent_options = rpc("getOption", seeder)
                assert torrent_options["bt-file-priority"] == "1=top", torrent_options
                assert torrent_options["force-sequential"] == "true", torrent_options
                assert rpc("tellStatus", seeder)["status"] == "paused"
                queue = rpc("tellWaiting", 0, 100)
                rpc("changePosition", seeder, 0, "POS_SET")
                assert rpc("tellWaiting", 0, 100)[0]["gid"] == seeder
                assert rpc("tellStatus", seeder)["status"] == "paused"
                assert isinstance(rpc("getBtTrackers", seeder), list)
                assert rpc("forceBtRecheck", seeder) == seeder
                time.sleep(0.2)
                assert rpc("tellStatus", seeder)["status"] == "paused"
                assert rpc("tellStatus", seeder)["uploadSpeed"] == "0"
                print("PASS queue ordering and torrent priorities, sequential mode, preview pieces, and sharing limits")
                rpc("unpause", seeder)
                wait_for(lambda: rpc("tellStatus", seeder)["seeder"] == "true")
                assert rpc("tellStatus", seeder)["status"] == "active"
                rpc("saveSession")
                time.sleep(1.2)
                process.kill()
                process.wait(timeout=10)
                process.stderr.close()
                request_count = Handler.request_count
                launch(resume=True)
                restored_seed = rpc("tellStatus", seeder)
                assert restored_seed["status"] == "paused", restored_seed
                assert int(restored_seed["completedLength"]) == len(seed_data), restored_seed
                time.sleep(0.5)
                assert Handler.request_count == request_count
                assert rpc("tellStatus", seeder)["uploadSpeed"] == "0"
                rpc("unpause", seeder)
                wait_for(lambda: rpc("tellStatus", seeder)["status"] == "active")
                assert (downloads / "seed.bin").read_bytes() == seed_data
                print("PASS BitTorrent seeding recovery: paused before transfer, original GID and validated data retained")
                # Finder can unlink a payload while libtorrent still has it open. Exercise
                # the app's pause / restore / explicit recheck sequence on the real engine.
                (downloads / "seed.bin").unlink()
                rpc("forcePause", seeder)
                wait_for(lambda: rpc("tellStatus", seeder)["status"] == "paused")
                rpc("saveSession")
                time.sleep(0.3)
                assert not (downloads / "seed.bin").exists(), "Paused seeder recreated externally deleted data"
                assert rpc("tellStatus", seeder)["uploadSpeed"] == "0"
                (downloads / "seed.bin").write_bytes(seed_data)
                rpc("forceBtRecheck", seeder)
                time.sleep(0.3)
                assert rpc("tellStatus", seeder)["status"] == "paused"
                assert rpc("tellStatus", seeder)["uploadSpeed"] == "0"
                rpc("unpause", seeder)
                wait_for(lambda: rpc("tellStatus", seeder)["seeder"] == "true")
                assert (downloads / "seed.bin").read_bytes() == seed_data
                print("PASS external deletion during seeding: pause without recreation, restore and recheck stay paused, manual resume retains GID")
            stop()
            if not previous_engine:
                verify_magnet_file_selection(engine, root)
                verify_magnet_file_selection(engine, root, shared_piece=True)
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
