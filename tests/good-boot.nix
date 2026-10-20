# VM test for automatic rollback: a generation that never reaches a good boot
# must be abandoned for the previous one (docs/adr/0009).
#
# This exists to settle a specific open question, not to re-test nixpkgs.
# Boot counting works by systemd-boot setting LoaderBootCountPath, a *volatile*
# EFI variable, at runtime — and every board here installs the loader with
# `--no-variables` at the removable fallback path (\EFI\BOOT\BOOTX64.EFI),
# because neither ODROID H2 firmware nor U-Boot will honour an NVRAM entry
# written by `bootctl`. Whether a loader that was forbidden from writing NVRAM
# at install time can still set a variable at boot time is why boot counting
# stayed switched off, and it could not be settled from the documentation: the
# two flags are unrelated in principle and the combination is untested upstream
# (nixpkgs' own bootCounting test runs with canTouchEfiVariables = true). So it
# is asked here, of a real loader on a real ESP.
#
# The two failure modes it has to rule out are both silent:
#
#   * systemd-bless-boot never runs. Its generator only pulls the unit in when
#     LoaderBootCountPath is set, so a loader that did not set the variable
#     produces no counter, no blessing and no error — every boot simply looks
#     fine while nothing is being assessed.
#   * The counter never reaches zero. An entry stuck at "+3" is never marked
#     bad, so the fallback that is the entire point never happens.
#
# Deliberately NOT the appliance's own closure: this boots a plain system with
# ../modules/core/good-boot.nix and a stub for the one thing the gate asks
# about. The subject is the boot chain, which no Go test can reach; that the
# daemon then notices the rollback is the subject of daemon/rollback_test.go,
# and the two meet in the last assertion here — the exact symlink disagreement
# detectRollback() keys off, taken from a system that really did roll back.
#
# The Raspberry Pi half of the question is not answerable in a VM at all: there
# the UEFI environment is U-Boot's, whose variable support is its own story.
# That one is asserted on the bench, in labgrid/test_first_boot.py's boot-chain
# section — in that file rather than one of its own because boot counting only
# applies to a freshly installed generation, and a separate file sorts after it,
# onto a second boot that is deliberately not counted.
{
  pkgs,
  ...
}:
let
  # Answer /healthz and nothing else, on the port the gate polls. A stand-in for
  # the daemon on purpose: wiring up the real one would drag the kiosk's closure
  # into a test about the bootloader, and the gate's question — is anything
  # answering? — is the same either way.
  #
  # Its own file rather than `python3 -c` inside the shell script: that would be
  # one indented string literal nested in another, and a formatter is free to
  # re-indent them relative to each other — which in Python is the difference
  # between a server and an IndentationError three VM boots into a run.
  healthzPy = pkgs.writeText "stub-healthz.py" ''
    import http.server


    class Healthz(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", 8080), Healthz).serve_forever()
  '';

  healthz = pkgs.writeShellScript "stub-healthz" ''
    exec ${pkgs.python3}/bin/python3 ${healthzPy}
  '';

  reachable = {
    systemd.services.stub-healthz = {
      description = "Stand in for the daemon's /healthz";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = healthz;
    };
  };

  common =
    { lib, ... }:
    {
      imports = [ ../modules/core/good-boot.nix ];

      # A real loader on a real ESP, which is what the question is about.
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.systemd-boot.enable = true;
      # The crux. Both the x86 target and the Pi targets set this, for different
      # firmware reasons, and it is what makes `bootctl install` pass
      # --no-variables and fall back to the removable path.
      boot.loader.efi.canTouchEfiVariables = false;

      # Registering generations by hand needs nix and switch-to-configuration.
      nix.enable = true;
      system.switch.enable = true;

      # machine-id has to survive the reboots, or dbus-broker refuses to start
      # on the second boot (same note as nixos/tests/systemd-boot.nix).
      environment.etc."machine-id".text = "0123456789abcdef0123456789abcdef\n";

      # The gate orders itself after the daemon unit, which does not exist here.
      # Harmless on the node that has no stub either: After= on an absent unit
      # is a no-op.
      systemd.services.dashboard-assistant-good-boot.after = lib.mkForce [ "stub-healthz.service" ];

      virtualisation.memorySize = 2048;
    };
in
pkgs.testers.runNixOSTest {
  name = "good-boot";

  nodes = {
    # Generation 1: the system the device was flashed with. Reaches a good boot.
    machine =
      { nodes, ... }:
      {
        imports = [
          common
          reachable
        ];

        # The other two closures have to be in this machine's store, because the
        # test registers them as generations from inside the VM.
        system.extraDependencies = [
          nodes.recovered.system.build.toplevel
          nodes.unreachable.system.build.toplevel
        ];
      };

    # Generation 2: a good release, newer than generation 1. It is what the
    # device must come back to, and having it here is what distinguishes
    # "skipped the bad entry and took the newest good one" from "fell all the
    # way back to the oldest entry on the ESP".
    recovered = {
      imports = [
        common
        reachable
      ];
      # Something to tell this closure apart from generation 1's.
      environment.etc."good-boot-test-marker".text = "recovered\n";
    };

    # Generation 3: the update that comes up unreachable. Nothing answers
    # /healthz, so the gate fails, boot-complete.target is never reached and the
    # counter is never cleared. Reproduced by leaving the stub out rather than by
    # a service that exits 1, so the test fails the way a real device would.
    #
    # TimeoutStartSec cuts the gate's own ~3 minute wait short. That wait is
    # right on a cold Raspberry Pi and wrong in a test that has to sit through
    # it three times; what is under test is what systemd-boot does with a unit
    # that failed, not how patiently it failed.
    unreachable = {
      imports = [ common ];
      systemd.services.dashboard-assistant-good-boot.serviceConfig.TimeoutStartSec = 10;
    };
  };

  testScript =
    { nodes, ... }:
    let
      flashed = nodes.machine.system.build.toplevel;
      recovered = nodes.recovered.system.build.toplevel;
      unreachable = nodes.unreachable.system.build.toplevel;
    in
    ''
      flashed = "${flashed}"
      recovered = "${recovered}"
      unreachable = "${unreachable}"

      # The boot entry for a generation, and the counter in its filename: "+3"
      # means three attempts left, "+0-3" means three spent and the entry marked
      # bad, no suffix means blessed. Same shape as nixos/tests/systemd-boot.nix.
      def entry(generation, tries_left=0, tries_failed=0):
          conf = machine.succeed(
              f"grep --files-with-matches 'version Generation {generation} NixOS' "
              "/boot/loader/entries/nixos-*.conf"
          ).split("\n")[0]
          suffix = ""
          if tries_left:
              suffix += f"+{tries_left}"
          if tries_failed:
              suffix += f"-{tries_failed}"
          assert conf.endswith(f"{suffix}.conf"), (
              f"generation {generation}'s entry is {conf}, expected it to end in "
              f"{suffix}.conf — the boot counter is not where it should be"
          )

      def booted(system_path, why):
          got = machine.succeed("readlink -f /run/booted-system").strip()
          assert got == system_path, f"{why}: booted {got}, expected {system_path}"

      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")

      # ------------------------------------------------------------------
      # Does a loader installed with --no-variables still count boots?
      # ------------------------------------------------------------------

      # systemd-boot sets this volatile EFI variable when it boots a counted
      # entry. Were runtime variable access the price of --no-variables, it
      # would be absent and everything below would pass vacuously.
      machine.succeed(
          "test -e /sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
      )

      # ...and the blessing really happens. systemd-bless-boot's generator only
      # enables the unit when that variable is set, so waiting on it is waiting
      # on the mechanism being live: it hangs rather than passes if boot counting
      # silently did nothing.
      machine.wait_for_unit("dashboard-assistant-good-boot.service")
      machine.wait_for_unit("boot-complete.target")
      machine.wait_for_unit("systemd-bless-boot.service")

      # Blessed means the counter is gone from the entry's filename.
      entry(1)
      booted(flashed, "a reachable device")

      # ------------------------------------------------------------------
      # An update that comes up unreachable
      # ------------------------------------------------------------------

      # Generation 2 is a good release and generation 3 the unreachable one, and
      # generation 3 is the one to boot — exactly what `nixos-rebuild switch`
      # leaves behind when a device installs the newest release.
      machine.succeed("nix-env -p /nix/var/nix/profiles/system --set ${recovered}")
      machine.succeed("nix-env -p /nix/var/nix/profiles/system --set ${unreachable}")
      machine.succeed("${unreachable}/bin/switch-to-configuration boot")

      # Three attempts each, per ADR 0009.
      entry(2, 3)
      entry(3, 3)

      for attempt, left in enumerate([2, 1, 0], start=1):
          machine.reboot()
          machine.wait_for_unit("multi-user.target")
          booted(unreachable, f"attempt {attempt} on the unreachable generation")
          # The gate has to actually fail, or this would be measuring some other
          # kind of broken boot than the one being guarded against.
          machine.wait_until_succeeds("systemctl is-failed --quiet dashboard-assistant-good-boot.service")
          entry(3, left, attempt)

      # The fourth boot is the one that matters: generation 3 has spent all three
      # attempts, so systemd-boot skips it and takes the newest entry that is not
      # marked bad — generation 2, not generation 1.
      machine.reboot()
      machine.wait_for_unit("multi-user.target")
      booted(recovered, "after three failed attempts")
      machine.wait_for_unit("systemd-bless-boot.service")
      entry(3, 0, 3)
      entry(2)

      # ------------------------------------------------------------------
      # ...and the daemon can tell. This is the state daemon/rollback.go
      # derives a rejected release from: the system profile still points at the
      # generation that was switched to, while the booted and the running
      # system are both the one the loader fell back to. Asserted here because
      # nothing else proves the Go side reads a situation real hardware
      # actually produces.
      # ------------------------------------------------------------------
      profile = machine.succeed("readlink -f /nix/var/nix/profiles/system").strip()
      current = machine.succeed("readlink -f /run/current-system").strip()
      booted_system = machine.succeed("readlink -f /run/booted-system").strip()
      assert current == booted_system, (
          "after a rollback the running system must be the one that booted, got "
          f"current={current} booted={booted_system}"
      )
      assert profile == unreachable, (
          "the system profile must still point at the generation that was "
          f"switched to — that is what names the rejected release; got {profile}"
      )
    '';
}
