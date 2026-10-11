# Home Assistant talks to devices over HTTPS, not MQTT

The integration reaches each device directly on the LAN: an HTTP API plus a Server-Sent Events stream, authenticated by the device API token and served over TLS. There is no MQTT broker. With MQTT, onboarding was too complex: users had to set up and run a broker before a device would work. Now they install the integration and add the device, and pairing and kiosk login happen without typing (9f38974).

TLS was added because the kiosk login carries a ten-year credential (cb5a421). It protects against passive capture only: an attacker already intercepting traffic during first pairing is not covered, and that is accepted.

## Considered Options

- **MQTT** was the transport until 2026-07-26 (9f38974), with the broker set through the web UI or the seed file.
