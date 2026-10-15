"""Unit tests for device.py — no bench, no board, no network.

Everything here is a parser for something the board said over its serial
console. Parsing it wrong is the quiet kind of wrong: a test that reads "no
address" as "the Wi-Fi did not come up" sends someone to the access point when
the real problem was an extra column in `ip -brief`.
"""

import pytest

import device

BRIEF = """\
lo               UNKNOWN        127.0.0.1/8 ::1/128
end0             UP             192.168.178.90/24 fe80::1/64
wlan0            UP             192.168.178.91/24
"""

BRIEF_WIRED_DOWN = """\
lo               UNKNOWN        127.0.0.1/8 ::1/128
end0             DOWN
wlan0            UP             192.168.178.91/24
"""


# --------------------------------------------------------------------------- #
# What addresses the board has
# --------------------------------------------------------------------------- #


def test_every_interface_is_read_with_its_state_and_addresses():
    assert device.interfaces(BRIEF)["end0"] == device.Interface(
        name="end0", state="UP", addresses=["192.168.178.90/24", "fe80::1/64"]
    )


def test_loopback_is_not_an_interface_this_cares_about():
    """A device answering only on 127.0.0.1 is not on the network at all, and
    counting it would make every connectivity assertion pass vacuously."""
    assert "lo" not in device.interfaces(BRIEF)


def test_an_interface_with_no_address_still_appears_with_its_state():
    down = device.interfaces(BRIEF_WIRED_DOWN)["end0"]
    assert down.state == "DOWN"
    assert down.addresses == []


def test_malformed_lines_are_ignored_rather_than_crashing_the_run():
    noisy = BRIEF + "\nip: command not found\n   \n"
    assert set(device.interfaces(noisy)) == {"end0", "wlan0"}


# --------------------------------------------------------------------------- #
# Which of them is the wire and which is the radio
# --------------------------------------------------------------------------- #


def test_the_wired_address_comes_off_the_ethernet_interface():
    assert device.wired_address(BRIEF) == "192.168.178.90"


def test_the_wireless_address_comes_off_the_radio():
    assert device.wireless_address(BRIEF) == "192.168.178.91"


def test_a_board_with_its_wire_down_has_no_wired_address():
    assert device.wired_address(BRIEF_WIRED_DOWN) is None


def test_a_board_with_no_radio_has_no_wireless_address():
    assert device.wireless_address("end0  UP  192.168.178.90/24\n") is None


def test_the_prefix_length_is_not_part_of_the_address():
    """It would be, if this returned the field verbatim — and `ssh
    root@192.168.178.90/24` fails in a way that reads like a network fault."""
    assert "/" not in device.wired_address(BRIEF)


def test_a_link_local_only_interface_does_not_count_as_addressed():
    """fe80:: comes up on its own whether or not DHCP ever answered, so
    accepting it would call an unconfigured interface configured."""
    assert device.wired_address("end0  UP  fe80::1/64\n") is None


def test_the_wired_interface_is_named_so_it_can_be_taken_down_and_put_back():
    """Taking the wire down needs the interface's name, not its address — and
    the name has to come from the board, because a Pi 5 calls it end0 and an
    x86 box calls it something derived from its PCI path."""
    assert device.wired_interface(BRIEF) == "end0"


def test_a_board_with_no_wire_at_all_has_no_wired_interface():
    assert device.wired_interface("wlan0  UP  192.168.178.91/24\n") is None


def test_a_wire_that_is_down_is_still_the_wire():
    """Otherwise restoring it after the test would have nothing to restore."""
    assert device.wired_interface(BRIEF_WIRED_DOWN) == "end0"


def test_the_interface_names_cover_what_these_boards_actually_use():
    """A Pi 5 calls its wire end0, an x86 box calls it enp2s0 or eth0."""
    for name in ("end0", "enp2s0", "eth0"):
        assert device.is_wired(name), name
    for name in ("wlan0", "wlp1s0"):
        assert device.is_wireless(name), name
    assert not device.is_wired("wlan0")


# --------------------------------------------------------------------------- #
# Whether the radio actually joined the Bench Wi-Fi
# --------------------------------------------------------------------------- #

IW_ASSOCIATED = """\
Connected to aa:bb:cc:dd:ee:ff (on wlan0)
\tSSID: BenchNet
\tfreq: 5180
\tsignal: -47 dBm
"""


def test_an_associated_radio_reports_the_network_it_joined():
    assert device.associated_ssid(IW_ASSOCIATED) == "BenchNet"


def test_an_unassociated_radio_reports_nothing():
    assert device.associated_ssid("Not connected.\n") is None


def test_an_ssid_with_spaces_survives_intact():
    assert device.associated_ssid("\tSSID: Bench Net 5G\n") == "Bench Net 5G"


# --------------------------------------------------------------------------- #
# What the device did with a service call
# --------------------------------------------------------------------------- #


def test_the_persisted_zoom_is_read_as_a_number():
    """daemon/config.go writes it as text with a trailing newline."""
    assert device.zoom_level("150\n") == 150


def test_an_unwritten_zoom_file_reads_as_none():
    assert device.zoom_level("") is None


def test_a_zoom_file_full_of_nonsense_reads_as_none():
    """`cat` on a missing file puts its error on the console, and reading that
    as a level would make the assertion compare two kinds of failure."""
    assert device.zoom_level("cat: /var/lib/...: No such file or directory") is None


# --------------------------------------------------------------------------- #
# Keeping a passphrase off the console and out of the transcript
# --------------------------------------------------------------------------- #


def test_a_seed_file_with_wifi_is_valid_yaml():
    import yaml

    seeded = yaml.safe_load(device.wifi_seed("http://ha:8123", "BenchNet", "p@ss\"w\\d"))
    assert seeded["wifi"] == {"ssid": "BenchNet", "psk": 'p@ss"w\\d'}
    assert seeded["ha_url"] == "http://ha:8123"


def test_a_passphrase_with_quotes_and_backslashes_round_trips():
    """Bare interpolation was not an escaper: a passphrase with a double quote
    broke the file outright, and one with a backslash escape was silently
    *reinterpreted*, so the device joined with a different passphrase than the
    one supplied. See labgrid/seed.py."""
    import yaml

    nasty = 'a"b\\nc\\'
    seeded = yaml.safe_load(device.wifi_seed("http://ha:8123", "n", nasty))
    assert seeded["wifi"]["psk"] == nasty


def test_building_a_seed_without_a_passphrase_is_refused():
    """An open network is not what the bench has, and silently writing a seed
    with no `psk` would produce a device that never associates and a failure
    that blames the radio."""
    with pytest.raises(ValueError, match="passphrase"):
        device.wifi_seed("http://ha:8123", "BenchNet", "")


def test_the_wireless_interface_is_named_so_iw_can_be_asked_about_it():
    assert device.wireless_interface(BRIEF) == "wlan0"


def test_a_board_with_no_radio_has_no_wireless_interface():
    assert device.wireless_interface("end0  UP  192.168.178.90/24\n") is None


def test_the_association_command_asks_about_the_radio_it_was_given():
    """Hardcoding wlan0 would make this silently useless on a board that names
    its radio something else: `iw` writes "No such device", the SSID reads as
    None, and the wait burns its whole timeout before blaming the access point
    for a harness bug."""
    assert device.association_command("wlp1s0") == "iw dev wlp1s0 link"
