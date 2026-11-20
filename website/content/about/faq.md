# FAQ

Frequently asked questions:

## Does it support Android?

No.

## Can I SSH into the device?

No. Dashboard Assistant is an appliance, not another PC you have to take care
of. The image has no SSH server at all; everything you need to do with the
device, you do from Home Assistant.

## Can I play music?

Yes. Every device ships with a [Sendspin](https://www.sendspin-audio.com/)
player, so it shows up in Music Assistant as a speaker you can play to, on its
own or in sync with your other speakers. See
[Multi-room audio](use-cases.md#audio).

## Why another kiosk OS?

Most "wall tablet" setups are a stack of manual tweaks: disable the lock screen,
side-load a kiosk browser, fight the OS updater, and hope none of it breaks after
a reboot. Dashboard Assistant takes the opposite approach:

- **Declarative and reproducible.** The whole system is defined in NixOS. The
  image you flash is the system you run — there is no hand-configuration to drift.
- **Recoverable by design.** Updates are atomic and every version is kept as a
  NixOS generation. If one misbehaves, the **Roll back** button in Home
  Assistant boots the previous one — the touchscreen itself stays read-only.
  See [Recovery](use-cases.md#recovery). (Automatic rollback on a failed boot isn't switched on yet,
  though every image now boots through systemd-boot, which provides it.)
- **A first-class Home Assistant citizen.** The panel doesn't just *show* Home
  Assistant — a native integration (installable
  [from the Marketplace](../getting-started.md#integration)) reports it back as a device with its own
  controls and sensors (display, brightness, zoom, screenshots, CPU,
  temperature and more).

## Why does Dashboard Assistant exist? { #why }

I wanted Home Assistant on the wall. What I *didn't* want was to babysit the
thing that showed it. Every option I tried came with a catch — so I built the
one I wished existed.

### The problem with the usual options

- **Android tablets age out fast.** Most cheap tablets stop getting updates
  within a year or two. The security patches dry up and the browser falls
  behind — and now you've got an unpatched screen wired straight into your smart
  home.
- **The DIY route needs real Linux skills.** Rolling your own kiosk means
  disabling the lock screen, autostarting a browser in the right mode, stopping
  the display from sleeping, and keeping all of it working after every reboot.
  That's a lot to ask of someone who just wants a dashboard.
- **You're on the hook for every update.** With a hand-built setup, updating
  means logging in and running commands and hoping nothing breaks. Skip it a few
  times and the device quietly rots.
- **One bad update can take the whole thing down.** When an update goes wrong on
  a DIY box, there's often no easy way back — just a dead screen and an evening
  of troubleshooting.

### What I wanted instead

- **A turnkey solution.** Flash it, point it at Home Assistant, done. No
  terminal, no tinkering, nothing to configure by hand.
- **Updates that come to me.** New versions show up right inside Home Assistant —
  one tap to install, no logging in, nothing to re-flash.
- **A real part of Home Assistant.** The panel should report back into HA as a
  device I can see, control and automate — not a black box hanging on the wall.
- **Something an update can't brick.** If a new version misbehaves, I want to
  roll back on the device itself and carry on.
- **Reuse of hardware I already have.** A spare mini-PC, an old single-board
  computer, whatever's in the drawer — not a locked-down, proprietary panel.
- **Set-and-forget reliability.** It should ride out power cuts and reboots and
  just come back up on its own, unattended, for years.
- **Repeatable by design.** Flashing a second or third panel should give me the
  exact same result every time, with no fiddly per-device setup.

That's Dashboard Assistant: a screen you flash once and forget, that stays
current, and that lives inside Home Assistant like it belongs there.

Curious how it all works? Have a look at the [Stack for Nerds](stack-for-nerds.md).
