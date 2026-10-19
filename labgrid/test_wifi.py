"""A device takes its Wi-Fi from a seed file and runs on the Bench Wi-Fi alone.

Asserting that a credentials file was written is the weaker half of the claim.
The half users care about is that the **device** actually runs with no wired
connection — and that is testable here in a way it is not on most benches,
because the harness drives the board over its **serial console**, not over the
network. Taking the wire away therefore costs no control over a board that has
just lost its only wired path, which makes the genuine assertion cheap.

The credentials arrive on the **FIRMWARE partition** and are applied by a boot,
because that is the path a user takes: write a file onto the card, put the card
in, power on. Injecting them into a running device would test a path nobody
uses.

The Bench Wi-Fi itself is provisioned on the site's access point, outside this
repository, and its credentials are declared in `secretspec.toml` rather than
committed — so a bench without them skips rather than fails. The passphrase
still crosses the board's serial console on its way onto the card, and so
appears in `labgrid/logs/`; see `seeded_wifi` below.

Runs last in the suite, and the ordering is not incidental: this reboots the
board and takes its network away, which is a poor state to hand to anything
else. The wire is restored whatever happens (see the `wired_link_down`
fixture), but a reboot is not something to make every other assertion pay for.
"""

import json
import urllib.error
import urllib.request

import pytest

import bench_ha
import device

#: Every assertion in this file needs a board on the bench's own network
#: segment. The x86_64 QEMU target has none, so the whole file skips there
#: rather than failing — see capability.missing_bench_place.
pytestmark = pytest.mark.usefixtures("on_the_bench")

#: The device's cleartext LAN API port (modules/core/ha-api.nix). `/api/ha/identify`
#: on it is unauthenticated and side-effect free — it returns the node id, the
#: friendly name and the TLS port, all of which the mDNS advertisement already
#: implies — so it is the right thing to knock on from off the board.
API_PORT = 8081
IDENTIFY_PATH = "/api/ha/identify"

#: How long to let the radio associate and DHCP answer after the boot that
#: applies the seed. An access point on another floor is slow; a gate that
#: fails for being early teaches people to re-run it.
ASSOCIATION_TIMEOUT = 120


def joined_network(shell):
    """The network the board's radio has joined, or None.

    Asks the board which interface its radio is before asking `iw` about it:
    a Pi 5 calls it wlan0 and an x86 box something derived from its PCI path,
    and a hardcoded name would turn a harness bug into "the Wi-Fi never came
    up".
    """
    radio = device.wireless_interface("\n".join(shell.run(device.ADDR_COMMAND)[0]))
    if not radio:
        return None
    return device.associated_ssid(
        "\n".join(shell.run(device.association_command(radio))[0])
    )


def identify(address, timeout=10):
    """Ask the device who it is, over the network, from off the board."""
    with urllib.request.urlopen(
        f"http://{address}:{API_PORT}{IDENTIFY_PATH}", timeout=timeout
    ) as response:
        return json.load(response)


@pytest.fixture(scope="session")
def seeded_wifi(shell, _bench, bench_wifi, bench_ha_url):
    """The board rebooted with Wi-Fi credentials on its FIRMWARE partition.

    The file is written to the partition and then the board is *rebooted*, so
    the credentials are delivered the way a user delivers them rather than
    poked into a running system. The file and the importer's content hash are
    removed on the way out, so a later run on this card cannot find itself
    already on the Bench Wi-Fi and pass without having done anything.

    The passphrase does cross the board's serial console, because the console
    is the only channel to a board that has not got a network yet — so it lands
    in `labgrid/logs/`, which is gitignored but is a real file on the machine
    running this. Nothing can fix that short of writing the card from the bench
    host, and saying so is better than implying otherwise: **do not attach a
    bench transcript to a public issue.** What is avoided is a *second* copy —
    the seed is assembled in memory and never written to disk here, and it is
    removed from the card afterwards.
    """
    seed = device.wifi_seed(bench_ha_url, bench_wifi.ssid, bench_wifi.psk)
    path = "/boot/dashboard-assistant.yaml"

    shell.run_check("mountpoint -q /boot")
    # Re-arm the importer: re-import is gated on the seed file's content hash,
    # so a board that has seen this exact file before would ignore it.
    shell.run("rm -f /var/lib/dashboard-assistant/seed-hash")
    shell.run_check(f"cat > {path} <<'EOF'\n{seed}EOF")
    try:
        # The same ShellDriver instance comes back — reboot() deactivates and
        # reactivates it rather than building a new one.
        _bench.reboot()
        bench_ha.wait_until(
            lambda: joined_network(shell) == bench_wifi.ssid,
            bench_ha.device_side(
                f"association with the Bench Wi-Fi after a boot that carried "
                f"its credentials on {path}"
            ),
            ASSOCIATION_TIMEOUT,
        )
        yield shell
    finally:
        shell.run(f"rm -f {path}")
        shell.run("rm -f /var/lib/dashboard-assistant/seed-hash")


def test_the_credentials_arrived_by_seed_file_on_the_firmware_partition(seeded_wifi):
    """The seed was read at boot, not poked in afterwards.

    The importer records the hash of what it imported, and that record is the
    device's own evidence that a file on the firmware partition is where the
    credentials came from.
    """
    out, _, _ = seeded_wifi.run("cat /var/lib/dashboard-assistant/seed-hash")
    assert out and out[0].strip(), bench_ha.device_side(
        "no seed-hash after the boot — the importer never read the file on the "
        "firmware partition, so whatever the radio is doing, it is not doing it "
        "because of this test"
    )


def test_the_device_associated_with_the_bench_wifi_and_got_an_address(
    seeded_wifi, bench_wifi
):
    """Associated *and* addressed. Either alone is a half-connected board."""
    brief = "\n".join(seeded_wifi.run(device.ADDR_COMMAND)[0])
    joined = joined_network(seeded_wifi)
    assert joined == bench_wifi.ssid, bench_ha.device_side(
        f"the radio joined {joined!r}, not the Bench Wi-Fi"
    )
    assert device.wireless_address(brief), bench_ha.device_side(
        f"the radio associated but has no address:\n{brief}"
    )


def test_the_device_runs_on_the_bench_wifi_alone(
    seeded_wifi, wired_link_down, paired, bench_home_assistant
):
    """The assertion the whole file exists for, and the only expensive one.

    Both halves live in one test because they are about one state of the
    hardware: the wire is down, and taking it down and putting it back twice
    would double the settling for nothing. Each assertion still names its own
    half, so a failure says whether it was the device that stopped answering or
    Home Assistant that failed to follow it.

    The harness still has the board throughout, because the harness was never
    using the network — that is what makes this affordable here.
    """
    shell = seeded_wifi
    brief = "\n".join(shell.run(device.ADDR_COMMAND)[0])
    assert device.wired_address(brief) is None, bench_ha.device_side(
        f"{wired_link_down} still has an address with the link down, so "
        f"nothing below would have proved anything:\n{brief}"
    )
    address = device.wireless_address(brief)
    assert address, bench_ha.device_side(
        f"the radio lost its address when the wire went down:\n{brief}"
    )

    # Device side: the API answers, and the answer cannot have come over
    # ethernet because there is no ethernet.
    answer = bench_ha.wait_until(
        lambda: _identify_or_none(address),
        bench_ha.device_side(
            f"an answer from {address}:{API_PORT}{IDENTIFY_PATH} with "
            f"{wired_link_down} down — the device API is not reachable over "
            "Wi-Fi alone"
        ),
        ASSOCIATION_TIMEOUT,
    )
    assert answer.get("node_id"), bench_ha.device_side(
        f"the device API answered over Wi-Fi without a node id: {answer!r}"
    )

    # Home Assistant side: it always opens the connection *to* the device
    # (ADR 0002), so a device that changes address is one it has to follow. The
    # integration de-duplicates by the node id from /api/ha/identify and
    # updates the entry rather than adding a second one. If it does not follow,
    # the entities go unavailable and the user's dashboard quietly stops
    # working — which is the failure this catches.
    bench_ha.wait_until(
        lambda: _all_answering(bench_home_assistant, paired.entities),
        bench_ha.ha_side(
            f"every entity of {paired.device['id']} answering with "
            f"{wired_link_down} down. Home Assistant has not followed the "
            f"device to {address}, so a device that changes network quietly "
            "stops working"
        ),
        ASSOCIATION_TIMEOUT,
    )


def _identify_or_none(address):
    """`identify`, with a refused connection as an answer rather than a crash.

    A board that has just lost its wire refuses connections for a moment while
    routes settle, and the waiting is the caller's job.
    """
    try:
        return identify(address)
    except (OSError, urllib.error.URLError, ValueError):
        return None


def _all_answering(client, entity_ids):
    """Whether every entity is answering. See bench_ha.unanswering."""
    return not bench_ha.unanswering(client.states(), entity_ids)
