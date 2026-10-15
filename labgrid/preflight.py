#!/usr/bin/env python3
"""Prove the bench is healthy before anything blames the image — `just hw-preflight`.

A release gate is only worth having if a red run means the image is bad. This
bench has already broken that once: a Debug Probe and a USB-SD-Mux sharing a USB
controller cost 34% of the board's serial bytes, and the run reported
"3 passed, 13 skipped, 1 error" — which looks nothing like a hardware fault. A
morning went into the wrong half of the system. See README.md, "What this bench
found".

So this runs first and reports a **bench fault** as its own outcome, in its own
words, before a card is written. Every check it makes is one this README already
told someone to make by hand; the only new thing is that nobody has to remember.

    ok    the bench can do this
    warn  worth knowing, not worth stopping for — a measurement is the authority
    fail  the bench cannot do this, and no test result from it means anything
    skip  not measured here, and said so rather than assumed

Must run under $LABGRID_PYTHON (see flake.nix), like flash.py — bare python3 in
the dev shell is whichever interpreter landed on PATH first, which is usually not
the one holding labgrid.
"""

import argparse
import collections
import re
import subprocess
import sys
import time

#: One answer. `status` is one of ok / warn / fail / skip, above.
Check = collections.namedtuple("Check", "name status detail")

#: A line the board echoes back while the console is measured. Fixed length and
#: no shell metacharacters, so a lost byte shows up as a line that does not
#: match rather than as a line that is merely reordered.
SENTINEL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

#: How many lines to echo. The README's by-hand version uses 40, and so does
#: this, so a number from one can be compared with the other.
SERIAL_LINES = 40

#: Linux reports block-device size in 512-byte sectors regardless of the
#: device's own sector size.
SECTOR_BYTES = 512

#: How many times to ask the medium for its size, a second apart. Switching the
#: mux is not the same thing as the block device being ready: measured on this
#: bench, it reports 0 for the first second or so and then its real size. One
#: read would call a present card an empty slot — see read_medium_size.
MEDIUM_ATTEMPTS = 8


# --------------------------------------------------------------------------- #
# Verdicts — pure, and tested without a bench (test_preflight.py)
# --------------------------------------------------------------------------- #


def read_medium_size(read, attempts=MEDIUM_ATTEMPTS, pause=1.0, sleep=time.sleep):
    """Ask `read` for the medium's size until it reports one, and return the text.

    The mux switching and the block device being usable are two different
    events, about a second apart, and nothing tells us when the second one
    happens: an absent card and a card that has not enumerated yet both report
    0. labgrid's own storage driver waits for the medium for exactly this
    reason; this check has to wait too, or it calls a card that is sitting right
    there an empty slot. Which is the most expensive wrong answer available
    here — it stops every run and sends someone to look at hardware that is
    fine.

    `sleep` is injectable so the waiting can be tested without doing any.
    """
    value = ""
    for attempt in range(attempts):
        value = read().strip()
        if value and value != "0":
            return value
        if attempt < attempts - 1:
            sleep(pause)
    return value


def card_verdict(size_output):
    """Is there a card in the mux, judged from /sys/block/<dev>/size.

    The card is the one part of this bench nothing on the network can see, and
    an empty slot is indistinguishable from a card routed to the board —
    both report 0. So this is only meaningful with the card routed to the bench
    host, which is what the caller does before asking.

    Without this check the symptom is a "timeout while waiting for medium" from
    the write step, several minutes in.
    """
    text = size_output.strip()
    try:
        sectors = int(text)
    except ValueError:
        return Check(
            "card in the mux",
            "fail",
            f"could not read the medium's size: {text!r}",
        )
    if sectors == 0:
        return Check(
            "card in the mux",
            "fail",
            "no card in the mux (the medium reports size 0 with the card routed "
            "here, which means the slot is empty)",
        )
    gib = sectors * SECTOR_BYTES / 1024**3
    return Check("card in the mux", "ok", f"{gib:.1f} GiB medium")


def controller_verdict(probe_path, mux_path):
    """Are the Debug Probe and the USB-SD-Mux on the same USB controller?

    A warning, never a failure. Sharing one controller starves the probe's
    CDC-ACM endpoint while ~4 GiB goes through the mux, which is how this bench
    lost a third of its serial bytes — but the harness now finishes the write
    and deactivates the storage driver before the console is ever opened, and on
    a host with a single xHCI controller they cannot be separated at all. The
    byte-loss measurement is the authority; this only says where to look first.
    """
    name = "probe and mux on separate USB controllers"
    probe = re.search(r"/(usb\d+)/", probe_path)
    mux = re.search(r"/(usb\d+)/", mux_path)
    if not probe or not mux:
        unreadable = probe_path if not probe else mux_path
        return Check(
            name,
            "warn",
            f"could not tell which controller from {unreadable!r} — "
            "measure the console instead of assuming",
        )
    if probe.group(1) == mux.group(1):
        return Check(
            name,
            "warn",
            f"both on {probe.group(1)}; writing an image can shred the console. "
            "If the console measures lossy, this is the first thing to look at",
        )
    return Check(name, "ok", f"probe on {probe.group(1)}, mux on {mux.group(1)}")


def serial_verdict(intact, total):
    """How much of what the board said actually arrived.

    The measurement that settles a lossy console, and the reason it is worth
    making: loss presents as clean *deletions*, not garbled characters, so a
    prompt arrives looking almost right and the failure reads as a bad regex.
    No regex can fix it, and relaxing one wastes the afternoon.
    """
    name = "serial console loses no bytes"
    if intact is None:
        return Check(
            name,
            "skip",
            f"not measured — needs a board at a shell, so pass --serial on a "
            f"bench whose card already carries a bootable image",
        )
    if intact == total:
        return Check(name, "ok", f"{intact}/{total} lines intact")
    return Check(
        name,
        "fail",
        f"{intact}/{total} lines intact — the console is dropping bytes. Check "
        "the USB topology before suspecting anything in software; a lossy "
        "console imitates a wrong prompt regex and no regex can fix it",
    )


def is_healthy(checks):
    """Whether the bench may be trusted to produce a meaningful test result."""
    return not any(check.status == "fail" for check in checks)


#: What each status looks like in the report. Spelled out rather than coloured:
#: this ends up in a transcript someone reads days later.
GLYPH = {"ok": "ok  ", "warn": "warn", "fail": "FAIL", "skip": "skip"}


def report(checks):
    """The whole verdict as text, bench faults named as such."""
    lines = ["bench preflight:"]
    for check in checks:
        lines.append(f"  [{GLYPH[check.status]}] {check.name}: {check.detail}")
    if is_healthy(checks):
        lines.append("bench is healthy — a failure from here is the image's")
    else:
        failed = ", ".join(c.name for c in checks if c.status == "fail")
        lines.append(
            f"BENCH FAULT: {failed}. This is the bench, not the image under "
            "test — no test result from this run means anything"
        )
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# Gathering — the impure half
# --------------------------------------------------------------------------- #


def on_bench_host(resource, command):
    """Run `command` on the host the resource is exported from, and return stdout.

    Uses labgrid's own wrapping rather than an ssh invocation of our own, so the
    hostname, the proxy and the ssh options are the ones the exporter published
    and there is no second copy of them here to drift.
    """
    wrapped = resource.wrap_command(["sh", "-c", command])
    done = subprocess.run(wrapped, capture_output=True, text=True, timeout=60)
    return done.stdout + done.stderr


def measure_serial_loss(shell, lines=SERIAL_LINES):
    """Echo a known line `lines` times from the board and count what arrives whole.

    The harness's version of the README's by-hand check. Driven through the
    ShellDriver so it measures the path the tests actually use — ser2net, the
    proxy and the probe — rather than a port on the bench host.

    A console lossy enough to break the driver's own marker matching raises
    instead of returning, which is itself the answer: nothing arrived whole.
    """
    try:
        output = shell.run(f"for i in $(seq 1 {lines}); do echo {SENTINEL}; done")[0]
    except Exception:  # noqa: BLE001 - any failure here is a lossy console
        return 0
    return sum(1 for line in output if line.strip() == SENTINEL)


def gather(target, measure_serial=False):
    """Every check, in the order a human would make them."""
    from labgrid.resource import NetworkPowerPort, NetworkSerialPort
    from labgrid.resource.remote import NetworkUSBSDMuxDevice

    import bench
    import capability

    checks = []
    published = {type(resource).__name__ for resource in target.resources}

    # The place first: every later check needs a resource, and "the exporter
    # never published it" is a different fault from "the hardware is broken".
    for name in capability.CAPABILITIES:
        unmet = capability.missing_resource(name, published)
        checks.append(
            Check(f"place publishes {name}", "fail", unmet)
            if unmet
            else Check(f"place publishes {name}", "ok", "published")
        )
    if not is_healthy(checks):
        return checks

    mux = target.get_resource(NetworkUSBSDMuxDevice, wait_avail=False)
    serial = target.get_resource(NetworkSerialPort, wait_avail=False)
    power = target.get_resource(NetworkPowerPort, wait_avail=False)

    # Unattended ssh to the bench host. Worth its own check because the failure
    # is so badly disguised: a key that cannot sign counts as a failed
    # authentication, and OpenSSH's per-source penalties then drop every
    # connection from this address for an hour, which presents as a connection
    # reset and looks nothing like a key problem.
    probe = on_bench_host(mux, "echo reachable").strip()
    if "reachable" not in probe:
        checks.append(
            Check(
                "unattended ssh to the bench host",
                "fail",
                f"no shell on the bench host: {probe!r}. A key that cannot sign "
                "unattended is worse than no key — one failed attempt can lock "
                "this address out for an hour (see README.md)",
            )
        )
        return checks
    checks.append(Check("unattended ssh to the bench host", "ok", "reachable"))

    # The mux has to be switchable at all: without the sg kernel module labgrid
    # finds the device over udev but never finds a control interface, and
    # reports it with a null control path.
    if not mux.control_path:
        checks.append(
            Check(
                "mux is switchable",
                "fail",
                "the mux has no control path — the bench host is probably "
                "missing the sg kernel module",
            )
        )
        return checks
    checks.append(Check("mux is switchable", "ok", f"control at {mux.control_path}"))

    # Route the card here to measure it, then hand it back whatever happens: a
    # preflight that leaves the card pointed at the wrong end has broken the
    # thing it was checking.
    #
    # Power down first, for the same reason the strategy's `flashed` transition
    # does: the card is about to be pulled out from under whatever is running on
    # the board. That is not hypothetical here — the documented
    # iterate-on-assertions workflow (`just hw-acquire` plus
    # `--lg-initial-state shell`) leaves a board booted off this card, and this
    # is advertised as the first thing to run when a run looks wrong. Yanking a
    # live btrfs root is a poor way to start diagnosing anything.
    #
    # The board is left de-energised afterwards. Switching the mux cannot be
    # done safely any other way, so a preflight is not quite read-only, and
    # saying so is better than a surprise.
    rail = target.get_driver("PowerProtocol")
    target.activate(rail)
    rail.off()

    driver = target.get_driver("USBSDMuxDriver")
    target.activate(driver)
    try:
        driver.set_mode("host")
        node = mux.path.split("/")[-1]
        size = read_medium_size(
            lambda: on_bench_host(mux, f"cat /sys/block/{node}/size")
        )
        checks.append(card_verdict(size))
    finally:
        driver.set_mode("dut")

    checks.append(
        controller_verdict(
            on_bench_host(serial, f"readlink -f /sys/class/tty/{serial.extra['path'].split('/')[-1]}/device"),
            on_bench_host(mux, f"readlink -f /sys/block/{mux.path.split('/')[-1]}/device"),
        )
    )

    # The plug has to meter, not merely switch. That measurement is what tells a
    # board that is not running from a console that is not working.
    try:
        watts = bench.plug_draw(power.host)
        state = bench.plug_state(power.host)
        # Reads 0 W with the rail cut above, which is a working meter
        # reporting an off board — the check is that it answers at all.
        checks.append(Check("plug meters", "ok", f"relay {state}, {watts} W"))
    except Exception as err:  # noqa: BLE001 - an ESP on Wi-Fi fails many ways
        checks.append(
            Check("plug meters", "fail", f"no reading from the plug: {err!r}")
        )

    if measure_serial:
        from strategy import Status

        strategy = target.get_driver("Strategy")
        # Enter at `flashed` rather than asking for `shell` outright. The
        # strategy reaches `shell` through `flashed`, which dd's an image onto
        # the card — and this check has no image, nor any business writing one:
        # the point is to measure the console against whatever is already there.
        # Claiming the state is what `force` does for the same reason.
        strategy.status = Status.flashed
        strategy.transition("shell")
        checks.append(
            serial_verdict(measure_serial_loss(strategy.shell), SERIAL_LINES)
        )
    else:
        checks.append(serial_verdict(None, SERIAL_LINES))

    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--serial",
        action="store_true",
        help="also boot the card that is in the mux and measure console loss",
    )
    args = parser.parse_args()

    from labgrid import Environment

    import bench

    target = Environment(config_file=bench.ENV_CONFIG).get_target()
    checks = gather(target, measure_serial=args.serial)
    print(report(checks))
    # A bench fault is not a test failure, and the exit code says so: 2, which
    # no pytest run produces for a failing assertion.
    sys.exit(0 if is_healthy(checks) else 2)


if __name__ == "__main__":
    main()
