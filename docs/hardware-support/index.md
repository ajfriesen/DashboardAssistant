---
icon: lucide/cpu
hide:
  - toc
---

# Hardware Support

Dashboard Assistant ships flashable disk images for `x86_64` and Raspberry Pi 4
and 5 today, plus a best-effort second x86_64 image on a newer kernel for hardware
the supported one cannot bring up.
The table below tracks the current state, and each target has its own page with the details.

| Target | Status | Notes |
|---|---|---|
| x86_64 (mini-PC, laptop, tablet) | :lucide-circle-check: Supported | Primary, tested target. Ships as a flashable disk image. |
| Raspberry Pi 5 (aarch64) | :lucide-circle-check: Supported | Tested and working. Ships as an SD-card image. |
| Raspberry Pi 4 (aarch64) | :lucide-circle-check: Supported | Tested and working. Ships as an SD-card image. |
| x86_64 — unstable channel | :lucide-flask-conical: Best-effort | Newer mainline kernel, Mesa and firmware, for hardware too new for the supported image. Not tested before release; may not boot. |

## x86_64

Most mini-PCs, old laptops and x86 tablets qualify. The image bundles broad
hardware and firmware support rather than being trimmed to one board, so the same
file boots across a wide range of devices. If a very recent machine shows a black
screen, no Wi-Fi or no touch, there is a
[best-effort image on a newer kernel](x86.md#hardware-too-new-for-the-supported-image)
to try.

[x86_64 details&nbsp;→](x86.md){ .da-btn .da-btn--primary }

## Raspberry Pi

Raspberry Pi 4 and Raspberry Pi 5 are both tested and working, each shipping as a
separate SD-card image.

[Raspberry Pi details&nbsp;→](raspberry-pi.md){ .da-btn .da-btn--primary }

## Touchscreens

A touchscreen is recommended if you are mounting the screen. The official Raspberry Pi touch
displays are tested and working.

[Tested touchscreens&nbsp;→](touchscreens.md){ .da-btn .da-btn--ghost }

## Monitor dimming

Real dimming depends on what your display supports. Dashboard Assistant picks the
best of three methods automatically: hardware backlight, DDC/CI, or a software
fallback.

[How dimming works&nbsp;→](dimming.md){ .da-btn .da-btn--ghost }
