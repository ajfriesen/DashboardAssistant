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
install. Every version is kept as a NixOS generation, so an update that goes
wrong is undone rather than repaired — automatically if the device cannot come
back up, and by hand from the admin page otherwise.

## Automatic rollback

An update gets three attempts to come back up. If the device is not reachable on
your network after the third, it returns to the version it was running before,
on its own and with nobody present.

It then writes that release off and stops offering it until a newer one ships —
and it keeps a list, not just the last one, so a device that has turned down two
releases does not end up alternating between them. The release is still there in
the version picker if you want to try it again deliberately; succeeding takes it
off the list. The device reports the rollback for Home Assistant to surface, so
you can find out it happened rather than noticing the version number went
backwards.

"Came back up" means the device is reachable, and nothing more. A blank screen
or a Home Assistant that happens to be down does not make the boot a bad one:
neither is the update's fault, and rolling back for them would undo a release
that was fine.

A freshly flashed device has nothing to roll back to. If it never comes up, the
fix is to flash it again — automatic rollback protects updates, not the first
boot.

## Recovery

If an update or configuration change misbehaves in a way that leaves the device
*reachable* — a dashboard that will not load, a setting that broke the screen —
nothing rolls back on its own, because from the outside the device is fine. Open
the [admin page](admin.md) at `http://<device-ip>:8099/` from another machine on
the network and pick an older, known-good generation to boot into. There is no
recovery option on the device itself: the screen is read-only so that nobody
walking past it can roll the device back or reset it.
