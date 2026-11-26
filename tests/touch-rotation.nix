# VM test for touch input following the display rotation (modules/core/kiosk.nix:
# swayRotate): after rotating, a tap lands where the finger is.
#
# Sway only maps a touchscreen to an output, so that it follows the output's
# transform, when told to or when it takes the touchscreen for built in (udev
# ID_PATH "platform-…", as on the Pi's DSI panel) and there is exactly one
# built-in output (eDP, LVDS, DSI). A USB touchscreen on an HDMI screen is
# neither, so it stayed mapped to the whole layout: the picture rotated and
# the touch did not.
#
# The touchscreen here is a uinput device, which has no ID_PATH and so is not
# built in either; the output is headless, which is not built in. greetd stays
# off, as in vnc.nix; Sway runs as the kiosk user with the libinput backend next
# to the headless one, through seatd, so it sees the device. wev, fullscreen,
# prints where each tap lands in the rotated (logical) picture.
{
  pkgs,
  version,
  ...
}:
let
  # A 1920x1080 touchscreen, the size of the output. Taps at the points
  # written to the FIFO (device coordinates, "x y" per line).
  touchscreen = pkgs.writers.writePython3 "fake-touchscreen" {
    libraries = [ pkgs.python3Packages.evdev ];
  } ''
    import time

    from evdev import AbsInfo, UInput
    from evdev import ecodes as e

    W, H = 1920, 1080
    caps = {
        e.EV_KEY: [e.BTN_TOUCH],
        e.EV_ABS: [
            (e.ABS_X, AbsInfo(0, 0, W - 1, 0, 0, 10)),
            (e.ABS_Y, AbsInfo(0, 0, H - 1, 0, 0, 10)),
            (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
            (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
            (e.ABS_MT_POSITION_X, AbsInfo(0, 0, W - 1, 0, 0, 10)),
            (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, H - 1, 0, 0, 10)),
        ],
    }
    ui = UInput(
        caps, name="Fake USB Touchscreen", input_props=[e.INPUT_PROP_DIRECT]
    )
    tid = 0
    while True:
        with open("/run/touch.fifo") as f:
            for line in f:
                x, y = (int(v) for v in line.split())
                tid += 1
                ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
                ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, tid)
                ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, x)
                ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, y)
                ui.write(e.EV_KEY, e.BTN_TOUCH, 1)
                ui.write(e.EV_ABS, e.ABS_X, x)
                ui.write(e.EV_ABS, e.ABS_Y, y)
                ui.syn()
                time.sleep(0.05)
                ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
                ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
                ui.syn()
  '';
in
pkgs.testers.runNixOSTest {
  name = "touch-rotation";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { config, lib, ... }:
    let
      swayConfig = pkgs.writeText "touch-rotation-test-sway.conf" ''
        output HEADLESS-1 mode 1920x1080 scale 1
        default_border none
        for_window [app_id="wev"] fullscreen enable
      '';
    in
    {
      imports = [ ../modules/core/default.nix ];

      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.wev ];
      environment.etc."touch-rotation-test/rotate".source = config.dashboardAssistant.kiosk.rotate;

      services.seatd.enable = true;
      users.users.kiosk.extraGroups = [ "seat" ];

      systemd.services.fake-touchscreen = {
        wantedBy = [ "multi-user.target" ];
        before = [ "headless-kiosk.service" ];
        preStart = "rm -f /run/touch.fifo; mkfifo /run/touch.fifo";
        serviceConfig.ExecStart = touchscreen;
      };

      # Started by the test script once the touchscreen is in udev: libinput
      # aborts Sway if it finds no input device at startup.
      systemd.services.headless-kiosk = {
        after = [
          "seatd.service"
          "fake-touchscreen.service"
        ];
        path = [
          pkgs.dbus
          pkgs.bash
        ];
        environment = {
          WLR_BACKENDS = "headless,libinput";
          WLR_RENDERER = "pixman";
          LIBSEAT_BACKEND = "seatd";
          XDG_RUNTIME_DIR = "/run/headless-kiosk";
        };
        serviceConfig = {
          User = "kiosk";
          RuntimeDirectory = "headless-kiosk";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${pkgs.sway}/bin/sway --config ${swayConfig}";
        };
      };
    };

  testScript = ''
    import json
    import re

    run = "/run/headless-kiosk"

    machine.start()
    machine.wait_for_unit("fake-touchscreen.service")
    machine.wait_until_succeeds(
        "grep -q 'Fake USB Touchscreen' /proc/bus/input/devices"
    )
    machine.succeed("udevadm settle")
    machine.succeed("systemctl start headless-kiosk.service")
    machine.wait_for_unit("headless-kiosk.service")
    machine.wait_until_succeeds(f"ls {run}/sway-ipc.*.sock")

    def as_kiosk(cmd):
        return machine.succeed(
            f"runuser -u kiosk -- env XDG_RUNTIME_DIR={run} WAYLAND_DISPLAY=wayland-1 "
            f"SWAYSOCK=$(ls {run}/sway-ipc.*.sock) {cmd}"
        )

    machine.wait_until_succeeds(
        f"runuser -u kiosk -- env XDG_RUNTIME_DIR={run} SWAYSOCK=$(ls {run}/sway-ipc.*.sock) "
        "swaymsg -t get_inputs | grep -q 'Fake USB Touchscreen'",
        timeout=60,
    )

    as_kiosk("swaymsg exec '${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.wev}/bin/wev -f wl_touch:down > /tmp/wev.log 2>&1'")
    machine.wait_until_succeeds(f"runuser -u kiosk -- env SWAYSOCK=$(ls {run}/sway-ipc.*.sock) swaymsg -t get_tree | grep -q '\"app_id\": \"wev\"'", timeout=30)

    def tap(x, y):
        """Tap at device coordinates; return where it landed in the picture."""
        before = machine.succeed("grep -c 'wl_touch.*down' /tmp/wev.log || true").strip()
        machine.succeed(f"echo '{x} {y}' > /run/touch.fifo")
        machine.wait_until_succeeds(f"[ $(grep -c 'wl_touch.*down' /tmp/wev.log) -gt {before} ]", timeout=10)
        line = machine.succeed("grep 'wl_touch.*down' /tmp/wev.log | tail -1")
        m = re.search(r"x, y: ([0-9.]+), ([0-9.]+)", line)
        assert m, line
        return round(float(m.group(1))), round(float(m.group(2)))

    def near(got, want):
        return abs(got[0] - want[0]) <= 3 and abs(got[1] - want[1]) <= 3

    def rotate(deg):
        as_kiosk(f"/etc/touch-rotation-test/rotate {deg}")
        size = json.loads(as_kiosk("swaymsg -t get_outputs"))[0]["rect"]
        machine.log(f"rotated {deg}: output is {size['width']}x{size['height']}")
        machine.sleep(1)  # let wev's fullscreen surface take the new size

    # Device point near the panel's top-right corner, and where it must land
    # in the picture for each rotation (Sway turns the picture clockwise, so
    # at 90° the picture's top-left sits at the panel's top-right).
    px, py = 1910, 10
    cases = [
        (0, (1910, 10)),
        (90, (10, 10)),
        (180, (10, 1070)),
        (270, (1070, 1910)),
    ]
    for deg, want in cases:
        with subtest(f"a tap lands under the finger at {deg}°"):
            rotate(deg)
            got = tap(px, py)
            assert near(got, want), f"at {deg}° a tap at ({px}, {py}) landed at {got}, want {want}"
  '';
}
