---
icon: lucide/sparkles
---

# Features

**The kiosk**

- Full-screen Chromium locked to your Home Assistant dashboard.
- Configure multiple dashboard URLs or any web site and cycle between them (from HA or on-screen).
- Wake the display by touch.
- On-screen keyboard for text fields on touch-only devices. (Experimental)
- Automatic login using a long-lived HA token — no tapping through the login screen.

**Multi-room audio** — see [Multi-room audio](../usage/audio.md).

- The dashboard is also a speaker: a built-in [Sendspin](https://www.sendspin-audio.com/)
  player joins a synchronized group alongside your other speakers.
- Music Assistant runs the show. Installed as the Home Assistant add-on, it gets a
  page on the dashboard automatically — already signed in, because Ingress carries
  the tablet's Home Assistant identity across.
- Audio never leaves your network, and there is no cloud account in the path.

**Control from Home Assistant** — see the [entity reference](#home-assistant-integration).

**Stays alive**

- Atomic OS updates surfaced as a Home Assistant `update` entity.
- Recovery built in: if an update misbehaves, roll back to a previous
  generation from the [admin page](../usage/admin.md) — LAN-only, off the
  touchscreen. (Automatic rollback on a failed boot isn't available yet — it
  needs boot-counting support that U-Boot doesn't provide.)

**Hands-off provisioning**

- A single device sets itself up on screen: a QR code joins it to your Wi-Fi
  and Home Assistant discovers it from there.
- For fleets or field deploys, a small YAML seed file (HA URL, token, Wi-Fi,
  dashboard URLs, optional integration token) dropped on a USB stick or the
  boot partition configures the device before it ever boots — no screen needed.
- Nothing on the tablet screen reconfigures the device. The bar carries
  navigation and the keyboard only, and the ⓘ view is read-only. Recovery
  (rollback, factory reset) lives on a separate [admin page](../usage/admin.md)
  you open from another machine on the network.

## Home Assistant integration

Install the first-party **Dashboard Assistant** integration
([via HACS](../usage/integration.md)) and Home Assistant discovers the device
over mDNS. A device that has not been added yet
hands over its API token automatically, so there is nothing to type and nothing to
press on the tablet. It appears as a single device with these entities:

### Controls

| Entity | Type | What it does |
|---|---|---|
| Display | `light` | Turn the panel on/off (DPMS) and set brightness |
| Zoom | `number` | Browser zoom, 25–400 % |
| Dark mode | `switch` | Flip the Home Assistant frontend dark/light |
| Rotation | `select` | Rotate the display 0 / 90 / 180 / 270° |
| Screenshot | `button` + `image` | Capture the current web view on demand; the latest shot shows as an image you can click to enlarge |
| Page | `select` | Jump to one of your configured dashboard URLs |
| Next / Previous page | `button` | Cycle through the dashboard URLs |
| Page 1 … N | `text` | Edit the dashboard URL list from HA |
| Sendspin player | `switch` | Turn the device's multi-room audio player on/off; carries a `status` attribute. Only on builds with the audio stack |
| Reboot / Shut down | `button` | Power-cycle the device |
| System update | `update` | Installed vs. latest release, with one-tap install |

### Sensors

| Entity | Type | Notes |
|---|---|---|
| Battery / Battery charging | `sensor` / `binary_sensor` | Only when the device has a battery |
| Temperature | `sensor` | CPU / board temperature, when a thermal sensor exists |
| CPU usage | `sensor` | |
| Memory total / used | `sensor` | |
| Storage total / used | `sensor` | |
| Generations | `sensor` | Number of bootable NixOS generations |
| Seconds since last touch | `sensor` | For presence / idle automations |
| Hostname | `sensor` | Device info / diagnostics |
| IP address | `sensor` | Device info / diagnostics |
| Uptime | `sensor` | Device info / diagnostics |
| Model | `sensor` | Device info / diagnostics |
| Serial | `sensor` | Device info / diagnostics |
