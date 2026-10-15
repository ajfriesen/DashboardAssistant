---
status: proposed
---

# The full journey is tested against a real Home Assistant on the bench

Every test stopped one step short of what the product promises. `tests/first-boot.nix` and the bench suite assert that a **device** boots, is **provisioned** and answers its **device API**; none of them assert that a **dashboard** is on the screen. So the **bench host** runs a **Bench Home Assistant**, and the **release gate** drives the whole journey through it: zeroconf discovery, the real config flow, **pairing**, and then the **kiosk** logged in and rendering.

A mock would not catch the failure this exists for. The **integration** repo already tests against a fake device, correctly, at its own level, and the OS repo already tests the device with no Home Assistant at all. Between those two sits the failure a user actually hits: a **kiosk token** that never arrives, which renders a perfectly healthy *login page* — reachable, unfailed, provisioned, and useless.

The Bench Home Assistant is pinned and its state is reset from a committed fixture before each run. A long-lived, mutable instance would make a red gate meaningless, and the strongest assertion available — Home Assistant's own DOM — is only safe to assert on against a frontend that cannot change underneath it. The integration is installed but left unconfigured, because the config flow is the step most likely to break for someone setting up their first device.

## Consequences

- A bad integration release can redden this repo's gate. That is correct, because the journey spans both, but it means the device-side and Home-Assistant-side assertions are named so a failure says which half broke.
- The state fixture is married to the pinned Home Assistant version: its on-disk schema migrates between releases, so the two bump together in one commit. The same holds for the browser automation's container and its client library, which must match.
- Home Assistant has to sit on the bench's own network segment, with host networking. It always opens the connection to the device ([0002](0002-home-assistant-talks-to-devices-over-https-not-mqtt.md)) and zeroconf is link-local, so anything that reflects or routes multicast becomes a thing the gate can fail on.
- Asserting the kiosk's own DOM needs a channel off the device, and the browser's debugging port is bound to loopback. A **dev image** therefore carries a key that can sign unattended, gated exactly like its root password — release images gain nothing.
- A release image has no shell, so its own check is the screenshot the device API already serves. That is a weaker oracle than the DOM, and it is the only one available without adding a surface to a shipped image; it exercises two shipped features rather than none.
- The gate pairs devices and factory-resets them, so it is never pointed at a Home Assistant anybody relies on.
