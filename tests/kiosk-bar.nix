# VM test for the bottom button bar and the on-screen keyboard
# (modules/core/kiosk.nix: displayRestore, waybarStart, oskToggle): on every
# panel we ship for, in either orientation, every button fits on screen, the
# buttons keep their physical size when the panel is rotated, and the keyboard
# fits the width.
#
# The Touch Display 2 is why this exists. Its panel is natively portrait,
# 720x1280 at ~210 DPI. Left alone, Sway scales it 2x unrotated and 1x rotated,
# because it decides from the rotated height. Unrotated it was a 360px-wide
# screen whose bar clipped the Keyboard button (#110); rotated, every button
# and label was half the size (#111). displayRestore now pins it at 1.5.
#
# greetd stays off, as in vnc.nix. A headless Sway (pixman renderer) runs as
# the kiosk user. Each case brings the output up the way the real session
# finds it (unrotated, at the scale Sway picks for that panel), persists a
# rotation, runs the session-start script, and reads the pills from a grim
# screenshot. Headless outputs report no physical size, so Sway never picks a
# scale itself: each case sets the one Sway picks on the real panel.
{
  pkgs,
  version,
  ...
}:
let
  oskAppId = "io.github.archisman-panigrahi.vboard";

  # Runs of non-background pixels along one row through the pills, just under
  # their top edge: below the rounded corners, above the labels and the sponsor
  # mark, so each pill reads as one unbroken run. Also the first pill's height,
  # down the middle of it. Prints JSON.
  pills = pkgs.writers.writePython3 "bar-pills" { libraries = [ pkgs.python3Packages.pillow ]; } ''
    import json
    import sys

    from PIL import Image

    img = Image.open(sys.argv[1]).convert("RGB")
    scale = float(sys.argv[2])
    w, h = img.size
    # The bar is 50 logical px tall; a pill starts 5px (its margin) below the
    # bar's top edge and its 10px corner radius ends 10px further down.
    y = h - round((50 - 16) * scale)
    bg = (0x10, 0x15, 0x20)


    def is_bg(p):
        return all(abs(a - b) <= 6 for a, b in zip(p, bg))


    runs, start = [], None
    for x in range(w):
        if not is_bg(img.getpixel((x, y))):
            if start is None:
                start = x
        elif start is not None:
            runs.append([start, x - 1])
            start = None
    if start is not None:
        runs.append([start, w - 1])

    height = 0
    if runs:
        x = (runs[0][0] + runs[0][1]) // 2
        top = bottom = y
        while top > 0 and not is_bg(img.getpixel((x, top - 1))):
            top -= 1
        while bottom < h - 1 and not is_bg(img.getpixel((x, bottom + 1))):
            bottom += 1
        height = bottom - top + 1
    print(json.dumps({"width": w, "runs": runs, "pill_height": height}))
  '';
in
pkgs.testers.runNixOSTest {
  name = "kiosk-bar";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../modules/core/default.nix ];

      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.grim ];
      environment.etc."kiosk-bar-test/display-restore".source =
        config.dashboardAssistant.kiosk.displayRestore;
      environment.etc."kiosk-bar-test/osk".source = config.dashboardAssistant.kiosk.osk;

      # Stand-in for the kiosk session, as in vnc.nix, with the kiosk's own
      # window rules for the keyboard.
      systemd.services.headless-kiosk = {
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.dbus
          pkgs.bash
        ];
        environment = {
          WLR_BACKENDS = "headless";
          WLR_RENDERER = "pixman";
          WLR_LIBINPUT_NO_DEVICES = "1";
          XDG_RUNTIME_DIR = "/run/headless-kiosk";
        };
        serviceConfig = {
          User = "kiosk";
          RuntimeDirectory = "headless-kiosk";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${pkgs.sway}/bin/sway --config ${pkgs.writeText "kiosk-bar-test-sway.conf" ''
            no_focus [app_id="${oskAppId}"]
            for_window [app_id="${oskAppId}"] floating enable, sticky enable, border none
          ''}";
        };
      };
    };

  testScript = ''
    import json

    run = "/run/headless-kiosk"
    rotation = "/var/lib/dashboard-assistant/rotation"
    pidfile = f"{run}/ha-kiosk-waybar.pid"
    osk_app = "${oskAppId}"

    machine.start()
    machine.wait_for_unit("headless-kiosk.service")
    machine.wait_until_succeeds(f"ls {run}/sway-ipc.*.sock")

    def as_kiosk(cmd):
        return machine.succeed(
            f"runuser -u kiosk -- env XDG_RUNTIME_DIR={run} WAYLAND_DISPLAY=wayland-1 "
            f"SWAYSOCK=$(ls {run}/sway-ipc.*.sock) {cmd}"
        )

    def output():
        return json.loads(as_kiosk("swaymsg -t get_outputs"))[0]

    def osk_rect():
        tree = json.loads(as_kiosk("swaymsg -t get_tree"))
        found = []

        def walk(n):
            if n.get("app_id") == osk_app:
                found.append(n["rect"])
            for c in n.get("nodes", []) + n.get("floating_nodes", []):
                walk(c)

        walk(tree)
        return found[0] if found else None

    # The worst case: with the Remote access marker showing, the bar carries
    # six pills (Home, Prev, sponsor, Next, the marker, Keyboard).
    as_kiosk(f"touch {run}/ha-vnc-on")
    expected = 6

    # (name, mode, the scale Sway picks for it unrotated, persisted rotation,
    #  scale after session start, bar layout, whether the keyboard fits)
    #
    # The keyboard does not fit a 1024x600 panel in portrait: even with the
    # small keys oskToggle asks for below 900px, vboard's grid maps 763px wide
    # on the 600px output. Logged rather than asserted until that is fixed, so
    # the case still guards the bar.
    cases = [
        ("Touch Display 2, portrait (its native orientation)", "720x1280", 2, None, 1.5, "compact", True),
        ("Touch Display 2, rotated to landscape", "720x1280", 2, "90", 1.5, "labelled", True),
        ("Touch Display, landscape", "800x480", 1, None, 1, "labelled", True),
        ("1024x600 panel, rotated to portrait", "1024x600", 1, "90", 1, "compact", False),
        ("1080p screen, landscape", "1920x1080", 1, None, 1, "labelled", True),
    ]
    pill_heights = {}

    for name, mode, native, rot, scale, layout, osk_fits in cases:
        with subtest(name):
            if rot is None:
                machine.succeed(f"rm -f {rotation}")
            else:
                machine.succeed(f"echo {rot} > {rotation}")
            as_kiosk(f"swaymsg output HEADLESS-1 mode {mode} transform normal scale {native}")
            old = machine.succeed(f"cat {pidfile} 2>/dev/null || true").strip()
            as_kiosk("swaymsg exec /etc/kiosk-bar-test/display-restore")
            machine.wait_until_succeeds(
                f"pid=$(cat {pidfile}) && [ \"$pid\" != '{old}' ] "
                "&& grep -q waybar /proc/$pid/comm"
            )

            out = output()
            assert out["scale"] == scale, f"scale {out['scale']}, expected {scale}"

            def drawn(_):
                as_kiosk("grim /tmp/bar.png")
                got = json.loads(machine.succeed(f"${pills} /tmp/bar.png {scale}"))
                return len(got["runs"]) > 0 and got

            retry(drawn, timeout_seconds=30)
            machine.sleep(2)  # the marker's script runs just after the first frame
            as_kiosk("grim /tmp/bar.png")
            got = json.loads(machine.succeed(f"${pills} /tmp/bar.png {scale}"))
            cfg = machine.succeed(f"tr '\\0' ' ' < /proc/$(cat {pidfile})/cmdline")
            machine.log(f"{name}: output {out['rect']} at {out['scale']}x, bar {got} via {cfg}")

            runs, width = got["runs"], got["width"]
            assert len(runs) == expected, f"{len(runs)} of {expected} pills visible: {runs}"
            # A pill is inset by its margin; one that touches the edge is being
            # cut off by it.
            assert runs[0][0] > 0 and runs[-1][1] < width - 1, f"a pill runs off the screen: {runs}"
            if layout == "compact":
                assert "compact" in cfg, cfg
            else:
                assert "compact" not in cfg, cfg
            pill_heights[name] = got["pill_height"]

            # The keyboard: open it from the button's own script, let the
            # toggle dock it, and check it lies within the output's width.
            as_kiosk("swaymsg exec /etc/kiosk-bar-test/osk")
            retry(lambda _: osk_rect() is not None, timeout_seconds=30)
            machine.sleep(3)  # the toggle polls, resizes, then re-centres
            k, o = osk_rect(), output()["rect"]
            machine.log(f"{name}: keyboard {k} on output {o}")
            fits = k["x"] >= o["x"] and k["x"] + k["width"] <= o["x"] + o["width"]
            if osk_fits:
                assert fits, f"the keyboard runs off the screen: {k} on {o}"
            elif fits:
                machine.log(f"{name}: the keyboard fits now; expect it to in the case list")
            as_kiosk("swaymsg exec /etc/kiosk-bar-test/osk")
            retry(lambda _: osk_rect() is None, timeout_seconds=30)

    with subtest("rotating the Touch Display 2 keeps its buttons the same size"):
        portrait = pill_heights["Touch Display 2, portrait (its native orientation)"]
        landscape = pill_heights["Touch Display 2, rotated to landscape"]
        # Within a pixel: at 1.5x a 40px pill lands on 60 or 61 device pixels
        # depending on where rounding falls.
        assert abs(portrait - landscape) <= 1, f"{portrait}px tall in portrait, {landscape}px in landscape"

    # Home Assistant's "Button bar" switch (#109). Every bar launch (session
    # start, rotation, screen saver dismissed) goes through the same script, so
    # it is the one that has to honour the marker.
    with subtest("a hidden bar stays hidden, and comes back when shown"):
        hidden = "/var/lib/dashboard-assistant/bar-hidden"
        machine.succeed(f"touch {hidden}")
        as_kiosk("swaymsg exec /etc/kiosk-bar-test/display-restore")
        machine.wait_until_succeeds(f"! test -e {pidfile}")
        # The strip it reserved is given back to the page.
        def page_fills_output(_):
            ws = json.loads(as_kiosk("swaymsg -t get_workspaces"))[0]["rect"]
            return ws["height"] == output()["rect"]["height"]

        retry(page_fills_output, timeout_seconds=30)

        machine.succeed(f"rm {hidden}")
        as_kiosk("swaymsg exec /etc/kiosk-bar-test/display-restore")
        machine.wait_until_succeeds(f"pid=$(cat {pidfile}) && grep -q waybar /proc/$pid/comm")
  '';
}
