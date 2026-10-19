#!/usr/bin/env python3
"""Provision the bench board from a seed file — `just hw-seed`.

Does for real what test_seed_file_provisioning does with a dummy URL: writes a
dashboard-assistant.yaml onto the running board, triggers the first-boot importer
and reports back what the device did with it, so the result is visible in Home
Assistant rather than only in an assertion.

    just hw-seed --ha-url http://192.168.178.73:8123
    DA_WIFI_PSK=... just hw-seed --ha-url http://... --wifi-ssid MyNet

The Wi-Fi passphrase comes from $DA_WIFI_PSK by default so it stays out of shell
history and out of this repo. Nothing is written to disk here: the YAML is
assembled in memory and echoed onto the device over the serial console.

NOTE on where it is written. This drops the file on the FAT partition — where
docs/flash/seed.md tells a user to put it, and where configimport.nix now looks.
It used to write to /boot instead, because on the Pi images /boot is a directory
on the btrfs root and the documented path did not work at all; see
labgrid/README.md ("What this bench found"). So this now exercises the real
user-facing path, not a stand-in for it.
"""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import shlex
import sys
import time

from labgrid import Environment

import bench

#: The EFI system partition, mounted at /boot on every target — same as
#: labgrid/test_first_boot.py. Under the old sd-image layout this was a
#: separate partition at /boot/firmware, declared nofail,noauto with no mount
#: point, so it had to be mounted and unmounted by hand around every edit.
BOOT_MNT = "/boot"
SEED_PATH = f"{BOOT_MNT}/dashboard-assistant.yaml"
STATE = "/var/lib/dashboard-assistant"


def mount_fat(sh):
    # /boot is a normal fstab entry now; just fail loudly if it is not there.
    sh.run_check(f"mountpoint -q {BOOT_MNT}")


def umount_fat(sh):
    """No-op: /boot stays mounted, and the importer reads it in place."""


def yaml_str(value):
    """Quote a string for YAML. JSON string syntax is a valid YAML
    double-quoted scalar with the same escape rules, so json.dumps is a correct
    YAML escaper. Bare f-string interpolation was not: a passphrase containing
    a double quote broke the file, and one containing a backslash escape was
    silently *reinterpreted* — the device joined with a different passphrase
    than the one supplied."""
    return json.dumps(value)


def build_seed(args):
    lines = [f"ha_url: {yaml_str(args.ha_url)}"]
    if args.wifi_ssid:
        psk = args.wifi_psk or os.environ.get("DA_WIFI_PSK")
        if not psk:
            sys.exit("--wifi-ssid given but no passphrase: set $DA_WIFI_PSK")
        lines += ["wifi:", f"  ssid: {yaml_str(args.wifi_ssid)}", f"  psk: {yaml_str(psk)}"]
    if args.token:
        lines.append(f"kiosk_token: {yaml_str(args.token)}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--file",
        help="copy this seed file to the device verbatim instead of building one. "
        "Its contents are never printed — it usually holds a Wi-Fi passphrase.",
    )
    ap.add_argument("--ha-url", help="Home Assistant base URL (required unless --file)")
    ap.add_argument("--wifi-ssid", help="Wi-Fi SSID (omit on a wired board)")
    ap.add_argument("--wifi-psk", help="Wi-Fi passphrase (default: $DA_WIFI_PSK)")
    ap.add_argument("--token", help="optional kiosk token for auto-login (seeded as kiosk_token)")
    ap.add_argument(
        "--reflash",
        action="store_true",
        help="flash a fresh image first, so the board really is unprovisioned",
    )
    ap.add_argument("--timeout", type=int, default=180, help="seconds to wait for HA")
    args = ap.parse_args()
    if not args.file and not args.ha_url:
        ap.error("either --file or --ha-url is required")

    seed = None if args.file else build_seed(args)

    env = Environment(config_file=bench.ENV_CONFIG)
    strategy = env.get_target().get_driver("Strategy")

    if args.reflash:
        strategy.image = bench.find_image()
        if not strategy.image:
            sys.exit("no image — run `just build-rpi5-dev`")
        strategy.transition("shell")
    else:
        # Use the board as it stands; it is already up from the last test run.
        strategy.force("shell")
    sh = strategy.shell

    # Forget which seed file was imported last, so the importer acts on this one
    # even when its contents happen to match. Re-import is gated on a content
    # hash now, not on the provisioned marker, so this is what re-arms it.
    sh.run(f"rm -f {STATE}/seed-hash")

    mount_fat(sh)

    if args.file:
        raw = pathlib.Path(args.file).read_bytes()
        # Identify the file by digest rather than by content: a seed file
        # normally carries a Wi-Fi passphrase, and this output is not private.
        print(
            f"copying {args.file} -> {SEED_PATH} "
            f"({len(raw)} bytes, sha256 {hashlib.sha256(raw).hexdigest()[:16]})"
        )
        # base64 in chunks: a serial console is a poor place for arbitrary bytes,
        # and this sidesteps quoting, CRLF translation and line-length limits in
        # one go. Chunks stay well under any sane terminal line limit.
        b64 = base64.b64encode(raw).decode()
        sh.run_check(f"rm -f {SEED_PATH}.b64")
        for i in range(0, len(b64), 180):
            sh.run_check(f"printf %s {b64[i:i + 180]} >> {SEED_PATH}.b64")
        sh.run_check(f"base64 -d {SEED_PATH}.b64 > {SEED_PATH}")
        sh.run_check(f"rm -f {SEED_PATH}.b64")
        # Verify the transfer without ever printing what was transferred.
        got = sh.run_check(f"sha256sum {SEED_PATH} | cut -c1-16")
        want = hashlib.sha256(raw).hexdigest()[:16]
        assert got == [want], f"transfer corrupted: device has {got}, expected {want}"
        print("transfer verified by digest")
    else:
        print(f"seed file ->  {SEED_PATH}")
        sh.run_check(f"cat > {SEED_PATH} <<'EOF'\n{seed}EOF")
    umount_fat(sh)
    sh.run_check("systemctl restart dashboard-assistant-boot-import.service")

    print("\nwaiting for the device to apply it...")
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        out, _, _ = sh.run(f"grep -c HA_URL {STATE}/runtime.env || true", timeout=30)
        up, _, _ = sh.run("ip route | grep -c '^default' || true", timeout=30)
        if out == ["1"] and up == ["1"]:
            break
        time.sleep(5)

    print("\n--- device state " + "-" * 50)
    for label, cmd in [
        ("runtime.env", f"grep -v TOKEN {STATE}/runtime.env"),
        ("provisioned", f"test -e {STATE}/provisioned && echo yes || echo no"),
        ("addresses", "ip -brief addr | grep -v '^lo'"),
        ("default route", "ip route | grep '^default' || echo none"),
        (
            "reaches HA",
            f"curl -skS -o /dev/null -m 8 -w '%{{http_code}}' {shlex.quote(args.ha_url)} || true"
            if args.ha_url
            else "echo 'skipped (no --ha-url given)'",
        ),
        ("hostname", "hostname"),
        ("mDNS name", "grep -o '<name[^<]*</name>' /etc/avahi/services/dashboard-assistant.service | head -1"),
    ]:
        out, _, _ = sh.run(cmd, timeout=40)
        print(f"{label:<16} {' '.join(out) if out else '-'}")

    print(
        "\nIf the integration is installed, Home Assistant should now discover\n"
        "this device over mDNS as _dashboard-assistant._tcp."
    )


if __name__ == "__main__":
    main()
