#!/usr/bin/env python3
"""Publish the exact upstream engine source beside the binary distribution."""

import hashlib
import pathlib
import re
import sys
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
config = dict(re.findall(r"^(ARIA2_NEXT_\w+) = (.+)$",
                         (root / "Vendor/Aria2Next/Aria2Next.xcconfig").read_text(), re.M))
version = config["ARIA2_NEXT_VERSION"]
output = pathlib.Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
destination = output / f"aria2-next-{version}-source.tar.gz"
request = urllib.request.Request(
    f"https://github.com/AnInsomniacy/aria2-next/archive/refs/tags/v{version}.tar.gz",
    headers={"User-Agent": "ChopChop-release"})
with urllib.request.urlopen(request, timeout=120) as response:
    data = response.read()
digest = hashlib.sha256(data).hexdigest()
if digest != config["ARIA2_NEXT_SOURCE_SHA256"]:
    sys.exit("error: upstream engine source checksum differs from the pinned archive")
destination.write_bytes(data)
destination.with_suffix(destination.suffix + ".sha256").write_text(f"{digest}  {destination.name}\n")
print(f"Verified engine source: {destination.name}")
