# Home Assistant talks to devices over HTTPS, not MQTT

The integration reaches each device directly on the LAN: an HTTP API plus a Server-Sent Events stream, authenticated by the device API token and served over TLS. There is no MQTT broker. With MQTT, onboarding was too complex: users had to set up and run a broker before a device would work. Now they install the integration and add the device, and pairing and kiosk login happen without typing (9f38974).

TLS was added because the kiosk login carries a ten-year credential (cb5a421). It protects against passive capture only: an attacker already intercepting traffic during first pairing is not covered, and that is accepted.

Home Assistant always dials the device, never the reverse, which makes "Home Assistant and the device are on the same network" a constraint of Dashboard Assistant rather than an accident. This is what lets a device be found over zeroconf, identified by `node_id` instead of an address, and pinned by its TLS certificate on first contact.

State travels one way, as whole snapshots over Server-Sent Events (`daemon/ha.go`); commands are ordinary authenticated POSTs that return the snapshot computed after they apply. Server-Sent Events rather than a WebSocket because the device is the server, so device-to-Home-Assistant is the direction they natively carry, and the traffic is asymmetric: continuous state up, occasional commands down. A snapshot is never a delta, and that is the load-bearing part. Absent sections (`sendspin`, `battery.present`, `btrfs.present`) make the snapshot a forward-compatible extension point: an app adds a key, an older integration ignores it, an older device omits it and no entity appears. Capability negotiation is implicit, so apps can be added without a protocol version on either side. Whole snapshots are also why a lagging subscriber's frames are dropped rather than queued, and why the stream needs no `id:`, `Last-Event-ID` or replay — the next frame carries everything.

## Considered Options

- **MQTT** was the transport until 2026-07-26 (9f38974), with the broker set through the web UI or the seed file.
- **A WebSocket** is what most Home Assistant local-push device integrations use (WLED, Shelly gen 2+, deCONZ, Z-Wave JS). Declined: its duplex buys nothing here, and it would cost bespoke auth framing, ping/pong and reconnect logic in both Go and Python, plus a command registry to version, in exchange for latency no one can perceive on a LAN.
- **An outbound WebSocket**, the device dialling Home Assistant, is how Shelly reaches devices it cannot route to and how Browser Mod works. Declined because same-network is a constraint: a device that cannot reach Home Assistant cannot load the dashboard either, so the transport is not the binding problem. It would also invert pairing, making the pairing window and certificate pinning largely redundant.
- **Long polling** is one-way like Server-Sent Events but reconnects per event and would need an event cursor so nothing is lost between polls. Its reason to exist is proxies that break streaming, and there are none on a LAN.
- **HTTP/3** would need a non-standard-library server, and aiohttp has no HTTP/3 client, so the integration could not speak it.

## Consequences

- The integration keeps polling `/api/ha/state` every 60 s even while the stream is healthy. That is deliberate, not dead weight: it is the path that raises reauth (the stream loop gives up permanently on a rejected token), and the only thing that catches a stream that is alive but stale. WLED stops polling while its socket is up and [entities consequently stay available with stale state when the device disappears](https://github.com/home-assistant/core/issues/185558).
- Apps are reached through this API too, so an app that needs to stream (audio, voice) brings its own protocol alongside it rather than through it — Sendspin streams out of band, and an Assist satellite would speak Wyoming.
