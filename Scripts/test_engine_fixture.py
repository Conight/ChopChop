import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from engine_fixture import download_engine


class EngineFixtureTests(unittest.TestCase):
    def test_only_verified_fixture_is_executable_and_returned(self):
        data = b"isolated engine fixture"
        configuration = {"version": "1.2.3", "url": "https://example.invalid/engine", "sha256": hashlib.sha256(data).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "engine"
            def transfer(_command, **_kwargs):
                destination.write_bytes(data)
            with patch("engine_fixture.json.loads", return_value=configuration), patch("engine_fixture.subprocess.run", side_effect=transfer):
                self.assertEqual(download_engine(destination), "1.2.3")
                self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
                configuration["sha256"] = "0" * 64
                with self.assertRaises(AssertionError):
                    download_engine(destination)
                self.assertFalse(destination.exists(), "A corrupt engine must not remain available to tests")


if __name__ == "__main__":
    unittest.main()
