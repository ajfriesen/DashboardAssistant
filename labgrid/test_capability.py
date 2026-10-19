"""Unit tests for capability.py — no bench, no board, no network.

These run anywhere `pytest` does, which is the point: the decision logic that
says "skip, the hardware is not there" is worth testing without the hardware.
"""

import capability


# --------------------------------------------------------------------------- #
# Resources the place publishes
# --------------------------------------------------------------------------- #


def test_capability_met_when_its_resource_is_published():
    assert capability.missing_resource("plug", {"NetworkPowerPort"}) is None


def test_capability_unmet_names_the_missing_resource():
    reason = capability.missing_resource("plug", {"NetworkSerialPort"})
    assert reason is not None
    assert "NetworkPowerPort" in reason


def test_unmet_reason_says_what_the_resource_is_for():
    reason = capability.missing_resource("card", set())
    assert "USB-SD-Mux" in reason


def test_every_capability_is_declared_with_a_resource_and_a_description():
    assert capability.CAPABILITIES
    for name, (cls, description) in capability.CAPABILITIES.items():
        assert cls and description, name


def test_an_undeclared_capability_is_a_programming_error():
    try:
        capability.missing_resource("teleporter", set())
    except KeyError:
        return
    raise AssertionError("an unknown capability must not quietly pass")


# --------------------------------------------------------------------------- #
# Whether a display is actually attached
# --------------------------------------------------------------------------- #

DSI_CONNECTED = (
    "/sys/class/drm/card1-DSI-1/status:connected\n"
    "/sys/class/drm/card1-HDMI-A-1/status:disconnected\n"
)
NOTHING_CONNECTED = (
    "/sys/class/drm/card1-DSI-1/status:disconnected\n"
    "/sys/class/drm/card1-HDMI-A-1/status:disconnected\n"
)


def test_connector_status_is_read_per_connector():
    assert capability.connector_status(DSI_CONNECTED) == {
        "card1-DSI-1": "connected",
        "card1-HDMI-A-1": "disconnected",
    }


def test_connector_status_ignores_blank_and_malformed_lines():
    noisy = "\n" + DSI_CONNECTED + "no-colon-here\n   \n"
    assert capability.connector_status(noisy) == {
        "card1-DSI-1": "connected",
        "card1-HDMI-A-1": "disconnected",
    }


def test_a_connected_connector_means_a_display_is_attached():
    assert capability.missing_display(DSI_CONNECTED) is None


def test_no_connected_connector_names_what_it_found():
    reason = capability.missing_display(NOTHING_CONNECTED)
    assert reason is not None
    assert "card1-DSI-1" in reason and "card1-HDMI-A-1" in reason


def test_no_connectors_at_all_is_reported_as_such():
    reason = capability.missing_display("")
    assert reason is not None
    assert "no DRM connector" in reason


# --------------------------------------------------------------------------- #
# Which board the target drives
# --------------------------------------------------------------------------- #


def test_a_test_declared_for_this_board_runs():
    assert capability.missing_board(("rpi4", "rpi5"), "rpi5") is None


def test_a_test_declared_for_another_board_skips_and_names_both():
    reason = capability.missing_board(("rpi4", "rpi5"), "x86_64")
    assert reason is not None
    assert "x86_64" in reason
    assert "rpi4" in reason and "rpi5" in reason


def test_a_target_that_declares_no_board_is_a_configuration_error():
    """Silently running every board's tests against an unknown target is how a
    Pi boot-chain assertion ends up "passing" on something that has no U-Boot."""
    try:
        capability.missing_board(("rpi5",), None)
    except ValueError:
        return
    raise AssertionError("an undeclared board must not quietly pass")


# --------------------------------------------------------------------------- #
# Whether this target is a bench at all
# --------------------------------------------------------------------------- #


def test_a_place_with_an_exported_console_is_a_bench():
    assert capability.missing_bench_place({"NetworkSerialPort"}) is None


def test_a_local_vm_is_a_different_target_not_a_broken_image():
    """The x86_64 QEMU target: user-mode networking carries no mDNS and puts
    the guest behind a NAT with no route in, so nothing can dial the device."""
    reason = capability.missing_bench_place({"QEMUDriver"})
    assert reason is not None
    assert "VM" in reason


def test_the_bench_place_check_does_not_ask_whether_the_device_answers():
    """Measuring reachability instead would also skip on a bench where the
    device has genuinely stopped answering — and a silent skip is the wrong
    answer to that. This bench has shipped a bug that way before."""
    assert capability.missing_bench_place({"NetworkSerialPort"}) is None


# --------------------------------------------------------------------------- #
# Whether this target has a Bench Home Assistant to pair with
# --------------------------------------------------------------------------- #


def test_a_reachable_bench_home_assistant_is_no_reason_to_skip():
    assert capability.missing_bench_home_assistant("http://bench:8123", True) is None


def test_a_target_with_no_home_assistant_configured_skips_and_says_how():
    """The x86_64 QEMU target has none: user-mode networking carries no mDNS and
    Home Assistant opens the connection *to* a device, so there is nothing for
    it to pair with. That is a different target, not a defect in the image."""
    reason = capability.missing_bench_home_assistant(None, False)
    assert reason is not None
    assert "BENCH_HA_URL" in reason


def test_a_configured_but_unreachable_home_assistant_names_the_address():
    reason = capability.missing_bench_home_assistant("http://bench:8123", False)
    assert reason is not None
    assert "http://bench:8123" in reason


# --------------------------------------------------------------------------- #
# Whether the gate holds a key it can sign with
# --------------------------------------------------------------------------- #


def test_a_private_key_on_disk_is_what_ssh_is_pointed_at():
    assert capability.gate_key_choice("/k/bench", True, True) == ("/k/bench", None)


def test_a_key_held_only_by_an_agent_is_used_through_its_public_half():
    """The normal case here: the private half lives in the operator's password
    manager and is served by ssh-agent, so only the .pub is on disk — and `ssh
    -i <pubkey>` is enough for the agent to be asked for the matching key."""
    key, reason = capability.gate_key_choice("/k/bench", False, True)
    assert key == "/k/bench.pub"
    assert reason is None


def test_neither_half_present_skips_and_names_both_paths():
    key, reason = capability.gate_key_choice("/k/bench", False, False)
    assert key is None
    assert "/k/bench" in reason and "/k/bench.pub" in reason


def test_the_absent_key_reason_warns_about_the_lockout():
    """A key that cannot sign is worse than no key: the failed attempt trips
    OpenSSH's per-source penalties and locks this address out for an hour. So
    the harness must not try — and whoever reads the skip should know why."""
    _, reason = capability.gate_key_choice("/nope", False, False)
    assert "hour" in reason


# --------------------------------------------------------------------------- #
# Whether the Bench Wi-Fi's credentials are available to this run
# --------------------------------------------------------------------------- #


def test_both_wifi_credentials_present_is_no_reason_to_skip():
    assert capability.missing_wifi_credentials("BenchNet", "hunter2") is None


def test_missing_wifi_credentials_name_the_declarations_not_the_values():
    reason = capability.missing_wifi_credentials(None, None)
    assert reason is not None
    assert "BENCH_WIFI_SSID" in reason and "BENCH_WIFI_PSK" in reason


def test_a_half_configured_wifi_names_only_the_missing_half():
    reason = capability.missing_wifi_credentials("BenchNet", None)
    assert reason is not None
    assert "BENCH_WIFI_PSK" in reason
    assert "BENCH_WIFI_SSID" not in reason


def test_the_wifi_reason_never_contains_the_passphrase():
    """This reason lands in a transcript that is not private."""
    reason = capability.missing_wifi_credentials("BenchNet", "")
    assert "hunter2" not in (reason or "")
