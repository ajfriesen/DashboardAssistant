#!/usr/bin/env python3
"""Report the state of every link in the bench chain — `just hw-status`.

Read-only. Written because "the mux is unavailable" can mean the sg module is not
loaded, the udev ACL never got applied, there is no card in the slot, or the mux is
simply in DUT mode — and telling those apart one command at a time is tedious.

Runs under $LABGRID_PYTHON (see flake.nix); bare python3 in the dev shell is not
the interpreter that has labgrid.
"""

import os
import shutil
import subprocess
import sys

from labgrid import Environment
from labgrid.resource.udev import USBSDMuxDevice
from labgrid.resource.serialport import RawSerialPort

import bench

OK = "ok"
BAD = "FAIL"


def line(label, verdict, detail=""):
    mark = "+" if verdict else "-"
    print(f" {mark} {label:<22} {detail}")


def access(path):
    """How this process may use a device node."""
    if not os.path.exists(path):
        return "missing"
    bits = ("r" if os.access(path, os.R_OK) else "-") + (
        "w" if os.access(path, os.W_OK) else "-"
    )
    st = os.stat(path)
    return f"{bits} (mode {oct(st.st_mode & 0o777)[2:]})"


def main():
    print("Host")
    sg_loaded = "sg" in subprocess.run(
        ["lsmod"], capture_output=True, text=True, check=False
    ).stdout.split()
    line("sg module", sg_loaded, "loaded" if sg_loaded else "NOT loaded — the mux has no control device")

    usbsdmux = shutil.which("usbsdmux")
    line("usbsdmux binary", bool(usbsdmux), usbsdmux or "not on PATH")

    print("\nlabgrid resources")
    env = Environment(config_file=bench.ENV_CONFIG)
    target = env.get_target()
    # Refreshes every resource from udev, which is what recomputes avail.
    target.update_resources()

    mux = disk = control = None
    for resource in target.resources:
        if isinstance(resource, USBSDMuxDevice):
            mux = resource
            control, disk = resource.control_path, resource.disk_path
            line(
                "USBSDMuxDevice",
                resource.avail,
                f"avail={resource.avail} control={control} disk={disk}",
            )
        elif isinstance(resource, RawSerialPort):
            ok = os.path.exists(resource.port) and os.access(resource.port, os.W_OK)
            line("RawSerialPort", ok, f"{resource.port} -> {access(resource.port)}")
        else:
            line(resource.__class__.__name__, resource.avail, f"avail={resource.avail}")

    if mux is None:
        print("\nno USBSDMuxDevice in the environment", file=sys.stderr)
        return 1

    print("\nUSB-SD-Mux")
    if control:
        line("control node", "w" in access(control), f"{control} -> {access(control)}")
        # Reading the mode is the real permission test: it is the same SCSI path
        # the driver uses, so a failure here is exactly what a flash would hit.
        mode = subprocess.run(
            [usbsdmux or "usbsdmux", control, "get"],
            capture_output=True,
            text=True,
            check=False,
        )
        detail = (mode.stdout or mode.stderr).strip().splitlines()
        line("mode", mode.returncode == 0, detail[-1] if detail else "no output")
    else:
        line("control node", False, "none — is the sg module loaded?")

    if disk:
        line("block node", "w" in access(disk), f"{disk} -> {access(disk)}")
        try:
            with open(f"/sys/block/{os.path.basename(disk)}/size") as fh:
                blocks = int(fh.read().strip())
        except OSError:
            blocks = 0
        size = blocks * 512
        # Size 0 is normal in DUT mode — the card is routed to the board, not here.
        # It only means "no card" if the mux is in host mode.
        line(
            "card visible here",
            size > 0,
            f"{size / 1e9:.1f} GB" if size else "0 (expected in DUT mode)",
        )
    else:
        line("block node", False, "none")

    print("\nPower")
    try:
        line("plug", True, f"state={bench.plug('state')} draw={bench.plug('draw')} W")
    except (subprocess.CalledProcessError, OSError) as e:
        line("plug", False, f"unreachable: {e}")

    print("\nImage")
    image = bench.find_image()
    line(
        "rpi5 dev image",
        bool(image),
        f"{image} ({os.path.getsize(image) / 1e9:.1f} GB)"
        if image
        else "none — run `just build-rpi5-dev`",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
