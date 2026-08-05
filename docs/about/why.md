---
icon: lucide/lightbulb
---

# Why Dashboard Assistant

I wanted Home Assistant on the wall. What I *didn't* want was to babysit the
thing that showed it. Every option I tried came with a catch — so I built the
one I wished existed.

## The problem with the usual options

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

## What I wanted instead

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

Curious how it all works? Have a look at the [Stack for Nerds](../stack-for-nerds.md).
