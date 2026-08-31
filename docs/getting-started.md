---
icon: lucide/rocket
hide:
  - toc
---

# Getting Started

Going from a spare device to a working Home Assistant dashboard takes four
steps. Follow them in order and you'll be up and running without a terminal or a
weekend of tinkering.

## 1. Flash the image

Write one image to an SD card or SSD, pop it into your tablet, mini-PC or
single-board computer, and power on. The [Flash](flash/flash.md) guide walks
through downloading the latest image and writing it to your target disk.

[Flash the image&nbsp;→](flash/flash.md){ .da-btn .da-btn--primary }

## 2. Get it on your network

On Ethernet there is nothing to do. On Wi-Fi, the display shows a QR code: scan it
with your phone, and a page opens where you enter your network name and password.
See [Wi-Fi setup](flash/wifi.md). If you are setting up several devices, a
[seed file](flash/seed.md) does this ahead of time instead.

## 3. Pair with Home Assistant

Once online, the device shows an "add me" screen. Install the **Dashboard
Assistant** integration — a HACS custom repository, added in a couple of
clicks — and Home Assistant discovers the panel over mDNS, so it shows up as a
device you can see, control and automate. There is no token to type. The
[Connect to Home Assistant](usage/integration.md) guide walks through it.

[Install the integration&nbsp;→](usage/integration.md){ .da-btn .da-btn--primary }

## 4. Use it day to day

Once it's up, you control it in two places: on the screen itself and
from Home Assistant. The [Usage](usage/usage.md) guide covers the on-device
controls, the integration's entities, one-tap OS updates and rolling back if an
update ever misbehaves. If something looks off, the
[admin page](usage/admin.md) is where you roll back or reset the device.

[Read the usage guide&nbsp;→](usage/usage.md){ .da-btn .da-btn--ghost }

## Need a hand?

Check [Hardware Support](hardware-support/index.md) for the current state of your
board, or ask on
[GitHub discussions](https://github.com/ajfriesen/DashboardAssistant/discussions).
