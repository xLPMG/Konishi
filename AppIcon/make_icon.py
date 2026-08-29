#!/usr/bin/env python3
"""Build Konishi.icns from an existing PNG.

Loads AppIcon/Konishi-1024.png, generates the required icon sizes into a
temporary .iconset, and emits an .icns via iconutil.

Usage: python3 AppIcon/make_icon.py
Output: Konishi.icns (repo root)
"""
from __future__ import annotations

import os
import subprocess
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_PNG = os.path.join(ROOT, "AppIcon", "Konishi-1024.png")


def make_icns(master: Image.Image):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "Konishi.iconset")
        os.makedirs(iconset)
        specs = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
        ]
        for px, name in specs:
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        out = os.path.join(ROOT, "Konishi.icns")
        subprocess.run(["iconutil", "-c", "icns", "-o", out, iconset], check=True)
        print("wrote", out)


if __name__ == "__main__":
    master = Image.open(SOURCE_PNG).convert("RGBA")
    if master.size != (1024, 1024):
        master = master.resize((1024, 1024), Image.LANCZOS)
    make_icns(master)
