"""Unit tests for kiosk.py — no bench, no board, no browser.

Two things are worth pinning down without hardware. The ssh invocation, because
getting it wrong is not a test failure but an hour-long lockout (see
labgrid/README.md), and the verdict on what is on screen, because the whole
point of the dashboard assertion is to tell a *dashboard* from a perfectly
healthy *login page* — and those are one boolean apart.
"""

import pytest

import kiosk


# --------------------------------------------------------------------------- #
# Reaching the device without a human
# --------------------------------------------------------------------------- #


def test_ssh_runs_a_command_on_the_device_as_root():
    argv = kiosk.ssh_argv("192.0.2.10", "/k", ["true"])
    assert argv[0] == "ssh"
    assert "root@192.0.2.10" in argv
    assert argv[-1] == "true"


def test_ssh_never_prompts():
    """An interactive prompt in an unattended run is a hang, and a hang on the
    bench holds the place against everybody else."""
    argv = kiosk.ssh_argv("192.0.2.10", "/k", ["true"])
    assert "BatchMode=yes" in argv


def test_ssh_offers_only_the_bench_key():
    """Without IdentitiesOnly, ssh still offers every other key first, and one
    that cannot sign is enough to trip the per-source penalty that locks this
    address out of the board for an hour."""
    argv = kiosk.ssh_argv("192.0.2.10", "/the-key", ["true"])
    assert "IdentitiesOnly=yes" in argv
    assert "/the-key" in argv


def test_ssh_does_not_collect_host_keys_for_a_board_that_is_reflashed_hourly():
    """A reflash regenerates the host key, so a known_hosts entry would turn
    every second run into a host-key failure."""
    argv = kiosk.ssh_argv("192.0.2.10", "/k", ["true"])
    assert "UserKnownHostsFile=/dev/null" in argv
    assert "StrictHostKeyChecking=no" in argv


def test_the_tunnel_forwards_a_local_port_to_the_devices_loopback():
    """The debugging port is unauthenticated and runs with permissive origins,
    so it stays bound to loopback on the device and comes to us over ssh. The
    remote end of the forward must therefore be 127.0.0.1, not the device's own
    address — which would only work if the port were exposed."""
    argv = kiosk.tunnel_argv("192.0.2.10", "/k", 19222, 9222)
    assert "-L" in argv
    assert argv[argv.index("-L") + 1] == "19222:127.0.0.1:9222"


def test_the_tunnel_runs_no_command():
    argv = kiosk.tunnel_argv("192.0.2.10", "/k", 19222, 9222)
    assert "-N" in argv


def test_the_tunnel_is_as_unattended_as_the_shell():
    argv = kiosk.tunnel_argv("192.0.2.10", "/k", 19222, 9222)
    assert "BatchMode=yes" in argv
    assert "IdentitiesOnly=yes" in argv


# --------------------------------------------------------------------------- #
# What is actually on the screen
# --------------------------------------------------------------------------- #


def test_a_dashboard_and_no_login_form_is_the_whole_point():
    assert kiosk.page_verdict(has_dashboard=True, has_login=False) is None


def test_a_login_page_is_named_as_the_missing_token_that_it_is():
    """The failure this assertion exists for. A device showing a login page is
    reachable, provisioned, paired, unfailed — and useless. A screenshot cannot
    tell it from a working one; the absence of a login form can."""
    reason = kiosk.page_verdict(has_dashboard=False, has_login=True)
    assert reason is not None
    assert "login" in reason
    assert "token" in reason


def test_a_login_form_over_a_dashboard_is_still_a_failure():
    """Home Assistant can render a view and then throw up a re-auth dialog over
    it. The screen the user is looking at is a login form either way."""
    assert kiosk.page_verdict(has_dashboard=True, has_login=True) is not None


def test_neither_one_says_the_page_never_rendered():
    """A blank page is its own failure and must not be reported as the missing
    token — that would send someone looking at pairing when the browser never
    got as far as loading anything."""
    reason = kiosk.page_verdict(has_dashboard=False, has_login=False)
    assert reason is not None
    assert "never rendered" in reason
    assert "token" not in reason


def test_the_two_selectors_are_asked_for_together():
    """Waiting for the dashboard alone would turn the interesting failure — a
    login page — into a timeout, which says nothing about what was on screen."""
    assert kiosk.DASHBOARD_SELECTOR in kiosk.EITHER_SELECTOR
    assert kiosk.LOGIN_SELECTOR in kiosk.EITHER_SELECTOR


def test_the_dashboard_selector_is_a_rendered_view_not_a_panel_shell():
    """`ha-panel-lovelace` exists while the panel is still loading, so matching
    it would pass against a blank screen."""
    assert "hui-view" in kiosk.DASHBOARD_SELECTOR


# --------------------------------------------------------------------------- #
# Which of the browser's pages is the one on the screen
# --------------------------------------------------------------------------- #


class FakePage:
    def __init__(self, url):
        self.url = url


def test_the_single_page_a_kiosk_runs_is_the_one():
    page = FakePage("http://ha:8123/lovelace/0")
    assert kiosk.kiosk_page([page]) is page


def test_a_transient_blank_page_is_not_mistaken_for_the_kiosk():
    """about:blank turns up while Chromium is navigating, and a verdict about
    it would be a verdict about something nobody is looking at."""
    real = FakePage("http://ha:8123/lovelace/0")
    assert kiosk.kiosk_page([FakePage("about:blank"), real]) is real


def test_a_browser_with_no_page_at_all_says_so():
    with pytest.raises(AssertionError, match="no page open"):
        kiosk.kiosk_page([])


def test_two_real_pages_are_refused_rather_than_guessed_between():
    with pytest.raises(AssertionError, match="more than one"):
        kiosk.kiosk_page([FakePage("http://ha:8123/a"), FakePage("http://ha:8123/b")])


def test_a_browser_showing_only_a_blank_page_still_gets_a_verdict():
    """Falling back to what there is, so the dashboard assertion reports "the
    page never rendered" rather than erroring out in the fixture."""
    blank = FakePage("about:blank")
    assert kiosk.kiosk_page([blank]) is blank
