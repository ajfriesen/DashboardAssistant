"""pytest wiring for the hardware bench — see README.md.

Adds three conveniences on top of labgrid's own pytest plugin (which supplies the
`env`, `target` and `strategy` fixtures):

  * `--lg-env` and `--lg-log` default to this directory, so `pytest labgrid/`
    needs no flags of its own
  * `--image` resolves the built dev image for the board under test, whose
    filename carries the release version and so cannot be written into the
    environment file
  * the variables the chosen environment file templates are checked up front,
    because the failure otherwise arrives as a yaml template error — but only
    the ones that file actually needs, and only when a test that needs the
    hardware has been collected, so the unit tests next to this file run
    anywhere and the x86_64 target needs no coordinator
  * tests whose hardware is not on this bench skip themselves, from what the
    place publishes and from what the board reports. See capability.py.

The hardware is not local: bench.yaml names a place on a labgrid coordinator, and
the place has to be acquired before any of this works. `just hw-test` does that
for you.
"""

import os
import shutil

import pytest
from labgrid.resource import NetworkPowerPort

import bench
import capability


def pytest_addoption(parser):
    group = parser.getgroup("dashboard-assistant")
    group.addoption(
        "--image",
        action="store",
        dest="image",
        metavar="PATH",
        help=f"image to flash (default: newest match of {bench.IMAGE_GLOB})",
    )


#: What the LG_* variables an environment file might template are for. Not
#: defaulted here on purpose: the justfile owns the defaults (one place,
#: overridable per bench), and a missing one should say so rather than quietly
#: pointing the run at someone else's hardware.
ENV_DESCRIPTIONS = {
    "LG_COORDINATOR": "host:port of the labgrid coordinator",
    "LG_PLACE": "name of the place to drive",
    "LG_OVMF_FD": "path to the UEFI firmware image",
}

#: Fixtures that cannot work without the bench — labgrid's own, and the ones
#: below that build on them. `item.fixturenames` is the transitive closure, so a
#: test asking for `shell` matches through `target` and `env` as well.
HARDWARE_FIXTURES = frozenset(
    {"env", "target", "strategy", "_bench", "booted", "shell", "console_log", "plug"}
)


def _required_env(env_config):
    """The LG_* variables this environment file templates, unset ones first.

    Asked of the file rather than hardcoded, because the two targets need
    different things: the bench templates the place it acquires, and the x86_64
    target has no place and no coordinator at all. A fixed list would make the
    one that needs no bench refuse to run without one.
    """
    try:
        with open(env_config, encoding="utf-8") as handle:
            wanted = bench.templated_variables(handle.read())
    except OSError:
        # Unreadable or absent: labgrid is about to say so far better than we
        # could, so do not pre-empt it with a guess about variables.
        return []
    # LG_COORDINATOR is templated by nothing but needed by every RemotePlace,
    # so it rides along with the place rather than being named in the file.
    if "LG_PLACE" in wanted:
        wanted.add("LG_COORDINATOR")
    return [name for name in sorted(wanted) if not os.environ.get(name)]


def _env_message(env_config, missing):
    """What to tell someone whose environment file cannot be templated."""
    described = ", ".join(
        f"{name} ({ENV_DESCRIPTIONS.get(name, 'needed by this environment')})"
        for name in missing
    )
    return (
        f"{os.path.basename(env_config)} needs these, and they are unset: "
        f"{described} — run it through `just` (hw-test / qemu-test), which "
        "defaults them, or export them by hand"
    )


def pytest_configure(config):
    """Fill in labgrid's options before its own hook consumes them.

    labgrid's pytest_configure is registered `trylast`, so this runs first: it can
    still set --lg-env/--lg-log, and it gets to clear the console log *before* the
    reporter opens it (the reporter appends, so without this a boot-log assertion
    would be reading previous runs too).
    """
    # labgrid resolves `!template $X` only for X starting with LG_, on purpose
    # ("protect from weird things in environment"), so the UEFI firmware path
    # the x86_64 environment needs has to arrive under that prefix. The dev
    # shell already exports it as OVMF_FD (flake.nix), so bridge the two rather
    # than making every invocation do it — and leave an explicit LG_OVMF_FD
    # alone, so pointing the target at different firmware stays possible.
    if not os.environ.get("LG_OVMF_FD") and os.environ.get("OVMF_FD"):
        os.environ["LG_OVMF_FD"] = os.environ["OVMF_FD"]

    # Which environment file this run wants, and whether it can actually be
    # used. An explicit --lg-env with something missing is a mistake worth
    # stopping for straight away — the user plainly meant a hardware run. A
    # *defaulted* one is different: leaving it unset lets a pure unit-test run
    # proceed on a machine with no bench, and the collection hook below still
    # stops a hardware run with the same message. Either way labgrid must not be
    # handed an environment it cannot template, because its own failure for that
    # is an INTERNALERROR traceback.
    explicit = config.option.lg_env or os.environ.get("LG_ENV")
    wanted = explicit or bench.ENV_CONFIG
    missing = _required_env(wanted)
    config._da_env_problem = None  # pylint: disable=protected-access
    if missing:
        if explicit:
            raise pytest.UsageError(_env_message(wanted, missing))
        config._da_env_problem = _env_message(  # pylint: disable=protected-access
            wanted, missing
        )
    elif not explicit:
        config.option.lg_env = wanted

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
    #
    # The marker *declares* the requirement; it no longer decides anything. The
    # `_display` fixture below asks the board whether a connector is actually
    # connected and skips on the answer, so an ordinary run needs no `-m` and
    # cannot be told the wrong thing by hand. That matters: this marker used to
    # be the only thing standing between a headless run and a storage bug that
    # shipped (README.md, "What this bench found").
    config.addinivalue_line(
        "markers", "needs_display: requires a display (or HDMI dummy) on the DUT"
    )
    # Same shape: the marker declares which boards an assertion is about, and
    # the `_needs_board` fixture decides from the environment which board is
    # actually under test. A Pi boot-chain assertion cannot ask the board what
    # it is — the whole point of those assertions is to work when there is
    # nobody to ask — so this one is declared per environment rather than
    # measured. See capability.missing_board.
    config.addinivalue_line(
        "markers", "board(*names): only applies to these boards (default: all)"
    )


def pytest_collection_modifyitems(config, items):
    """Fail the run up front if the bench is needed and not configured.

    Deliberately here rather than in pytest_configure: the unit tests beside this
    file need neither variable, and a run that collects only those must work on
    any machine. A run that does need the bench still gets the error before
    anything is flashed, which is the whole point of checking at all.
    """
    _skip_other_boards(config, items)

    problem = getattr(config, "_da_env_problem", None)
    if not problem:
        return
    if not any(HARDWARE_FIXTURES & set(item.fixturenames) for item in items):
        return
    raise pytest.UsageError(problem)


def _skip_other_boards(config, items):
    """Skip tests written for a board other than the one under test.

    Deliberately at collection time rather than in a fixture. `shell` and
    `booted` are session-scoped, and pytest sets higher-scoped fixtures up
    before a function-scoped autouse fixture gets a chance to skip anything — so
    a fixture-based check would have the harness flash and boot a board on
    behalf of a test that was never going to run. On the x86_64 target that is
    not merely wasteful: the Pi assertion it was setting up for cannot pass
    there, and `never_retry` marks the strategy broken when it fails, which
    takes the whole run down with it. A skip marker added here is evaluated
    before any fixture, so nothing is set up at all.
    """
    env_config = config.option.lg_env or os.environ.get("LG_ENV")
    if not env_config:
        return
    board = bench.declared_board(env_config)
    for item in items:
        marker = item.get_closest_marker("board")
        if marker is None:
            continue
        try:
            reason = capability.missing_board(marker.args, board)
        except ValueError as err:
            reason = str(err)
        if reason:
            item.add_marker(pytest.mark.skip(reason=reason))


@pytest.fixture(scope="session")
def board(env):
    """Which board this environment drives, e.g. "rpi5" or "x86_64".

    Here for the `image` fixture, which picks which image to look for. The
    *skipping* of other boards' tests does not go through this: it happens at
    collection time, before any fixture exists. See _skip_other_boards.
    """
    return env.config.get_option("board", None)


@pytest.fixture(scope="session")
def image(request, board):
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

    # Which image to look for follows the board, so neither target needs the
    # flag for an ordinary run and neither can pick up the other's image — a
    # mistake that would present as a boot failure rather than as a wrong file.
    if board == "x86_64":
        return bench.find_x86_image()
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
def published_resources(target):
    """Class names of everything the acquired place publishes.

    The one honest answer to "can this bench do X": it comes from the exporter,
    so a bench without a plug has no plug and a test needing one skips itself.
    """
    return {type(resource).__name__ for resource in target.resources}


@pytest.fixture(scope="session")
def _display_reason(shell):
    """Why `needs_display` tests cannot run here, or None if a display is attached.

    Asked of the board, once per run, because a panel is not a labgrid resource
    and so nothing on the network can see it. The alternative — a marker someone
    selects by hand — is what let a storage bug ship.
    """
    output = shell.run("grep -H . /sys/class/drm/*/status 2>/dev/null || true")[0]
    return capability.missing_display("\n".join(output))


@pytest.fixture(autouse=True)
def _needs_display(request):
    """Skip a `needs_display` test when the board reports nothing connected.

    Autouse so the marker cannot be forgotten, and lazy so a test that does not
    carry it never pays for the query.
    """
    if request.node.get_closest_marker("needs_display") is None:
        return
    reason = request.getfixturevalue("_display_reason")
    if reason:
        pytest.skip(reason)


@pytest.fixture(scope="session")
def plug(target, published_resources):
    """Read the plug directly, out of band from the driver that switches it.

    The plug measures actual current, which is how a board that is not running is
    told apart from a serial console that is not working. labgrid's power backends
    only switch and report the relay, so this talks to the plug itself — at the
    address the exporter published, so there is no second copy of it to go stale.

    Skips rather than fails on a bench with no plug, or a plug that is not a
    Shelly Gen 1: the bench it is pointed at is then simply a different bench,
    which is not a defect in the OS under test.
    """
    unmet = capability.missing_resource("plug", published_resources)
    if unmet:
        pytest.skip(unmet)

    port = target.get_resource(NetworkPowerPort)
    if port.model != "shelly_gen1":
        pytest.skip(f"plug is {port.model}, and only shelly_gen1 is read here")

    def read(what):
        if what == "draw":
            return bench.plug_draw(port.host)
        if what == "state":
            return bench.plug_state(port.host)
        raise ValueError(f"unknown plug query {what!r}")

    return read
