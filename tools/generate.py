#!/usr/bin/env python3
"""Generate LCARS terminal assets from palette/lcars.json.

Produces, with zero third-party dependencies (PNG via zlib, sounds via wave):
  assets/lcars-frame-16x9.png      frame art for Ghostty / Windows Terminal
  assets/lcars-frame-16x9@2x.png
  assets/lcars-frame-21x9.png
  assets/lcars-frame-21x9@2x.png
  assets/lcars-frame-4x3.png
  assets/lcars-frame-4x3@2x.png
  assets/lcars-frame-termapp.png   dimmed variant for Terminal.app (no padding)
  assets/lcars-splash.png          fastfetch splash panel
  assets/lcars-splash@2x.png
  sounds/lcars-confirm.wav         prompt beep
  sounds/lcars-ok.wav
  sounds/lcars-alert.wav

Usage:
  python3 tools/generate.py                 # everything
  python3 tools/generate.py --only frames
  python3 tools/generate.py --preview       # ASCII preview of frame + splash
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import time
import wave
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PALETTE = json.loads((ROOT / "palette" / "lcars.json").read_text())
COLORS = {}


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


COLORS = {k: hex_rgb(v) for k, v in PALETTE["colors"].items()}


# --------------------------------------------------------------------------
# tiny software rasterizer (signed distance fields, 1px analytic AA)
# --------------------------------------------------------------------------

class Canvas:
    __slots__ = ("w", "h", "px")

    def __init__(self, w: int, h: int):
        self.w = w
        self.h = h
        self.px = bytearray(w * h * 3)

    def blend(self, x: int, y: int, color: tuple[int, int, int], a: float) -> None:
        i = (y * self.w + x) * 3
        px = self.px
        if a >= 0.999:
            px[i], px[i + 1], px[i + 2] = color
            return
        ia = 1.0 - a
        px[i] = int(px[i] * ia + color[0] * a + 0.5)
        px[i + 1] = int(px[i + 1] * ia + color[1] * a + 0.5)
        px[i + 2] = int(px[i + 2] * ia + color[2] * a + 0.5)

    def dim(self, factor: float) -> None:
        px = self.px
        for i in range(len(px)):
            px[i] = int(px[i] * factor)

    def write_png(self, path: Path) -> None:
        stride = self.w * 3
        raw = bytearray()
        px = self.px
        for y in range(self.h):
            raw.append(0)
            raw += px[y * stride:(y + 1) * stride]

        def chunk(tag: bytes, data: bytes) -> bytes:
            return (
                struct.pack(">I", len(data))
                + tag
                + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
            )

        blob = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")
        )
        path.write_bytes(blob)


# shapes: (sdf, bbox) where bbox = (x0, y0, x1, y1) in pixels
Shape = tuple


def capsule(x0: float, y0: float, x1: float, y1: float, t: float) -> Shape:
    r = t / 2.0
    dx, dy = x1 - x0, y1 - y0
    l2 = dx * dx + dy * dy

    def sdf(px: float, py: float) -> float:
        if l2 == 0.0:
            return math.hypot(px - x0, py - y0) - r
        u = ((px - x0) * dx + (py - y0) * dy) / l2
        u = 0.0 if u < 0.0 else (1.0 if u > 1.0 else u)
        return math.hypot(px - x0 - dx * u, py - y0 - dy * u) - r

    bbox = (min(x0, x1) - r - 2, min(y0, y1) - r - 2,
            max(x0, x1) + r + 2, max(y0, y1) + r + 2)
    return sdf, bbox


def box(cx: float, cy: float, w: float, h: float, r: float = 0.0) -> Shape:
    hw, hh = w / 2.0, h / 2.0
    r = min(r, hw, hh)

    def sdf(px: float, py: float) -> float:
        qx = abs(px - cx) - (hw - r)
        qy = abs(py - cy) - (hh - r)
        return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r

    bbox = (cx - hw - 2, cy - hh - 2, cx + hw + 2, cy + hh + 2)
    return sdf, bbox


def circle(cx: float, cy: float, r: float) -> Shape:
    def sdf(px: float, py: float) -> float:
        return math.hypot(px - cx, py - cy) - r

    return sdf, (cx - r - 2, cy - r - 2, cx + r + 2, cy + r + 2)


def arc_quadrant(cx: float, cy: float, r: float, t: float, quad: str) -> Shape:
    """Quarter ring used for LCARS corner sweeps. quad in tl, tr, bl, br."""

    def sdf(px: float, py: float) -> float:
        d = abs(math.hypot(px - cx, py - cy) - r) - t / 2.0
        if quad == "tl":
            return max(d, px - cx, py - cy)
        if quad == "tr":
            return max(d, cx - px, py - cy)
        if quad == "bl":
            return max(d, px - cx, cy - py)
        return max(d, cx - px, cy - py)

    if quad == "tl":
        bbox = (cx - r - t, cy - r - t, cx + t, cy + t)
    elif quad == "tr":
        bbox = (cx - t, cy - r - t, cx + r + t, cy + t)
    elif quad == "bl":
        bbox = (cx - r - t, cy - t, cx + t, cy + r + t)
    else:
        bbox = (cx - t, cy - t, cx + r + t, cy + r + t)
    return sdf, bbox


def union(*shapes: Shape) -> Shape:
    def sdf(px: float, py: float) -> float:
        return min(s(px, py) for s, _ in shapes)

    x0 = min(b[0] for _, b in shapes)
    y0 = min(b[1] for _, b in shapes)
    x1 = max(b[2] for _, b in shapes)
    y1 = max(b[3] for _, b in shapes)
    return sdf, (x0, y0, x1, y1)


def cut(shape: Shape, ax: float, ay: float, bx: float, by: float,
        keep_left: bool = True) -> Shape:
    """Intersect shape with the half-plane on one side of line a->b.

    keep_left=True keeps the side where the cross product (b-a)x(p-a) is >= 0.
    """
    s, bbox = shape
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy) or 1.0
    sign = -1.0 if keep_left else 1.0

    def sdf(px: float, py: float) -> float:
        side = ((px - ax) * dy - (py - ay) * dx) / length
        return max(s(px, py), sign * side)

    return sdf, bbox


def draw(cv: Canvas, shape: Shape, color: tuple[int, int, int], alpha: float = 1.0) -> None:
    sdf, (x0, y0, x1, y1) = shape
    X0 = max(0, int(math.floor(x0)))
    Y0 = max(0, int(math.floor(y0)))
    X1 = min(cv.w - 1, int(math.ceil(x1)))
    Y1 = min(cv.h - 1, int(math.ceil(y1)))
    for y in range(Y0, Y1 + 1):
        fy = y + 0.5
        for x in range(X0, X1 + 1):
            cov = 0.5 - sdf(x + 0.5, fy)
            if cov > 0.0:
                cv.blend(x, y, color, (cov if cov < 1.0 else 1.0) * alpha)


# --------------------------------------------------------------------------
# layouts
# --------------------------------------------------------------------------

def rail_geometry(w: int, h: int):
    """Edge metrics shared by every frame size (authored for 1080p, scaled)."""
    k = h / 1080.0
    m = 13.0 * k              # rail centerline offset from the edge
    rt = 26.0 * k             # rail thickness
    R = 137.0 * k             # corner sweep radius (centerline)
    cx_l, cx_r = m + R, w - (m + R)
    cy_t, cy_b = m + R, h - (m + R)
    return k, m, rt, R, cx_l, cx_r, cy_t, cy_b


def frame_shapes(w: int, h: int):
    k, m, rt, R, cx_l, cx_r, cy_t, cy_b = rail_geometry(w, h)
    shapes = []
    # corner sweeps
    shapes.append((arc_quadrant(cx_l, cy_t, R, rt, "tl"), COLORS["sunset"]))
    shapes.append((arc_quadrant(cx_r, cy_t, R, rt, "tr"), COLORS["sunset"]))
    shapes.append((arc_quadrant(cx_l, cy_b, R, rt, "bl"), COLORS["salmon"]))
    shapes.append((arc_quadrant(cx_r, cy_b, R, rt, "br"), COLORS["lavender"]))
    # rails and bars
    shapes.append((capsule(m, cy_t, m, cy_b, rt), COLORS["sunset"]))                      # left rail
    shapes.append((capsule(w - m, cy_t, w - m, cy_b, rt), COLORS["mauve"]))               # right rail
    shapes.append((capsule(cx_l, m, cx_r, m, rt), COLORS["sunset"]))                      # top bar
    shapes.append((capsule(cx_l, h - m, cx_r, h - m, rt), COLORS["lavender"]))            # bottom bar
    # top accent pills
    shapes.append((capsule(150 * k, 96 * k, 560 * k, 96 * k, 30 * k), COLORS["lavender"]))
    shapes.append((capsule(w - 560 * k, 96 * k, w - 150 * k, 96 * k, 30 * k), COLORS["ice"]))
    # bottom detail bars, ends cut at 45 degrees
    bl_bar = capsule(60 * k, h - 70 * k, 620 * k, h - 70 * k, 48 * k)
    xe, ye, t = 620 * k, h - 70 * k, 48 * k
    bl_bar = cut(bl_bar, xe - t * 0.5, ye + t, xe + t * 0.5, ye - t, keep_left=True)
    shapes.append((bl_bar, COLORS["salmon"]))

    br_bar = capsule(w - 620 * k, h - 70 * k, w - 60 * k, h - 70 * k, 48 * k)
    xe, ye, t = w - 620 * k, h - 70 * k, 48 * k
    br_bar = cut(br_bar, xe + t * 0.5, ye + t, xe - t * 0.5, ye - t, keep_left=False)
    shapes.append((br_bar, COLORS["lavender"]))

    centre = capsule(w / 2 - 190 * k, h - 70 * k, w / 2 + 190 * k, h - 70 * k, 30 * k)
    shapes.append((centre, COLORS["peach"]))
    return shapes


def build_frame(w: int, h: int, dim_factor: float = 1.0) -> Canvas:
    cv = Canvas(w, h)
    for shape, color in frame_shapes(w, h):
        draw(cv, shape, color)
    if dim_factor != 1.0:
        cv.dim(dim_factor)
    return cv


# --- micro block font (5x7) for splash lettering ---------------------------

FONT = {
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "4": ["10001", "10001", "10001", "11111", "00001", "00001", "00001"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    " ": ["00000"] * 7,
}


def draw_text(cv: Canvas, text: str, x: float, y: float, cell: float,
              color: tuple[int, int, int]) -> float:
    step = cell * 1.18
    for ch in text:
        glyph = FONT.get(ch.upper())
        if not glyph:
            x += step * 6
            continue
        for row, bits in enumerate(glyph):
            for col, bit in enumerate(bits):
                if bit == "1":
                    draw(cv, box(x + col * step + cell / 2, y + row * step + cell / 2,
                                 cell, cell, cell * 0.28), color)
        x += step * 6
    return x


def build_splash(w: int, h: int) -> Canvas:
    cv = Canvas(w, h)
    k, m, rt, R, cx_l, cx_r, cy_t, cy_b = rail_geometry(w, h)

    draw(cv, arc_quadrant(cx_l, cy_t, R, rt, "tl"), COLORS["sunset"])
    draw(cv, arc_quadrant(cx_r, cy_t, R, rt, "tr"), COLORS["sunset"])
    draw(cv, arc_quadrant(cx_l, cy_b, R, rt, "bl"), COLORS["lavender"])
    draw(cv, arc_quadrant(cx_r, cy_b, R, rt, "br"), COLORS["lavender"])
    draw(cv, capsule(m, cy_t, m, cy_b, rt), COLORS["sunset"])
    draw(cv, capsule(w - m, cy_t, w - m, cy_b, rt), COLORS["mauve"])
    draw(cv, capsule(cx_l, m, cx_r, m, rt), COLORS["sunset"])
    draw(cv, capsule(cx_l, h - m, cx_r, h - m, rt), COLORS["lavender"])

    # header pill with block letters
    draw(cv, capsule(84, 96, 430, 96, 58), COLORS["lavender"])
    draw_text(cv, "LCARS", 100, 75, 6.0, COLORS["space"])
    # registry number
    draw_text(cv, "47", w - 246, 58, 14.0, COLORS["sunset"])

    # stacked readout pills
    rows = [
        (COLORS["sunset"], 84, 268),
        (COLORS["ice"], 84, 330),
        (COLORS["salmon"], 84, 228),
        (COLORS["mauve"], 84, 190),
    ]
    y = 176
    for color, x0, x1 in rows:
        draw(cv, capsule(x0, y, x1, y, 22), color)
        y += 36

    # small data block
    widths = [(40, "peach"), (74, "lavender"), (32, "ice"),
              (58, "salmon"), (46, "sunset"), (70, "mauve"),
              (36, "warn"), (64, "slate"), (44, "salmon")]
    x = w * 0.55
    y = 176
    for i, (width, name) in enumerate(widths):
        if i % 3 == 0:
            x = w * 0.55
            y += 34
        draw(cv, capsule(x, y, x + width, y, 16 * 0.9), COLORS[name])
        x += width + 22

    # caption bar
    caption = capsule(84, h - 78, 620, h - 78, 26)
    xe, ye, t = 620, h - 78, 26
    caption = cut(caption, xe - t * 0.5, ye + t, xe + t * 0.5, ye - t, keep_left=True)
    draw(cv, caption, COLORS["salmon"])
    draw(cv, capsule(w - 420, h - 78, w - 84, h - 78, 26), COLORS["ice"])
    return cv


# --------------------------------------------------------------------------
# sounds
# --------------------------------------------------------------------------

def write_wav(path: Path, notes, sample_rate: int = 44100) -> None:
    samples = []
    for freq, dur, vol in notes:
        n = int(sample_rate * dur)
        for i in range(n):
            if freq <= 0:
                samples.append(0)
                continue
            t = i / sample_rate
            env = min(1.0, i / (sample_rate * 0.006)) * math.exp(-t * 7.0)
            s = math.sin(2 * math.pi * freq * t) * 0.82
            s += math.sin(2 * math.pi * freq * 2 * t) * 0.18
            samples.append(int(max(-1.0, min(1.0, s * env * vol)) * 32767))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))


# --------------------------------------------------------------------------
# preview (ASCII) so layout can be checked without an image viewer
# --------------------------------------------------------------------------

def preview(cv: Canvas, cols: int = 100) -> None:
    ramp = " .:-=+*#%@"
    cols = min(cols, cv.w)
    step = cv.w / cols
    rows = int(cv.h / step / 2.1)
    out = []
    for r in range(rows):
        y = int((r + 0.5) * step * 2.1)
        if y >= cv.h:
            break
        line = []
        for c in range(cols):
            x = int((c + 0.5) * step)
            i = (y * cv.w + x) * 3
            lum = (cv.px[i] * 3 + cv.px[i + 1] * 6 + cv.px[i + 2]) / (10 * 255)
            line.append(ramp[min(len(ramp) - 1, int(lum * len(ramp)))])
        out.append("".join(line))
    print("\n".join(out))


# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=["all", "frames", "splash", "sounds"], default="all")
    ap.add_argument("--preview", action="store_true",
                    help="print ASCII previews of the 16:9 frame and splash")
    ap.add_argument("--out", type=Path, default=ROOT, help="output root (default: repo root)")
    args = ap.parse_args()

    assets = args.out / "assets"
    sounds = args.out / "sounds"
    assets.mkdir(parents=True, exist_ok=True)
    sounds.mkdir(parents=True, exist_ok=True)

    jobs = []
    if args.only in ("all", "frames"):
        jobs += [
            ("frame", "lcars-frame-16x9", 1920, 1080, 1.0),
            ("frame", "lcars-frame-21x9", 2560, 1080, 1.0),
            ("frame", "lcars-frame-4x3", 1600, 1200, 1.0),
            ("frame", "lcars-frame-termapp", 1920, 1080, 0.34),
        ]
    if args.only in ("all", "splash"):
        jobs += [("splash", "lcars-splash", 880, 420, 1.0)]

    t0 = time.time()
    for kind, name, w, h, dim in jobs:
        if kind == "frame":
            cv = build_frame(w, h, dim)
            cv2 = build_frame(w * 2, h * 2, dim)
        else:
            cv = build_splash(w, h)
            cv2 = build_splash(w * 2, h * 2)
        cv.write_png(assets / f"{name}.png")
        cv2.write_png(assets / f"{name}@2x.png")
        print(f"assets/{name}.png ({w}x{h}) + @2x ({w * 2}x{h * 2})")
        if args.preview and name in ("lcars-frame-16x9", "lcars-splash"):
            preview(cv)

    if args.only in ("all", "sounds"):
        write_wav(sounds / "lcars-confirm.wav",
                  [(880, 0.075, 0.5), (0, 0.02, 0), (1318.5, 0.095, 0.42)])
        write_wav(sounds / "lcars-ok.wav", [(1046.5, 0.09, 0.4)])
        write_wav(sounds / "lcars-alert.wav",
                  [(740, 0.11, 0.5), (0, 0.035, 0), (554.4, 0.16, 0.5)])
        for name in ("lcars-confirm", "lcars-ok", "lcars-alert"):
            print(f"sounds/{name}.wav")

    print(f"done in {time.time() - t0:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
