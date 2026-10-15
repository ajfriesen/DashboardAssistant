"""The full journey: a flashed device ends up showing a dashboard.

Every assertion in test_first_boot.py stops one step short of what the product
promises. It boots, it is provisioned, its device API answers — and none of that
says a **dashboard** is on the screen. This file is the rest of the journey, run
against a real **Bench Home Assistant** on the bench's own network segment:
discovery with nobody typing anything, the real config flow, **pairing**, a
service call that reaches the device, and finally the **kiosk** logged in and
rendering.

See docs/adr/0012-the-full-journey-is-tested-against-a-real-home-assistant.md.

Three things about how it is written:

  * The enrollment happens once, in the `paired` fixture (conftest.py), and
    every assertion here reads what it produced. A run pairs once, and a
    failure points at one step rather than at the fourth attempt to repeat the
    same four minutes of hardware.
  * Each test name says **which half** it is about. A bad integration release
    can redden this repository's gate — correctly, because the journey spans
    both sides — and that is only tolerable if a red run says where to look.
  * Nothing sleeps. Every wait is a poll with a named thing being waited for,
    so a timeout says what never happened.

The whole file skips itself on a target with no Home Assistant reachable: the
x86_64 QEMU target is one, because user-mode networking carries no mDNS and
Home Assistant opens the connection *to* a device.
"""

import subprocess

import pytest

import bench_ha
import device
import kiosk

#: Every assertion in this file needs a board on the bench's own network
#: segment. The x86_64 QEMU target has none, so the whole file skips there
#: rather than failing — see capability.missing_bench_place.
pytestmark = pytest.mark.usefixtures("on_the_bench")


# --------------------------------------------------------------------------- #
# The channel the gate reaches the device on
#
# These are about modules/dev.nix and modules/core/kiosk.nix rather than about
# Home Assistant, and they come first on purpose: if the gate cannot log in or
# the port is exposed, the dashboard assertion below is either impossible or
# asserting against something that should not exist.
# --------------------------------------------------------------------------- #


def test_the_gate_logs_into_the_device_without_a_human(device_ip, gate_key):
    """A dev image must be reachable by an automated run.

    The two hardware-backed keys beside the bench key in modules/dev.nix cannot
    sign without somebody touching a token, and an unsignable key is worse than
    no key: the failed attempt trips OpenSSH's per-source penalties and locks
    this address out of the board for an hour. So this is the assertion that
    the one key that *can* sign is still there and still accepted.
    """
    done = subprocess.run(
        kiosk.ssh_argv(device_ip, gate_key, ["echo", "gate-is-in"]),
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert "gate-is-in" in done.stdout, (
        f"the release gate cannot log into {device_ip} with {gate_key}: "
        f"{done.stderr.strip()!r}. Do not retry by hand with another key — a "
        "failed authentication locks this address out of the board for an hour"
    )


@pytest.mark.needs_display
def test_the_debugging_port_is_not_exposed_on_the_network(device_ip):
    """The browser's debugging port must answer on loopback and nowhere else.

    It is unauthenticated and runs with `--remote-allow-origins=*`, so a device
    that published it would hand remote code execution to anything on the same
    network — on every dev image, on every network, which is a far larger
    affordance than the documented console password beside it.

    Marked `needs_display` so it cannot pass vacuously: with no kiosk session
    there is no browser listening anywhere, and a closed port would then prove
    nothing at all.
    """
    assert not kiosk.port_is_open(kiosk.CDP_PORT, host=device_ip), (
        f"{device_ip}:{kiosk.CDP_PORT} accepts connections from the network — "
        "the kiosk browser's debugging port is unauthenticated and runs with "
        "permissive origins, so this is remote code execution on anything that "
        "can reach the device. It must stay bound to loopback and be tunnelled"
    )


@pytest.mark.needs_display
def test_the_gate_reaches_the_debugging_port_through_a_tunnel(device_ip, gate_key):
    """...and the tunnel is how the gate gets to it anyway."""
    with kiosk.tunnel(device_ip, gate_key) as port:
        assert kiosk.port_is_open(port), (
            f"the tunnel to {device_ip} is up but nothing answers on "
            f"127.0.0.1:{port} — the kiosk browser is not listening on "
            f"{kiosk.CDP_PORT} inside the device"
        )


# --------------------------------------------------------------------------- #
# Home Assistant's half: discovery, the flow, the entry it creates
# --------------------------------------------------------------------------- #


def test_home_assistant_side_a_discovery_flow_appeared_unprompted(paired):
    """The no-typing promise, asserted rather than assumed.

    Nothing in this run started a flow. The `paired` fixture waits for one to
    already be there, so a flow whose source is `user` would mean somebody had
    to ask — which is the claim being disproved, not evidence for it.
    """
    source = (paired.flow.get("context") or {}).get("source")
    assert source in bench_ha.UNPROMPTED_SOURCES, bench_ha.ha_side(
        f"the config flow was raised by {source!r}, which is not discovery — "
        "the device is supposed to be found, not added by hand"
    )


def test_home_assistant_side_the_flow_completed_and_the_device_is_paired(paired):
    """A created config entry, loaded, with a device behind it."""
    assert paired.entry_id, bench_ha.ha_side("the config flow created no entry")
    assert paired.device, bench_ha.ha_side(
        f"config entry {paired.entry_id} exists but produced no device"
    )


def test_device_side_the_pairing_window_closed_behind_the_integration(paired, shell):
    """Pairing is one-shot, and the device is what enforces it.

    `/api/ha/pair` hands out the device's token while the device has never been
    paired, and closes on first *use* of that token (daemon/pairing.go). So the
    marker's existence is the device's own record that Home Assistant actually
    came and collected it — not merely that a flow completed somewhere.
    """
    marker = "/var/lib/dashboard-assistant/paired"
    out, _, status = shell.run(f"test -e {marker} && echo paired || echo open")
    assert out == ["paired"], bench_ha.device_side(
        f"{marker} is absent after pairing (status {status}) — the integration "
        "completed a flow without ever using the token, so nothing is actually "
        "talking to this device"
    )


def test_home_assistant_side_the_devices_entities_appear(paired):
    assert paired.entities, bench_ha.ha_side(
        f"device {paired.device['id']} was created with no entities at all"
    )


def test_home_assistant_side_the_devices_entities_answer(paired, bench_home_assistant):
    """Present in the registry is not the same as answering.

    An entity whose coordinator cannot reach the device is registered and
    `unavailable`, which is exactly the half-paired state a gate has to catch.
    """
    silent = bench_ha.unanswering(bench_home_assistant.states(), paired.entities)
    assert not silent, bench_ha.ha_side(
        f"entities exist but do not answer: {', '.join(silent)} — Home "
        f"Assistant cannot reach the device at {paired.address}"
    )


# --------------------------------------------------------------------------- #
# The device's half: a call from Home Assistant lands on the board
# --------------------------------------------------------------------------- #


def test_device_side_a_service_call_takes_effect_on_the_device(
    paired, bench_home_assistant, shell
):
    """The round trip, end to end, read off the board itself.

    Zoom is the control, because the daemon persists it to a plain file that
    the serial console can read — so this needs no display, no screenshot and
    no second API, and a failure cannot be the oracle's fault. The value is
    chosen to differ from whatever is there now, so a call that did nothing
    cannot pass by coincidence.
    """
    entity_id = bench_ha.zoom_entity(paired.entities)
    assert entity_id, bench_ha.ha_side(
        "the integration exposes no zoom number entity, so there is no control "
        f"to make a round trip with. It created: {', '.join(paired.entities)}"
    )

    before = device.zoom_level("\n".join(shell.run(f"cat {device.ZOOM_FILE}")[0]))
    wanted = 125 if before != 125 else 150

    bench_home_assistant.call_service("number", "set_value", entity_id, value=wanted)

    def persisted_the_new_level():
        return (
            device.zoom_level("\n".join(shell.run(f"cat {device.ZOOM_FILE}")[0]))
            == wanted
        )

    bench_ha.wait_until(
        persisted_the_new_level,
        bench_ha.device_side(
            f"zoom {wanted}% in {device.ZOOM_FILE} after setting {entity_id}. "
            f"It was {before}, and Home Assistant accepted the call — so the "
            "call reached Home Assistant and stopped there"
        ),
        bench_ha.SERVICE_TIMEOUT,
    )


# --------------------------------------------------------------------------- #
# What the whole journey is for: a dashboard on the screen
# --------------------------------------------------------------------------- #


@pytest.mark.needs_display
def test_the_kiosk_shows_a_dashboard_and_not_a_login_page(paired, device_ip, gate_key):
    """The assertion the product is actually about.

    The failure it catches is a **kiosk token** that never arrived, which
    renders a perfectly healthy *login page* — a device that is reachable,
    provisioned, paired, unfailed and useless. A screenshot cannot tell that
    apart from a working device; the absence of a login form can.

    Waits for *either* the dashboard or the login form rather than for the
    dashboard alone, so the interesting failure arrives as "a login form is on
    the screen" instead of as a bare timeout that says nothing about what was
    there.
    """
    with kiosk.tunnel(device_ip, gate_key) as port:
        with kiosk.attached_page(port) as page:
            # Attached rather than visible: Home Assistant renders inside open
            # shadow roots, and Playwright's visibility check on a custom
            # element nested that deep is a worse oracle than its presence.
            page.locator(kiosk.EITHER_SELECTOR).first.wait_for(
                state="attached", timeout=kiosk.RENDER_TIMEOUT * 1000
            )
            reason = kiosk.page_verdict(
                has_dashboard=page.locator(kiosk.DASHBOARD_SELECTOR).count() > 0,
                has_login=page.locator(kiosk.LOGIN_SELECTOR).count() > 0,
            )
            assert reason is None, f"{reason} (page at {page.url})"
