---
icon: material/usb-flash-drive
---

# Live Installer & First-Boot Setup

## Install from a USB stick

When the target's storage is soldered-down eMMC — or you simply have no reader
for it — you can't [flash the disk image](../flash/flash.md) directly. The
**installer ISO** covers that case: flash the small ISO to any spare USB stick,
boot the machine from it, and it installs the full system onto the internal disk.

Grab the installer ISO from the
[GitHub releases page](https://github.com/ajfriesen/dashboard-assistant/releases/latest)
and write it to a USB stick like any bootable image:

```bash
sudo dd if=dashboard-assistant-*-x86_64.iso of=/dev/sdX bs=4M oflag=sync conv=fsync status=progress
```

Boot the target from that stick. On its console the installer:

- lists the machine's internal disks (removable media, USB-attached disks and
  the boot stick itself are filtered out) and asks you to **choose which one to
  erase** — nothing is preselected, and you confirm by typing the disk name back.
  The USB never wipes a machine on its own, so it's safe to keep around;
- partitions and formats the chosen disk from the same declarative layout the
  disk image uses, copies the system onto it, and installs the bootloader —
  entirely offline (everything ships inside the ISO);
- powers the machine off. Remove the USB stick and power it back on to boot the
  installed system, which comes up on the waiting screen below.

!!! danger "The disk you pick is erased"
    Everything on the selected disk is destroyed. Read the disk name, size and
    model the installer prints, and only confirm the one you mean to wipe.

!!! note "Needs a keyboard and screen"
    Because you choose the target at the console, plug in a display and keyboard
    for the install. Once installed, the kiosk needs neither.

## First-Boot Setup

After the device boots the installed system (whether you installed from a USB
stick or [flashed the image](../flash/flash.md) directly) for the first time, it
comes up **unprovisioned** and shows a waiting screen. The device is
configured entirely from a [seed file](../flash/seed.md) — there is no on-screen
setup wizard, so nobody standing at the panel can point it at a different Home
Assistant instance.

## Provision with a seed file

Create a `dashboard-assistant.yaml` describing what the device needs — Wi-Fi,
the Home Assistant URL, an access token, dashboard pages, and optionally a
preset integration token — and hand it to the device on a USB stick or on the
boot partition. The device applies it on first boot and goes straight to your
dashboard.

See [Seed File](../flash/seed.md) for the full schema and the two ways to apply
it, and [Create Home Assistant User](../flash/home-assistant-setup.md) for how to
make a dedicated kiosk user and generate the access token.

## The on-device panel

Once running, a ⚙ **Config** button on the kiosk opens a small local admin panel
(served on `localhost`, reachable only from the device screen). It is read-only
with respect to provisioning — it does **not** let anyone reconfigure where the
kiosk points. It offers two tabs:

- **Info** — device identity and network details (hostname, IP, MAC, model,
  serial, version, device ID, Home Assistant URL) plus the integration URL and
  API token to paste into Home Assistant.
- **Recovery** — boot an earlier system generation if an update misbehaved.

## Home Assistant integration

To have the panel appear back inside Home Assistant as a device with its own
controls and sensors, install the first-party **Dashboard Assistant** integration
(via HACS). Home Assistant discovers the device over mDNS; pair it with the API
token shown on the on-device Config → Info panel (or preset one in the seed
file's `api_token`). See the
[Home Assistant integration](../about/features.md#home-assistant-integration)
reference for the full list of entities it exposes.
