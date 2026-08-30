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

Install the **Dashboard Assistant** integration
([via HACS](integration.md)) and Home Assistant discovers the device over mDNS
as a single device and pairs itself. A device that has not been added yet hands
over its API token automatically, so there is nothing to type. From there you
can:

- Turn the **display** on/off and set **brightness**.
- Adjust **zoom** and flip **dark mode**.
- **Rotate** the display to 0, 90, 180 or 270°.
- Take a **screenshot** of the current view on demand.
- Switch the active **page**, or edit the list of dashboard URLs.
- Turn the **Sendspin player** on or off — see [Multi-room audio](audio.md).
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

If an update or configuration change misbehaves, open the
[admin page](admin.md) at `http://<device-ip>:8099/` from another machine on the
network and pick an older, known-good generation to boot into. There is no
recovery option on the tablet itself: the screen is read-only so that nobody
walking past it can roll the device back or reset it.

!!! note "Automatic rollback isn't available yet"
    Booting into the previous generation *automatically* after a failed boot
    relies on boot-counting support. The images use **U-Boot**, which doesn't
    provide it, and the NixOS support is still in testing — so today recovery is
    manual, using the admin page. This may change as the targets mature.
