"""First-boot health on real hardware.

The hardware counterpart of tests/first-boot.nix. The assertions that a VM can
make are deliberately the same ones, and for the same reasons — those comments are
worth reading before changing anything here. What this file adds is everything a
VM cannot reach: the Pi's boot chain (GPU firmware -> U-Boot -> extlinux ->
Linux), first-boot growfs on a real SD card, the FAT firmware partition, and
whether the board is drawing current at all.

    just hw-test                        flash, boot, assert
    pytest labgrid/ --lg-initial-state shell    skip the flash, board already up
    pytest labgrid/ -m "not needs_display"      headless bench
"""

import json
import os

import pytest


#: Where the sd-image declares the FAT partition, mounted or not.
FIRMWARE_MNT = "/boot/firmware"


def mount_fat(shell):
    """Mount the flashed card's FAT partition read-write and return its path.

    This is the partition a user sees when they put the card in a laptop, so it
    is the only place they can drop a seed file before first boot.

    Both steps are needed. nixpkgs' sd-image declares the filesystem
    `nofail,noauto`, so it is never mounted, and nothing creates the mount point
    either — `mount /boot/firmware` on an untouched device fails with "mount
    point does not exist".
    """
    shell.run_check(f"mkdir -p {FIRMWARE_MNT}")
    shell.run_check(f"mountpoint -q {FIRMWARE_MNT} || mount {FIRMWARE_MNT}")
    return FIRMWARE_MNT


def umount_fat(shell):
    shell.run(f"umount {FIRMWARE_MNT}")


# --------------------------------------------------------------------------- #
# Boot chain — only observable on the serial console
# --------------------------------------------------------------------------- #


def test_uboot_ran(console_log):
    """The GPU firmware must chainload U-Boot.

    The Pi's firmware cannot read extlinux.conf, so rpi5.nix sets
    hardware.raspberry-pi.firmware.uboot.enable to stage u-boot.bin on the FAT
    partition and point config.txt's kernel= at it. Without that there is no
    kernel on the firmware partition and the board flashes the green LED seven
    times against a black screen — a failure with no other symptom reachable from
    software.
    """
    assert "U-Boot 2" in console_log, "no U-Boot banner on the console"


def test_no_kernel_panic(console_log):
    assert "Kernel panic" not in console_log


# --------------------------------------------------------------------------- #
# The same failure classes tests/first-boot.nix guards, re-checked on hardware
# --------------------------------------------------------------------------- #


def test_no_systemd_ordering_cycle(shell):
    """A systemd ordering cycle "resolves" by deleting jobs — half the boot
    quietly never happens. This exact failure shipped once (journal-flush ordered
    against tmpfiles-setup); never again.
    """
    out, _, _ = shell.run("journalctl -b | grep -c 'Breaking ordering cycle'")
    assert out == ["0"], f"ordering cycle in the boot journal: {out}"
    out, _, _ = shell.run("journalctl -b | grep -c 'Deleting job'")
    assert out == ["0"], f"systemd deleted jobs during boot: {out}"


@pytest.mark.needs_display
def test_no_failed_units(shell):
    """Nothing may sit in the failed state after a clean boot."""
    failed, _, _ = shell.run("systemctl --failed --no-legend")
    assert failed == [], f"failed units: {failed}"


def test_daemon_state_dir(shell):
    """tmpfiles must have run and produced the daemon's state dir with the right
    owner and the session FIFOs. A root-owned dir here means the unprivileged
    daemon cannot persist anything (token, config, markers) and first-boot
    provisioning collapses.
    """
    owner = shell.run_check("stat -c %U /var/lib/dashboard-assistant")
    assert owner == ["dashboard-assistant"], owner
    shell.run_check("test -p /var/lib/dashboard-assistant/display.fifo")


def test_mdns_advertisement(shell):
    """How Home Assistant discovers the device."""
    shell.run_check("systemctl is-active avahi-daemon.service")
    shell.run_check(
        "grep -q _dashboard-assistant._tcp "
        "/etc/avahi/services/dashboard-assistant.service"
    )


def test_ha_api_identity(shell):
    """The HA API answers on the LAN port with the device identity, and advertises
    where TLS lives — which is how the integration knows to stop using the
    cleartext port.
    """
    out = shell.run_check("curl -fsS http://localhost:8081/api/ha/identify")
    ident = json.loads("".join(out))
    assert ident["node_id"].startswith("da_"), ident
    assert ident["tls_port"] == 8443, ident


def test_tls_listener(shell):
    """The TLS listener serves the same API, which proves the daemon generated and
    loaded a keypair on first boot. -k because the certificate is self-signed by
    design; the integration pins its fingerprint rather than validating a chain.
    """
    plain = json.loads(
        "".join(shell.run_check("curl -fsS http://localhost:8081/api/ha/identify"))
    )
    tls = json.loads(
        "".join(shell.run_check("curl -fsSk https://localhost:8443/api/ha/identify"))
    )
    assert tls["node_id"] == plain["node_id"], tls


def test_tls_key_not_world_readable(shell):
    """Unlike the HA token, nothing else on the device needs the private key."""
    mode = shell.run_check("stat -c %a /var/lib/dashboard-assistant/tls-key.pem")
    assert mode == ["600"], mode


def test_seed_file_provisioning(shell):
    """The headless field-provisioning path, exercised the way a user does it.

    Writes to /boot, which is where modules/core/configimport.nix actually looks,
    and confirms the import machinery works end to end on real hardware.

    Note that on this board /boot is a directory on the btrfs root, *not* the FAT
    partition a user can write to from another computer — so passing here does not
    mean seeding works in the field. That gap is
    test_seed_file_from_flashed_partition below.
    """
    fat = "/boot"
    shell.run_check(
        'printf \'ha_url: "http://198.51.100.7:8123"\\n\' '
        f"> {fat}/dashboard-assistant.yaml"
    )
    try:
        shell.run_check("systemctl restart dashboard-assistant-boot-import.service")

        # Read it back from the admin listener's info payload, which is where the
        # daemon surfaces the HA URL. (Not /api/state — that returns only the
        # splash state machine's current state, never the URL.)
        info = shell.run_check("curl -fsS http://localhost:8099/api/admin/info")
        assert "198.51.100.7" in "".join(info), info

        # ...and that it was persisted, not just held in memory.
        shell.run_check("grep -q 198.51.100.7 /var/lib/dashboard-assistant/runtime.env")

        # The import must also mark the device provisioned, so the boot importer
        # never re-runs.
        shell.run_check("test -e /var/lib/dashboard-assistant/provisioned")
    finally:
        # The card is reflashed next run anyway, but leaving a seed file behind
        # makes a --lg-initial-state session lie to the next one.
        shell.run(f"rm -f {fat}/dashboard-assistant.yaml")


# --------------------------------------------------------------------------- #
# Hardware-only
# --------------------------------------------------------------------------- #


def test_board_draws_power(plug):
    """The plug measures real current, so this separates "the board is not
    running" from "the console is misconfigured" — the two failures that otherwise
    look identical from a silent serial port.
    """
    watts = float(plug("draw"))
    assert watts > 0.5, f"board drawing {watts} W — is it plugged into the bench plug?"


def test_root_filesystem_grew(shell, image):
    """First boot resizes the root filesystem to fill the card, so one image fits
    any capacity (see rpi5.nix). No VM test covers it: there is no card to grow
    into. If growfs silently no-ops the device ships full.
    """
    if image is None:
        pytest.skip("no image path to compare against")

    image_bytes = os.path.getsize(image)
    out = shell.run_check("findmnt -bno SIZE /")
    fs_bytes = int(out[0])
    assert fs_bytes > image_bytes, (
        f"root filesystem is {fs_bytes} B, image was {image_bytes} B — "
        "first-boot growfs did not run"
    )


def test_firmware_partition_present(shell):
    """The card carries the FAT firmware partition, populated with config.txt and
    u-boot.bin — the boot chain rpi5.nix sets up.

    No VM test can cover this: first-boot.nix has no disk layout at all and just
    mkdir's a plain /boot.
    """
    labels = shell.run_check("lsblk -no LABEL,FSTYPE")
    assert any("FIRMWARE" in line and "vfat" in line for line in labels), labels

    fat = mount_fat(shell)
    try:
        shell.run_check(f"test -f {fat}/config.txt")
        shell.run_check(f"test -f {fat}/u-boot.bin")
    finally:
        umount_fat(shell)


def test_seed_file_from_flashed_partition(shell):
    """Provisioning the way docs/flash/seed.md tells a user to do it.

    Mount the flashed card's FAT partition, drop dashboard-assistant.yaml in its
    root, eject, boot. This is the whole point of testing on hardware: the harness
    owns the card through the SD-Mux, so it performs the literal user action
    rather than a stand-in for it.

    It used to be a strict xfail. modules/core/configimport.nix read only /boot,
    which on this board is a directory on the btrfs root — so the file landed
    somewhere the importer never looked, the unit was skipped by a
    ConditionPathExists, and nothing was logged. bootImport now falls back to
    mounting the FAT partition read-only (by the label configimport.nix takes from
    sdImage.firmwarePartitionName, so the two cannot drift), which is what this
    proves.

    Nothing is cleared before the import. The provisioned marker no longer gates
    the unit — re-import is gated on the seed file's content hash — and this file
    is new content, so the importer must act on it unprompted. A `rm -f
    .../provisioned` here would hide a regression in exactly that.

    The partition is unmounted before the importer runs, both because that is what
    ejecting a card looks like and because the importer mounts it itself.
    """
    fat = mount_fat(shell)
    try:
        shell.run_check(
            'printf \'ha_url: "http://198.51.100.42:8123"\\n\' '
            f"> {fat}/dashboard-assistant.yaml"
        )
    finally:
        umount_fat(shell)

    try:
        shell.run_check("systemctl restart dashboard-assistant-boot-import.service")
        info = shell.run_check("curl -fsS http://localhost:8099/api/admin/info")
        assert "198.51.100.42" in "".join(info), info
        shell.run_check("test -e /var/lib/dashboard-assistant/provisioned")
        # The hash of what was imported is recorded; that is what makes the next
        # boot a no-op instead of a re-import.
        shell.run_check("test -s /var/lib/dashboard-assistant/seed-hash")

        # And immediately re-running it must now do nothing, because the file has
        # not changed. Same mechanism a reboot relies on, without costing a boot.
        shell.run_check("systemctl restart dashboard-assistant-boot-import.service")
        log = shell.run_check(
            "journalctl -u dashboard-assistant-boot-import -n 5 --no-pager"
        )
        assert any("unchanged" in line for line in log), log
    finally:
        fat = mount_fat(shell)
        shell.run(f"rm -f {fat}/dashboard-assistant.yaml")
        umount_fat(shell)


def test_firmware_dropzone_files(shell):
    """The FAT partition explains itself.

    A user who opens this card sees 40-odd .dtb files, start.elf and u-boot.bin,
    and nothing saying a seed file belongs here — so the image stages a README
    and a commented example onto it (modules/core/configimport.nix). Hardware
    only: the staging happens in sd-image's populateFirmwareCommands, and it
    reaches the card through nixos-hardware's mkForce, which is fragile enough to
    be worth asserting on the real artifact.
    """
    fat = mount_fat(shell)
    try:
        shell.run_check(f"test -f {fat}/README.txt")
        shell.run_check(f"test -f {fat}/dashboard-assistant.yaml.example")

        # The README has to name the file a user must create.
        shell.run_check(f"grep -q dashboard-assistant.yaml {fat}/README.txt")

        # The example must not be able to provision anything if it is renamed
        # without being edited: every non-blank line is a comment.
        out = shell.run_check(
            f"grep -cvE '^[[:space:]]*(#|$)' {fat}/dashboard-assistant.yaml.example"
            " || true"
        )
        assert out == ["0"], f"example has uncommented keys: {out}"

        # The firmwareSize bump must not silently revert: 30 MiB left 4.49 MiB
        # free, which is less than one raspberrypifw bump.
        size = shell.run_check(
            "lsblk -bno SIZE,LABEL | awk '$2 == \"FIRMWARE\" { print $1 }'"
        )
        assert int(size[0]) > 60 * 1024 * 1024, f"FIRMWARE is only {size[0]} B"
    finally:
        umount_fat(shell)


@pytest.mark.needs_display
def test_kiosk_not_restarted_by_unchanged_seed(shell):
    """An import that applies nothing must not relaunch the session.

    The daemon restarts the kiosk whenever an import applies something
    (daemon/main.go handleImport), and its 8-second coalescing window does not
    cover the first restart after a daemon start — lastKioskRestart is the zero
    Time then, so the window has long since "expired". Hash-gating plus the
    importer's Before=greetd.service is what keeps a routine boot from visibly
    tearing the screen down and bringing it back.

    Deliberately measured as a *delta* around one no-op import rather than as
    "greetd started once this boot". An absolute count only holds on a boot
    where nothing was ever imported, and the seed tests above import twice on
    purpose — so the absolute form passed in the VM, failed here with
    greetd started 2 times, and was measuring test order rather than behaviour.

    No VM test can make this assertion at all: greetd is disabled there.
    """
    fat = mount_fat(shell)
    try:
        shell.run_check(
            'printf \'ha_url: "http://198.51.100.42:8123"\\n\' '
            f"> {fat}/dashboard-assistant.yaml"
        )
    finally:
        umount_fat(shell)

    def greetd_starts():
        out = shell.run_check(
            "journalctl -b -u greetd --no-pager | grep -c 'Started ' || true"
        )
        return int(out[0])

    try:
        # Import once so the file's hash is on record. This one *does* apply
        # something, so it legitimately restarts the kiosk.
        shell.run_check("systemctl restart dashboard-assistant-boot-import.service")
        # Outlast the coalescing window (8 s) so that restart has actually
        # landed and cannot be counted against the no-op below.
        shell.run_check("sleep 12")
        before = greetd_starts()
        # Guard against the delta below passing vacuously: on a board where
        # greetd never came up at all, 0 -> 0 satisfies the assertion for
        # entirely the wrong reason.
        assert before >= 1, (
            "greetd has not started this boot, so a restart delta proves "
            "nothing — is the display attached?"
        )

        # Now the same file again. Unchanged, so the importer must skip it
        # outright: no POST, so nothing to restart the session for.
        shell.run_check("systemctl restart dashboard-assistant-boot-import.service")
        log = shell.run_check(
            "journalctl -u dashboard-assistant-boot-import -n 5 --no-pager"
        )
        assert any("unchanged" in line for line in log), log

        # Long enough that a deferred restart would have fired by now.
        shell.run_check("sleep 10")
        after = greetd_starts()
        assert after == before, (
            f"greetd restarted during a no-op import ({before} -> {after}): the "
            "seed file was unchanged, so nothing should have been applied"
        )
    finally:
        fat = mount_fat(shell)
        shell.run(f"rm -f {fat}/dashboard-assistant.yaml")
        umount_fat(shell)


def test_seed_file_reimported_after_edit(shell, _bench):
    """Editing the seed file on the card re-provisions the device on the next boot.

    This is the behaviour the old provisioned-marker gate made impossible, and
    silently so. Costs a real boot, so it goes last — it invalidates where the
    console transcript is sitting for anything after it.
    """
    fat = mount_fat(shell)
    try:
        shell.run_check(
            'printf \'ha_url: "http://198.51.100.55:8123"\\n\' '
            f"> {fat}/dashboard-assistant.yaml"
        )
    finally:
        umount_fat(shell)

    try:
        # The same ShellDriver instance comes back: reboot() deactivates and
        # re-activates it rather than rebuilding it, so `shell` stays valid.
        _bench.reboot()
        shell.run_check(
            "grep -q 198.51.100.55 /var/lib/dashboard-assistant/runtime.env"
        )
        info = shell.run_check("curl -fsS http://localhost:8099/api/admin/info")
        assert "198.51.100.55" in "".join(info), info
    finally:
        fat = mount_fat(shell)
        shell.run(f"rm -f {fat}/dashboard-assistant.yaml")
        umount_fat(shell)
