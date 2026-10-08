#!/usr/bin/env python3
"""Isolated Aria2 Next media RPC test using locally generated HLS/DASH fixtures.

Requires ffmpeg/ffprobe only for test fixtures and validation. They are not app dependencies.
"""
import base64
import functools
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


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def wait(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timed out waiting for media state')


class Handler(http.server.SimpleHTTPRequestHandler):
    requests = []
    denied = False
    live_epoch = None

    def do_GET(self):
        Handler.requests.append(self.path)
        if self.path.split('?', 1)[0] == '/live.m3u8':
            if Handler.live_epoch is None: Handler.live_epoch = time.monotonic()
            count = min(12, 3 + int(time.monotonic() - Handler.live_epoch))
            manifest = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n'
            manifest += ''.join(f'#EXTINF:1.000,\nlow-{index:03d}.ts\n' for index in range(count))
            payload = manifest.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if Handler.denied and '.ts' in self.path and self.headers.get('Authorization') != 'Bearer updated':
            self.send_error(403)
            return
        # Leave time to pause an actual payload transfer.
        if '.ts' in self.path:
            time.sleep(.15)
        super().do_GET()

    def copyfile(self, source, output):
        try:
            super().copyfile(source, output)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def main():
    for executable in ('ffmpeg', 'ffprobe'):
        if not shutil.which(executable):
            raise SystemExit(f'{executable} is required for this test')
    with tempfile.TemporaryDirectory(prefix='chopchop-media-') as temporary:
        root = pathlib.Path(temporary)
        media = root / 'media'
        media.mkdir()
        for name, size in [('low', '320x180'), ('high', '640x360')]:
            run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                f'testsrc2=size={size}:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                '-t', '12', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '25', '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-f', 'hls', '-hls_time', '1', '-hls_playlist_type', 'vod',
                '-hls_segment_filename', str(media / f'{name}-%03d.ts'), str(media / f'{name}.m3u8'))
        (media / 'master.m3u8').write_text('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180,CODECS="avc1.42c00d,mp4a.40.2"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"\nhigh.m3u8\n')
        # An event-style live playlist retains its segments and waits for an explicit finish.
        (media / 'live.m3u8').write_text((media / 'low.m3u8').read_text().replace('#EXT-X-PLAYLIST-TYPE:VOD\n', '').replace('#EXT-X-ENDLIST\n', ''))
        run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25',
            '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000', '-t', '5', '-c:v', 'libx264',
            '-preset', 'ultrafast', '-g', '25', '-c:a', 'aac', '-f', 'dash', '-seg_duration', '1', str(media / 'clip.mpd'))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(media)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        config = json.loads((ROOT / 'Scripts/engine-test-release.json').read_text())
        version = config['version']
        engine = root / 'aria2-next'
        asset = f'aria2-next-{version}-macos-arm64'
        run('curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '180',
            f'https://github.com/AnInsomniacy/aria2-next/releases/download/v{version}/{asset}', '--output', str(engine))
        assert hashlib.sha256(engine.read_bytes()).hexdigest() == config['sha256']
        engine.chmod(0o755)
        entitlements = root / 'empty.plist'
        entitlements.write_bytes(plistlib.dumps({}))
        run('codesign', '--force', '--sign', '-', '--timestamp=none', '--entitlements', str(entitlements), str(engine))
        rpc_port, token = port(), uuid.uuid4().hex
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        session = root / 'aria2.session'
        downloads = root / 'downloads'
        downloads.mkdir()
        process = None

        def rpc(method, *params):
            body = json.dumps({'jsonrpc': '2.0', 'id': 'media', 'method': 'aria2.' + method, 'params': ['token:' + token, *params]}).encode()
            request = urllib.request.Request(f'http://127.0.0.1:{rpc_port}/jsonrpc', data=body, headers={'Content-Type': 'application/json'})
            with opener.open(request, timeout=5) as response:
                value = json.load(response)
            assert 'error' not in value, value
            return value['result']

        def launch():
            nonlocal process
            arguments = [str(engine), '--no-conf=true', '--enable-rpc=true', '--rpc-listen-all=false',
                         f'--rpc-listen-port={rpc_port}', f'--rpc-secret={token}', f'--dir={downloads}',
                         f'--state-dir={root / "state"}', f'--save-session={session}', '--save-session-interval=1',
                         '--state-save-interval=1', '--pause=true', '--enable-dht=false', '--bt-enable-lpd=false',
                         '--ed2k-listen-port=0', '--ed2k-udp-listen-port=0', f'--listen-port={port()}', '--quiet=true']
            if session.exists(): arguments.append(f'--input-file={session}')
            process = subprocess.Popen(arguments, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            def ready():
                if process.poll() is not None: raise AssertionError(process.stderr.read().decode())
                try: return rpc('getVersion')
                except OSError: return False
            wait(ready)

        def stop():
            rpc('saveSession')
            rpc('shutdown')
            assert process.wait(timeout=15) == 0
            process.stderr.close()

        def status(gid): return rpc('tellStatus', gid)

        def complete(gid):
            def ended():
                task = status(gid)
                assert task['status'] != 'error', task.get('media') or task
                return task if task['status'] == 'complete' else None
            return wait(ended)

        def inspect(name, **changes):
            before = len([p for p in Handler.requests if '.ts' in p])
            options = {'media-pause-after-probe': 'true', 'pause': 'false', 'media-format': 'mp4', **changes}
            gid = rpc('addUri', [f'http://127.0.0.1:{server.server_port}/{name}'], options)
            def inspected():
                task = status(gid)
                assert task['status'] != 'error', task.get('media') or task
                return task if task['status'] == 'paused' and task.get('media', {}).get('tracks') else None
            value = wait(inspected)
            assert len([p for p in Handler.requests if '.ts' in p]) == before, 'Inspection fetched video payload'
            return gid, value['media']

        def verify_output(task, expected_height):
            path = pathlib.Path(task['files'][0]['path'])
            assert path.exists() and path.stat().st_size > 0
            streams = json.loads(run('ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(path)))['streams']
            assert any(s.get('height') == expected_height for s in streams), streams
            assert any(s.get('codec_type') == 'audio' for s in streams), streams
            run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(path), '-f', 'null', '-')

        try:
            launch()
            gid, snapshot = inspect('master.m3u8')
            videos = [track for track in snapshot['tracks'] if track['type'] in ('video', 'muxed')]
            assert len(videos) == 2, snapshot
            choice = next(track for track in videos if track['height'] == '180')
            rpc('changeOption', gid, {'media-video': choice['id'], 'media-audio': choice['id'], 'media-format': 'mkv', 'media-pause-after-probe': 'false'})
            rpc('unpause', gid)
            wait(lambda: int(status(gid).get('media', {}).get('completedDuration', '0')) >= 2000)
            rpc('pause', gid)
            wait(lambda: status(gid)['status'] == 'paused')
            retained = int(status(gid)['media']['completedDuration'])
            assert retained > 0
            stop()
            requests = len(Handler.requests)
            launch()
            assert status(gid)['status'] == 'paused'
            assert int(status(gid)['media']['completedDuration']) >= retained
            time.sleep(.5)
            assert len(Handler.requests) == requests, 'Restored media transferred before resume'
            rpc('unpause', gid)
            verify_output(complete(gid), 180)
            print('PASS HLS: no payload before selection; selected quality; same-GID paused restart; MKV decoded')

            dash, _ = inspect('clip.mpd')
            rpc('changeOption', dash, {'media-pause-after-probe': 'false'})
            rpc('unpause', dash)
            verify_output(complete(dash), 180)
            print('PASS DASH: inspected tracks, MP4 audio/video decoded')

            live, _ = inspect('live.m3u8', **{'media': 'hls'})
            rpc('changeOption', live, {'media-pause-after-probe': 'false'})
            rpc('unpause', live)
            try:
                wait(lambda: int(status(live).get('media', {}).get('completedDuration', '0')) >= 2000)
            except AssertionError:
                raise AssertionError(status(live))
            rpc('pause', live)
            wait(lambda: status(live)['status'] == 'paused')
            rpc('finishMedia', live)
            verify_output(complete(live), 180)
            print('PASS live recording: paused then explicitly finished and published a playable file')

            retry, _ = inspect('master.m3u8')
            Handler.denied = True
            rpc('changeOption', retry, {'media-pause-after-probe': 'false'})
            rpc('unpause', retry)
            wait(lambda: status(retry)['status'] == 'error')
            assert isinstance(rpc('getOption', retry), dict)
            assert rpc('retryMedia', retry, {'header': 'Authorization: Bearer updated'}) == retry
            verify_output(complete(retry), 360)
            print('PASS media retry: original GID retained after a controlled HTTP failure')
            stop()
        finally:
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.shutdown()
            server.server_close()


if __name__ == '__main__': main()
