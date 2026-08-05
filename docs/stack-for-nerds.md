---
icon: lucide/cpu
---

# Stack for Nerds

The technical bits, for the curious. If you just want a dashboard on your wall,
the [landing page](index.md) and [Get started](flash/flash.md) guide are all you
need — this page is about *how* it works under the hood.

## Built on NixOS

Dashboard Assistant OS is a minimal, **declarative NixOS** system.

- **Reproducible.** The whole system is defined in code. The image you flash is
  the system you run — there's no hand-configuration to drift over time.
- **Atomic updates, delivered through Home Assistant.** New versions appear as
  an `update` entity — install with one tap, no terminal and nothing to
  re-flash. An update either fully applies or not at all, and each version is
  kept as a NixOS *generation*.
- **Boots straight into a kiosk.** No desktop, no display manager, no login
  screen — just a full-screen Chromium locked to your dashboards.

## Recovery & rollback

Because every version is retained as a generation, you can always go back.

- **Manual rollback (available today).** An on-screen recovery picker lets you
  boot an older, known-good generation right from the device's touchscreen —
  useful if a configuration change misbehaves but the system still boots.
- **Automatic rollback (not yet).** Booting into the previous generation
  *automatically* after a failed boot relies on boot-counting support. The
  images use **U-Boot**, which doesn't provide it, and the NixOS support is
  still in testing — so today recovery is manual. This may change as the targets
  mature.

## Home Assistant integration

The panel doesn't just *show* Home Assistant — it reports back into it as a
device.

- A **first-party integration**, installable via [HACS](https://hacs.xyz/).
- Home Assistant **discovers the device over mDNS** and pairs with an API token
  shown on the device's Config → Info screen.
- **No MQTT broker required** — it talks to Home Assistant directly.
- Exposes controls and sensors: display on/off, brightness, zoom, dark mode,
  rotation, screenshot, reboot / shutdown, updates, plus battery, temperature,
  CPU, memory and storage.

See the [entity reference](about/features.md#home-assistant-integration) for the
full list.

## Provisioning

The device is configured entirely from a small **YAML seed file** (Home
Assistant URL, token, Wi-Fi, dashboard URLs, optional integration token) dropped
on a USB stick or the boot partition — no on-screen wizard, so a person at the
panel can't re-point the device. The on-device Config panel is read-only.

## Hardware

x86_64 is the primary, tested target today. Raspberry Pi and other aarch64
boards are a work in progress — see [Hardware Support](hardware-support.md) for
the current state.

## Development

Dashboard Assistant is under active development on
[GitHub](https://github.com/ajfriesen/DashboardAssistant) — issues and pull
requests are welcome.
