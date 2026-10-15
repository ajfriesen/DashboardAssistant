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
  * what answers on the network — a **Bench Home Assistant** is not a labgrid
    resource either, so the question is asked of the address itself
    (missing_bench_home_assistant)
  * what this run was given — the key the release gate signs with
    (gate_key_choice) and the Bench Wi-Fi's credentials
    (missing_wifi_credentials). Both are secrets that are deliberately not in
    this repository, so "absent" has to mean "this bench is not set up for
    that", never "the image is broken"

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


def missing_bench_place(published):
    """Reason to skip a test needing a device on a real network segment, or None.

    The journey assertions — discovery, pairing, the kiosk's browser, Wi-Fi —
    all need a board that other machines can open connections *to*. The x86_64
    QEMU target is not that: user-mode networking carries no mDNS and puts the
    guest behind a NAT with no route in, and Home Assistant always dials the
    device (docs/adr/0002). So it is a different target, not a defect in the
    image under test.

    Derived from the place rather than measured, deliberately. "Can I reach the
    device right now" would also be true on a bench where the device has
    genuinely stopped answering — and a skip is the wrong answer to that. What
    is asked here is whether this target is a bench at all, which a VM can
    never become by breaking.
    """
    if CAPABILITIES["console"][0] in published:
        return None
    return (
        "this target drives a local VM, not a board on the bench's own network "
        "segment — nothing can open a connection to it, so discovery, pairing "
        "and a tunnel to its browser cannot happen here"
    )


def missing_bench_home_assistant(url, is_reachable):
    """Reason to skip a test needing the Bench Home Assistant, or None.

    Two different answers, deliberately kept apart. A target with no URL
    configured simply has no Home Assistant — the x86_64 QEMU target is one,
    because user-mode networking carries no mDNS and Home Assistant opens the
    connection *to* a device, so there is nothing there to pair with. A target
    that has one and cannot reach it is a bench that is half up, and the reason
    names the address so nobody goes looking in the image for it.

    Neither is a failure: the suite has to run on a laptop with no bench at all.
    """
    if not url:
        return (
            "no Bench Home Assistant on this target — set BENCH_HA_URL (the "
            "justfile defaults it for the bench) to run the pairing journey"
        )
    if not is_reachable:
        return (
            f"nothing answers at {url} — the Bench Home Assistant is not up, "
            "which is the bench rather than the image under test"
        )
    return None


#: Where the key the release gate signs with is expected to be. Declared on dev
#: images in modules/dev.nix; the private half lives on the bench host and in
#: the operator's password manager, never in this repository.
GATE_KEY = "~/.ssh/id_ed25519_bench"


def gate_key_choice(path, private_exists, public_exists):
    """Which file to hand `ssh -i`, and the reason to skip if neither will do.

    Returns `(key, None)` or `(None, reason)`.

    The private half is usually not on disk. It lives in the operator's password
    manager and is served by an ssh-agent, which leaves only `<path>.pub` in
    `~/.ssh` — and that is enough: given a *public* key file and an agent
    holding its private half, ssh uses the agent. So the public key is a first
    class answer here rather than a fallback, and `IdentitiesOnly=yes` then
    means "that one agent key", which is exactly what is wanted.

    Checked before connecting rather than after failing, because the failure is
    not recoverable within a run: an attempt with a key that cannot sign counts
    as a failed authentication, and OpenSSH's per-source penalties then drop
    every further connection from this address for an hour — taking the rest of
    the suite with it. See labgrid/README.md.
    """
    if private_exists:
        return path, None
    if public_exists:
        return f"{path}.pub", None
    return None, (
        f"no key at {path} or {path}.pub — the release gate cannot log into "
        "the device without a human. Do not substitute another key: one that "
        "cannot sign unattended locks this address out of the board for an hour"
    )


#: The Bench Wi-Fi's credentials, declared in secretspec.toml and resolved into
#: the environment by `secretspec run`. Never committed: the access point is the
#: site's, and the passphrase is not this repository's to hold.
WIFI_SSID_ENV = "BENCH_WIFI_SSID"
WIFI_PSK_ENV = "BENCH_WIFI_PSK"


def missing_wifi_credentials(ssid, psk):
    """Reason to skip a test needing the Bench Wi-Fi, or None.

    Names the declarations that are unset, never the values — this reason ends
    up in a transcript that is not private, and one of the two values is a
    passphrase.
    """
    unset = [
        name
        for name, value in ((WIFI_SSID_ENV, ssid), (WIFI_PSK_ENV, psk))
        if not value
    ]
    if not unset:
        return None
    return (
        f"the Bench Wi-Fi's credentials are not in this run's environment "
        f"({', '.join(unset)} unset) — they are declared in secretspec.toml, "
        "so run through `secretspec run -- just hw-test`"
    )
