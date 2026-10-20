"""Pure fixture synchronization tests; no server, engine, or app is launched."""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("smoke_media", Path(__file__).with_name("smoke-media.py"))
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class MediaFixtureTests(unittest.TestCase):
    def test_progress_segments_pass_but_completion_waits_for_explicit_release(self):
        gate = media.PayloadGate(f"/low-{index:03d}.ts" for index in range(2, 12))
        for path in ("/master.m3u8", "/low-000.ts", "/low-001.ts"):
            self.assertTrue(gate.permits(path, timeout=0))
        with ThreadPoolExecutor(max_workers=2) as pool:
            pending = [pool.submit(gate.permits, path) for path in ("/low-002.ts", "/low-011.ts?token=fixture")]
            try:
                self.assertTrue(gate.reached.wait(timeout=5))
                self.assertTrue(all(not request.done() for request in pending),
                                "Concurrent downloads must not release the remaining segments")
            finally:
                gate.released.set()
            self.assertTrue(all(request.result(timeout=5) for request in pending))

    def test_timeout_fails_closed_and_handler_does_not_send_payload(self):
        gate = media.PayloadGate(["/low-002.ts"])
        self.assertFalse(gate.permits("/low-002.ts", timeout=0))
        handler = object.__new__(media.Handler)
        handler.path = "/low-002.ts"
        handler.send_error = Mock()
        with patch.object(media.Handler, "payload_gate", gate), \
             patch.object(gate, "permits", return_value=False), \
             patch.object(media.http.server.SimpleHTTPRequestHandler, "do_GET") as send_payload:
            handler.do_GET()
        handler.send_error.assert_called_once_with(504, "Test did not release the media payload gate")
        send_payload.assert_not_called()


if __name__ == "__main__":
    unittest.main()
