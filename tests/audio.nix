# VM test for the device's audio output and input (modules/core/audio.nix,
# daemon/audio.go): Home Assistant lists the PipeWire sinks and sources, picks
# one of each as the default, and the choices outlive a restart of the audio
# stack. Sendspin and the kiosk's browser play to PipeWire's default sink; a
# voice assistant records from its default source.
#
# Two virtual sound cards (dummy and loopback), each with playback and capture,
# give PipeWire two sinks and two sources to pick between. greetd stays off, as
# in first-boot.nix.
{
  pkgs,
  version,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "audio";

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
    # The unit is active before the daemon has written its token.
    token = machine.wait_until_succeeds("cat /var/lib/dashboard-assistant/api-token").strip()

    def api(method, path, body=None):
        cmd = f"curl -fsS -X {method} -H 'Authorization: Bearer {token}' http://localhost:8081/api/ha/{path}"
        if body is not None:
            cmd += f" -H 'Content-Type: application/json' -d '{json.dumps(body)}'"
        return json.loads(machine.succeed(cmd))

    def audio(_=None):
        return api("GET", "state").get("audio") or {}

    def ready(side):
        return lambda _: audio().get(side, {}).get("current") and len(audio()[side]["options"]) >= 2

    picked = {}
    for side in ["output", "input"]:
        with subtest(f"Home Assistant sees both sound cards' {side}s"):
            retry(ready(side), timeout_seconds=60)
            state = audio()[side]
            machine.log(f"{side}: {state}")
            names = [o["name"] for o in state["options"]]
            assert state["current"] in names, state
            # A sink's monitor is not a microphone.
            assert not any(".monitor" in n for n in names), names

        picked[side] = next(n for n in names if n != state["current"])

        with subtest(f"picking an {side} makes it the default"):
            after = api("POST", "audio", {side: picked[side]})["audio"]
            assert after[side]["current"] == picked[side], after

    with subtest("unknown devices are refused, and a sink is not an input"):
        for body in [{"output": "alsa_output.nothing"}, {"input": picked["output"]}, {}]:
            machine.fail(
                f"curl -fsS -X POST -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json' "
                f"-d '{json.dumps(body)}' http://localhost:8081/api/ha/audio"
            )

    with subtest("the agent idles when nothing changes"):
        # It once republished in a loop, set off by its own PipeWire client.
        def cpu_ns():
            return int(machine.succeed("systemctl show -P CPUUsageNSec audio-agent.service"))
        before = cpu_ns()
        machine.sleep(10)
        used = (cpu_ns() - before) / 1e9
        assert used < 0.5, f"the agent used {used:.2f}s of CPU in 10s of quiet"

    with subtest("the choices outlive a restart of the audio stack"):
        machine.succeed("systemctl restart pipewire.service wireplumber.service")
        retry(lambda _: audio().get("output", {}).get("current") == picked["output"]
              and audio().get("input", {}).get("current") == picked["input"], timeout_seconds=60)
  '';
}
