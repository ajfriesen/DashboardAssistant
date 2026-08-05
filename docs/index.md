---
icon: lucide/rocket
hide:
  - navigation
  - toc
---

<section class="da-hero" markdown>

<div class="da-hero__text" markdown>

<span class="da-hero__eyebrow">Home Assistant kiosk OS</span>

# Turn any panel into an <span class="da-accent">unbreakable</span> Home Assistant dashboard {: .da-hero__title }

<p class="da-hero__lead">
A declarative kiosk OS built on NixOS. Flash it, point it at your Home
Assistant, and get a self-contained wall dashboard that integrates back into HA
through a native custom integration — installable via HACS, no MQTT broker
required.
</p>

<div class="da-hero__cta" markdown>
[Flash it&nbsp;→](flash/flash.md){ .da-btn .da-btn--primary }
[See it in action](in-action.md){ .da-btn .da-btn--ghost }
</div>

</div>

<!--
  Tablet mockup. The screen crossfades through the <img> slides below — swap
  these for your own screenshots any time. The crossfade is tuned for THREE
  slides; if you add/remove images, update `--da-slides` and the `:nth-child`
  delays in docs/stylesheets/extra.css.
-->
<div class="da-tablet">
  <div class="da-tablet__screen">
    <img class="da-slide" src="img/home-assistant.jpg" alt="A Home Assistant overview running full-screen on the panel">
    <img class="da-slide" src="img/shopping-list.jpg" alt="A shopping-list dashboard on the panel">
    <img class="da-slide" src="img/website.jpg" alt="An arbitrary web dashboard on the panel">
  </div>
</div>

</section>

## Why Dashboard Assistant OS {: .da-section-title }

<p class="da-section-lead">Built to be flashed once and forgotten.</p>

<div class="da-cards" markdown>

<div class="da-card" markdown>
<div class="da-card__icon">⚡</div>
### Easy flash & install
No Linux knowledge needed. Flash the image, drop in a small seed file, and boot
straight into your dashboard.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">🏠</div>
### Native HA integration
A first-party integration (via HACS) exposes the device as entities you can
automate — no MQTT broker required.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">🛡️</div>
### Unbreakable via NixOS
A bad update boots into the last working generation, with an on-screen recovery
picker as backup.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">🔌</div>
### Broad hardware support
x86_64 today; Raspberry Pi and other aarch64 boards planned.
</div>

</div>

## What it does {: .da-section-title }

<p class="da-section-lead">A full wall panel you drive from Home Assistant.</p>

<div class="da-cards" markdown>

<div class="da-card" markdown>
<div class="da-card__icon">🖥️</div>
### The kiosk
Full-screen Chromium locked to your dashboards. Configure multiple URLs and
cycle between them, wake the display by touch, and type with the on-screen
keyboard on touch-only devices.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">🎛️</div>
### Control from HA
Display on/off, brightness, zoom, dark mode, rotation, screenshot, reboot /
shutdown and over-the-air updates — all as native entities.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">📊</div>
### Monitor everything
Battery, temperature, CPU, memory and storage surfaced back to Home Assistant
as sensors.
</div>

</div>

<div class="da-hero__cta" markdown>
[Get started&nbsp;→](flash/flash.md){ .da-btn .da-btn--primary }
[Read the features](about/features.md){ .da-btn .da-btn--ghost }
</div>
