---
icon: lucide/rocket
hide:
  - toc
---

# Getting Started

Going from a spare device to a working Home Assistant dashboard takes a few steps.
Follow them in order and you'll be up and running without a terminal or a weekend of tinkering.

## 1. Download the image

Get the latest release here:

https://github.com/ajfriesen/DashboardAssistant/releases


## 2. Flash the image

Write one image to an SD card or SSD, pop it into your tablet, mini-PC or
single-board computer, and power on. The [Flash](flash/flash.md) guide walks
through downloading the latest image and writing it to your target disk.

[Flash the image&nbsp;→](flash/flash.md){ .da-btn .da-btn--primary }

## 3. Get it on your network

On Ethernet there is nothing to do.
For Wi-Fi, put your network name and password in a [seed file](flash/seed.md).
A short YAML file on the boot partition or a USB stick.
The device reads it on first boot and joins.
The same file configures every other setting, so it is also how you set up several devices at once.


## 4. Install the DashboardAssistant Integraton

Once online, the device shows an "add me" screen. Install the **DashboardAssistant** integration.
A HACS custom repository, added in a couple of clicks.
Home Assistant discovers the panel over mDNS, so it shows up as a device you can see, control and automate.
The [Connect to Home Assistant](usage/integration.md) guide walks through it.

[Install the integration&nbsp;→](usage/integration.md){ .da-btn .da-btn--primary }

## 5. Use it day to day

Once it's up, you control it in two places: on the screen itself and
from Home Assistant. The [Usage](usage/usage.md) guide covers the on-device
controls, the integration's entities, one-tap OS updates and rolling back if an
update ever misbehaves. If something looks off, the
[admin page](usage/admin.md) is where you roll back or reset the device.

[Read the usage guide&nbsp;→](usage/usage.md){ .da-btn .da-btn--ghost }

