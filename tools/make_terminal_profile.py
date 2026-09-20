#!/usr/bin/env python3
"""Generate terminal-app/LCARS.terminal from palette/lcars.json.

Terminal.app stores profile colors as base64 NSKeyedArchiver blobs wrapping an
NSColor. This script rebuilds that structure with plistlib (stdlib only), so
the profile can be regenerated whenever the palette changes.

Import on macOS: double-click the .terminal file, or let install/macos.sh
open it for you. The background image is set separately in
Terminal > Settings > Profiles > LCARS > Window (bookmark data cannot be
generated outside macOS).
"""

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def hex_rgb(value: str) -> tuple[float, float, float]:
    value = value.lstrip("#")
    return (
        int(value[0:2], 16) / 255.0,
        int(value[2:4], 16) / 255.0,
        int(value[4:6], 16) / 255.0,
    )


def nscolor_data(rgb: tuple[float, float, float]) -> bytes:
    """NSKeyedArchiver archive of an NSColor, as Terminal.app writes it."""
    r, g, b = rgb
    archive = {
        "$archiver": "NSKeyedArchiver",
        "$objects": [
            "$null",
            {
                "NSRGB": f"{r!r} {g!r} {b!r}\x00".encode(),
                "NSColorSpace": 2,
                "$class": plistlib.UID(2),
            },
            {"$classes": ["NSColor", "NSObject"], "$classname": "NSColor"},
        ],
        "$top": {"root": plistlib.UID(1)},
        "$version": 100000,
    }
    return plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)


def build_profile(palette: dict) -> dict:
    ansi = {k: hex_rgb(v) for k, v in palette["ansi"].items()}
    ui = {k: hex_rgb(v) for k, v in palette["colors"].items()}

    profile = {
        "ANSIBlackColor": nscolor_data(ansi["black"]),
        "ANSIRedColor": nscolor_data(ansi["red"]),
        "ANSIGreenColor": nscolor_data(ansi["green"]),
        "ANSIYellowColor": nscolor_data(ansi["yellow"]),
        "ANSIBlueColor": nscolor_data(ansi["blue"]),
        "ANSIMagentaColor": nscolor_data(ansi["magenta"]),
        "ANSICyanColor": nscolor_data(ansi["cyan"]),
        "ANSIWhiteColor": nscolor_data(ansi["white"]),
        "ANSIBrightBlackColor": nscolor_data(ansi["brightBlack"]),
        "ANSIBrightRedColor": nscolor_data(ansi["brightRed"]),
        "ANSIBrightGreenColor": nscolor_data(ansi["brightGreen"]),
        "ANSIBrightYellowColor": nscolor_data(ansi["brightYellow"]),
        "ANSIBrightBlueColor": nscolor_data(ansi["brightBlue"]),
        "ANSIBrightMagentaColor": nscolor_data(ansi["brightMagenta"]),
        "ANSIBrightCyanColor": nscolor_data(ansi["brightCyan"]),
        "ANSIBrightWhiteColor": nscolor_data(ansi["brightWhite"]),
        "BackgroundColor": nscolor_data(ui["space"]),
        "TextColor": nscolor_data(ui["peach"]),
        "TextBoldColor": nscolor_data(ansi["brightWhite"]),
        "CursorColor": nscolor_data(ui["sunset"]),
        "SelectionColor": nscolor_data(ui["lavender"]),
        "name": "LCARS",
        "type": "Window Settings",
        "ProfileCurrentVersion": 2.04,
        "columnCount": 110,
        "rowCount": 32,
    }
    return profile


def main() -> int:
    palette = json.loads((ROOT / "palette" / "lcars.json").read_text())
    profile = build_profile(palette)
    out = ROOT / "terminal-app" / "LCARS.terminal"
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("wb") as f:
        plistlib.dump(profile, f, sort_keys=True)
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
