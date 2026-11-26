# VM test for the screen saver's own brightness (daemon/screensaver.go,
# daemon/display.go, modules/core/kiosk.nix: displayAgent, brightnessSet,
# brightnessRestore, brightnessResolve): while a saver shows, the panel sits at
# the saver's level, and it comes back to the normal one after. The normal
# level is what HA's slider shows, and a slider move while the saver is up
# changes the level it comes back to without lighting the saver up.
#
# greetd stays off, as in vnc.nix. A headless Sway runs as the kiosk user and
# execs the brightness resolver and the display agent the kiosk session runs,
# forced to the software dimmer, the one backend a VM has. Headless Sway has no
# gamma control, so the real wl-gammarelay-rs takes a new brightness and drops
# it; a stand-in with its D-Bus interface keeps the value to read back, and the
# resolver uses it because it only starts wl-gammarelay-rs when none runs. No
# browser either, so another stand-in holds the screen saver FIFO open in
# place of the screen saver agent.
{
  pkgs,
  version,
  ...
}:
let
  fakeGammarelay = pkgs.writers.writePython3Bin "wl-gammarelay-rs" {
    libraries = [ pkgs.python3Packages.dbus-next ];
  } ''
    import asyncio

    from dbus_next.aio import MessageBus
    from dbus_next.service import ServiceInterface, dbus_property


    class Gammarelay(ServiceInterface):
        def __init__(self):
            super().__init__("rs.wl.gammarelay")
            self._brightness = 1.0

        @dbus_property()
        def Brightness(self) -> "d":  # noqa: F821
            return self._brightness

        @Brightness.setter
        def Brightness(self, value: "d"):  # noqa: F821
            self._brightness = value


    async def main():
        bus = await MessageBus().connect()
        bus.export("/", Gammarelay())
        await bus.request_name("rs.wl-gammarelay")
        await asyncio.Future()


    asyncio.run(main())
  '';
in
pkgs.testers.runNixOSTest {
  name = "screensaver-brightness";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { config, lib, ... }:
    let
      swayConfig = pkgs.writeText "screensaver-brightness-test-sway.conf" ''
        output HEADLESS-1 resolution 1280x800
        exec sh -c '${fakeGammarelay}/bin/wl-gammarelay-rs & sleep 2; exec ${config.dashboardAssistant.kiosk.brightnessResolve}'
        exec ${config.dashboardAssistant.kiosk.displayAgent}
      '';
    in
    {
      imports = [ ../modules/core/default.nix ];

      dashboardAssistant.kiosk.brightness.method = "software";
      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.curl ];

      systemd.services.headless-kiosk = {
        wantedBy = [ "multi-user.target" ];
        after = [ "dashboard-assistant-daemon.service" ];
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
          ExecStart = "${pkgs.sway}/bin/sway --config ${swayConfig}";
        };
      };

      # Stand-in for the screen saver agent: holds its FIFO open and logs what
      # the daemon sends.
      systemd.services.screensaver-stand-in = {
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        script = ''
          f=/var/lib/dashboard-assistant/screensaver.fifo
          [ -p $f ] || mkfifo -m 0660 $f
          chown dashboard-assistant:dashboard-assistant $f
          exec 3<> $f
          while read -r line <&3; do echo "$line" >> /tmp/screensaver.log; done
        '';
      };
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("dashboard-assistant-daemon.service")
    machine.wait_for_unit("headless-kiosk.service")
    machine.wait_for_unit("screensaver-stand-in.service")
    machine.wait_until_succeeds(
        "ls -l /proc/$(pgrep -f ha-display-agent | head -1)/fd | grep -q display.fifo", timeout=120
    )
    machine.wait_until_succeeds("test -s /var/lib/dashboard-assistant/brightness.env", timeout=60)

    token = machine.wait_until_succeeds("cat /var/lib/dashboard-assistant/api-token").strip()

    def api(method, path, body=None):
        cmd = f"curl -fsS -X {method} -H 'Authorization: Bearer {token}' http://localhost:8081/api/ha/{path}"
        if body is not None:
            cmd += f" -H 'Content-Type: application/json' -d '{json.dumps(body)}'"
        return json.loads(machine.succeed(cmd))

    def gamma():
        # The session bus is the one the sway wrapper's dbus-run-session made.
        pid = machine.succeed("pgrep -u kiosk -x sway | head -1").strip()
        bus = machine.succeed(
            f"tr '\\0' '\\n' < /proc/{pid}/environ | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p'"
        ).strip()
        out = machine.succeed(
            f"runuser -u kiosk -- env DBUS_SESSION_BUS_ADDRESS='{bus}' "
            "busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Brightness"
        )
        return round(float(out.split()[1]) * 100)

    def panel_at(pct):
        retry(lambda _: gamma() == pct, timeout_seconds=15)

    def slider():
        return api("GET", "state")["display"]["brightness"]

    with subtest("off by default: the saver leaves the brightness alone"):
        assert api("GET", "state")["screensaver"]["brightness"] == 0
        api("POST", "display", {"brightness": 80})
        panel_at(80)
        api("POST", "screensaver", {"active": True})
        machine.sleep(2)
        assert gamma() == 80
        api("POST", "screensaver", {"active": False})

    with subtest("the panel dims while the saver shows and comes back after"):
        s = api("POST", "screensaver", {"brightness": 20})["screensaver"]
        assert s["brightness"] == 20, s
        assert gamma() == 80, "dimmed with no saver up"
        api("POST", "screensaver", {"active": True})
        panel_at(20)
        assert slider() == 80, "the slider moved to the saver's level"
        api("POST", "screensaver", {"active": False})
        panel_at(80)

    with subtest("a slider move while dimmed sets the level to come back to"):
        api("POST", "screensaver", {"active": True})
        panel_at(20)
        api("POST", "display", {"brightness": 50})
        machine.sleep(2)
        assert gamma() == 20, "the slider lit the saver up"
        assert slider() == 50
        api("POST", "screensaver", {"active": False})
        panel_at(50)

    with subtest("changing the saver's level while it shows applies at once"):
        api("POST", "screensaver", {"active": True})
        panel_at(20)
        api("POST", "screensaver", {"brightness": 35})
        panel_at(35)
        api("POST", "screensaver", {"brightness": 0})
        panel_at(50)
        api("POST", "screensaver", {"brightness": 20, "active": False})

    with subtest("a power cycle keeps the saver dimmed"):
        api("POST", "screensaver", {"active": True})
        panel_at(20)
        api("POST", "display", {"on": False})
        api("POST", "display", {"on": True})
        machine.sleep(2)
        panel_at(20)
        assert slider() == 50
        api("POST", "screensaver", {"active": False})
        panel_at(50)

    with subtest("a daemon restart puts back the brightness a saver left dimmed"):
        api("POST", "screensaver", {"active": True})
        panel_at(20)
        machine.succeed("systemctl restart dashboard-assistant-daemon.service")
        panel_at(50)
        assert api("GET", "state")["screensaver"]["brightness"] == 20, "the level was not kept"
  '';
}
