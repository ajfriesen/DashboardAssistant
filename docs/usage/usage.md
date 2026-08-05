# Usage

Once provisioned, the device boots straight into your Home Assistant dashboard
and stays there. Day-to-day you control it in two places: **on the screen
itself** and **from Home Assistant** through the native integration.

## On the device

A small bar gives you touch controls without leaving the kiosk:

- **Next / Previous page** — cycle through your configured dashboard URLs.
- **⌨ Keyboard** — toggle the on-screen keyboard for text fields on touch-only
  devices *(experimental)*.
- **Touch to wake** — tapping the screen wakes the display when it has slept.

## From Home Assistant

Install the **Dashboard Assistant** integration (via HACS) and Home Assistant
discovers the device over mDNS as a single device — enter the API token shown on
the device's Config → Info screen to pair. From there you can:

- Turn the **display** on/off and set **brightness**.
- Adjust **zoom** and flip **dark mode**.
- **Rotate** the display to 0, 90, 180 or 270°.
- Take a **screenshot** of the current view on demand.
- Switch the active **page**, or edit the list of dashboard URLs.
- **Reboot** or **shut down** the device.
- Install an **OS update** when one is available.

It also reports sensors — CPU, memory, storage, temperature, uptime, battery
(when present) and idle time — so you can build automations (for example, dim
the panel at night or wake it on motion).

See the [Home Assistant integration](../about/features.md#home-assistant-integration)
reference for the complete entity list.

## Updates

OS updates are atomic and surface in Home Assistant as an `update` entity: it
compares the installed version against the latest release and offers a one-tap
install. Every version is kept as a NixOS generation, so if an update misbehaves
you can roll back from the device (see below).

## Recovery

If an update or configuration change misbehaves, an on-screen picker lets you
choose an older, known-good generation to boot into — recovery is done by hand,
right on the device's touchscreen.

!!! note "Automatic rollback isn't available yet"
    Booting into the previous generation *automatically* after a failed boot
    relies on boot-counting support. The images use **U-Boot**, which doesn't
    provide it, and the NixOS support is still in testing — so today recovery is
    manual, using the picker above. This may change as the targets mature.
