# VM test for VNC (modules/core/vnc.nix, daemon/vnc.go): the server runs only
# while Home Assistant has it switched on, and it refuses any client that will
# not encrypt.
#
# greetd stays off, as in first-boot.nix: without a GPU the real kiosk session
# crash-loops. In its place a headless Sway (pixman renderer, no input devices)
# runs as the kiosk user and execs the same VNC agent the kiosk session does.
# That is everything wayvnc needs: a wlroots compositor to capture.
{
  pkgs,
  version,
  ...
}:
let
  # Speaks just enough RFB to list the security types the server offers, and,
  # when VeNCrypt is among them, its subtypes. Prints both as JSON.
  rfbProbe = pkgs.writers.writePython3 "rfb-probe" { } ''
    import json
    import socket
    import struct
    import sys


    def recv(s, n):
        b = b""
        while len(b) < n:
            chunk = s.recv(n - len(b))
            if not chunk:
                raise EOFError("server closed the connection")
            b += chunk
        return b


    def connect():
        s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10)
        recv(s, 12)
        s.sendall(b"RFB 003.008\n")
        (n,) = struct.unpack("B", recv(s, 1))
        return s, list(recv(s, n))


    s, types = connect()
    s.close()

    subtypes = []
    if 19 in types:
        s, _ = connect()
        s.sendall(bytes([19]))
        recv(s, 2)  # server VeNCrypt version, 0.2
        s.sendall(bytes([0, 2]))
        recv(s, 1)  # ack
        (n,) = struct.unpack("B", recv(s, 1))
        subtypes = list(struct.unpack(f">{n}I", recv(s, 4 * n)))
        s.close()

    print(json.dumps({"types": types, "vencrypt": subtypes}))
  '';
in
pkgs.testers.runNixOSTest {
  name = "vnc";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { config, lib, ... }:
    let
      swayConfig = pkgs.writeText "vnc-test-sway.conf" ''
        output HEADLESS-1 resolution 1280x800
        exec ${config.dashboardAssistant.vnc.agent}
      '';
    in
    {
      imports = [ ../modules/core/default.nix ];

      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.curl ];

      # Stand-in for the kiosk session: Sway as the kiosk user, after the
      # daemon, as greetd would start it.
      systemd.services.headless-kiosk = {
        wantedBy = [ "multi-user.target" ];
        after = [ "dashboard-assistant-daemon.service" ];
        # The nixpkgs sway wrapper starts its own dbus-run-session when no bus is
        # set, and Sway runs `exec` lines through `sh` from PATH. greetd's
        # session has both on the system PATH; a bare unit has neither.
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
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("dashboard-assistant-daemon.service")
    machine.wait_for_unit("headless-kiosk.service")
    # The agent is up once it holds the FIFO open.
    machine.wait_until_succeeds(
        "ls -l /proc/$(pgrep -f ha-vnc-agent | head -1)/fd | grep -q vnc.fifo", timeout=120
    )

    token = machine.succeed("cat /var/lib/dashboard-assistant/api-token").strip()

    def api(method, path, body=None):
        cmd = f"curl -fsS -X {method} -H 'Authorization: Bearer {token}' http://localhost:8081/api/ha/{path}"
        if body is not None:
            cmd += f" -H 'Content-Type: application/json' -d '{json.dumps(body)}'"
        return json.loads(machine.succeed(cmd))

    flag = "/run/headless-kiosk/ha-vnc-on"

    with subtest("VNC is off after boot"):
        assert json.loads(machine.succeed(f"curl -fsS -H 'Authorization: Bearer {token}' http://localhost:8081/api/ha/info"))["has_vnc"]
        vnc = api("GET", "state")["vnc"]
        assert vnc["on"] is False and "password" not in vnc, vnc
        machine.fail("ss -ltn | grep -q ':5900 '")
        machine.fail(f"test -e {flag}")

    with subtest("switching on starts wayvnc with a fresh password"):
        vnc = api("POST", "vnc", {"on": True})["vnc"]
        assert vnc["on"] and len(vnc["password"]) >= 12, vnc
        assert vnc["timeout"] == 15 and vnc["closes_at"] > 0, vnc
        machine.wait_for_open_port(5900)
        machine.succeed(f"test -e {flag}")
        # The config holding the password: tmpfs, readable by the daemon and
        # (through the group) the kiosk user only.
        stat = machine.succeed("stat -c '%a %U %G' /run/dashboard-assistant/wayvnc.conf").strip()
        assert stat == "640 dashboard-assistant dashboard-assistant", stat

    with subtest("only encrypted security types are offered"):
        probe = json.loads(machine.succeed("${rfbProbe} 5900"))
        machine.log(f"offered: {probe}")
        # RFB security types: 5 = RSA-AES, 129 = RSA-AES-256, 19 = VeNCrypt.
        # Anything else (1 None, 2 VNC auth/DES, 6 RSA-AES unencrypted, 30 Apple
        # DH) would let a client in without encrypting the session.
        assert probe["types"] and set(probe["types"]) <= {5, 19, 129}, probe
        # VeNCrypt subtypes that use TLS and a password: 258 TLSVnc, 259
        # TLSPlain, 261 X509Vnc, 262 X509Plain. Never 256 Plain (cleartext).
        assert set(probe["vencrypt"]) <= {258, 259, 261, 262}, probe

    with subtest("switching off stops wayvnc and removes the password"):
        vnc = api("POST", "vnc", {"on": False})["vnc"]
        assert vnc["on"] is False and "password" not in vnc, vnc
        machine.wait_for_closed_port(5900)
        machine.fail("test -e /run/dashboard-assistant/wayvnc.conf")
        machine.fail(f"test -e {flag}")

    with subtest("a daemon restart stops a running server"):
        api("POST", "vnc", {"on": True})
        machine.wait_for_open_port(5900)
        machine.succeed("systemctl restart dashboard-assistant-daemon.service")
        machine.wait_for_closed_port(5900)
        assert api("GET", "state")["vnc"]["on"] is False

    with subtest("wayvnc dying is reported back"):
        api("POST", "vnc", {"on": True})
        machine.wait_for_open_port(5900)
        machine.succeed("pkill -x wayvnc")
        retry(lambda _: api("GET", "state")["vnc"]["on"] is False, timeout_seconds=30)

    with subtest("refreshing the marker never kills a process without a handler"):
        # The agent signals the bar's PID with SIGRTMIN+9, whose default action
        # is to terminate. A waybar that is still starting up has no handler
        # yet, and on a real device that killed the whole bar at boot. Stand in
        # for it with a kiosk-owned process that has no handler.
        bar_pid = "/run/headless-kiosk/ha-kiosk-waybar.pid"
        machine.succeed(
            f"runuser -u kiosk -- setsid sh -c 'echo $$ > {bar_pid}; exec sleep 1000' >/dev/null 2>&1 &"
        )
        machine.wait_until_succeeds(f"test -s {bar_pid}")
        pid = machine.succeed(f"cat {bar_pid}").strip()
        api("POST", "vnc", {"on": True})
        machine.wait_for_open_port(5900)
        api("POST", "vnc", {"on": False})
        machine.wait_for_closed_port(5900)
        machine.succeed(f"kill -0 {pid}")
  '';
}
