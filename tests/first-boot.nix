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

    # ------------------------------------------------------------------
    # Flash endurance (modules/core/flash-wear.nix). The journal is the
    # biggest writer on this appliance -- 2.87 GB to an SD card in one boot,
    # once -- so it lives in RAM and is copied to flash on a timer instead.
    # ------------------------------------------------------------------

    # The journal must be in RAM. /run is a tmpfs, so Storage=volatile is the
    # whole mechanism; if this reverts to persistent, every logged line goes
    # back to hitting the card and nothing else here would notice.
    machine.succeed("grep -qx 'Storage=volatile' /etc/systemd/journald.conf")
    assert machine.succeed("findmnt -no FSTYPE -T /run/log/journal").strip() == "tmpfs"

    # The global burst, which is the knob that would actually have caught the
    # sendspin flood (the stock 10000/30s did not).
    machine.succeed("grep -qx 'RateLimitBurst=2000' /etc/systemd/journald.conf")
    machine.succeed("grep -qx 'RuntimeMaxUse=64M' /etc/systemd/journald.conf")

    # ...and journald must not be persisting on its own. Nothing has run the
    # sync yet, so the persistent tree must not exist at all: if journald were
    # still writing there, Storage=volatile would be a lie and the timer below
    # would merely be duplicating writes we are trying to eliminate.
    machine.fail("test -e /var/log/journal")

    # /tmp must be the tmpfs, not a directory on flash that is also never
    # cleaned. This doubles as proof that we went through boot.tmp.useTmpfs
    # (which uses systemd.mounts) rather than declaring fileSystems ourselves:
    # qemu-vm.nix mkVMOverrides fileSystems wholesale, so the latter would
    # evaluate perfectly and simply not exist here.
    assert machine.succeed("findmnt -no FSTYPE /tmp").strip() == "tmpfs"

    # ...and Nix must not build inside it. One substituter miss during an
    # on-device update would otherwise try to build in RAM on a 2 GB Pi and die
    # with ENOSPC mid-switch — the one way this work could brick a device
    # rather than just wear it.
    machine.succeed("grep -qx 'build-dir = /var/tmp' /etc/nix/nix.conf")
    assert machine.succeed("nix config show build-dir").strip() == "/var/tmp"

    # Reclaim tuning for a box whose only swap is compressed RAM
    # (modules/core/memory.nix). Not a flash saving in itself, but it is what
    # makes the tmpfs above reclaimable rather than RAM pinned forever.
    assert machine.succeed("sysctl -n vm.swappiness").strip() == "180"
    assert machine.succeed("sysctl -n vm.page-cluster").strip() == "0"

    # The screenshot handoff buffer's directory must be the daemon's tmpfs
    # RuntimeDirectory, group-writable so the in-session grim agent (user
    # `kiosk`) can drop a frame into it. The grim write itself needs a Wayland
    # session, which this node has none of — labgrid/test_first_boot.py covers
    # that end. What a VM can prove is the half that silently rots: the
    # directory exists, is on tmpfs, and the daemon can be reached through it.
    assert machine.succeed("findmnt -no FSTYPE -T /run/dashboard-assistant").strip() == "tmpfs"
    assert (
        machine.succeed("stat -c %U:%G:%a /run/dashboard-assistant").strip()
        == "dashboard-assistant:dashboard-assistant:775"
    )
    # ...and nothing writes frames to the state dir any more. A leftover here
    # would mean the Nix and Go halves of the path disagreed and the HA image
    # entity was quietly serving a stale frame from flash.
    machine.fail("test -e /var/lib/dashboard-assistant/screenshot.jpg")

    # The sync is timer-driven, so the timer has to be armed -- an ExecStart
    # nothing ever triggers would silently archive nothing until the device
    # was cleanly shut down.
    machine.succeed("systemctl is-active dashboard-assistant-journal-sync.timer")
    # The shutdown flush is a RemainAfterExit unit whose only job is its
    # ExecStop, so "active" is its working state, not a leftover.
    machine.succeed("systemctl is-active dashboard-assistant-journal-sync-shutdown.service")

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

    # No seed file on this boot. The importer is no longer gated on the
    # provisioned marker (it is gated on the seed file's content hash instead),
    # so it must have run — and must have done nothing, quietly.
    machine.succeed(
        "test \"$(systemctl show -p Result --value dashboard-assistant-boot-import.service)\" = success"
    )
    machine.succeed(
        "test \"$(systemctl show -p ExecMainStatus --value dashboard-assistant-boot-import.service)\" = 0"
    )
    machine.fail("journalctl -b -u dashboard-assistant-boot-import | grep -q importing")
    machine.fail("test -e /var/lib/dashboard-assistant/seed-hash")
    machine.fail("test -e /var/lib/dashboard-assistant/provisioned")

    # The importer must be ordered ahead of the session, so that the kiosk
    # restart an import triggers cannot land mid-autologin. greetd is disabled
    # on this node, so the edge can only be asserted as declared, never
    # exercised — labgrid/test_first_boot.py does that part on hardware.
    machine.succeed(
        "systemctl show -p Before dashboard-assistant-boot-import.service | grep -q greetd.service"
    )

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

    # The import also marks the device provisioned, which is what skips the
    # waiting splash. It no longer stops the importer from running again --
    # that is the content hash's job, asserted across the reboots below.
    machine.wait_until_succeeds("test -e /var/lib/dashboard-assistant/provisioned", timeout=30)

    # ...and the hash of what was imported is recorded, since that is what makes
    # the next boot a no-op.
    machine.succeed("test -s /var/lib/dashboard-assistant/seed-hash")
    first_hash = machine.succeed("cat /var/lib/dashboard-assistant/seed-hash").strip()

    # A malformed file must fail loudly and must NOT be recorded as imported --
    # otherwise a typo is swallowed once and the device silently never picks the
    # file up again, which is the bug class this whole mechanism exists to kill.
    machine.succeed("cp /boot/dashboard-assistant.yaml /tmp/good.yaml")
    machine.succeed("printf 'ha_url: \"unterminated\\n' > /boot/dashboard-assistant.yaml")
    machine.fail("systemctl restart dashboard-assistant-boot-import.service")
    assert machine.succeed("cat /var/lib/dashboard-assistant/seed-hash").strip() == first_hash
    machine.succeed("cp /tmp/good.yaml /boot/dashboard-assistant.yaml")
    machine.succeed("systemctl reset-failed dashboard-assistant-boot-import.service")

    # ------------------------------------------------------------------
    # Hash gating across real reboots. runNixOSTest reuses the same qcow2
    # across shutdown()/start(), so state persists and these are genuine boots.
    # ------------------------------------------------------------------

    def reboot():
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("dashboard-assistant-daemon.service")
        # Every boot has to stay clean, not just the first one. The importer now
        # runs on all of them and is ordered against the session.
        machine.fail("journalctl -b | grep -q 'Breaking ordering cycle'")
        machine.fail("journalctl -b | grep -q 'Deleting job'")
        machine.succeed("systemctl --failed --no-legend | grep -q . && exit 1 || exit 0")

    # Boot 2: the file is untouched, so nothing may be imported — and a change
    # made on the device in the meantime has to survive. This is the whole point
    # of hashing the contents instead of re-applying unconditionally.
    machine.succeed(
        "sed -i s/198.51.100.7/198.51.100.8/ /var/lib/dashboard-assistant/runtime.env"
    )
    reboot()
    machine.succeed("journalctl -b -u dashboard-assistant-boot-import | grep -q unchanged")
    machine.succeed("grep -q 198.51.100.8 /var/lib/dashboard-assistant/runtime.env")

    # Boot 3: edit the file on the boot medium. The edit wins — this is
    # re-provisioning in place, which the old provisioned-marker gate made
    # impossible (and silently so).
    machine.succeed(
        "printf 'ha_url: \"http://198.51.100.9:8123\"\\n' > /boot/dashboard-assistant.yaml"
    )
    reboot()
    machine.wait_until_succeeds(
        "grep -q 198.51.100.9 /var/lib/dashboard-assistant/runtime.env", timeout=30
    )
    assert machine.succeed("cat /var/lib/dashboard-assistant/seed-hash").strip() != first_hash

    # Boot 4: delete the file. Nothing is applied and the device keeps what it
    # has — deleting the seed file must not reset a working device.
    machine.succeed("rm -f /boot/dashboard-assistant.yaml")
    reboot()
    machine.fail("journalctl -b -u dashboard-assistant-boot-import | grep -q importing")
    machine.succeed("grep -q 198.51.100.9 /var/lib/dashboard-assistant/runtime.env")

    # ------------------------------------------------------------------
    # The journal survives a reboot despite living in RAM. This is the half of
    # flash-wear.nix with no upstream module behind it, so it is the half that
    # has to be exercised rather than merely declared. Costs a real boot, so
    # it goes last.
    # ------------------------------------------------------------------

    mid = machine.succeed("cat /etc/machine-id").strip()
    machine.succeed("systemctl start dashboard-assistant-journal-sync.service")

    # Sealed files got archived...
    machine.succeed(f"ls /var/log/journal/{mid}/*@*.journal")
    # ...and the live one did NOT. Copying a journal journald is still
    # mmap-writing yields a torn file that journalctl reports as corrupt, so
    # the `@` in the glob is load-bearing, not cosmetic.
    machine.fail(f"test -e /var/log/journal/{mid}/system.journal")
    # Nothing may be left behind half-written: the archive is built with
    # copy-to-temp + rename precisely so a power cut cannot leave one of these.
    machine.fail(f"ls /var/log/journal/{mid}/.*.tmp")
    # The RAM copy is dropped once it is durable, which is what keeps the
    # tmpfs from growing and the next sync from re-copying.
    machine.fail(f"ls /run/log/journal/{mid}/*@*.journal")

    reboot()

    # The payoff, and the reason the archive goes to the standard persistent
    # path rather than somewhere of our own: a plain `journalctl -b -1` reads
    # it, with no -D and no --merge. If this breaks, the support story for a
    # misbehaving device ("send me the previous boot") breaks with it.
    assert int(machine.succeed("journalctl -b -1 --no-pager | wc -l").strip()) > 0
  '';
}
