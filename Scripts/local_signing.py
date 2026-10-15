"""Share the shell checks' signing policy with standalone Python probes."""
from pathlib import Path
import subprocess


def require_disposable_test_host():
    result = subprocess.run(
        ["sh", str(Path(__file__).with_name("test-host-policy.sh")), "--require-disposable-host"]
    )
    if result.returncode:
        raise SystemExit(result.returncode)


def signing_identity():
    return subprocess.check_output(
        ["sh", str(Path(__file__).with_name("local-signing.sh")), "--print-identity"], text=True
    ).strip()
