# About

**Dashboard Assistant OS** turns any spare tablet, mini-PC or single-board
computer into a dedicated Home Assistant wall panel. It is a minimal, declarative
NixOS system that boots straight into a full-screen browser locked to your
dashboard — no desktop, no login screen, nothing to tap through.

## Why another kiosk OS?

Most "wall tablet" setups are a stack of manual tweaks: disable the lock screen,
side-load a kiosk browser, fight the OS updater, and hope none of it breaks after
a reboot. Dashboard Assistant takes the opposite approach:

- **Declarative and reproducible.** The whole system is defined in NixOS. The
  image you flash is the system you run — there is no hand-configuration to drift.
- **Recoverable by design.** Updates are atomic and every version is kept as a
  NixOS generation. If one misbehaves, an on-screen recovery picker lets you roll
  back to an older, known-good generation right on the device's touchscreen.
  (Automatic rollback on a failed boot isn't available yet — it needs
  boot-counting support that U-Boot doesn't provide and that NixOS is still
  testing.)
- **A first-class Home Assistant citizen.** The panel doesn't just *show* Home
  Assistant — a native integration (installable via HACS) reports it back as a
  device with its own controls and sensors (display, brightness, zoom,
  screenshots, CPU, temperature and more).

## Project status

Dashboard Assistant is under active development. x86_64 is the primary, tested
target today; Raspberry Pi and other aarch64 boards are a work in progress. See
[Hardware Support](../hardware-support.md) for the current state.

The project is developed in the open on
[GitHub](https://github.com/ajfriesen/dashboard-assistant) — issues and pull
requests are welcome.
