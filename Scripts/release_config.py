#!/usr/bin/env python3
"""Read the literal public release configuration used directly by Xcode."""
import argparse
import base64
import json
from pathlib import Path
import re

DEFAULT = Path(__file__).resolve().parent.parent / "Configuration/Release.xcconfig"
FIELDS = {"CHOPCHOP_RELEASE_REPOSITORY", "CHOPCHOP_APP_IDENTIFIER", "CHOPCHOP_UPDATE_PUBLIC_KEY"}


def load(configuration=DEFAULT):
    values = {}
    for line in Path(configuration).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        match = re.fullmatch(r"([A-Z_]+)\s*=\s*(\S+)", line)
        if not match or match[1] not in FIELDS or match[1] in values:
            raise ValueError("Release configuration must contain unique literal assignments only")
        if "//" in match[2]:
            raise ValueError("Xcode treats // as a comment; use --set-public-key to escape public keys")
        values[match[1]] = match[2].replace("$()", "") if match[1] == "CHOPCHOP_UPDATE_PUBLIC_KEY" else match[2]
    if values.keys() != FIELDS:
        raise ValueError("Missing release configuration fields")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", values["CHOPCHOP_RELEASE_REPOSITORY"]):
        raise ValueError("Expected a GitHub owner/repository")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", values["CHOPCHOP_APP_IDENTIFIER"]):
        raise ValueError("Invalid app bundle identifier")
    if len(base64.b64decode(values["CHOPCHOP_UPDATE_PUBLIC_KEY"], validate=True)) != 32:
        raise ValueError("Expected a 32-byte Ed25519 public key")
    return values


def info(values):
    return dict(ChopChopReleaseRepository=values["CHOPCHOP_RELEASE_REPOSITORY"],
                ChopChopAppIdentifier=values["CHOPCHOP_APP_IDENTIFIER"],
                ChopChopUpdatePublicKey=values["CHOPCHOP_UPDATE_PUBLIC_KEY"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", type=Path, default=DEFAULT)
    parser.add_argument("--check-repository", help="Require the release destination to match this GitHub repository")
    parser.add_argument("--info-json", action="store_true", help="Output public Info.plist fields for signing tools")
    parser.add_argument("--set-public-key", help="Write a base64 public key, escaping slashes for Xcode")
    args = parser.parse_args()
    try:
        if args.set_public_key is not None:
            if len(base64.b64decode(args.set_public_key, validate=True)) != 32:
                raise ValueError("Expected a 32-byte Ed25519 public key")
            source = args.configuration.read_text()
            escaped = args.set_public_key.replace("/", "/$()")
            updated, count = re.subn(r"^CHOPCHOP_UPDATE_PUBLIC_KEY\s*=.*$",
                                    "CHOPCHOP_UPDATE_PUBLIC_KEY = " + escaped, source, flags=re.MULTILINE)
            if count != 1:
                raise ValueError("Expected exactly one public key setting")
            args.configuration.write_text(updated)
        values = load(args.configuration)
        if args.check_repository and args.check_repository.casefold() != values["CHOPCHOP_RELEASE_REPOSITORY"].casefold():
            raise ValueError("Configure CHOPCHOP_RELEASE_REPOSITORY for this repository before publishing")
        print(json.dumps(info(values) if args.info_json else values, sort_keys=True))
    except (ValueError, OSError) as error:
        parser.exit(1, f"error: {error}\n")
