# Sway, not Cage, as the kiosk compositor

The kiosk runs Sway with a single fullscreen Chromium, even though Cage is the usual choice for a single-app Wayland kiosk. Cage lacks three things the kiosk needs: wlr-layer-shell for the status bar, floating and no-focus window rules for the on-screen keyboard, and output power control for turning the display off (`modules/core/kiosk.nix`).
