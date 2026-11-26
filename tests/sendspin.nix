# VM test for the Sendspin player (modules/core/sendspin.nix): switched on from
# Home Assistant, it stays up, advertises itself over mDNS and accepts the
# server's connection. Music Assistant finds players and dials them, so a
# player that only browses for servers (the old sendspin-go one, whose browse
# loop leaked 2.8 GB on a device in the field, #16) or is firewalled off fails.
#
# `server` stands in for Music Assistant on the same LAN: it browses for
# players with Avahi and opens a TCP connection to the port advertised.
#
# greetd stays off, as in first-boot.nix. A dummy sound card gives PipeWire a
# sink to play into.
{
  pkgs,
  version,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "sendspin";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/core/default.nix ];

      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;
      boot.kernelModules = [ "snd-dummy" ];
      environment.systemPackages = [ pkgs.curl ];
    };

  nodes.server = {
    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };
    environment.systemPackages = [ pkgs.netcat ];
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("dashboard-assistant-daemon.service")
    server.wait_for_unit("avahi-daemon.service")

    # The unit is active before the daemon has written its token.
    token = machine.wait_until_succeeds("cat /var/lib/dashboard-assistant/api-token").strip()
    machine.succeed(
        f"curl -fsS -X POST -H 'Authorization: Bearer {token}' "
        "-H 'Content-Type: application/json' -d '{\"on\": true}' "
        "http://localhost:8081/api/ha/sendspin"
    )

    with subtest("the player starts and stays up"):
        machine.wait_for_unit("sendspin-player.service")
        machine.sleep(10)
        machine.succeed("systemctl is-active sendspin-player.service")
        restarts = machine.succeed("systemctl show -P NRestarts sendspin-player.service").strip()
        assert restarts == "0", f"the player restarted {restarts} times"

    with subtest("a server on the LAN finds the player"):
        # IPv4, as Music Assistant dials it (aiosendspin browses V4Only). The
        # player's WebSocket server binds 0.0.0.0 only, although Avahi also
        # advertises its IPv6 address.
        found = server.wait_until_succeeds(
            "avahi-browse -rpt _sendspin._tcp | grep '^=;[^;]*;IPv4;'", timeout=60
        )
        # =;iface;proto;name;type;domain;host;address;port;txt
        record = found.splitlines()[0].split(";")
        host, port = record[7], record[8]
        server.log(f"player advertised at {host}:{port}: {record}")

    with subtest("the server can connect to the player"):
        server.succeed(f"nc -z -w 5 {host} {port}")
  '';
}
