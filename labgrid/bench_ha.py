"""The Bench Home Assistant — the instance a bench device actually pairs with.

See docs/adr/0012-the-full-journey-is-tested-against-a-real-home-assistant.md.
It is pinned, it lives on the bench host, and it is reset to a committed fixture
before every run, so one leftover config entry cannot make a red gate
meaningless. None of that is declared here: the service, the fixture and the
reset unit live in the bench host's own configuration, outside this repository.
What is here is the client half — how the suite finds it, authenticates to it,
and drives it.

Two transports, which is not a choice:

  * **WebSocket** for everything with a `type:` — the registries, the states,
    service calls, and the list of flows in progress. This is Home Assistant's
    own API, the one its frontend uses, so the gate exercises the real
    discovery path without depending on frontend markup that can change
    underneath it.
  * **REST** for `config/config_entries/flow`, because that is the only place
    config flows are steppable. The frontend posts there too; there is no
    websocket command for it.

The decision-making is kept out of the client and in the pure functions at the
top, so the things that make the gate *mean* something — that a flow appeared
unprompted, that a flow that ended actually paired a device, which half of the
journey a failure belongs to — are testable with no Home Assistant anywhere
near. See test_bench_ha.py.
"""

import collections
import json
import os
import time
import urllib.error
import urllib.request

#: The integration's domain, and so its config-flow handler.
DOMAIN = "dashboard_assistant"

#: Where the integration comes from: the built-in marketplace's default catalog,
#: the same listing a user installs it from. The suite installs it after every
#: reset, so the install path is part of what the gate tests and the version is
#: the run's choice rather than the bench host's. The price is that a run needs
#: GitHub — see install_integration.
REPOSITORY = "ajfriesen/dashboard-assistant-integration"

#: Which version of the integration to install, as a release tag (`v1.1.0`).
#: Unset installs whatever the catalog currently offers — what a user installing
#: it today would get, which is the honest default for a release gate. Set it to
#: gate against a pre-release or to bisect: a named tag installs even when the
#: catalog hides pre-releases.
VERSION_ENV = "BENCH_HA_INTEGRATION_VERSION"

#: Where the Bench Home Assistant is, and an optional token override. Not
#: defaulted here on purpose, exactly like the LG_* variables: the justfile owns
#: the defaults (one place, overridable per bench) and an unset one must read as
#: "this target has no Home Assistant" rather than quietly pointing the run at
#: somebody else's instance. See capability.missing_bench_home_assistant.
URL_ENV = "BENCH_HA_URL"
TOKEN_ENV = "BENCH_HA_TOKEN"

#: The fixture's long-lived token, on the bench host. Read from the box rather
#: than committed here: a second copy is a copy that can drift from the fixture
#: that minted it, and the fixture is already married to the pinned version.
TOKEN_PATH = "/etc/bench-home-assistant/token"

#: Resetting is a unit rather than a sequence of API calls, and it exits
#: non-zero unless Home Assistant is up *and* answers to the fixture's token —
#: so the suite does not re-implement that wait, and a slow start does not read
#: as a failure. It says nothing about the integration: the fixture has none
#: installed, and installing it is this suite's job. A polkit rule on the bench
#: host scopes it to this one unit, so no tty and no sudo are needed.
RESET_UNIT = "bench-home-assistant-reset.service"

#: How long a reset may take. ~27s on the ODROID-H2 that runs the bench, so this
#: is generous; it exists so a wedged instance fails the run instead of hanging
#: it.
RESET_TIMEOUT = 180


# --------------------------------------------------------------------------- #
# Pure: what the data means
# --------------------------------------------------------------------------- #

#: Config-flow sources that nobody asked for. This is the no-typing promise,
#: written down: the product's claim is that a freshly flashed device ends up in
#: Home Assistant with nobody touching a keyboard, so a flow whose source is
#: `user` is the very thing being disproved and must not satisfy the assertion.
#: `reconfigure` is excluded for the same reason — it presupposes an entry.
UNPROMPTED_SOURCES = frozenset(
    {
        "zeroconf",
        "ssdp",
        "dhcp",
        "usb",
        "homekit",
        "mqtt",
        "discovery",
        "integration_discovery",
    }
)


def unprompted_flow(flows, domain=DOMAIN):
    """The discovery flow for `domain` that appeared on its own, or None.

    `flows` is what `config_entries/flow/progress` returns. A bench Home
    Assistant on a real network segment discovers printers and speakers too, so
    the handler is matched as well as the source.
    """
    for flow in flows:
        if flow.get("handler") != domain:
            continue
        if (flow.get("context") or {}).get("source") in UNPROMPTED_SOURCES:
            return flow
    return None


#: What to send at a flow step. Empty, and that is the assertion: enrollment is
#: typing-free because the integration fetches the device's token itself over
#: POST /api/ha/pair (daemon/pairing.go), so every step here is a bare
#: confirmation. The day this needs a field, the promise has already broken.
CONFIRM_INPUT = {}

#: One decision about a flow result. `action` is submit / done / aborted;
#: `detail` is the step to submit, the entry id created, or the abort reason.
FlowStep = collections.namedtuple("FlowStep", "action detail")


#: The menu branch that enrolls a device without anyone typing anything. The
#: integration also offers `manual`, which is where a human enters a host and
#: port — the documented fallback for when discovery fails
#: (docs/usage/integration.md). Taking that one would pass this gate while
#: disproving the promise it exists to assert, so the branch is named here
#: rather than chosen by position.
TYPING_FREE_STEP = "pair"


def menu_options(result):
    """The step ids a menu result offers, in the order it offers them."""
    for field in result.get("data_schema") or []:
        if field.get("name") == "next_step_id":
            return [option[0] for option in field.get("options") or []]
    return []


def next_flow_action(result):
    """What to do with a config-flow result.

    Raises on a result type this does not know. Home Assistant has grown step
    types since this was written (`progress`, `external`), and guessing at one
    is the expensive kind of wrong: treating it as "keep going" hangs the run,
    treating it as success passes a gate that paired nothing.

    `menu` is known now — the integration serves one offering `pair` or
    `manual` — but it is stepped down the named typing-free branch only. A menu
    that does not offer it is refused the same way an unknown type is, because
    "pick the first option" is exactly the guess this function exists to avoid.
    """
    kind = result.get("type")
    if kind == "form":
        return FlowStep("submit", result.get("step_id"))
    if kind == "create_entry":
        return FlowStep("done", (result.get("result") or {}).get("entry_id"))
    if kind == "abort":
        return FlowStep("aborted", result.get("reason") or "no reason given")
    if kind == "menu":
        offered = menu_options(result)
        if TYPING_FREE_STEP not in offered:
            raise ValueError(
                f"the config flow offered a menu without a {TYPING_FREE_STEP!r} "
                f"step — it offered {offered!r}. Enrollment is supposed to need "
                "no typing, and picking another branch would pass this gate "
                "while disproving that"
            )
        return FlowStep("menu", TYPING_FREE_STEP)
    raise ValueError(
        f"unknown config-flow result type {kind!r} — this gate does not know "
        "how to step it, and guessing would either hang the run or pass it "
        "without pairing anything"
    )


def device_of(devices, entry_id):
    """The device registry entry this config entry created, or None."""
    for device in devices:
        if entry_id in (device.get("config_entries") or []):
            return device
    return None


def entities_of(entities, device_id):
    """Entity ids belonging to `device_id`, sorted."""
    return sorted(
        entry["entity_id"] for entry in entities if entry.get("device_id") == device_id
    )


#: The control the service-call round trip is made against. Zoom, because the
#: device persists it to a plain file (daemon/config.go: zoomFile) that the
#: serial console can read — so "the call took effect on the device" needs no
#: display, no second API, and nothing that could itself be broken.
ZOOM_SUFFIX = "_zoom"


def zoom_entity(entity_ids):
    """The number entity that drives the kiosk's zoom, or None.

    Matched by shape rather than by a hardcoded id: the entity id carries the
    device's name, which carries its hostname, which differs per board.
    """
    for entity_id in sorted(entity_ids):
        if entity_id.startswith("number.") and entity_id.endswith(ZOOM_SUFFIX):
            return entity_id
    return None


#: The state Home Assistant gives every entity of a device its coordinator
#: cannot reach. `unknown` is deliberately *not* here: a button's state is the
#: timestamp of its last press and an event entity's is its last event, so both
#: rest at `unknown` on a device that is working perfectly. Failing on it would
#: redden the gate for the wrong reason.
NOT_ANSWERING = "unavailable"


def unanswering(states, entity_ids):
    """Which of `entity_ids` are not answering, as "id=state" strings.

    `states` maps entity id to state string. Every one is named rather than
    just the first: "three of the four are unavailable" and "one is" are
    different problems.
    """
    bad = []
    for entity_id in entity_ids:
        state = states.get(entity_id)
        if state is None:
            bad.append(f"{entity_id}=<no state>")
        elif state == NOT_ANSWERING:
            bad.append(f"{entity_id}={state}")
    return bad


def ha_side(message):
    """Label a failure as Home Assistant's half of the journey.

    ADR 0012: a bad integration release can redden this repository's gate, and
    that is correct, because the journey spans both. It is only tolerable if the
    failure says which side it is on without anyone having to read the test.
    """
    return f"Home Assistant side: {message}"


def device_side(message):
    """Label a failure as the device's half of the journey. See ha_side."""
    return f"device side: {message}"


#: The marketplace's stage once its startup tasks — the catalog fetch among
#: them — are done. Before that its repository list is the cache the fixture
#: was captured with, which can predate a release or the listing itself.
MARKETPLACE_RUNNING = "running"


def marketplace_running(info):
    """Whether `marketplace/info` says it is ready to install from.

    Raises rather than returning False when the marketplace has disabled
    itself, because that is a verdict rather than a stage to wait out, and
    the reason (a GitHub rate limit, typically) is the whole diagnosis.
    """
    reason = info.get("disabled_reason")
    if reason:
        raise RuntimeError(f"the marketplace is disabled: {reason}")
    return info.get("stage") == MARKETPLACE_RUNNING


def catalog_entry(repositories, full_name=REPOSITORY):
    """The marketplace's entry for `full_name`, or None.

    Matched case-insensitively, as GitHub does: the catalog keeps the name as
    it was listed, and a change of case in the owner's name would otherwise
    read as a delisting.
    """
    wanted = full_name.lower()
    for repository in repositories:
        if (repository.get("full_name") or "").lower() == wanted:
            return repository
    return None


def requested_version(environ):
    """The integration version this run asked for, or None for the catalog's."""
    return (environ.get(VERSION_ENV) or "").strip() or None


def same_version(tag, manifest_version):
    """Whether a release tag and a manifest.json version name the same release.

    Tags carry a `v` and manifests do not (`v1.1.0` is `1.1.0`), and that is
    the only difference tolerated: anything looser would let a stale install
    pass for the version the run asked for.
    """

    def bare(version):
        version = (version or "").strip()
        return version[1:] if version[:1] in ("v", "V") else version

    return bool(bare(tag)) and bare(tag) == bare(manifest_version)


def install_problem(manifest, version=None, domain=DOMAIN):
    """What is wrong with the integration Home Assistant now resolves, or None.

    `manifest` is what `manifest/get` returns after the restart. A built-in of
    the same name, or a version other than the one asked for, means the
    journey would run against something other than the release under test —
    and pass or fail for reasons that have nothing to do with it.
    """
    if manifest.get("is_built_in"):
        return f"{domain} resolves to a built-in integration, not the installed one"
    if version is not None and not same_version(version, manifest.get("version")):
        return (
            f"asked for {version} but Home Assistant loaded "
            f"{manifest.get('version')!r}"
        )
    return None


def websocket_url(base):
    """The websocket endpoint for a Home Assistant at `base`."""
    scheme, _, rest = base.rstrip("/").partition("://")
    return f"{'wss' if scheme == 'https' else 'ws'}://{rest}/api/websocket"


def read_token(environ, read_bench_host):
    """The fixture's long-lived token, or None.

    An explicit token in the environment wins, so a throwaway instance needs no
    bench host at all; otherwise it comes off the bench host, where the fixture
    that minted it also lives. `read_bench_host` is a thunk so this stays
    testable with nothing to ssh to.
    """
    explicit = (environ.get(TOKEN_ENV) or "").strip()
    if explicit:
        return explicit
    return (read_bench_host() or "").strip() or None


# --------------------------------------------------------------------------- #
# Impure: talking to it
# --------------------------------------------------------------------------- #


class BenchHomeAssistant:
    """A connected, authenticated session against the Bench Home Assistant.

    Synchronous on purpose. The suite around it is synchronous, labgrid is
    synchronous, and an event loop here would buy nothing but a second way for a
    hang to present itself.
    """

    def __init__(self, base_url, token, timeout=30):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._socket = None
        self._next_id = 1

    # -- lifecycle ---------------------------------------------------------- #

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *_):
        self.close()

    def connect(self):
        """Open the websocket and authenticate. Raises on a refused token."""
        # Imported here rather than at module scope so the pure half above — and
        # every unit test of it — keeps working in an interpreter that has no
        # websockets installed.
        from websockets.sync.client import connect

        # No frame limit: the client's default is 1 MiB, and the marketplace's
        # repository list alone is several. Over the limit, the client closes
        # the connection rather than raising, so every later command fails
        # with an error that points away from the cause.
        self._socket = connect(
            websocket_url(self.base_url), open_timeout=self.timeout, max_size=None
        )
        # Anything that goes wrong from here leaves an open socket behind,
        # and `with BenchHomeAssistant(...)` never reaches __exit__ when
        # __enter__ raises — so the close has to happen here.
        try:
            hello = self._receive()
            if hello.get("type") != "auth_required":
                raise RuntimeError(ha_side(f"unexpected greeting: {hello!r}"))
            self._send({"type": "auth", "access_token": self.token})
            verdict = self._receive()
            if verdict.get("type") != "auth_ok":
                raise RuntimeError(
                    ha_side(
                        "the fixture's token was refused "
                        f"({verdict.get('message') or verdict!r}) — the reset "
                        "and the token have come apart"
                    )
                )
        except BaseException:
            self.close()
            raise

    def close(self):
        if self._socket is not None:
            self._socket.close()
            self._socket = None

    # -- the websocket API -------------------------------------------------- #

    def _send(self, message):
        self._socket.send(json.dumps(message))

    def _receive(self):
        return json.loads(self._socket.recv(timeout=self.timeout))

    def command(self, type_, **fields):
        """Send a websocket command and return its result.

        Commands are answered in order on this connection — nothing here
        subscribes to anything — so matching the id is a sanity check rather
        than a dispatcher.
        """
        message_id = self._next_id
        self._next_id += 1
        self._send({"id": message_id, "type": type_, **fields})
        while True:
            reply = self._receive()
            if reply.get("id") != message_id:
                continue  # an event from something else; not ours to handle
            if not reply.get("success", False):
                error = reply.get("error") or {}
                raise RuntimeError(
                    ha_side(
                        f"{type_} failed: "
                        f"{error.get('code')} {error.get('message')}"
                    )
                )
            return reply.get("result")

    def flows_in_progress(self):
        """Every config flow Home Assistant currently has open."""
        return self.command("config_entries/flow/progress") or []

    def devices(self):
        return self.command("config/device_registry/list") or []

    def entities(self):
        return self.command("config/entity_registry/list") or []

    def states(self):
        """Every entity's state, as {entity_id: state}.

        One round trip for all of them: `get_states` returns the whole machine
        either way, so asking it once per entity would be the same payload N
        times over a websocket that is also carrying events.
        """
        return {
            state["entity_id"]: state.get("state")
            for state in self.command("get_states") or []
        }

    def call_service(self, domain, service, entity_id, **data):
        """Call a service against one entity and wait for it to be handled."""
        return self.command(
            "call_service",
            domain=domain,
            service=service,
            target={"entity_id": entity_id},
            service_data=data,
        )

    # -- the marketplace ---------------------------------------------------- #

    def marketplace_info(self):
        """The marketplace's stage, and why it is disabled if it is."""
        return self.command("marketplace/info") or {}

    def marketplace_repositories(self):
        """The integrations the marketplace lists, installed or not."""
        return (
            self.command("marketplace/repositories/list", categories=["integration"])
            or []
        )

    def accept_marketplace_warning(self):
        """Accept the marketplace's first-run warning for the fixture's user.

        Every install is refused until this user has, and accepting is what
        clicking through the warning in the panel does. Done on every run rather
        than baked into the fixture, so a re-capture cannot quietly drop it.
        """
        return self.command("marketplace/warning/accept")

    def install_repository(self, repository_id, version=None):
        """Install a catalog repository, at `version` or at the catalog's."""
        fields = {"repository": str(repository_id)}
        if version is not None:
            fields["version"] = version
        return self.command("marketplace/repository/install", **fields)

    def manifest(self, domain=DOMAIN):
        """The manifest Home Assistant resolves for `domain`."""
        return self.command("manifest/get", integration=domain) or {}

    def restart(self):
        """Restart Home Assistant, returning once this instance has gone.

        Returns when the old instance drops this connection, which it does on
        its way down — the one signal that cannot be confused with the
        instance still being up. Polling for "not RUNNING" instead would race
        a fast restart. The connection is closed afterwards either way; call
        connect() again once the new instance is RUNNING.
        """
        from websockets.exceptions import ConnectionClosed

        message_id = self._next_id
        self._next_id += 1
        self._send(
            {
                "id": message_id,
                "type": "call_service",
                "domain": "homeassistant",
                "service": "restart",
            }
        )
        try:
            while True:
                reply = self._receive()
                # Home Assistant checks its configuration before restarting,
                # and refuses here rather than going down if that fails.
                if reply.get("id") == message_id and not reply.get("success", True):
                    error = reply.get("error") or {}
                    raise RuntimeError(
                        ha_side(
                            "Home Assistant refused to restart: "
                            f"{error.get('code')} {error.get('message')}"
                        )
                    )
        except ConnectionClosed:
            pass
        finally:
            self.close()

    def config(self):
        """Home Assistant's /api/config, including its `state`."""
        return self._rest("GET", "config")

    # -- the config-flow REST API ------------------------------------------- #

    def _rest(self, method, path, payload=None):
        request = urllib.request.Request(
            f"{self.base_url}/api/{path}",
            method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as err:
            raise RuntimeError(
                ha_side(f"{method} {path} returned {err.code}: {err.read()[:200]!r}")
            ) from err

    def step_flow(self, flow_id, user_input=None):
        """Submit one step of a config flow and return the next result."""
        return self._rest(
            "POST",
            f"config/config_entries/flow/{flow_id}",
            CONFIRM_INPUT if user_input is None else user_input,
        )

    def finish_flow(self, flow_id, max_steps=8):
        """Step a flow to completion and return the config entry id.

        Bounded rather than `while True`: a flow that re-serves the same form
        forever is a real failure mode of a half-written integration, and a gate
        that hangs on it is worse than one that fails.
        """
        user_input = None
        for _ in range(max_steps):
            step = next_flow_action(self.step_flow(flow_id, user_input))
            # A menu is answered by naming the next step, not by an empty
            # confirmation, so the choice is carried into the following POST.
            user_input = (
                {"next_step_id": step.detail} if step.action == "menu" else None
            )
            if step.action == "done":
                return step.detail
            if step.action == "aborted":
                raise AssertionError(
                    ha_side(
                        f"the config flow aborted: {step.detail}. "
                        "`already_configured` means the reset left an entry "
                        "behind and nothing about this run is meaningful"
                    )
                )
        raise AssertionError(
            ha_side(
                f"the config flow was still asking for input after {max_steps} "
                "steps — enrollment is supposed to need none"
            )
        )

    def delete_entry(self, entry_id):
        """Remove a config entry. Used to leave the instance as it was found."""
        return self._rest("DELETE", f"config/config_entries/entry/{entry_id}")


def reachable(base_url, timeout=5):
    """Whether something answers as Home Assistant at `base_url`.

    Deliberately the unauthenticated `/` rather than an API call: this question
    is "is there a Home Assistant on this network", and answering it with an
    authenticated call would conflate a missing instance with a bad token —
    which are a skip and a failure respectively.
    """
    try:
        with urllib.request.urlopen(base_url, timeout=timeout) as response:
            return 200 <= response.status < 400
    except OSError:
        return False


def configured_url(environ=None):
    """Where the Bench Home Assistant is, or None if this target has none."""
    return ((environ if environ is not None else os.environ).get(URL_ENV) or "").strip() or None


# --------------------------------------------------------------------------- #
# Waiting for the journey to happen
# --------------------------------------------------------------------------- #

#: How long to let discovery take. mDNS announcement, Home Assistant's own
#: zeroconf browser and its flow debounce all sit inside this, and the board is
#: still settling after a first boot that resized a filesystem. Generous on
#: purpose: a gate that fails for being early teaches people to re-run it.
DISCOVERY_TIMEOUT = 180

#: How long to let the registries catch up after a config entry is created.
#: Short, because by this point the entry exists and the integration has
#: already talked to the device.
REGISTRY_TIMEOUT = 60

#: How long to let a service call reach the device and be persisted there.
SERVICE_TIMEOUT = 30


def wait_until(
    produce,
    what,
    timeout,
    interval=1.0,
    now=time.monotonic,
    sleep=time.sleep,
):
    """Call `produce` until it returns something truthy, and return it.

    Polling rather than subscribing, because every one of these questions is
    "has this appeared yet" and a subscription would need its own connection
    and its own failure mode. The clock is injectable so the waiting is
    testable without doing any (test_bench_ha.py).

    An exception from `produce` is *not* the final answer: Home Assistant
    refuses registry commands for a moment while a config entry is being set
    up, and failing a four-minute hardware run for being early is the wrong
    trade. The last one is kept and reported if the wait runs out, because
    "nothing appeared" on its own is true and useless.
    """
    deadline = now() + timeout
    last_error = None
    while True:
        try:
            found = produce()
            if found:
                return found
            last_error = None
        except Exception as err:  # noqa: BLE001 - reported below if it persists
            last_error = err
        if now() >= deadline:
            break
        sleep(interval)
    trailer = f" (last error: {last_error!r})" if last_error else ""
    raise AssertionError(f"{what} did not appear within {timeout}s{trailer}")


#: How long the marketplace may take to finish its startup tasks. They include
#: fetching the catalog from GitHub, after Home Assistant itself has started.
MARKETPLACE_TIMEOUT = 120

#: How long a restart may take. The same cold start a reset waits out
#: (RESET_TIMEOUT), plus the shutdown in front of it.
RESTART_TIMEOUT = 240


def install_integration(client, version=None):
    """Install the integration from the marketplace, as a user would.

    Returns the version Home Assistant loaded. Then restarts Home Assistant,
    and that restart is not optional: a first install of a config-flow
    integration is usable without one, but zeroconf reads the service types to
    browse for exactly once, at startup. Skip the restart and the device
    announces itself to a Home Assistant that is not listening for it, which
    fails the discovery assertion for a reason that looks like the device's.

    `client` is left connected to the restarted instance.

    The marketplace fetches from GitHub, so this is where a run stops being
    offline. Anonymous GitHub access is rate-limited, but installing the
    catalog's own version downloads from hosts without that limit — so leaving
    VERSION_ENV unset is also the setting least likely to be throttled.
    """
    wait_until(
        lambda: marketplace_running(client.marketplace_info()),
        ha_side("the marketplace finishing its startup"),
        MARKETPLACE_TIMEOUT,
    )
    entry = wait_until(
        lambda: catalog_entry(client.marketplace_repositories()),
        ha_side(
            f"{REPOSITORY} in the marketplace catalog. It is in the default "
            "catalog, so if the catalog fetch worked and it is still missing, "
            "it has been delisted"
        ),
        MARKETPLACE_TIMEOUT,
    )
    if entry.get("installed"):
        raise AssertionError(
            ha_side(
                f"{REPOSITORY} is already installed — the reset left it behind, "
                "and nothing about this run would say which version it tests"
            )
        )

    client.accept_marketplace_warning()
    client.install_repository(entry["id"], version)

    client.restart()
    wait_until(
        lambda: client.config().get("state") == "RUNNING",
        ha_side("Home Assistant RUNNING again after the post-install restart"),
        RESTART_TIMEOUT,
    )
    client.connect()

    manifest = client.manifest()
    problem = install_problem(manifest, version)
    if problem:
        raise AssertionError(ha_side(problem))
    return manifest.get("version")


#: What one run of the journey produced, for the assertions to read.
Pairing = collections.namedtuple("Pairing", "flow entry_id device entities address")


def wait_for_unprompted_flow(client, timeout=DISCOVERY_TIMEOUT):
    """Wait for Home Assistant to raise a discovery flow on its own.

    Nothing here starts a flow, and that is the assertion: the product's claim
    is that a freshly flashed device ends up in Home Assistant with nobody
    typing anything, so the flow has to already be there when we look.
    """
    return wait_until(
        lambda: unprompted_flow(client.flows_in_progress()),
        f"an unprompted discovery flow for {DOMAIN}. The device advertises over "
        "mDNS (test_first_boot.py::test_mdns_advertisement says whether it "
        "still does) and Home Assistant browses for it, so if that assertion "
        "passed and this one did not, the Home Assistant side is where to look",
        timeout,
    )


def wait_for_device(client, entry_id, timeout=REGISTRY_TIMEOUT):
    """Wait for the config entry to produce a device registry entry."""
    return wait_until(
        lambda: device_of(client.devices(), entry_id),
        ha_side(f"a device in the registry for config entry {entry_id}"),
        timeout,
    )


def wait_for_entities(client, device_id, timeout=REGISTRY_TIMEOUT):
    """Wait for the device to produce entities."""
    return wait_until(
        lambda: entities_of(client.entities(), device_id),
        ha_side(f"entities for device {device_id}"),
        timeout,
    )
