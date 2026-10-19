#!/usr/bin/env python3
"""Rasterize the project's simple geometric icon without image dependencies."""
from pathlib import Path
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / "vlc-ios-master/Resources/iOS/Images.xcassets/RoxyIcon.appiconset"


def main():
    ASSET.mkdir(parents=True, exist_ok=True)
    # Source artwork uses only geometric shapes; iOS supplies the icon mask.
    svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#171d42"/><stop offset="1" stop-color="#0a1126"/></linearGradient>
<linearGradient id="play" x2="1" y2="1"><stop stop-color="#67e8f9"/><stop offset="1" stop-color="#a78bfa"/></linearGradient></defs>
<path fill="url(#bg)" d="M0 0h1024v1024H0z"/>
<circle cx="512" cy="512" r="338" fill="none" stroke="#29335b" stroke-width="6"/>
<path fill="url(#play)" d="M386 282L734 512 386 742z"/>
</svg>'''
    (ROOT / "docs/RoxyIcon.svg").write_text(svg)
    # Match the vector geometry with 2x area sampling for clean icon edges.
    rows = bytearray()
    for y in range(1024):
        rows.append(0)
        for x in range(1024):
            color = [0.0, 0.0, 0.0]
            for dx, dy in ((0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)):
                px, py = x + dx, y + dy
                t = (px + py) / 2048
                rgb = [23 - 13 * t, 29 - 12 * t, 66 - 28 * t]
                distance = ((px - 512) ** 2 + (py - 512) ** 2) ** 0.5
                if 335 <= distance <= 341: rgb = [41, 51, 91]
                if 386 <= px <= 734 and abs(py - 512) <= 230 * (734 - px) / 348:
                    rgb = [103 + 64 * t, 232 - 93 * t, 249 + t]
                color = [a + b / 4 for a, b in zip(color, rgb)]
            rows.extend(round(c) for c in color)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    (ASSET / "Roxy.png").write_bytes(png)
    (ASSET / "Contents.json").write_text(json.dumps({"images": [{"filename": "Roxy.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "Roxy Player", "version": 1}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
