"""Share the shell checks' signing policy with standalone Python probes."""
from pathlib import Path
import subprocess


def signing_identity():
    return subprocess.check_output(
        ["sh", str(Path(__file__).with_name("local-signing.sh")), "--print-identity"], text=True
    ).strip()
