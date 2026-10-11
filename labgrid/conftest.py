"""pytest wiring for the hardware bench — see README.md.

Adds two conveniences on top of labgrid's own pytest plugin (which supplies the
`env`, `target` and `strategy` fixtures):

  * `--lg-env` and `--lg-log` default to this directory, so `pytest labgrid/`
    works with no flags
  * `--image` resolves the built Pi 5 dev image, whose filename carries the
    release version and so cannot be written into bench.yaml
"""

import os
import shutil

import pytest

import bench


def pytest_addoption(parser):
    group = parser.getgroup("dashboard-assistant")
    group.addoption(
        "--image",
        action="store",
        dest="image",
        metavar="PATH",
        help=f"image to flash (default: newest match of {bench.IMAGE_GLOB})",
    )


def pytest_configure(config):
    """Fill in labgrid's options before its own hook consumes them.

    labgrid's pytest_configure is registered `trylast`, so this runs first: it can
    still set --lg-env/--lg-log, and it gets to clear the console log *before* the
    reporter opens it (the reporter appends, so without this a boot-log assertion
    would be reading previous runs too).
    """
    if config.option.lg_env is None and os.environ.get("LG_ENV") is None:
        config.option.lg_env = bench.ENV_CONFIG

    if config.option.lg_log is None:
        config.option.lg_log = bench.LOG_DIR
        # Clear only the directory this file owns. Never rmtree a user-supplied
        # --lg-log: labgrid declares the flag with nargs='?' and const='.', so
        # the bare form points it at the *current directory* — deleting that
        # would silently take the repo checkout with it. The cost of skipping
        # the wipe for an explicit log dir is stale console logs from earlier
        # runs; whoever picks their own directory manages its lifetime.
        shutil.rmtree(bench.LOG_DIR, ignore_errors=True)

    # On real hardware the kiosk session actually runs, and greetd/sway/Chromium
    # crash-loop with no display attached — which makes a strict "nothing failed"
    # check fail for reasons that have nothing to do with the code under test.
    # Run `pytest labgrid/ -m "not needs_display"` on a headless bench.
    config.addinivalue_line(
        "markers", "needs_display: requires a display (or HDMI dummy) on the DUT"
    )


@pytest.fixture(scope="session")
def image(request):
    """Absolute path of the image to flash, or None if there is nothing to find.

    Deliberately not a hard failure: with `--lg-initial-state shell` the board is
    already running and no image is needed, and the strategy raises a clear error
    if it turns out one was.
    """
    explicit = request.config.getoption("image")
    if explicit:
        path = os.path.abspath(explicit)
        if not os.path.isfile(path):
            pytest.fail(f"--image {explicit}: no such file")
        return path

    return bench.find_image()


@pytest.fixture(scope="session")
def _bench(strategy, image):
    """The strategy with its image resolved. Use `booted` or `shell` instead."""
    strategy.image = image
    return strategy


@pytest.fixture(scope="session")
def booted(_bench):
    """Board flashed, powered on, and its whole boot read off the serial port.

    No login is attempted, which is the point: boot-chain assertions have to work
    when userspace is broken or the prompt regex is wrong, since that is when the
    transcript is the only evidence there is.
    """
    _bench.transition("booted")
    return _bench


@pytest.fixture(scope="session")
def shell(_bench):
    """A logged-in root shell on the freshly flashed board.

    Session-scoped, so the flash and boot happen once for the whole run.
    """
    _bench.transition("shell")
    return _bench.shell


@pytest.fixture
def console_log(booted, request):
    """The serial transcript so far, as text.

    Function-scoped and re-read each time, so a test running after something took
    a shell sees the later output too. Named for labgrid's
    ConsoleLoggingReporter, which writes console_<target>[_<driver>].
    """
    path = os.path.join(request.config.option.lg_log, f"console_{booted.target.name}")
    if not os.path.exists(path):
        pytest.skip(f"no console log at {path}")
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="replace")


@pytest.fixture(scope="session")
def plug():
    """Query the smart plug directly — the same script the power driver drives.

    Useful as an out-of-band check: the plug measures actual current, so it can
    tell "the board is not running" apart from "the serial console is wrong".
    """
    return bench.plug
