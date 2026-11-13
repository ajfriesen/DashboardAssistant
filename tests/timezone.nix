# VM test for the device timezone (daemon/timezone.go): Home Assistant pushes
# its own zone, the daemon hands it to timedated, and the device keeps it across
# a reboot. A device nobody has told anything stays on UTC.
#
# greetd stays off, as in first-boot.nix: without a GPU the kiosk session
# crash-loops, and nothing here needs it.
{
  pkgs,
  version,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "timezone";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/core/default.nix ];
      systemd.services.greetd.enable = lib.mkForce false;
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("dashboard-assistant-daemon.service")
    token = machine.succeed("cat /var/lib/dashboard-assistant/api-token").strip()

    def push(zone):
        return machine.succeed(
            f"curl -sS -o /dev/null -w '%{{http_code}}' -X POST"
            f" -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json'"
            f" -d '{json.dumps({"timezone": zone})}'"
            " http://localhost:8081/api/ha/timezone"
        ).strip()

    def zone():
        return machine.succeed("timedatectl show -p Timezone --value").strip()

    with subtest("a device starts on UTC"):
        assert zone() == "UTC", zone()

    with subtest("Home Assistant sets the zone"):
        code = push("Europe/Berlin")
        assert code == "200", code
        assert zone() == "Europe/Berlin", zone()
        # Local time follows: Berlin is never at UTC's offset.
        assert machine.succeed("date +%Z").strip() in ("CET", "CEST")

    with subtest("a name outside the tz database changes nothing"):
        code = push("Mars/Olympus_Mons")
        assert code == "400", code
        assert zone() == "Europe/Berlin", zone()

    with subtest("the zone survives a reboot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("dashboard-assistant-daemon.service")
        assert zone() == "Europe/Berlin", zone()
  '';
}
