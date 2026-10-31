"""What the board says about itself, parsed.

The serial console is the only channel that survives a board losing its
network, which is exactly the situation the Wi-Fi assertions put it in — so
every question here is asked as a shell command and answered by parsing text.
Keeping the parsing separate from the asking is what lets it be tested with no
board attached (test_device.py), and the parsers are worth testing: a wrong one
reads "no address" as "the radio never associated" and sends somebody to look
at an access point that is fine.
"""

import collections
import json

#: One line of `ip -brief addr`. `addresses` keeps the prefix lengths, because
#: a caller that wants a bare address asks for one (see wired_address).
Interface = collections.namedtuple("Interface", "name state addresses")

#: How this project's boards name their wire and their radio. The Pi 5 uses the
#: predictable `end0`, an x86 mini-PC `enp2s0`, and an older image `eth0`;
#: radios are `wld0` (Pi 5), `wlan0` or `wlp1s0`. Matched by prefix rather than
#: listed exactly,
#: because the suffix encodes a PCI path that differs per board.
WIRED_PREFIXES = ("en", "eth")
WIRELESS_PREFIXES = ("wl",)

#: The command whose output `interfaces` parses.
ADDR_COMMAND = "ip -brief addr"


def is_wired(name):
    """Whether `name` is an ethernet interface."""
    return name.startswith(WIRED_PREFIXES)


def is_wireless(name):
    """Whether `name` is a radio."""
    return name.startswith(WIRELESS_PREFIXES)


def interfaces(output):
    """Parse `ip -brief addr` into {name: Interface}, loopback excluded.

    Only the wire and the radio are returned. Loopback is dropped because a
    device answering only on 127.0.0.1 is not on the network at all, and
    letting it through would make every connectivity assertion here pass
    vacuously; anything else — bridges, tethers, a `wwan0` — is dropped because
    this bench has none and silently counting one would let the Wi-Fi
    assertions pass over a path that is not Wi-Fi.

    Anything that is not an interface line is ignored — a shell error message on
    the console must read as "no interfaces", not crash a run several minutes
    into a flash.
    """
    found = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        name, state, *addresses = fields
        if name == "lo" or not (is_wired(name) or is_wireless(name)):
            continue
        found[name] = Interface(name=name, state=state, addresses=addresses)
    return found


def _routable_address(interface):
    """The first address on `interface` that means anything off this link.

    Link-local (fe80::) is excluded: it comes up on its own whether or not DHCP
    ever answered, so accepting it would call an unconfigured interface
    configured. The prefix length is stripped, because every caller wants
    something it can connect to and `ssh root@192.0.2.1/24` fails in a way that
    reads like a network fault.
    """
    if interface.state != "UP":
        return None
    for address in interface.addresses:
        bare = address.split("/")[0]
        if bare.startswith("fe80:") or bare.startswith("169.254."):
            continue
        return bare
    return None


def _address_of(output, predicate):
    for name, interface in sorted(interfaces(output).items()):
        if predicate(name):
            address = _routable_address(interface)
            if address:
                return address
    return None


def wired_interface(output):
    """The name of the board's ethernet interface, or None.

    Needed by name rather than by address, because the Wi-Fi assertion takes
    the wire *down* — and an interface that is already down has no address to
    be found by. Which is also why this does not go through `_routable_address`.
    """
    for name in sorted(interfaces(output)):
        if is_wired(name):
            return name
    return None


def wired_address(output):
    """The board's address on its ethernet interface, or None."""
    return _address_of(output, is_wired)


def wireless_address(output):
    """The board's address on its radio, or None."""
    return _address_of(output, is_wireless)


def wireless_interface(output):
    """The name of the board's radio, or None. See wired_interface."""
    for name in sorted(interfaces(output)):
        if is_wireless(name):
            return name
    return None


#: NetworkManager's "fully activated" device state, the only one that means the
#: radio has finished joining. Lower numbers are stages on the way there
#: (`prepare`, `config`, `need-auth`), and NetworkManager already names the
#: profile it is *attempting* during those, so the name alone does not mean
#: joined.
NM_STATE_ACTIVATED = "100"


def association_command(interface):
    """Ask NetworkManager what network the radio has joined.

    A different question from whether an address was configured — a board can
    hold a stale lease on a network it has left.

    NetworkManager rather than `iw`, for two reasons. It is the authority: the
    daemon joins by creating a profile and asking NetworkManager to activate it
    (daemon/network.go), so there is no second opinion to prefer. And `iw` is
    not in the image — it wrote "iw: command not found" on every poll, the SSID
    read as None, and the wait spent its whole timeout blaming the access point
    for a harness bug, which is the exact failure this docstring used to warn
    about for a different reason. Adding `iw` would not do: the release gate
    flashes release images, and a diagnostic tool does not belong in one.

    The connection's *name* is the SSID because the daemon names the profile it
    creates after the network it is for (`"id": ssid`, daemon/network.go:248).

    The interface is a parameter rather than a constant, because hardcoding
    `wlan0` would make this silently useless on any board that names its radio
    something else — a Pi 5 says `wld0`.
    """
    return f"nmcli -t -f GENERAL.CONNECTION,GENERAL.STATE device show {interface}"


def associated_ssid(output):
    """The network the radio has joined, or None if it has joined none.

    Reads `nmcli -t` key:value lines (see association_command). Anything that
    is not a fully activated device reads as None — including nmcli's own error
    output for a device it has no row for, which is a harness bug and not an
    SSID, and must not be mistaken for one.
    """
    fields = {}
    for line in output.splitlines():
        key, separator, value = line.partition(":")
        if separator:
            fields[key.strip()] = value
    state = fields.get("GENERAL.STATE", "")
    if not state.strip().startswith(NM_STATE_ACTIVATED):
        return None
    # `nmcli -t` backslash-escapes its own separator inside a value, so an SSID
    # containing a colon arrives as `Bench\:5G`.
    name = fields.get("GENERAL.CONNECTION", "").replace("\\:", ":").strip()
    return name or None


#: Where the daemon persists the kiosk's zoom level (daemon/config.go).
ZOOM_FILE = "/var/lib/dashboard-assistant/zoom"


def zoom_level(output):
    """The persisted zoom percent, or None if there is not one there.

    Anything unparseable reads as None rather than raising: `cat` on a missing
    file puts its error on the console, and treating that as a level would have
    the assertion comparing two different kinds of failure.
    """
    try:
        return int(output.strip())
    except (TypeError, ValueError):
        return None


def wifi_seed(ha_url, ssid, psk):
    """A seed file that provisions Home Assistant *and* the Bench Wi-Fi.

    JSON, which is a subset of YAML with the same string-escape rules, so
    `json.dumps` is a correct YAML escaper and the passphrase survives whatever
    is in it. Bare interpolation was not: a passphrase containing a double quote
    broke the file outright, and one containing a backslash escape was silently
    *reinterpreted*, so the device joined with a different passphrase than the
    one supplied. Same reasoning as seed.py's yaml_str, and the same bug.

    Refuses an empty passphrase rather than writing a seed without one: the
    bench's network is not open, and a device that silently never associates
    produces a failure that blames the radio.
    """
    return f"ha_url: {json.dumps(ha_url)}\n" + wifi_only_seed(ssid, psk)


def wifi_only_seed(ssid, psk):
    """A seed file that carries the Bench Wi-Fi and nothing else.

    What the bench seeds to get a board onto the network, because the journey
    being asserted has Home Assistant hand over the dashboard URL itself
    (POST /api/ha/kiosk_login). Seeding `ha_url` here would mark the device
    provisioned before anything paired it and skip that path entirely.

    Escaping and the empty-passphrase refusal live here, so wifi_seed above
    cannot drift away from them.
    """
    if not psk:
        raise ValueError(
            "no Wi-Fi passphrase — refusing to write a seed file without one. "
            "The Bench Wi-Fi is not an open network, so the device would simply "
            "never associate and the failure would read as a broken radio"
        )
    return (
        "wifi:\n"
        f"  ssid: {json.dumps(ssid)}\n"
        f"  psk: {json.dumps(psk)}\n"
    )


def joined_network(run):
    """The network the board's radio has joined, or None.

    `run` takes a command and returns its output as one string, so the caller
    owns how it reaches the board and this stays testable off hardware.

    Asks the board which interface its radio is before asking `iw` about it: a
    Pi 5 calls it wld0 and an x86 box something derived from its PCI path, and
    a hardcoded name would turn a harness bug into "the Wi-Fi never came up".
    No radio at all reads as None, not an error — a wired-only board has joined
    no network, which is a fact rather than a fault.
    """
    radio = wireless_interface(run(ADDR_COMMAND))
    if not radio:
        return None
    return associated_ssid(run(association_command(radio)))
