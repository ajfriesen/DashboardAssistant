# VM test for first-boot health: the boot must come up clean and a seed file
# must provision the device without any on-screen interaction.
#
# This encodes the failure classes that actually shipped in the btrfs image
# work: a systemd ordering cycle silently deleting jobs (journal-flush vs
# tmpfiles-setup), tmpfiles never running (build-user-owned /), and the seed
# import dying because the daemon could not persist to a root-owned state dir.
# Each got its own assertion below; a regression in any of them fails loudly
# instead of bricking a flashed device in the field.
#
# The kiosk session itself (greetd/sway/Chromium) is disabled: without a GPU it
# crash-loops and buries the signals this test is about. Session-level checks
# (PAM, OSK) stay on-device for now.
{
  pkgs,
  version,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "first-boot";

  node.specialArgs = {
    inherit version;
    impermanence = null; # only referenced by the deferred impermanence scaffold
  };

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/core/default.nix ];

      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;

      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("dashboard-assistant-daemon.service")

    # A systemd ordering cycle "resolves" by deleting jobs — half the boot
    # quietly never happens. This exact failure shipped once (journal-flush
    # ordered against tmpfiles-setup); never again.
    machine.fail("journalctl -b | grep -q 'Breaking ordering cycle'")
    machine.fail("journalctl -b | grep -q 'Deleting job'")

    # Nothing may sit in the failed state after a clean boot.
    machine.succeed("systemctl --failed --no-legend | grep -q . && exit 1 || exit 0")

    # tmpfiles must have run and produced the daemon's state dir with the
    # right owner and the session FIFOs. A root-owned dir here means the
    # unprivileged daemon cannot persist anything (token, config, markers)
    # and first-boot provisioning collapses.
    machine.succeed("test \"$(stat -c %U /var/lib/dashboard-assistant)\" = dashboard-assistant")
    machine.succeed("test -p /var/lib/dashboard-assistant/display.fifo")

    # mDNS advertisement (how Home Assistant discovers the device).
    machine.wait_for_unit("avahi-daemon.service")
    machine.succeed(
        "grep -q _dashboard-assistant._tcp /etc/avahi/services/dashboard-assistant.service"
    )

    # The HA API answers on the LAN port with the device identity.
    ident = json.loads(machine.succeed("curl -fsS http://localhost:8081/api/ha/identify"))
    assert ident["node_id"].startswith("da_"), ident

    # ...and advertises where TLS lives, which is how the integration knows to
    # stop using the cleartext port above.
    assert ident["tls_port"] == 8443, ident

    # The TLS listener is up and serving the same API, which proves the daemon
    # generated and loaded a keypair on first boot. -k because the certificate is
    # self-signed by design; the integration pins its fingerprint rather than
    # validating a chain.
    tls_ident = json.loads(
        machine.succeed("curl -fsSk https://localhost:8443/api/ha/identify")
    )
    assert tls_ident["node_id"] == ident["node_id"], tls_ident

    # The private key must not be readable beyond the daemon. Unlike the HA token,
    # nothing else on the device needs it.
    machine.succeed("test \"$(stat -c %a /var/lib/dashboard-assistant/tls-key.pem)\" = 600")

    # Seed-file provisioning: drop a dashboard-assistant.yaml where the
    # first-boot import looks, run the import, and the daemon must accept and
    # persist it. This is the headless field-provisioning path.
    #
    # On a real device /boot is the ESP, mounted by the hardware module. This
    # node has no disk layout, so create the directory the importer reads —
    # what is under test is the import, not where the partition came from.
    machine.succeed("mkdir -p /boot")
    machine.succeed(
        "printf 'ha_url: \"http://198.51.100.7:8123\"\\n' > /boot/dashboard-assistant.yaml"
    )
    machine.succeed("systemctl restart dashboard-assistant-boot-import.service")
    # Read it back from the admin listener's info payload, which is where the
    # daemon surfaces the HA URL. (Not /api/state — that returns only the
    # splash state machine's current state, never the URL.)
    machine.wait_until_succeeds(
        "curl -fsS http://localhost:8099/api/admin/info | grep -q 198.51.100.7", timeout=30
    )
    # ...and that it was persisted, not just held in memory.
    machine.succeed("grep -q 198.51.100.7 /var/lib/dashboard-assistant/runtime.env")

    # The import must also mark the device provisioned, so the boot importer
    # never re-runs.
    machine.wait_until_succeeds("test -e /var/lib/dashboard-assistant/provisioned", timeout=30)
  '';
}
