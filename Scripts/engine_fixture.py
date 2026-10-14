"""Pinned upstream engine used by the isolated HTTP/RPC and media integration tests."""
import hashlib
import json
import re
from pathlib import Path
import subprocess

CONFIGURATION = Path(__file__).resolve().parent / "engine-test-release.json"


def download_engine(destination):
    config = json.loads(CONFIGURATION.read_text())
    version = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", config["version"])
    if not version or int(version[1]) < 3:
        raise ValueError("Integration tests require a stable Aria2 Next v3+ release")
    destination = Path(destination)
    try:
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                        "--connect-timeout", "30", "--max-time", "180", config["url"], "--output", str(destination)], check=True)
        if hashlib.sha256(destination.read_bytes()).hexdigest() != config["sha256"]:
            raise AssertionError("Upstream test engine SHA-256 differs from the pinned release")
        destination.chmod(0o755)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return config["version"]
