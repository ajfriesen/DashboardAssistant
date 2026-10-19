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
  * the **Bench Home Assistant** and the journey through it — reset, pairing,
    the key the gate signs with, the Bench Wi-Fi's credentials. All
    session-scoped, because a run should pair once, and all skipping rather
    than failing when this target simply has no Home Assistant. See bench_ha.py
    and docs/adr/0012-the-full-journey-is-tested-against-a-real-home-assistant.md.

The hardware is not local: bench.yaml names a place on a labgrid coordinator, and
the place has to be acquired before any of this works. `just hw-test` does that
for you.
"""

import collections
import os
import shlex
import shutil
import subprocess

import pytest
from labgrid.resource import NetworkPowerPort

import bench
import bench_ha
import candidate
import capability
import device


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

    Read from the file rather than through `env.config.get_option`, which
    re-raises KeyError whenever the default is None (labgrid/config.py) — so the
    obvious spelling would throw for any environment that declares no board
    instead of returning one. It also keeps this and the collection-time check
    reading the same thing the same way.
    """
    return bench.declared_board(env.config_file)


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


# --------------------------------------------------------------------------- #
# The Bench Home Assistant, and the journey through it
#
# See docs/adr/0012-the-full-journey-is-tested-against-a-real-home-assistant.md
# and bench_ha.py. Session-scoped throughout: the reset takes ~27s and the
# pairing is the thing every later assertion builds on, so doing either per test
# would make a run take longer than the flash it follows.
# --------------------------------------------------------------------------- #


@pytest.fixture(scope="session")
def on_the_bench(published_resources):
    """Skip unless this target is a board on the bench's own network segment.

    Every journey assertion needs a device other machines can dial: discovery
    is link-local, Home Assistant opens the connection *to* the device
    (docs/adr/0002), and the kiosk's browser is reached by tunnelling into the
    board. The x86_64 QEMU target can do none of that and never will, so it
    skips rather than failing — which is also why this asks what the place is
    rather than whether the device happens to answer. See
    capability.missing_bench_place.

    Applied per module (`pytestmark = pytest.mark.usefixtures("on_the_bench")`)
    rather than per test, because it is true of a whole file or of none of it.
    """
    unmet = capability.missing_bench_place(published_resources)
    if unmet:
        pytest.skip(unmet)


@pytest.fixture(scope="session")
def bench_host(target, on_the_bench):
    """Any resource from the acquired place, for running commands on its host.

    Which one does not matter — they are all exported from the same bench host,
    and labgrid's own wrapping carries the hostname, the proxy and the ssh
    options. Which *kind* does matter, and subtly: see bench.host_resource.
    """
    resource = bench.host_resource(target.resources)
    if resource is None:
        pytest.skip("this place exports nothing that can run a command on its host")
    return resource


@pytest.fixture(scope="session")
def bench_ha_url(on_the_bench):
    """Where the Bench Home Assistant is, or a skip saying this target has none.

    Separate from the client fixture because the Wi-Fi seed needs the address
    without needing a session against it — and because a target with no Home
    Assistant should skip before anything resets anything.
    """
    url = bench_ha.configured_url()
    unmet = capability.missing_bench_home_assistant(
        url, bool(url) and bench_ha.reachable(url)
    )
    if unmet:
        pytest.skip(unmet)
    return url


@pytest.fixture(scope="session")
def bench_home_assistant(bench_host, bench_ha_url):
    """The Bench Home Assistant, reset to its fixture and authenticated.

    Reset *here* rather than in a test: a long-lived mutable instance makes a
    red gate meaningless, so every run starts from the committed fixture — one
    administrator, one token, a known dashboard, discovery on, the integration
    installed but deliberately not configured. The unit on the bench host does
    the waiting and exits non-zero unless Home Assistant is up, answers to the
    fixture's token and has loaded the integration, so a slow start cannot read
    as a failure here.
    """
    reset = bench.on_bench_host(
        bench_host,
        f"systemctl start {bench_ha.RESET_UNIT} && echo reset-ok",
        timeout=bench_ha.RESET_TIMEOUT,
    )
    if "reset-ok" not in reset:
        pytest.fail(
            f"the Bench Home Assistant would not reset: {reset.strip()!r}. That "
            "is the bench, not the image — no result from this run means anything"
        )

    token = bench_ha.read_token(
        os.environ,
        lambda: bench.on_bench_host(
            bench_host, f"cat {bench_ha.TOKEN_PATH}"
        ),
    )
    if not token:
        pytest.fail(
            f"no token at {bench_ha.TOKEN_PATH} on the bench host and "
            f"none in ${bench_ha.TOKEN_ENV} — the reset wrote a fixture "
            "whose credential cannot be found"
        )

    with bench_ha.BenchHomeAssistant(bench_ha_url, token) as client:
        yield client


@pytest.fixture(scope="session")
def device_ip(shell):
    """The board's address on the wire, asked of the board itself.

    Not read from a lease table or an environment file: the board is reflashed
    on most runs and its address is whatever DHCP just gave it, so anything
    written down here would be a second copy waiting to go stale.
    """
    output = "\n".join(shell.run(device.ADDR_COMMAND)[0])
    address = device.wired_address(output)
    if not address:
        pytest.fail(
            bench_ha.device_side(
                f"the board has no address on its wire:\n{output}"
            )
        )
    return address


@pytest.fixture(scope="session")
def gate_key(on_the_bench):
    """The key the release gate signs with, or a skip saying why not.

    Checked for existence before anything tries to use it, because the failure
    is not recoverable within a run: an attempt with a key that cannot sign
    counts as a failed authentication, and OpenSSH's per-source penalties then
    drop every further connection from this address for an hour — taking the
    rest of the suite with it. See labgrid/README.md.
    """
    path = os.path.expanduser(capability.GATE_KEY)
    key, unmet = capability.gate_key_choice(
        path, os.path.isfile(path), os.path.isfile(f"{path}.pub")
    )
    if unmet:
        pytest.skip(unmet)
    return key


@pytest.fixture(scope="session")
def paired(bench_home_assistant, shell, device_ip):
    """The device enrolled into the Bench Home Assistant, and what that produced.

    The journey itself, run once: wait for Home Assistant to raise a discovery
    flow on its own, step that flow to completion, and read back the device and
    entities it created. Every assertion in test_journey.py reads this record
    rather than repeating the enrollment, so a run pairs once and a failure
    points at one step rather than at the fourth attempt to do the same thing.

    The entry is removed afterwards. The reset at the start of the next run
    would do it anyway, but leaving a paired device behind makes the instance
    confusing to look at by hand, and `already_configured` is the abort this
    fixture is most likely to hit.
    """
    client = bench_home_assistant
    flow = bench_ha.wait_for_unprompted_flow(client)
    entry_id = client.finish_flow(flow["flow_id"])
    registry_device = bench_ha.wait_for_device(client, entry_id)
    entities = bench_ha.wait_for_entities(client, registry_device["id"])
    try:
        yield bench_ha.Pairing(
            flow=flow,
            entry_id=entry_id,
            device=registry_device,
            entities=entities,
            address=device_ip,
        )
    finally:
        try:
            client.delete_entry(entry_id)
        except Exception as err:  # noqa: BLE001 - teardown must not mask a failure
            print(f"could not remove config entry {entry_id}: {err!r}")


#: Never logged, never put in an assertion message: `psk` is a passphrase
#: and the console transcript is not private.
BenchWifi = collections.namedtuple("BenchWifi", "ssid psk")


@pytest.fixture(scope="session")
def bench_wifi():
    """The Bench Wi-Fi's SSID and passphrase, from the secret declarations.

    Declared in secretspec.toml and resolved into the environment by
    `secretspec run`; never committed, because the access point is the site's
    and the passphrase is not this repository's to hold. A bench without them
    skips rather than fails — a missing secret is a bench that is not set up,
    not an image that is broken.
    """
    ssid = os.environ.get(capability.WIFI_SSID_ENV)
    psk = os.environ.get(capability.WIFI_PSK_ENV)
    unmet = capability.missing_wifi_credentials(ssid, psk)
    if unmet:
        pytest.skip(unmet)
    return BenchWifi(ssid=ssid, psk=psk)


@pytest.fixture
def wired_link_down(shell):
    """Take the board's wire down for the test, and put it back afterwards.

    This is the assertion that is cheap *here* and expensive on most benches:
    the harness drives the board over its serial console, not over the network,
    so taking the only wired path away costs no control over it. Which is what
    makes a genuine Wi-Fi-only claim affordable — asserting that a credentials
    file was written is the weaker half of it.

    Restored in a `finally`, whatever the test did. A board left with no wire
    is a board every later test on this bench fails against, and the next
    person would be debugging the wrong run.
    """
    wire = device.wired_interface("\n".join(shell.run(device.ADDR_COMMAND)[0]))
    if not wire:
        pytest.skip("this board has no wired interface to take down")
    shell.run_check(f"ip link set {wire} down")
    try:
        yield wire
    finally:
        shell.run(f"ip link set {wire} up")
        # Give DHCP a moment to put the address back, so the next test does not
        # inherit a board that is technically up and not yet addressed.
        shell.run(
            f"timeout 60 sh -c 'until ip -4 addr show {wire} "
            "| grep -q \"inet \"; do sleep 1; done'"
        )


# --------------------------------------------------------------------------- #
# The candidate under test, and whether the board can fetch it
#
# A precondition rather than an assertion about the image: without it the
# update phase does not fail, it *compiles a system on a Raspberry Pi* — and a
# release gate that takes a night is a release gate nobody runs. See
# candidate.py and README.md, "The candidate has to be in the cache".
# --------------------------------------------------------------------------- #


def _host_eval(command):
    """Run an evaluation on the machine driving the bench, not on the board.

    Here rather than in candidate.py so that module stays pure and testable
    with no nix anywhere near it. The timeout is generous because a cold
    evaluation fetches the tag and a nixpkgs tarball first; it exists so a
    machine with no network fails in minutes rather than hanging.

    No shell: the command is a list of plain arguments once split, and the
    candidate's tag arrives from the environment. candidate.toplevel_installable
    already refuses a tag that is not one, the same way
    modules/core/update.nix refuses a ref that is not one — this is the second
    half of that, so neither has to hold the line alone.
    """
    done = subprocess.run(
        shlex.split(command), capture_output=True, text=True, timeout=1800
    )
    if done.returncode != 0:
        pytest.fail(
            f"could not resolve the candidate's closure on this machine: "
            f"`{command}` exited {done.returncode}\n{done.stderr.strip()}"
        )
    return done.stdout


@pytest.fixture(scope="session")
def candidate_tag():
    """The release tag this run is gating, or a skip saying it is gating none.

    A skip, not a failure: the suite runs against a working tree far more
    often than against a release, and `just hw-test` on a branch is not a
    broken gate.
    """
    tag = candidate.configured_tag(os.environ)
    unmet = candidate.missing_candidate(tag)
    if unmet:
        pytest.skip(unmet)
    return tag


@pytest.fixture(scope="session")
def candidate_closure(candidate_tag, board, shell):
    """The candidate's system closure, and what the board would do to realise it.

    Split across the two machines on purpose, and the split is the whole
    design:

      * the store path is resolved on the *host*, because evaluation is pure
        and so gives the same answer anywhere — while on the board it would
        mean a full nixpkgs evaluation driven over a serial console
      * whether that path can be fetched is asked on the *board*, because the
        answer depends on the board's own substituters and trusted keys
        (modules/core/binary-cache.nix). Nothing off the board can answer it:
        a cache the bench host can reach says nothing about a device.

    Session-scoped, so the board is asked once however many phases depend on
    it.
    """
    installable = candidate.toplevel_installable(candidate_tag, board)
    path = candidate.store_path(installable, _host_eval)
    # Querying a whole system closure's narinfos is hundreds of round trips
    # from a board on a home LAN, so this gets a timeout of its own rather
    # than the driver's 30 s default.
    output = "\n".join(shell.run(candidate.dry_run_command(path), timeout=600)[0])
    return path, candidate.plan(output)


@pytest.fixture(scope="session")
def candidate_in_cache(candidate_tag, board, candidate_closure):
    """Refuse to start a phase that would build a system on the board.

    What an update phase asks for. It fails rather than skipping: a candidate
    whose closure is not in the cache is a release that cannot be gated, and
    silently passing over that is how a verdict comes to mean nothing.
    """
    path, verdict = candidate_closure
    missing = candidate.not_in_cache(candidate_tag, board, path, verdict)
    if missing:
        pytest.fail(missing)
    return path
