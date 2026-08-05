---
icon: lucide/scale
---

# How It Compares

There are plenty of ways to get a dashboard on the wall. Here's how Dashboard
Assistant stacks up against the common ones — the honest version, including where
it's still catching up.

| | **Dashboard Assistant** | Android tablet + kiosk app | DIY Raspberry Pi kiosk | Dedicated HA panel |
|---|---|---|---|---|
| **Setup** | Flash an image, drop a seed file — no Linux needed | Install a kiosk app, tweak Android settings | Build it yourself: browser, autostart, disable sleep | Buy it, plug it in |
| **Updates** | One tap from Home Assistant, atomic | Manual, app- and vendor-dependent | Manual — you run the commands | Vendor firmware, if any |
| **Security patches over time** | Ongoing OS updates | Usually dry up after 1–2 years | Only if you keep patching by hand | Depends on the vendor |
| **Recovery from a bad update** | Roll back on the device's touchscreen | Reinstall / factory reset | Re-image or troubleshoot | Vendor-dependent |
| **Home Assistant integration** | Native — appears as a device with controls and sensors | Partial, via the app | DIY (scripts / MQTT) | Varies |
| **Runs on hardware you own** | Yes — mini-PC, x86, SBC (Raspberry Pi in progress) | Uses tablets you have | Yes | No — specific hardware |
| **Tamper-resistant** | Yes — seed-only setup, read-only on-device config | No — full Android underneath | Up to you | Usually |
| **Cost** | Spare or cheap hardware, no panel to buy | Tablet (+ possible app licence) | Board + your time | Dedicated panel $$ |

!!! note "Where it's honest"
    Dashboard Assistant is under active development. **x86_64** is the tested
    target today; **Raspberry Pi** and other aarch64 boards are a work in
    progress. Rollback after a bad update is **manual** (a picker on the device's
    touchscreen) — automatic rollback on a failed boot isn't available yet. See
    [Hardware Support](hardware-support.md) and the
    [Stack for Nerds](stack-for-nerds.md) for the full picture.

## The short version

- **vs an Android tablet + Fully Kiosk / WallPanel** — no Android to age out and
  stop getting security updates, no app settings to fight, and the panel is a
  first-class Home Assistant device rather than a browser with a few sensors
  bolted on.
- **vs a DIY Raspberry Pi kiosk** — you skip the evening of wiring up a kiosk
  browser, autostart and sleep settings, and you don't own the update treadmill
  afterwards.
- **vs a dedicated panel** — reuse hardware you already have instead of buying
  locked-down kit, and get updates you actually control.

Ready to try it? Head to [Get started](flash/flash.md).
