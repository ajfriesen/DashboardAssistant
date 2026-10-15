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

#: The integration's domain, and so its config-flow handler. Pinned in the bench
#: host's configuration as a flake input; never fetched over the network during
#: a run, because a HACS rate limit must not be able to redden this gate.
DOMAIN = "dashboard_assistant"

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
#: non-zero unless Home Assistant is up *and* answers to the fixture's token
#: *and* has loaded the integration — so the suite does not re-implement that
#: wait, and a slow start does not read as a failure. A polkit rule on the bench
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


def next_flow_action(result):
    """What to do with a config-flow result.

    Raises on a result type this does not know. Home Assistant has grown step
    types since this was written (`menu`, `progress`, `external`), and guessing
    at one is the expensive kind of wrong: treating it as "keep going" hangs the
    run, treating it as success passes a gate that paired nothing.
    """
    kind = result.get("type")
    if kind == "form":
        return FlowStep("submit", result.get("step_id"))
    if kind == "create_entry":
        return FlowStep("done", (result.get("result") or {}).get("entry_id"))
    if kind == "abort":
        return FlowStep("aborted", result.get("reason") or "no reason given")
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

        self._socket = connect(
            websocket_url(self.base_url), open_timeout=self.timeout
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
        for _ in range(max_steps):
            step = next_flow_action(self.step_flow(flow_id))
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
