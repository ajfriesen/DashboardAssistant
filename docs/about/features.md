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

**Control from Home Assistant** — see the [entity reference](#home-assistant-integration).

**Stays alive**

- Automatic generation rollback on a failed boot, plus a manual recovery picker.
- Atomic OS updates surfaced as a Home Assistant `update` entity.

**Seed-file provisioning**

- Configured entirely from a small YAML seed file (HA URL, token, Wi-Fi, MQTT,
  dashboard URLs) dropped on a USB stick or the boot partition — no on-screen
  wizard, so a person at the panel can't re-point the device.
- On-device ⚙ Config panel is read-only: Info and Recovery tabs only.

## Home Assistant integration

Once you give the device your MQTT broker, it auto-discovers as a single
**Dashboard Assistant** device with these entities:

### Controls

| Entity | Type | What it does |
|---|---|---|
| Display | `light` | Turn the panel on/off (DPMS) and set brightness |
| Zoom | `number` | Browser zoom, 25–400 % |
| Dark mode | `switch` | Flip the Home Assistant frontend dark/light |
| Screenshot | `button` + `image` | Capture the current web view on demand; the latest shot shows as an image you can click to enlarge |
| Page | `select` | Jump to one of your configured dashboard URLs |
| Next / Previous page | `button` | Cycle through the dashboard URLs |
| Page 1 … N | `text` | Edit the dashboard URL list from HA |
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
