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
