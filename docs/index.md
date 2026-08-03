---
icon: lucide/rocket
---

# Dashboard Assistant OS

A declarative, **unbreakable Home Assistant kiosk OS** built on NixOS. Flash it,
point it at your Home Assistant, and get a self-contained wall dashboard that
integrates back into HA through a native custom integration (installable via
HACS).

<figure markdown="span">
  ![A tablet on the wall running a Home Assistant dashboard](img/website.jpg){ width="600" }
  <figcaption>A wall tablet booted straight into a Home Assistant dashboard.</figcaption>
</figure>

## Goals

- **Easy flash and install** — no Linux knowledge needed.
- **Integrates natively with Home Assistant** — a first-party integration
  (installable via HACS) exposes the device as entities you can automate; no MQTT
  broker required.
- **Unbreakable system via NixOS** — a bad update boots into the last working
  generation.
- **Broad hardware support** — x86_64 today; Raspberry Pi and other aarch64
  boards planned.

## Features

- Easy install and over-the-air updates (via Home Assistant or the local GUI).
- Configure multiple dashboard URLs and cycle between them.
- Wake the display by touch.
- Control from Home Assistant:
    - display on/off
    - brightness
    - zoom
    - dark mode
    - rotation
    - screenshot
    - reboot/shutdown
    - update
- Monitor battery, temperature, CPU, memory and storage.
