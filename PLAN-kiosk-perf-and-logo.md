# Plan: kiosk performance fixes + sponsor logo

Findings from the 2026-09-14 investigation of `dashboard-assistant-d7bbb4`
(192.168.178.212). Two unrelated causes of dashboard lag, plus a branding
change that happens to subsume one of the fixes.

Nothing here is implemented yet. Deploy path for all of it:

    just deploy-rpi5-dev root@dashboard-assistant-d7bbb4.local

---

## Background: what was actually wrong

**Not thermal.** 62.3 °C against an 80 °C soft-throttle threshold, CPU 94.5%
idle, no throttle flags. The load average of ~4.3 was misleading.

| Cause | Evidence | Status |
|---|---|---|
| `sendspin-player` mDNS re-discovery loop | 398,730 rediscoveries of the *same* server in 28 h; leaked to 2.8 GB RSS (70% of RAM); 145 MB available; journald wrote 2.87 GB to the SD card | Mitigated by restart on 2026-09-14, **will recur** |
| waybar heartbeat animating `font-size` | 41,148 s CPU = 45.7% of one core over 25 h; 620 s in the `[pango] fontcon` thread alone | Open |

The restart dropped sendspin from 2,865 MB to 17 MB and took available memory
from 122 MB to 2,823 MB. The discovery rate fell from 5.6/s to 0.33/s — slower,
but still ~28k/day for a server it is already connected to. Expect the leak to
re-exhaust RAM in roughly 1–2 days.

---

## Work item 1 — stop the sendspin leak

### 1a. Pin the server, bypassing mDNS discovery

The module already has the escape hatch; it is just unset. `modules/core/sendspin.nix:97`
defines `server`, and `:63` already threads it into the launcher as
`--server`, so this is config only — no code change.

Set in the host config (wherever this device's `dashboardAssistant.sendspin`
block lives):

    dashboardAssistant.sendspin.server = "ws://192.168.178.83:8927";

`192.168.178.83:8927` is the Music Assistant / sendspin server it was
rediscovering 398k times.

**Trade-off to decide:** pinning means the device no longer follows the server
if its IP changes. Options, pick one:
  - Pin the IP (simplest, breaks on DHCP change)
  - Give the server a DHCP reservation first, then pin
  - Pin a hostname (`ws://musicassistant.local:8927`) — still mDNS, but
    resolution only, not the broken browse loop

### 1b. Cap the blast radius

`modules/core/sendspin.nix:204` `serviceConfig` currently has `Restart = "on-failure"`
and no memory bound, so a leak can consume the whole box. Add:

    MemoryMax = "512M";
    MemoryAccounting = true;

With `Restart = "on-failure"` already set (`:208`), systemd will OOM-kill and
restart it instead of letting it starve Chromium. Verify 512M is comfortably
above steady-state: the freshly restarted process sat at **17 MB**, so this is
~30x headroom. If bursty playback needs more, 256M is likely still fine.

Consider also `Restart = "always"` so an OOM kill (not strictly a "failure"
in all systemd versions) reliably restarts.

### 1c. Silence the log flood

Even pinned, the player logs at a rate that filled 99.6% of the journal
(398,442 of 400,115 lines this boot). Independently of 1a, add a rate limit so
no future upstream chattiness can grind the SD card again:

    # in serviceConfig
    LogRateLimitIntervalSec = 30;
    LogRateLimitBurst = 100;

### 1d. Report upstream

Against `sendspin-player` 1.8.2, two defects:
  - mDNS discovery re-announces an already-connected server without
    deduplication, and retains per-discovery state (2.8 GB of anonymous heap
    over 28 h, 284k major faults thrashing it through zram)
  - `Discovered server: ...` is logged at info level on every hit; should be
    debug, or logged once per newly-seen server

Also observed and probably downstream of the same loop: repeated
`Burst sample N/8 timed out` — these stopped after restart.

---

## Work item 2 — the sponsor button: logo instead of the beating heart

These are one change, because replacing the glyph with an image removes the
animation that was burning the CPU.

### Why the current one is expensive

`modules/core/kiosk.nix:943-955`:

    #custom-sponsor { animation: heartbeat 1.2s ease-in-out infinite; }
    @keyframes heartbeat { 0% { font-size: 18px; } 15% { font-size: 25px; } ... }

Animating `font-size` forces a full Pango reshape and re-rasterization of the
glyph every frame — 60 text relayouts per second, forever. The in-code comment
correctly notes GTK3 has no `transform`, but `font-size` is the worst available
fallback. `opacity` and `color` animate without touching text layout.

The animation only runs while the display is on (wlroots stops frame callbacks
when the output is DPMS-off, halting GTK's frame clock) — which is exactly why
it correlated with the lag you noticed while using the dashboard.

### 2a. Produce a bar-suitable logo asset

Neither existing asset can be dropped in as-is.

`docs/brand/favicon.svg` is the right shape (40x40 square) but **its `plate`
and `tile` rects carry no `fill` — they are styled by classes defined in
`brand/colors.css`**. Loaded by librsvg with no stylesheet, they render black.
`docs/brand/mark-wide.svg` *does* have inline fills but is a wide 64x40 lockup,
wrong for a square bar button.

So: create a **self-contained square mark** with fills inlined, resolving the
class references against `docs/brand/colors.css`:
  - `.plate` -> `#23211D` (`--da-text`, matching how `mark-wide.svg` fills its plate)
  - `.tile`  -> `#FFFFFF`
  - third rect is already `#E8A33D` (`--da-amber`)

Note the bar background is `#101520` (`kiosk.nix:917`), which is very close to
the plate's `#23211D`. Decide whether the plate should be dropped entirely
(transparent, letting the module's own `#1e2633` pill show) or kept for contrast.
Dropping it will probably look better against the existing button styling.

**Format decision — resolve before writing CSS:** GTK3 loads SVG only if the
librsvg gdk-pixbuf loader is in waybar's wrapper environment, which is not
guaranteed in nixpkgs. Check first; if absent, either add librsvg to the
wrapper or ship a pre-rendered PNG. A PNG at 2x the display size is the low-risk
path.

**Where it lives:** the brand assets currently exist only under `docs/brand/`
and `site/brand/` (byte-identical duplicates) and are consumed by nothing in
`modules/`. Add the kiosk asset into the Nix store, e.g. a `sponsorLogo` binding
next to the other `pkgs.writeText` derivations in `kiosk.nix`, so the CSS can
reference a store path. Avoid making it a third hand-maintained copy of the
brand mark — either derive it from `docs/brand/` at build time or leave a
comment pointing at the source of truth.

### 2b. Rework the CSS

Replace `kiosk.nix:943-955` with a background-image button:

    #custom-sponsor {
      padding: 0 20px;
      min-width: 32px;
      min-height: 32px;
      background-image: url("${sponsorLogo}");
      background-repeat: no-repeat;
      background-position: center;
      background-size: 24px 24px;
    }

Sizing: the bar is 50px tall (`kiosk.nix` waybar config `"height": 50`), and
`waybarStyle`'s `min-height` note at `:797` warns the OSK position is keyed to
the bar height — **keep the bar at 50px** so the on-screen keyboard doesn't
shift. A 24-28px mark inside a 50px bar leaves sensible padding.

The existing `min-width: 32px` was sized for the largest beat frame; with a
fixed-size image it just becomes the button box, so keep it (it still stops
Prev/Next shifting).

Delete the `@keyframes heartbeat` block entirely.

**If you still want a pulse:** animate `opacity` (0.55 -> 1.0), never
`font-size`. Two notes: with a background-image, `font-size` would no longer
even change the visual, but would still burn the same CPU; and any infinite
animation keeps GTK's frame clock at 60fps, so an opacity pulse costs a few
percent of a core rather than ~0. A static mark is free.

### 2c. Update both bar configs

The `❤` glyph appears in two places and both must change:
  - `modules/core/kiosk.nix:876-880` — `waybarConfig`, landscape, labelled
  - `modules/core/kiosk.nix:906` — `waybarConfigPortrait`, icon-only

They share the single stylesheet `waybarStyle` (`:911`), so the CSS above covers
both. With a background-image the `"format"` should become a single space
(`" "`) rather than empty — an empty label can collapse the widget. Leave
`on-click` and `tooltip` untouched.

The comment at `:890-894` instructing that the module set be kept in sync
between the two configs still applies.

---

## Verification

After `just deploy-rpi5-dev`:

1. **waybar CPU — the real test.** Must be measured with the **display on**;
   it reads 0% when DPMS-off regardless of the bug.

       ssh root@192.168.178.212 'WB=$(pgrep -f waybar-wrapped|head -1); \
         a=$(awk "{print \$14+\$15}" /proc/$WB/stat); sleep 15; \
         b=$(awk "{print \$14+\$15}" /proc/$WB/stat); \
         echo "$(( (b-a)*100/100/15 ))% of one core"'

   Expect ~0% static / low single digits with an opacity pulse, vs 45.7% before.
   Confirm the screen is on first: `/var/lib/dashboard-assistant/display-off`
   must be **absent**.

2. **Pango thread** should stop accumulating:

       for t in /proc/$WB/task/*/; do echo "$(cat $t/comm) $(awk '{print $14+$15}' $t/stat)"; done

3. **sendspin memory**, after 24h and again after 72h — should stay flat near
   17 MB, not climb:

       systemctl show sendspin-player -p MemoryCurrent

4. **Journal flood gone:**

       journalctl -b | grep -c "Discovered server"

5. **Logo renders** — if the SVG loader is missing, the button will be blank
   rather than erroring. Check it visually, and check waybar's stderr for
   gdk-pixbuf loader warnings.

6. **Portrait rotation** still lays out correctly (the icon-only bar is the
   tighter constraint).

---

## Rollback

All changes are in two Nix modules, so `git revert` + redeploy restores the
previous generation. On the device itself, `nixos-rebuild --rollback` or picking
the prior generation at boot works if a deploy leaves the kiosk unusable.

---

## Suggested sequencing

1. **1a + 1b together** — highest value, config-only, stops the recurrence.
   Do this first; the leak is on a ~1-2 day clock.
2. **1c** — one-line hardening, fold into the same change.
3. **2a** — the asset decisions (plate or no plate, SVG vs PNG) are the only
   part needing real judgement; resolve before touching CSS.
4. **2b + 2c** — mechanical once 2a is settled.
5. **1d** — upstream report, independent of everything else.

Items 1 and 2 are independent and can ship as separate commits.
