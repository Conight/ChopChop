"""Release configuration validation, including fork destinations and unsafe input."""
import base64
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from release_config import DEFAULT, info, load


class ReleaseConfigurationTests(unittest.TestCase):
    def test_fork_configuration_and_release_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "Release.xcconfig"
            key = base64.b64encode(bytes(range(32))).decode()
            config.write_text(f"""// Fork fixture
CHOPCHOP_RELEASE_REPOSITORY = example/ChopChopFork
CHOPCHOP_APP_IDENTIFIER = org.example.ChopChopFork
CHOPCHOP_UPDATE_PUBLIC_KEY = {key}
""")
            self.assertEqual(info(load(config)), dict(ChopChopReleaseRepository="example/ChopChopFork",
                             ChopChopAppIdentifier="org.example.ChopChopFork", ChopChopUpdatePublicKey=key))
            command = [sys.executable, str(DEFAULT.parent.parent / "Scripts/release_config.py"), "--configuration", str(config), "--check-repository"]
            self.assertEqual(subprocess.run(command + ["Example/ChopChopFork"], capture_output=True).returncode, 0)
            self.assertNotEqual(subprocess.run(command + ["Conight/ChopChop"], capture_output=True).returncode, 0)

    def test_invalid_or_ambiguous_configuration_is_rejected(self):
        source = DEFAULT.read_text()
        values = load()
        invalid = [source + "CHOPCHOP_APP_IDENTIFIER = org.other.app\n",
                   source + "#include other.xcconfig\n",
                   source.replace(values["CHOPCHOP_RELEASE_REPOSITORY"], "example/repo?redirect=other"),
                   source.replace(values["CHOPCHOP_APP_IDENTIFIER"], "$(OTHER_IDENTIFIER)"),
                   source.replace(values["CHOPCHOP_UPDATE_PUBLIC_KEY"], "not-a-key"),
                   source.replace("CHOPCHOP_UPDATE_PUBLIC_KEY", "UNKNOWN_KEY")]
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "Release.xcconfig"
            for content in invalid:
                config.write_text(content)
                with self.subTest(content=content), self.assertRaises(ValueError):
                    load(config)

    def test_public_key_slashes_are_escaped_for_xcode(self):
        key = base64.b64encode(b"\xff" * 32).decode()
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "Release.xcconfig"
            config.write_text(DEFAULT.read_text())
            subprocess.run([sys.executable, str(DEFAULT.parent.parent / "Scripts/release_config.py"),
                            "--configuration", str(config), "--set-public-key", key], check=True, capture_output=True)
            self.assertEqual(load(config)["CHOPCHOP_UPDATE_PUBLIC_KEY"], key)
            key_line = next(line for line in config.read_text().splitlines() if line.startswith("CHOPCHOP_UPDATE_PUBLIC_KEY"))
            self.assertNotIn("//", key_line)
            config.write_text(config.read_text().replace("$()", ""))
            with self.assertRaises(ValueError):
                load(config)


if __name__ == "__main__":
    unittest.main()
