#!/usr/bin/env python3
"""Export shared branding from ChopChop/AppIcon.icon using Xcode 27.

Run after editing the layered icon in Icon Composer. MenuBarIcon is a template
PDF derived from the foreground paths; BrandIcon and browser assets use Apple's
renderer, including its native lighting and separate dark appearance.
"""

import json
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
ICON = ROOT / "ChopChop/AppIcon.icon"
CATALOG = ROOT / "ChopChop/Assets.xcassets"
XCODE = pathlib.Path(subprocess.check_output(
    ["/bin/sh", str(ROOT / "Scripts/xcode-environment.sh"), "--print-xcode-directory"], text=True).strip())
ICTOOL = XCODE.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def render(path, size, rendition="Default"):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(ICTOOL), str(ICON), "--export-image", "--output-file", str(path),
                    "--platform", "macOS", "--rendition", rendition, "--width", str(size),
                    "--height", str(size), "--scale", "1", "--design-generation", "27"], check=True)


def template_pdf():
    # Optical crop: retain the slightly lowered mark, remove the app tile, and
    # fit the two equal-width chevrons inside an 18 pt menu bar image.
    scale = 18 / 704
    commands = [f"q {scale} 0 0 {-scale} {-160 * scale} {864 * scale} cm 0 g"]
    model = json.loads((ICON / "icon.json").read_text())
    for group in model["groups"]:
        for layer in group["layers"]:
            svg = ET.parse(ICON / "Assets" / layer["image-name"]).getroot()
            for path in svg.findall("{http://www.w3.org/2000/svg}path"):
                translate = re.fullmatch(r"translate\(([-\d.]+)[ ,]+([-\d.]+)\)", path.get("transform", "translate(0 0)"))
                if translate is None:
                    raise ValueError("Unsupported SVG transform; update the template exporter")
                commands.append(f"q 1 0 0 1 {translate[1]} {translate[2]} cm")
                # The canonical artwork deliberately uses only absolute M/L/C/Z.
                tokens = re.findall(r"[A-Za-z]|-?(?:\d*\.)?\d+", path.attrib["d"])
                counts = {"M": 2, "L": 2, "C": 6, "Z": 0}
                index = 0
                while index < len(tokens):
                    command = tokens[index]
                    if command not in counts:
                        raise ValueError(f"Unsupported SVG path command: {command}")
                    count = counts[command]
                    values = tokens[index + 1:index + 1 + count]
                    if len(values) != count:
                        raise ValueError("Incomplete SVG path")
                    for value in values:
                        float(value)
                    commands.append(" ".join(values + [{"M": "m", "L": "l", "C": "c", "Z": "h"}[command]]))
                    index += count + 1
                commands.append("f Q")
    commands.append("Q")
    stream = "\n".join(commands).encode("ascii")
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 18 18] /Resources << >> /Contents 4 0 R >>",
               f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream"]
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, content in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f"{number} 0 obj\n".encode() + content + b"\nendobj\n")
    start = len(pdf)
    pdf.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        pdf.extend(f"{offset:010d} 00000 n \n".encode())
    pdf.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode())
    return pdf


def main():
    brand = CATALOG / "BrandIcon.imageset"
    images = []
    for rendition in ("Default", "Dark"):
        for scale in (1, 2):
            filename = f"brand-{rendition.lower()}@{scale}x.png"
            render(brand / filename, 128 * scale, rendition)
            entry = {"filename": filename, "idiom": "mac", "scale": f"{scale}x"}
            if rendition == "Dark":
                entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(entry)
    write_json(brand / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})
    menu = CATALOG / "MenuBarIcon.imageset"
    menu.mkdir(parents=True, exist_ok=True)
    (menu / "menu-bar.pdf").write_bytes(template_pdf())
    write_json(menu / "Contents.json", {"images": [{"filename": "menu-bar.pdf", "idiom": "mac"}],
               "info": {"author": "xcode", "version": 1},
               "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}})
    for size in (16, 32, 48, 128):
        render(ROOT / f"BrowserExtension/icons/icon-{size}.png", size)
    print("Exported app, menu bar and browser branding from AppIcon.icon")


if __name__ == "__main__":
    main()
