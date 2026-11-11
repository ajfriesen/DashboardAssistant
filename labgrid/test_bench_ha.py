"""Unit tests for bench_ha.py — no bench, no board, no Home Assistant.

The decisions that make the pairing gate meaningful are all made on data that
can be written down here: whether a flow appeared *unprompted*, whether a flow
that ended actually paired anything, and which half of the journey a failure
belongs to. Keeping them pure is what lets them be tested without the half-hour
of hardware that producing the real data would cost.
"""

import pytest

import bench_ha as ha


# --------------------------------------------------------------------------- #
# A discovery flow appeared without being asked for
# --------------------------------------------------------------------------- #


def zeroconf_flow(handler=ha.DOMAIN, source="zeroconf", flow_id="abc"):
    return {
        "flow_id": flow_id,
        "handler": handler,
        "step_id": "confirm",
        "context": {"source": source},
    }


def test_a_zeroconf_flow_for_our_integration_is_the_one_we_want():
    flow = zeroconf_flow()
    assert ha.unprompted_flow([flow]) == flow


def test_no_flow_at_all_is_not_a_flow():
    assert ha.unprompted_flow([]) is None


def test_another_integrations_discovery_is_not_ours():
    """The bench Home Assistant discovers printers and Chromecasts too."""
    assert ha.unprompted_flow([zeroconf_flow(handler="hue")]) is None


def test_a_flow_somebody_started_by_hand_does_not_count():
    """The promise is that nobody types anything. A `user` flow is exactly the
    typing this test exists to prove unnecessary, so accepting one would let the
    gate pass while the product's one claim was broken."""
    assert ha.unprompted_flow([zeroconf_flow(source="user")]) is None


def test_a_reconfigure_of_an_existing_entry_does_not_count():
    assert ha.unprompted_flow([zeroconf_flow(source="reconfigure")]) is None


def test_our_flow_is_found_among_other_integrations():
    flows = [zeroconf_flow(handler="hue"), zeroconf_flow(flow_id="ours")]
    found = ha.unprompted_flow(flows)
    assert found is not None and found["flow_id"] == "ours"


def test_every_unprompted_source_is_a_source_home_assistant_knows():
    """A typo here would silently make the gate stricter than intended — the
    flow would be there and we would call it absent."""
    assert ha.UNPROMPTED_SOURCES
    assert "user" not in ha.UNPROMPTED_SOURCES
    assert "zeroconf" in ha.UNPROMPTED_SOURCES


# --------------------------------------------------------------------------- #
# Stepping the flow to completion
# --------------------------------------------------------------------------- #


def test_a_form_asks_to_be_submitted():
    step = ha.next_flow_action({"type": "form", "step_id": "confirm"})
    assert step.action == "submit"
    assert step.detail == "confirm"


def test_a_created_entry_is_the_end_of_the_flow():
    result = {"type": "create_entry", "result": {"entry_id": "e1"}, "title": "Kiosk"}
    step = ha.next_flow_action(result)
    assert step.action == "done"
    assert step.detail == "e1"


def test_an_abort_is_named_by_its_reason():
    """`already_configured` is the one that will actually happen — it means the
    reset left a config entry behind, which makes the whole run meaningless."""
    step = ha.next_flow_action({"type": "abort", "reason": "already_configured"})
    assert step.action == "aborted"
    assert step.detail == "already_configured"


def test_an_abort_with_no_reason_still_says_something():
    step = ha.next_flow_action({"type": "abort"})
    assert step.action == "aborted"
    assert step.detail


def test_an_unknown_flow_result_is_a_programming_error():
    """Home Assistant grew `menu` and `progress` step types after this was
    written. Treating one as "keep going" would hang the run; treating it as
    success would pass a gate that paired nothing."""
    with pytest.raises(ValueError, match="menu"):
        ha.next_flow_action({"type": "menu"})


def test_a_flow_needs_no_input_to_be_stepped():
    """Typing-free enrollment: the integration fetches the device's token over
    /api/ha/pair itself, so every form here is a bare confirmation. If this ever
    has to grow a field, the no-typing promise has already been broken."""
    assert ha.CONFIRM_INPUT == {}


# --------------------------------------------------------------------------- #
# What the entry actually produced
# --------------------------------------------------------------------------- #

DEVICES = [
    {"id": "dev-ours", "config_entries": ["e1"], "name": "Dashboard Assistant"},
    {"id": "dev-other", "config_entries": ["e2"], "name": "A lamp"},
]
ENTITIES = [
    {"entity_id": "number.kiosk_zoom", "device_id": "dev-ours"},
    {"entity_id": "sensor.kiosk_uptime", "device_id": "dev-ours"},
    {"entity_id": "light.lamp", "device_id": "dev-other"},
]


def test_the_entrys_device_is_found_by_entry_id():
    assert ha.device_of(DEVICES, "e1")["id"] == "dev-ours"


def test_an_entry_with_no_device_reads_as_none():
    assert ha.device_of(DEVICES, "e3") is None


def test_only_the_devices_own_entities_are_counted():
    assert ha.entities_of(ENTITIES, "dev-ours") == [
        "number.kiosk_zoom",
        "sensor.kiosk_uptime",
    ]


def test_a_device_with_no_entities_reads_as_empty():
    assert ha.entities_of(ENTITIES, "dev-nothing") == []


def test_the_zoom_entity_is_the_one_a_service_call_can_be_checked_against():
    """Zoom is the control picked for the round trip because the device persists
    it to a file the serial console can read, so the assertion needs no display
    and no second API."""
    assert ha.zoom_entity(["sensor.kiosk_uptime", "number.kiosk_zoom"]) == (
        "number.kiosk_zoom"
    )


def test_no_zoom_entity_reads_as_none_rather_than_picking_something_else():
    assert ha.zoom_entity(["sensor.kiosk_uptime", "number.kiosk_brightness"]) is None


# --------------------------------------------------------------------------- #
# Which half broke
# --------------------------------------------------------------------------- #


def test_the_two_halves_are_named_differently():
    """ADR 0012: a bad integration release can redden this repo's gate, which is
    correct — but only if the failure says which side of the journey it is on."""
    assert ha.ha_side("x") != ha.device_side("x")


def test_a_home_assistant_side_failure_says_so():
    assert "Home Assistant" in ha.ha_side("no flow appeared")
    assert "no flow appeared" in ha.ha_side("no flow appeared")


def test_a_device_side_failure_says_so():
    assert "device" in ha.device_side("mDNS is not being advertised")


# --------------------------------------------------------------------------- #
# Where the Bench Home Assistant is, and how we authenticate to it
# --------------------------------------------------------------------------- #


def test_the_websocket_lives_under_the_same_origin():
    assert ha.websocket_url("http://bench:8123") == "ws://bench:8123/api/websocket"


def test_a_tls_home_assistant_gets_a_tls_websocket():
    assert ha.websocket_url("https://bench:8123") == "wss://bench:8123/api/websocket"


def test_a_trailing_slash_does_not_produce_a_double_slash():
    assert ha.websocket_url("http://bench:8123/") == "ws://bench:8123/api/websocket"


def test_an_explicit_token_in_the_environment_wins():
    """So a second bench, or a throwaway instance, needs no bench host at all."""
    token = ha.read_token({ha.TOKEN_ENV: "from-env"}, lambda: "from-bench-host")
    assert token == "from-env"


def test_otherwise_the_token_is_read_off_the_bench_host():
    """Never committed here: a second copy of the token is a copy that can drift
    from the fixture that minted it."""
    assert ha.read_token({}, lambda: "from-bench-host") == "from-bench-host"


def test_a_token_is_stripped_of_the_newline_a_shell_adds():
    assert ha.read_token({}, lambda: "from-bench-host\n") == "from-bench-host"


def test_a_bench_host_with_no_token_reads_as_none():
    assert ha.read_token({}, lambda: "") is None


# --------------------------------------------------------------------------- #
# Waiting for something to appear, rather than sleeping at it
# --------------------------------------------------------------------------- #


class FakeClock:
    """A clock that only moves when something sleeps on it."""

    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.t += seconds


def test_something_already_there_is_returned_without_waiting():
    clock = FakeClock()
    assert ha.wait_until(lambda: "here", "it", 10, 1, clock.now, clock.sleep) == "here"
    assert clock.t == 0


def test_something_that_turns_up_later_is_waited_for():
    clock = FakeClock()
    answers = [None, None, "here"]
    found = ha.wait_until(
        lambda: answers.pop(0), "it", 10, 1, clock.now, clock.sleep
    )
    assert found == "here"
    assert clock.t > 0


def test_something_that_never_turns_up_fails_naming_what_was_waited_for():
    """A bare `TimeoutError` at the end of a four-minute hardware run tells
    nobody which half of the journey stalled."""
    clock = FakeClock()
    with pytest.raises(AssertionError, match="a discovery flow"):
        ha.wait_until(
            lambda: None, "a discovery flow", 5, 1, clock.now, clock.sleep
        )


def test_the_timeout_is_honoured_rather_than_looping_forever():
    clock = FakeClock()
    with pytest.raises(AssertionError):
        ha.wait_until(lambda: None, "it", 5, 1, clock.now, clock.sleep)
    assert clock.t <= 6


def test_a_raised_error_while_polling_does_not_end_the_wait():
    """Home Assistant refuses registry commands for a moment while a config
    entry is being set up. Treating that as the final answer would fail a run
    for being early."""
    clock = FakeClock()
    attempts = []

    def flaky():
        attempts.append(1)
        if len(attempts) < 3:
            raise RuntimeError("not ready")
        return "here"

    assert ha.wait_until(flaky, "it", 10, 1, clock.now, clock.sleep) == "here"


def test_an_error_that_never_clears_is_reported_with_the_timeout():
    """Otherwise the last exception is swallowed and the run reports only that
    nothing appeared — which is true and useless."""
    clock = FakeClock()

    def always_broken():
        raise RuntimeError("auth refused")

    with pytest.raises(AssertionError, match="auth refused"):
        ha.wait_until(always_broken, "it", 5, 1, clock.now, clock.sleep)


# --------------------------------------------------------------------------- #
# Which entities are not answering
# --------------------------------------------------------------------------- #


def test_an_entity_with_a_real_state_is_answering():
    assert ha.unanswering({"number.zoom": "125"}, ["number.zoom"]) == []


def test_an_unavailable_entity_is_not_answering():
    """`unavailable` is what Home Assistant sets on every entity of a device
    its coordinator cannot reach — the half-paired state a gate has to catch."""
    assert ha.unanswering({"number.zoom": "unavailable"}, ["number.zoom"]) == [
        "number.zoom=unavailable"
    ]


def test_an_entity_with_no_state_object_at_all_is_not_answering():
    assert ha.unanswering({}, ["number.zoom"]) == ["number.zoom=<no state>"]


def test_unknown_is_not_treated_as_a_failure():
    """A button's state is the timestamp of its last press, so it is `unknown`
    until somebody presses it — and so are `event` entities on a device that
    has not emitted one. Failing on `unknown` would redden the gate for a
    device that is working perfectly."""
    assert ha.unanswering({"button.reboot": "unknown"}, ["button.reboot"]) == []


def test_every_unanswering_entity_is_named_not_just_the_first():
    bad = ha.unanswering(
        {"a.x": "unavailable", "b.y": "on", "c.z": "unavailable"},
        ["a.x", "b.y", "c.z"],
    )
    assert bad == ["a.x=unavailable", "c.z=unavailable"]


MENU_RESULT = {
    "type": "menu",
    "flow_id": "01M6A6BGBH71Z1D391N3817YE2",
    "handler": "dashboard_assistant",
    "data_schema": [
        {
            "type": "select",
            "options": [["pair", "pair"], ["manual", "manual"]],
            "name": "next_step_id",
            "required": False,
        }
    ],
}


def test_a_menu_is_stepped_down_the_typing_free_branch():
    """The integration offers `pair` or `manual`. `manual` is where a human
    types a host and port (docs/usage/integration.md calls it the fallback for
    when discovery fails), so taking it would pass the gate while disproving
    the very promise the gate exists to assert.
    """
    step = ha.next_flow_action(MENU_RESULT)
    assert step.action == "menu"
    assert step.detail == "pair"


def test_a_menu_without_the_typing_free_branch_is_refused():
    """Still no guessing: if `pair` is not on offer the gate says what was,
    rather than picking whatever is first and calling it enrollment."""
    renamed = {**MENU_RESULT, "data_schema": [
        {"name": "next_step_id", "options": [["manual", "manual"]]}
    ]}
    with pytest.raises(ValueError, match="manual"):
        ha.next_flow_action(renamed)


def test_an_unknown_step_type_is_still_refused():
    """`progress` and `external` remain unknown, and must stay that way."""
    with pytest.raises(ValueError):
        ha.next_flow_action({"type": "progress"})


# --------------------------------------------------------------------------- #
# Installing the integration from the marketplace
# --------------------------------------------------------------------------- #


def test_the_marketplace_is_ready_once_running():
    assert ha.marketplace_running({"stage": "running", "disabled_reason": None})


def test_the_marketplace_still_starting_is_waited_for():
    """Before `running` its list is the fixture's cache, which can predate the
    release under test."""
    assert not ha.marketplace_running({"stage": "startup", "disabled_reason": None})


def test_a_disabled_marketplace_is_a_verdict_not_a_stage():
    """Waiting out a rate limit would burn the whole timeout and then report
    "did not appear" — the reason is the diagnosis, so it is raised."""
    with pytest.raises(RuntimeError, match="rate_limit"):
        ha.marketplace_running({"stage": "running", "disabled_reason": "rate_limit"})


def catalog_repo(full_name=ha.REPOSITORY, repo_id="1311459696", installed=False):
    return {"full_name": full_name, "id": repo_id, "installed": installed}


def test_our_repository_is_found_in_the_catalog():
    ours = catalog_repo()
    assert ha.catalog_entry([catalog_repo("someone/else", "1"), ours]) == ours


def test_the_catalog_match_ignores_case():
    ours = catalog_repo(ha.REPOSITORY.upper())
    assert ha.catalog_entry([ours]) == ours


def test_a_catalog_without_us_reads_as_none():
    assert ha.catalog_entry([catalog_repo("someone/else")]) is None


def test_an_unset_version_means_the_catalogs():
    assert ha.requested_version({}) is None
    assert ha.requested_version({ha.VERSION_ENV: "  "}) is None


def test_a_requested_version_is_taken_as_written():
    assert ha.requested_version({ha.VERSION_ENV: " v1.1.0-rc.3\n"}) == "v1.1.0-rc.3"


def test_a_tag_and_its_manifest_version_are_the_same_release():
    assert ha.same_version("v1.1.0", "1.1.0")
    assert ha.same_version("1.1.0", "1.1.0")


def test_a_pre_release_is_not_its_final_release():
    assert not ha.same_version("v1.1.0-rc.3", "1.1.0")


def test_nothing_is_not_a_version():
    assert not ha.same_version("", "")
    assert not ha.same_version(None, None)


def test_the_installed_integration_is_accepted():
    assert ha.install_problem({"is_built_in": False, "version": "1.1.0"}) is None


def test_any_version_is_accepted_when_none_was_asked_for():
    assert ha.install_problem({"is_built_in": False, "version": "9.9.9"}) is None


def test_the_wrong_version_is_named():
    problem = ha.install_problem({"is_built_in": False, "version": "1.0.0"}, "v1.1.0")
    assert problem and "v1.1.0" in problem and "1.0.0" in problem


def test_a_built_in_of_the_same_name_is_not_the_installed_integration():
    assert ha.install_problem({"is_built_in": True, "version": None}) is not None
