import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from engine_fixture import download_engine


class EngineFixtureTests(unittest.TestCase):
    def test_only_verified_fixture_is_executable_and_returned(self):
        data = b"isolated engine fixture"
        configuration = {"version": "3.0.1", "url": "https://example.invalid/engine", "sha256": hashlib.sha256(data).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "engine"
            def transfer(_command, **_kwargs):
                destination.write_bytes(data)
            with patch("engine_fixture.json.loads", return_value=configuration), patch("engine_fixture.subprocess.run", side_effect=transfer):
                self.assertEqual(download_engine(destination), "3.0.1")
                self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
                configuration["sha256"] = "0" * 64
                with self.assertRaises(AssertionError):
                    download_engine(destination)
                self.assertFalse(destination.exists(), "A corrupt engine must not remain available to tests")

    def test_v2_fixture_is_rejected_before_network_access(self):
        with patch("engine_fixture.json.loads", return_value={"version": "2.8.6"}), patch("engine_fixture.subprocess.run") as run:
            with self.assertRaises(ValueError):
                download_engine("/unused/engine")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
