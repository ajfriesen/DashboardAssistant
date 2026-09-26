# FAQ

Frequently asked questions:

## Does it support Android?

No.

## Why another kiosk OS?

Most "wall tablet" setups are a stack of manual tweaks: disable the lock screen,
side-load a kiosk browser, fight the OS updater, and hope none of it breaks after
a reboot. Dashboard Assistant takes the opposite approach:

- **Declarative and reproducible.** The whole system is defined in NixOS. The
  image you flash is the system you run — there is no hand-configuration to drift.
- **Recoverable by design.** Updates are atomic and every version is kept as a
  NixOS generation. If one misbehaves, the device's LAN-only
  [admin page](../usage/admin.md) lets you roll back to an older, known-good
  generation from any machine on your network — the touchscreen itself stays
  read-only. (Automatic rollback on a failed boot isn't available yet — it
  needs boot-counting support that U-Boot doesn't provide and that NixOS is
  still testing.)
- **A first-class Home Assistant citizen.** The panel doesn't just *show* Home
  Assistant — a native integration (installable
  [via HACS](../usage/integration.md)) reports it back as a device with its own
  controls and sensors (display, brightness, zoom, screenshots, CPU,
  temperature and more).
