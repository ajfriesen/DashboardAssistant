---
icon: lucide/sun-dim
---

# Monitor dimming

Real dimming depends on what your display supports. Dashboard Assistant detects
the best available method once per session and uses one of three:

1. **Backlight.** Internal panels that expose `/sys/class/backlight` (an eDP
   laptop or tablet screen) are dimmed at the hardware backlight. This is the
   ideal case and gives true brightness control.
2. **DDC/CI.** External monitors that speak DDC/CI are dimmed over that channel
   (`ddcutil`). Your monitor has to support DDC/CI and have it enabled in its
   on-screen menu, and it needs to be reachable over the video connection.
3. **Software gamma.** If neither of the above is available, a software fallback
   dims the rendered output instead of the physical backlight. It works on any
   display or VM, but the panel itself keeps drawing power at full backlight, so
   it never goes fully dark.

By default the method is picked automatically (backlight, then DDC/CI, then
software). If your monitor supports hardware dimming but isn't detected, check
that DDC/CI is turned on in the display's settings.
