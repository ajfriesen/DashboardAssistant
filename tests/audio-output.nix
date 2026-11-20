# VM test for the device's audio output (modules/core/audio-output.nix,
# daemon/audio.go): Home Assistant lists the PipeWire sinks, picks one as the
# default, and the choice outlives a restart of the audio stack. Sendspin and
# the kiosk's browser both play to PipeWire's default sink, so this is the one
# switch for both.
#
# Two virtual sound cards (dummy and loopback) give PipeWire two sinks to pick
# between. greetd stays off, as in first-boot.nix.
{
  pkgs,
  version,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "audio-output";

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
      boot.kernelModules = [
        "snd-dummy"
        "snd-aloop"
      ];
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("dashboard-assistant-daemon.service")
    token = machine.succeed("cat /var/lib/dashboard-assistant/api-token").strip()

    def api(method, path, body=None):
        cmd = f"curl -fsS -X {method} -H 'Authorization: Bearer {token}' http://localhost:8081/api/ha/{path}"
        if body is not None:
            cmd += f" -H 'Content-Type: application/json' -d '{json.dumps(body)}'"
        return json.loads(machine.succeed(cmd))

    def audio(_=None):
        return api("GET", "state").get("audio")

    with subtest("Home Assistant sees both sound cards"):
        retry(lambda _: (audio() or {}).get("current") and len(audio()["options"]) >= 2, timeout_seconds=60)
        state = audio()
        machine.log(f"audio: {state}")
        names = [o["name"] for o in state["options"]]
        assert state["current"] in names, state

    target = next(n for n in names if n != state["current"])

    with subtest("picking a sink makes it the default"):
        after = api("POST", "audio", {"output": target})["audio"]
        assert after["current"] == target, after

    with subtest("an unknown sink is refused"):
        machine.fail(
            f"curl -fsS -X POST -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json' "
            "-d '{\"output\": \"alsa_output.nothing\"}' http://localhost:8081/api/ha/audio"
        )

    with subtest("the agent idles when nothing changes"):
        # It once republished in a loop, set off by its own PipeWire client.
        def cpu_ns():
            return int(machine.succeed("systemctl show -P CPUUsageNSec audio-output-agent.service"))
        before = cpu_ns()
        machine.sleep(10)
        used = (cpu_ns() - before) / 1e9
        assert used < 0.5, f"the agent used {used:.2f}s of CPU in 10s of quiet"

    with subtest("the choice outlives a restart of the audio stack"):
        machine.succeed("systemctl restart pipewire.service wireplumber.service")
        retry(lambda _: (audio() or {}).get("current") == target, timeout_seconds=60)
  '';
}
