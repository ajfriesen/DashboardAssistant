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
([from the Marketplace](../getting-started.md#integration)) and Home Assistant discovers the device over mDNS
as a single device and pairs itself. A device that has not been added yet hands
over its API token automatically, so there is nothing to type. From there you
can:

- Turn the **display** on/off and set **brightness**.
- Adjust **zoom** and flip **dark mode**.
- **Rotate** the display to 0, 90, 180 or 270°.
- Show the **screen saver** now, pick its style, or set how long the panel
  waits without a touch before it starts (10 minutes by default; 0 turns it
  off). A tap dismisses it.
- Take a **screenshot** of the current view on demand.
- Switch the active **page**, and choose the dashboard and pages (any website)
  under **Configure** on the integration card.
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

If an update misbehaves, press the device's **Roll back** button in Home
Assistant to boot the previous generation. There is no recovery option on the
device's screen: it is read-only so that nobody walking past it can roll the
device back or reset it. [Recovery](recovery.md) covers the rest.

!!! note "Automatic rollback isn't available yet"
    Booting into the previous generation *automatically* after a failed boot
    relies on boot-counting support, which comes from **systemd-boot**. Every
    image boots through it now, so the mechanism is available — switching it on
    is tracked separately. Until then recovery is manual, from Home
    Assistant.
