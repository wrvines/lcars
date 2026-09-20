#!/usr/bin/env python3
"""Read LCARS install manifests (.lcars-install.json).

Used by install/common.sh so the bash side never has to parse JSON.
"""

from __future__ import annotations

import json
import sys


def load(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        sys.exit(1)


def emit(fields: list) -> None:
    # US (0x1f) separator keeps empty fields addressable in bash `read`.
    print("\x1f".join(fields))


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, path = sys.argv[1], sys.argv[2]
    manifest = load(path)

    if cmd == "field":
        value = manifest.get(sys.argv[3], "")
        print(value if isinstance(value, str) else json.dumps(value))
    elif cmd == "terminal-field":
        value = manifest.get("terminal_app", {}).get(sys.argv[3], "")
        print(value if isinstance(value, str) else json.dumps(value))
    elif cmd == "created":
        for entry in manifest.get("created", []):
            print(entry)
    elif cmd == "patched":
        for entry in manifest.get("patched", []):
            emit([
                entry.get("path", ""),
                entry.get("backup", ""),
                entry.get("start", ""),
                entry.get("end", ""),
            ])
    elif cmd == "patched-entry":
        for entry in manifest.get("patched", []):
            if entry.get("path") == sys.argv[3]:
                emit([
                    entry.get("backup", ""),
                    entry.get("start", ""),
                    entry.get("end", ""),
                ])
                return 0
        return 1
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
