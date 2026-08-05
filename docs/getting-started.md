---
icon: lucide/rocket
hide:
  - toc
---

# Getting Started

Going from a spare device to a Home Assistant panel on the wall takes three
steps. Follow them in order and you'll be up and running without a terminal or a
weekend of tinkering.

## 1. Flash the image

Write one image to an SD card or SSD, pop it into your tablet, mini-PC or
single-board computer, and power on. The [Flash](flash/flash.md) guide walks
through downloading the latest image and writing it to your target disk, plus
[seeding](flash/seed.md) the device so it knows which Home Assistant to show.

[Flash the image&nbsp;→](flash/flash.md){ .da-btn .da-btn--primary }

## 2. Boot and pair

On first boot the device comes up as a Home Assistant dashboard. Install the
**Dashboard Assistant** integration (via HACS) and Home Assistant discovers the
panel over mDNS, so it shows up as a device you can see, control and automate.

## 3. Use it day to day

Once it's on the wall, you control it in two places: on the screen itself and
from Home Assistant. The [Usage](usage/usage.md) guide covers the on-device
controls, the integration's entities, one-tap OS updates and rolling back if an
update ever misbehaves. If something looks off, [Diagnostics](usage/diagnostics.md)
helps you track it down.

[Read the usage guide&nbsp;→](usage/usage.md){ .da-btn .da-btn--ghost }

## Need a hand?

Check [Hardware Support](hardware-support/index.md) for the current state of your
board, or ask on
[GitHub discussions](https://github.com/ajfriesen/DashboardAssistant/discussions).
