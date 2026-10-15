"""What this bench can and cannot do, decided from the hardware.

A test must skip when the hardware it needs is not there, and must *not* be
skippable by someone typing the wrong thing. That distinction is not academic
here. `test_no_failed_units` was once marked `needs_display`, README.md
recommended `-m "not needs_display"` for a headless bench, and so a marker
meaning "needs a screen" quietly decided whether a storage bug was visible —
devices shipped with a quarter of their storage. See README.md, "What this bench
found".

So the decision comes from the hardware, never from a flag:

  * what the place publishes — the exporter's resources, so a bench with no
    plug simply has no plug (missing_resource)
  * what the board reports — a panel is not a labgrid resource, so the board is
    asked whether a connector is connected (missing_display)
  * which board the target drives, declared once per environment file alongside
    the place it names (missing_board)

The last one is config rather than a measurement, and it is worth being honest
about why: a Pi boot-chain assertion cannot ask the board what it is, because
the whole point of those assertions is to work when userspace is broken and
there is nobody to ask. So the environment file states which board it drives,
next to the place it names — one declaration per bench, not one flag per run.

Both return a *reason* to skip, or None to run. Keeping them pure keeps them
testable with no bench attached: see test_capability.py.
"""

#: capability -> (labgrid resource class name, what it is there for).
#:
#: The class names are labgrid's, and they are the network-facing ones on
#: purpose: the bench's hardware hangs off the bench host and is reached through
#: the coordinator, so what a place publishes is always the Network* variant
#: (docs/adr/0010-the-bench-is-driven-through-a-labgrid-coordinator.md).
CAPABILITIES = {
    "plug": (
        "NetworkPowerPort",
        "a switchable mains plug that also meters, to tell a board that is not "
        "running from a console that is not working",
    ),
    "card": (
        "NetworkUSBSDMuxDevice",
        "a removable card in a USB-SD-Mux, to flash an image onto the medium the "
        "board actually boots from",
    ),
    "console": (
        "NetworkSerialPort",
        "a serial console, the only transport that survives a board losing its "
        "network",
    ),
}


def missing_resource(capability, published):
    """Reason to skip a test needing `capability`, or None if the place has it.

    `published` is the set of resource class names the acquired place offers.
    An unknown capability raises KeyError rather than passing: a typo in a
    fixture must not read as "the hardware is fine".
    """
    cls, purpose = CAPABILITIES[capability]
    if cls in published:
        return None
    return f"this place publishes no {cls} — needs {purpose}"


def connector_status(output):
    """Parse `grep . /sys/class/drm/*/status` into {connector: status}.

    Lines look like `/sys/class/drm/card1-DSI-1/status:connected`, so the
    connector is the directory holding the file. Anything that is not a
    path:status pair is ignored — an empty glob or a shell error message must
    read as "no connectors", not crash the run.
    """
    found = {}
    for line in output.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        path, _, status = line.rpartition(":")
        parts = path.split("/")
        if len(parts) < 2 or parts[-1] != "status":
            continue
        found[parts[-2]] = status.strip()
    return found


def missing_display(output):
    """Reason to skip a `needs_display` test, or None if something is connected.

    Takes the raw output rather than a parsed dict so a caller only has to run
    one command. The reason names every connector it saw, because "no display"
    and "a display on the connector you did not expect" are different problems
    and the transcript should say which one it is.
    """
    connectors = connector_status(output)
    if not connectors:
        return "no DRM connector on the board — the display stack is not up"
    if "connected" in connectors.values():
        return None
    seen = ", ".join(f"{name}={status}" for name, status in sorted(connectors.items()))
    return f"nothing attached to the board's display outputs ({seen})"


def missing_board(wanted, actual):
    """Reason to skip a test declared for `wanted` boards on an `actual` one.

    `wanted` is what the test's own marker declares; `actual` comes from the
    environment file. A target that declares nothing raises rather than
    matching everything: a boot-chain assertion silently "passing" against
    something with no U-Boot is worse than a loud configuration error.
    """
    if not actual:
        raise ValueError(
            "this environment declares no board — add `options: {board: ...}` "
            "to it, or a test written for one board will run against any of them"
        )
    if actual in wanted:
        return None
    return f"this target drives {actual}, and this test is for {', '.join(sorted(wanted))}"
