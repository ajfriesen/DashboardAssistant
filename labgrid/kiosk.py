"""Reaching the kiosk's browser from off the device, and reading what it shows.

Every other assertion in this suite stops one step short of the thing the
product is for: a **dashboard** on the screen. This is the step. The failure it
catches is a **kiosk token** that never arrived, which renders a perfectly
healthy *login page* on a device that is reachable, provisioned, paired,
unfailed and useless — a screenshot cannot tell those two apart, and the absence
of a login form can.

How it gets there, and why it is not simpler:

  * The browser's debugging port is bound to loopback on every image, release
    and dev alike, and must stay that way: it is unauthenticated and already
    runs with `--remote-allow-origins=*`, so publishing it would put remote code
    execution on every device on every network. So nothing on the board is
    opened — the port is forwarded over ssh instead.
  * That ssh needs a key that signs with nobody present. Dev images declare one
    (modules/dev.nix); release images deliberately declare none, which is why
    this file only ever runs against a dev image. **Never substitute another
    key**: one that cannot sign counts as a failed authentication, and OpenSSH's
    per-source penalties then lock this address out of the board for an hour.
  * The page is read with Playwright rather than raw CDP, because the assertion
    has to *wait* for the page rather than sleep at it, and because its CSS
    engine pierces open shadow roots — Home Assistant's entire UI lives in them.
    Playwright and the kiosk's Chromium are a married pair, and here they cannot
    drift: both come out of the one pinned nixpkgs (docs/adr/0008), so
    `nix flake update nixpkgs-unstable` moves them together. See
    labgrid/README.md.

The decisions are kept pure at the top so the ssh invocation and the verdict on
what is on screen can be tested with no board and no browser — see
test_kiosk.py.
"""

import contextlib
import socket
import subprocess
import time

#: The device's debugging port, as bound inside the device. modules/core/kiosk.nix
#: passes `--remote-debugging-port=9222` and nothing else, which binds it to
#: 127.0.0.1; the release-has-no-unattended-access check in flake.nix fails if
#: that ever stops being true.
CDP_PORT = 9222

#: Our end of the forward. Deliberately not 9222: `just qemu-ssh` already
#: forwards the QEMU target's CDP to 9222 on this machine, and a bench run must
#: not silently attach to a QEMU guest somebody left running in another
#: terminal — which would be a green gate against the wrong device entirely.
LOCAL_CDP_PORT = 19222

#: ssh options shared by the shell and the tunnel. BatchMode because an
#: interactive prompt in an unattended run is a hang, and a hang on the bench
#: holds the place against everybody else. IdentitiesOnly because without it ssh
#: offers every other key first, and one that cannot sign trips the per-source
#: penalty described above. The host-key options because the board is reflashed
#: on most runs and regenerates its host key each time, so a known_hosts entry
#: would turn every second run into a host-key failure.
SSH_OPTIONS = [
    "-o",
    "BatchMode=yes",
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    "-o",
    "ConnectTimeout=10",
    # Without this, `ssh -L` on a port that is already bound logs "bind:
    # Address already in use" and *keeps running*. The tunnel would then look
    # perfectly healthy — the process is alive and the port accepts — while
    # the connection actually goes to whatever already owned it: a leaked
    # `ssh -N` from a killed run, pointing at a board that has since been
    # reflashed. That is the green-gate-against-the-wrong-device failure this
    # whole file is supposed to prevent.
    "-o",
    "ExitOnForwardFailure=yes",
]


def ssh_argv(host, key, command, user="root"):
    """Run `command` on the device over the bench key."""
    return ["ssh", *SSH_OPTIONS, "-i", key, f"{user}@{host}", *command]


def tunnel_argv(host, key, local_port=LOCAL_CDP_PORT, remote_port=CDP_PORT, user="root"):
    """Forward `local_port` here to `remote_port` on the device's loopback.

    The remote end is 127.0.0.1 *as the device sees it* — that is the whole
    point. Pointing it at the device's own address would only work on a board
    that had exposed the port, which is exactly what must never happen.
    """
    return [
        "ssh",
        *SSH_OPTIONS,
        "-N",
        "-L",
        f"{local_port}:127.0.0.1:{remote_port}",
        "-i",
        key,
        f"{user}@{host}",
    ]


# --------------------------------------------------------------------------- #
# What is on the screen
# --------------------------------------------------------------------------- #

#: A rendered Lovelace view. `hui-view` rather than `ha-panel-lovelace`, which
#: exists while the panel is still loading and would therefore match a blank
#: screen. Playwright's CSS engine pierces open shadow roots, and Home
#: Assistant's are all open, so this finds it however deeply nested it is.
DASHBOARD_SELECTOR = "hui-view"

#: The login page. `ha-authorize` is its root element; the username field is
#: there in case the element is ever renamed, since this is the assertion that
#: catches the failure the whole test exists for.
LOGIN_SELECTOR = "ha-authorize, input[name='username']"

#: How long to let the kiosk get as far as rendering something. Generous: this
#: runs right after pairing, and the kiosk reloads itself once the token lands,
#: so the page under the microscope may be the *second* one the browser loads.
RENDER_TIMEOUT = 120

#: Both at once, which is what the wait asks for. Waiting for the dashboard
#: alone would turn the one interesting failure into a bare timeout — and a
#: timeout says nothing about what was actually on the screen.
EITHER_SELECTOR = f"{DASHBOARD_SELECTOR}, {LOGIN_SELECTOR}"


def page_verdict(has_dashboard, has_login):
    """Why the kiosk is not showing a dashboard, or None if it is."""
    if has_login:
        return (
            "a login form is on the kiosk's screen — the kiosk token never "
            "arrived, so the device is reachable, provisioned, paired and "
            "useless. This is the failure the whole journey exists to catch"
            + (", and it is rendered over a dashboard view" if has_dashboard else "")
        )
    if not has_dashboard:
        return (
            f"no {DASHBOARD_SELECTOR} in the kiosk's page and no login form "
            "either — the page never rendered at all"
        )
    return None


# --------------------------------------------------------------------------- #
# Getting there
# --------------------------------------------------------------------------- #


def port_is_open(port, host="127.0.0.1", timeout=1):
    """Whether something accepts connections on `port`."""
    with contextlib.closing(socket.socket()) as probe:
        probe.settimeout(timeout)
        return probe.connect_ex((host, port)) == 0


@contextlib.contextmanager
def tunnel(host, key, local_port=LOCAL_CDP_PORT, remote_port=CDP_PORT, timeout=30):
    """An ssh port-forward to the device's debugging port, for the block's life.

    Waits for the forward to accept rather than sleeping at it, and tears it
    down on the way out whatever happened — a leaked `ssh -N` would hold the
    local port and make the *next* run attach to a tunnel pointing at a board
    that has since been reflashed.
    """
    # Belt as well as braces: ExitOnForwardFailure makes ssh exit rather than
    # linger, but an occupied port is worth naming outright — "the tunnel died"
    # does not tell anyone there is a stale one to go and kill.
    if port_is_open(local_port):
        raise RuntimeError(
            f"127.0.0.1:{local_port} is already in use — something else holds "
            "the tunnel port, most likely a leaked `ssh -N` from an "
            "interrupted run. Attaching to it would assert against whatever "
            "board that one points at. Find it with "
            f"`ss -ltnp 'sport = :{local_port}'`"
        )
    process = subprocess.Popen(
        tunnel_argv(host, key, local_port, remote_port),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                stderr = (process.stderr.read() or b"").decode(errors="replace")
                raise RuntimeError(
                    f"the ssh tunnel to {host} died immediately: {stderr.strip()}"
                )
            if port_is_open(local_port):
                break
            time.sleep(0.2)
        else:
            raise TimeoutError(
                f"the ssh tunnel to {host} never started forwarding "
                f"{local_port} -> 127.0.0.1:{remote_port} within {timeout}s"
            )
        yield local_port
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


#: Pages that are not the kiosk's. `about:blank` turns up as a transient while
#: Chromium is navigating, and devtools:// if anyone has ever opened the
#: inspector against this browser.
NOT_THE_KIOSK = ("about:blank", "chrome://", "devtools://")


def kiosk_page(pages):
    """The one page that is on the screen, out of what the browser reports.

    Raises rather than guessing when there is more than one left: the kiosk
    runs a single page, and asserting against the wrong one would produce a
    verdict about something nobody is looking at.
    """
    if not pages:
        raise AssertionError(
            "the kiosk's browser has no page open at all — Chromium is "
            "running and inspectable, and showing nothing"
        )
    candidates = [
        page for page in pages if not page.url.startswith(NOT_THE_KIOSK)
    ] or pages
    if len(candidates) > 1:
        raise AssertionError(
            "the kiosk's browser has more than one page open "
            f"({[page.url for page in candidates]}) — which one is on the "
            "screen is no longer knowable from here"
        )
    return candidates[0]


@contextlib.contextmanager
def attached_page(local_port=LOCAL_CDP_PORT, timeout=30):
    """The kiosk's live page, over an already-open tunnel.

    Imported lazily, like the websocket client in bench_ha.py, so the pure half
    of this module stays usable in an interpreter that has no Playwright.
    """
    from playwright.sync_api import sync_playwright

    with sync_playwright() as playwright:
        browser = playwright.chromium.connect_over_cdp(
            f"http://127.0.0.1:{local_port}", timeout=timeout * 1000
        )
        try:
            yield kiosk_page(
                [page for context in browser.contexts for page in context.pages]
            )
        finally:
            # For a browser obtained with connect_over_cdp this *disconnects*
            # rather than quitting it — Playwright only terminates browsers it
            # launched itself. The kiosk's Chromium keeps running, which it
            # must: later `needs_display` assertions, and the next person at
            # the bench, are looking at the same screen.
            browser.close()
