#!/usr/bin/env python3
"""Repository self-check for the LCARS terminal theme.

Validates that every generated and hand-written config parses, that all colors
come from palette/lcars.json, and that referenced assets exist.

  python3 tools/check.py
"""

from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
import tomllib
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ERRORS: list[str] = []
WARNINGS: list[str] = []


def error(msg: str) -> None:
    ERRORS.append(msg)


def warn(msg: str) -> None:
    WARNINGS.append(msg)


def load_palette() -> dict:
    palette = json.loads((ROOT / "palette" / "lcars.json").read_text())
    values = set()
    for section in ("colors", "ansi"):
        for name, value in palette[section].items():
            if not re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
                error(f"palette/{section}/{name}: invalid color {value!r}")
            values.add(value.upper())
            values.add(value.lower())
    return palette


def known(values: set, color: str) -> bool:
    return color in values or color.upper() in {v.upper() for v in values}


def check_ghostty(palette: dict, values: set) -> None:
    theme = (ROOT / "ghostty" / "themes" / "lcars").read_text().splitlines()
    indices = []
    for line in theme:
        match = re.match(r"^palette\s*=\s*(\d+)\s*=\s*(#[0-9A-Fa-f]{6})\s*$", line.strip())
        if match:
            indices.append(int(match.group(1)))
            if not known(values, match.group(2)):
                error(f"ghostty theme: palette {match.group(1)} color {match.group(2)} "
                      "not in palette/lcars.json")
    if sorted(indices) != list(range(16)):
        error(f"ghostty theme: expected palette 0-15, got {sorted(indices)}")

    conf = (ROOT / "ghostty" / "ghostty.conf").read_text()
    if conf.count("palette = ") != 16:
        error("ghostty/ghostty.conf: expected 16 palette lines")
    for match in re.finditer(r"^(background|foreground|cursor-color|selection-background)\s*=\s*(#[0-9A-Fa-f]{6})", conf, re.M):
        if not known(values, match.group(2)):
            error(f"ghostty/ghostty.conf: {match.group(1)} {match.group(2)} not in palette")
    if "__LCARS_DIR__" not in conf:
        warn("ghostty/ghostty.conf: no __LCARS_DIR__ tokens found (installer expects them)")
    if not (ROOT / "ghostty" / "shaders" / "lcars-crt.glsl").read_text().count("mainImage"):
        error("ghostty shader: missing mainImage entry point")


def check_windows(values: set) -> None:
    scheme = json.loads((ROOT / "windows" / "lcars-scheme.json").read_text())
    for key, value in scheme.items():
        if key == "name":
            continue
        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", str(value)):
            error(f"windows scheme: {key} = {value!r} is not a color")
        elif not known(values, str(value)):
            error(f"windows scheme: {key} = {value} not in palette/lcars.json")

    snippet = json.loads((ROOT / "windows" / "profile.snippet.json").read_text())
    guid = snippet.get("guid", "")
    if not re.fullmatch(r"\{[0-9a-fA-F-]{36}\}", guid):
        error(f"windows profile snippet: guid looks wrong: {guid!r}")
    if snippet.get("colorScheme") != scheme["name"]:
        error("windows profile snippet: colorScheme does not match scheme name")
    if "__LCARS_DIR__" not in snippet.get("backgroundImage", ""):
        warn("windows profile snippet: backgroundImage has no __LCARS_DIR__ token")


def check_toml() -> None:
    with (ROOT / "prompt" / "starship.toml").open("rb") as f:
        try:
            tomllib.load(f)
        except tomllib.TOMLDecodeError as exc:
            error(f"prompt/starship.toml: {exc}")


def strip_jsonc(text: str) -> str:
    out, i, in_string, escaped = [], 0, False, False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            out.append(ch)
        elif text.startswith("//", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def check_fastfetch() -> None:
    raw = (ROOT / "fastfetch" / "config.jsonc").read_text()
    try:
        config = json.loads(strip_jsonc(raw))
    except json.JSONDecodeError as exc:
        error(f"fastfetch/config.jsonc: {exc}")
        return
    source = config.get("logo", {}).get("source", "")
    if "__LCARS_DIR__" not in source:
        warn("fastfetch config: logo source has no __LCARS_DIR__ token")


def check_terminal_profile() -> None:
    path = ROOT / "terminal-app" / "LCARS.terminal"
    profile = plistlib.loads(path.read_bytes())
    if profile.get("name") != "LCARS":
        error("LCARS.terminal: profile name is not LCARS")
    required = ["BackgroundColor", "TextColor", "CursorColor", "SelectionColor"]
    required += [f"ANSI{c}Color" for c in
                 ("Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White")]
    for key in required:
        if key not in profile:
            error(f"LCARS.terminal: missing {key}")
            continue
        archive = plistlib.loads(profile[key])
        if "$objects" not in archive or "NSRGB" not in archive["$objects"][1]:
            error(f"LCARS.terminal: {key} archive is malformed")


def check_tmux(values: set) -> None:
    conf = (ROOT / "tmux" / "lcars.conf").read_text()
    for match in re.finditer(r"#[0-9A-Fa-f]{6}", conf):
        if not known(values, match.group(0)):
            error(f"tmux/lcars.conf: color {match.group(0)} not in palette/lcars.json")
    for match in re.finditer(r"#[0-9A-Fa-f]{1,5}\b", conf):
        warn(f"tmux/lcars.conf: suspicious short hex {match.group(0)!r}")


def check_assets() -> None:
    assets = sorted((ROOT / "assets").glob("*.png"))
    if not assets:
        error("assets/: no PNGs found (run: python3 tools/generate.py)")
    for path in assets:
        raw = path.read_bytes()
        if raw[:8] != b"\x89PNG\r\n\x1a\n":
            error(f"{path.name}: not a PNG")
            continue
        w, h = struct.unpack(">II", raw[16:24])
        if "@2x" in path.name and (w % 2 or h % 2):
            error(f"{path.name}: @2x dimensions not even ({w}x{h})")
    sounds = sorted((ROOT / "sounds").glob("*.wav"))
    if not sounds:
        error("sounds/: no WAVs found (run: python3 tools/generate.py)")
    for path in sounds:
        with wave.open(str(path)) as w:
            if w.getframerate() != 44100 or w.getnchannels() != 1:
                error(f"{path.name}: expected 44.1kHz mono")


def check_scripts() -> None:
    for script in ("shell/shell.sh", "install/common.sh", "install/linux.sh", "install/macos.sh"):
        text = (ROOT / script).read_text()
        if "lcars-ok.wav" in text or "lcars-alert.wav" in text or "lcars-confirm.wav" in text:
            for sound in ("lcars-ok", "lcars-alert", "lcars-confirm"):
                if sound in text and not (ROOT / "sounds" / f"{sound}.wav").exists():
                    error(f"{script}: references missing sounds/{sound}.wav")
    ps = (ROOT / "powershell" / "profile.ps1").read_text()
    for sound in ("lcars-ok", "lcars-alert"):
        if sound in ps and not (ROOT / "sounds" / f"{sound}.wav").exists():
            error(f"powershell/profile.ps1: references missing sounds/{sound}.wav")


def main() -> int:
    palette = load_palette()
    values = {v.upper() for section in ("colors", "ansi")
              for v in palette[section].values()}
    check_ghostty(palette, values)
    check_windows(values)
    check_toml()
    check_fastfetch()
    check_terminal_profile()
    check_tmux(values)
    check_assets()
    check_scripts()

    for warning in WARNINGS:
        print(f"warning: {warning}")
    for problem in ERRORS:
        print(f"ERROR: {problem}")
    if ERRORS:
        print(f"\n{len(ERRORS)} error(s), {len(WARNINGS)} warning(s)")
        return 1
    print(f"all checks passed ({len(WARNINGS)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
