# The seed file is the only way to configure a device

A device is configured only by seeding: a `dashboard-assistant.yaml` on the FIRMWARE partition or a USB stick. There is no on-screen setup, and recovery lives on the LAN-only admin page. The device is a wall panel that guests touch. An on-screen wizard let anyone at the touchscreen re-point the kiosk at a different Home Assistant, and the seed file already covered everything the wizard did (003def6).

## Considered Options

- **On-screen setup wizard and MQTT config screen** (164331c): removed because of the touchscreen takeover risk above.
- **Wi-Fi access point with a captive portal** (e7e6d4e): removed in 3734435 for its maintenance cost. The seed file already covered the same need, and the portal's end-to-end test never passed.
