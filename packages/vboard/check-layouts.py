"""Check that vboard's key labels match what xkb types from those keys.

vboard injects physical keycodes, so the character a key types is decided by
Sway's xkb layout, not by the label vboard draws on it. For every layout the
kiosk pairs with an xkb layout (modules/core/kiosk.nix, regionEnv), each
labelled key must type its label at level 1 and its shifted label with Shift.

Usage: check-layouts.py <vboard layouts dir> <vboard>=<xkb> ...
Needs xkbcli on PATH.
"""

import json
import subprocess
import sys

# vboard's row tokens (input_backends.py key_map) to xkb key names.
KEYS = {
    "`": "TLDE", "-": "AE11", "=": "AE12",
    "[": "AD11", "]": "AD12", "\\": "BKSL",
    ";": "AC10", "'": "AC11",
    ",": "AB08", ".": "AB09", "/": "AB10", "<": "LSGT",
}
KEYS.update({c: f"AE{i:02}" for i, c in enumerate("1234567890", 1)})
KEYS.update({c: f"AD{i:02}" for i, c in enumerate("QWERTYUIOP", 1)})
KEYS.update({c: f"AC{i:02}" for i, c in enumerate("ASDFGHJKL", 1)})
KEYS.update({c: f"AB{i:02}" for i, c in enumerate("ZXCVBNM", 1)})

# Labels that xkb produces as dead keys rather than the character itself.
DEAD = {"^": "dead_circumflex", "´": "dead_acute", "`": "dead_grave",
        "¨": "dead_diaeresis", "~": "dead_tilde"}


def direct(xkb, char):
    """(key name, modifiers) pairs that type char directly on layout xkb."""
    found = set()
    queries = [[char]] if char not in DEAD else [[char], ["--keysym", DEAD[char]]]
    for q in queries:
        out = subprocess.run(
            ["xkbcli", "how-to-type", "--disable-compose", "--layout", xkb, *q],
            capture_output=True, text=True, check=True,
        ).stdout
        for line in out.splitlines():
            f = line.split()
            if len(f) > 2 and f[0].isdigit() and "[" in line:
                # KEYCODE KEY-NAME LAYOUT LAYOUT-NAME (may hold spaces) LEVEL [ MODS ]
                found.add((f[1], "[" + line.rsplit("[", 1)[1]))
    return found


def check(layouts, vboard, xkb):
    with open(f"{layouts}/{vboard}.json") as fh:
        layout = json.load(fh)
    labels, shifted = layout.get("labels", {}), layout.get("shifted", {})
    errors = []
    for token in (t for row in layout["rows"] for t in row if t in KEYS):
        key = KEYS[token]
        plain = labels.get(token, token)
        if len(plain) == 1 and plain.isalpha():
            plain = plain.lower()  # vboard draws letters in capitals
        if (key, "[ ]") not in direct(xkb, plain):
            errors.append(f"{vboard}: key {token!r} shows {plain!r}, xkb {xkb} types something else")
        if token in shifted and (key, "[ Shift ]") not in direct(xkb, shifted[token]):
            errors.append(f"{vboard}: key {token!r} shows {shifted[token]!r} with Shift, xkb {xkb} types something else")
    # Every letter has to be on some key, or it cannot be typed at all.
    shown = {labels.get(t, t).lower() for row in layout["rows"] for t in row if t in KEYS}
    for c in "abcdefghijklmnopqrstuvwxyz":
        if c not in shown:
            errors.append(f"{vboard}: no key shows {c!r}")
    return errors


def main():
    layouts, pairs = sys.argv[1], sys.argv[2:]
    errors = []
    for pair in pairs:
        errors += check(layouts, *pair.split("="))
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
