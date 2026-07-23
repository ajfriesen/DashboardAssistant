---
icon: material/usb-flash-drive
---

# First-Boot Setup

After you [flash the image](../flash/flash.md) and boot the device for the first
time, it comes up **unprovisioned** and shows a waiting screen. The device is
configured entirely from a [seed file](../flash/seed.md) — there is no on-screen
setup wizard, so nobody standing at the panel can point it at a different Home
Assistant instance or broker.

## Provision with a seed file

Create a `dashboard-assistant.yaml` describing what the device needs — Wi-Fi,
the Home Assistant URL, an access token, MQTT and dashboard pages — and hand it
to the device on a USB stick or on the boot partition. The device applies it on
first boot and goes straight to your dashboard.

See [Seed File](../flash/seed.md) for the full schema and the two ways to apply
it, and [Create Home Assistant User](../flash/home-assistant-setup.md) for how to
make a dedicated kiosk user and generate the access token.

## The on-device panel

Once running, a ⚙ **Config** button on the kiosk opens a small local admin panel
(served on `localhost`, reachable only from the device screen). It is read-only
with respect to provisioning — it does **not** let anyone reconfigure where the
kiosk points. It offers two tabs:

- **Info** — device identity and network details (hostname, IP, MAC, model,
  serial, version, MQTT node ID, Home Assistant URL).
- **Recovery** — boot an earlier system generation if an update misbehaved.

## MQTT integration

To have the panel appear back inside Home Assistant as a device with its own
controls and sensors, include MQTT broker settings in the seed file. See the
[Home Assistant integration](../about/features.md#home-assistant-integration)
reference for the full list of entities it exposes.
