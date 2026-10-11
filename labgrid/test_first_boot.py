"""First-boot health on real hardware.

The hardware counterpart of tests/first-boot.nix. The assertions that a VM can
make are deliberately the same ones, and for the same reasons — those comments are
worth reading before changing anything here. What this file adds is everything a
VM cannot reach: the Pi's boot chain (GPU firmware -> U-Boot's UEFI loader ->
systemd-boot -> Linux), first-boot growfs on a real SD card, the ESP that
carries both the Raspberry Pi firmware and the bootloader, and whether the board
is drawing current at all.

    just hw-test                        flash, boot, assert
    pytest labgrid/ --lg-initial-state shell    skip the flash, board already up
    pytest labgrid/ -m "not needs_display"      headless bench
"""

import json
import os

import pytest


#: The FAT partition a user sees when they put the card in a laptop, and the
#: only place they can drop a seed file before first boot. It is now the EFI
#: system partition, mounted at /boot on every target — under the old sd-image
#: layout it was a separate, never-mounted partition at /boot/firmware, which is
#: why these helpers used to have to mount it by hand (and mkdir the mount point
#: first, because nothing created it).
BOOT_MNT = "/boot"


def kiosk_uid(shell):
    """The kiosk user's uid, for the paths under its logind runtime dir.

    Not hardcoded: the user is declared without an explicit uid
    (modules/core/default.nix), so NixOS allocates it and the number is not
    part of any contract.
    """
    return shell.run_check("id -u kiosk")[0]


def mount_fat(shell):
    """Return the mounted FAT partition.

    Kept as a function so the seed-file tests below read the same as they did
    when this had real work to do. /boot is a normal fstab entry now, so the
    only thing worth doing is failing loudly if it somehow is not mounted.
    """
    shell.run_check(f"mountpoint -q {BOOT_MNT}")
    return BOOT_MNT


def umount_fat(shell):
    """No-op: /boot stays mounted. Retained so callers need no restructuring."""


# --------------------------------------------------------------------------- #
# Boot chain — only observable on the serial console
# --------------------------------------------------------------------------- #


def test_uboot_ran(console_log):
    """The GPU firmware must chainload U-Boot.

    U-Boot is here to provide the UEFI environment systemd-boot runs in, so
    rpi-disk-image.nix sets hardware.raspberry-pi.firmware.uboot.enable to stage
    u-boot.bin onto the ESP and point config.txt's kernel= at it. Without that
    there is no kernel on the FAT partition and the board flashes the green LED
    seven times against a black screen — a failure with no other symptom
    reachable from software.
    """
    assert "U-Boot 2" in console_log, "no U-Boot banner on the console"


def test_uboot_handed_off_to_systemd_boot(console_log):
    """U-Boot's EFI bootmanager must find \\EFI\\BOOT\\BOOTAA64.EFI.

    This is the hinge of the whole boot chain and it is only visible here: if
    `bootctl install` wrote the loader somewhere U-Boot does not scan, or the ESP
    came out with the wrong partition type, U-Boot drops to its prompt instead
    and the board never reaches Linux.
    """
    assert "efi_mgr" in console_log, "U-Boot did not boot a bootflow via efi_mgr"


def test_kernel_got_the_firmware_device_tree(shell):
    """The firmware-merged device tree has to survive the U-Boot -> EFI handoff.

    start*.elf merges the config.txt dtoverlays (vc4-kms-v3d among them) into the
    DTB and hands it to U-Boot, which passes it on through the EFI configuration
    table. systemd-boot's installDeviceTree is deliberately off so that nothing
    replaces it with a single flat DTB, which would silently drop every overlay.

    Asserted against the running system rather than the console log on purpose.
    The kernel does announce this ("efi: EFI v2.11 by Das U-Boot", "Machine
    model: Raspberry Pi 5 Model B Rev 1.1") but both are KERN_INFO, so at the
    default loglevel=4 neither reaches the console — and grepping dmesg for them
    would make this test a hostage of how verbose the image happens to be.
    /sys is the state itself.

    The failure mode is quiet: the kernel boots on a generic device tree, the
    machine model is wrong and v3d never probes, so the kiosk falls back to
    software rendering with nothing logged as an error. See also
    test_gpu_render_node below.
    """
    # Booted through UEFI (U-Boot's EFI loader), not via extlinux.
    shell.run_check("test -d /sys/firmware/efi")

    # ...and the device tree it was handed is the board's, not a generic one.
    model = shell.run_check("tr -d '\\0' < /sys/firmware/devicetree/base/model")
    assert model and model[0].startswith("Raspberry Pi"), model


def test_gpu_render_node(shell):
    """v3d must have probed, which only happens if the vc4-kms-v3d overlay from
    config.txt made it into the device tree the kernel booted on.

    This is the overlay that costs the most if it is silently lost: Chromium
    falls back to software rendering and the panel just feels slow, with nothing
    in the logs calling it an error.
    """
    shell.run_check("test -e /dev/dri/renderD128")
    drivers = shell.run_check("cat /sys/class/drm/card*/device/uevent | grep ^DRIVER=")
    assert any("v3d" in d or "vc4" in d for d in drivers), drivers


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


def test_boot_partition_is_the_esp(shell):
    """/boot is the vfat EFI system partition, carrying both halves of the boot
    chain: the Raspberry Pi firmware (config.txt, u-boot.bin) and systemd-boot.

    No VM test can cover this: first-boot.nix has no disk layout at all and just
    mkdir's a plain /boot. And the partition *type* is load-bearing rather than
    cosmetic — `bootctl` refuses to install into anything that is not an ESP
    ("has wrong type for an EFI System Partition"), so a layout change that
    quietly reverted partition 1 to Microsoft basic data would break the next
    update rather than this boot.
    """
    assert shell.run_check("findmnt -no FSTYPE /boot") == ["vfat"]
    assert shell.run_check(
        "lsblk -no PARTTYPENAME $(findmnt -no SOURCE /boot)"
    ) == ["EFI System"]

    fat = mount_fat(shell)
    # The Raspberry Pi half...
    shell.run_check(f"test -f {fat}/config.txt")
    shell.run_check(f"test -f {fat}/u-boot.bin")
    shell.run_check(f"test -d {fat}/overlays")
    # ...and the UEFI half, at the removable fallback path U-Boot scans for.
    shell.run_check(f"test -f {fat}/EFI/BOOT/BOOTAA64.EFI")
    shell.run_check(f"test -d {fat}/loader/entries")


def test_root_has_subvolumes(shell):
    """The root is btrfs with the same @ / @nix split as the x86 image.

    Under the sd-image builder the Pi root was a flat btrfs — make-btrfs-fs
    could not emit subvolumes — so this is the assertion that the Pi really is
    on the shared disko layout now and not on something that merely resembles
    it.
    """
    assert shell.run_check("findmnt -no FSTYPE /") == ["btrfs"]
    subvols = shell.run_check("btrfs subvolume list / | awk '{print $NF}'")
    assert "@" in subvols, subvols
    assert "@nix" in subvols, subvols


def test_journal_is_in_ram(shell):
    """The journal lives on tmpfs, not on the card.

    Hardware matters here in a way it does not for most of this file: the VM
    counterpart asserts the same thing, but a VM has no flash to wear and no
    real card to lose. On a board this is the single biggest write source there
    is — 2.87 GB in one boot, once (modules/core/sendspin.nix) — so the
    assertion is cheap and the regression is expensive and invisible.
    """
    assert shell.run_check("findmnt -no FSTYPE -T /run/log/journal") == ["tmpfs"]
    shell.run_check("grep -qx 'Storage=volatile' /etc/systemd/journald.conf")

    # journald itself must not be writing to flash. The sync unit archives
    # sealed files there, so the directory may well exist by now — what must
    # never exist is a LIVE journal on the card, which is what Storage=persistent
    # would give back.
    mid = shell.run_check("cat /etc/machine-id")[0]
    shell.run_check(f"test ! -e /var/log/journal/{mid}/system.journal")

    # Both halves of the mechanism have to be armed, not merely installed.
    shell.run_check("systemctl is-active dashboard-assistant-journal-sync.timer")
    shell.run_check(
        "systemctl is-active dashboard-assistant-journal-sync-shutdown.service"
    )


def test_nix_builds_outside_the_tmpfs(shell):
    """A substituter miss during an on-device update must not build in RAM.

    This is the one failure in the flash-wear work that bricks a board instead
    of merely wearing it: /tmp on tmpfs, plus a 2 GB board, plus one
    unsubstituted derivation equals ENOSPC in the middle of nixos-rebuild
    switch, on something screwed to a wall. No VM test can see it — the VM has
    as much RAM as we hand it and no binary cache to miss.
    """
    assert shell.run_check("findmnt -no FSTYPE /tmp") == ["tmpfs"]
    assert shell.run_check("nix config show build-dir") == ["/var/tmp"]
    # /var/tmp has to be on real storage, or the setting bought nothing.
    assert shell.run_check("findmnt -no FSTYPE -T /var/tmp") == ["btrfs"]


@pytest.mark.needs_display
def test_browser_cache_is_in_ram(shell):
    """Chromium's caches are on tmpfs, and nothing cache-shaped is left on flash.

    Hardware only, and not incidentally: tests/first-boot.nix force-disables
    greetd (without a GPU Chromium crash-loops and buries the signals that test
    is about), so no VM test ever starts a browser. checks.kiosk-flash-flags
    asserts the flags are *passed*; only a real session proves they took effect.
    """
    cache = f"/run/user/{kiosk_uid(shell)}/kiosk-cache"
    assert shell.run_check(f"findmnt -no FSTYPE -T {cache}") == ["tmpfs"]
    dirs = shell.run_check(f"find {cache} -maxdepth 4 -type d -name '*Cache*' || true")
    assert any("Cache" in d for d in dirs), dirs

    # The old on-flash location must not be filling up behind our back. A few
    # stray KiB from an earlier build are fine; a real cache is not.
    out = shell.run_check("du -sk /home/kiosk/.cache/chromium 2>/dev/null || echo 0")
    assert int(out[0].split()[0]) < 1024, out


@pytest.mark.needs_display
def test_browser_cache_stays_within_its_cap(shell):
    """--disk-cache-size has to actually bound the tmpfs footprint.

    Those pages are only reclaimable because zram exists (memory.nix), and shmem
    is charged to the cgroup that faults it in — so an uncapped cache in /tmp
    becomes the memory pressure systemd-oomd then kills the kiosk session for,
    in a loop, with the files surviving the kill. Only reproducible with a real
    session rendering a real dashboard.
    """
    cache = f"/run/user/{kiosk_uid(shell)}/kiosk-cache"
    out = shell.run_check(f"du -sm {cache} | cut -f1")
    assert int(out[0]) < 96, f"browser cache is {out[0]} MiB, cap is 64 MiB"


@pytest.mark.needs_display
def test_screenshot_lands_on_tmpfs(shell):
    """The grim handoff frame goes to /run, never to the state dir on flash.

    Needs a Wayland session by construction: the writer is an in-session agent
    running as `kiosk` and the reader is the daemon running as
    dashboard-assistant, in two languages and two users. The VM test can assert
    the directory exists; only hardware can assert the handoff happens.

    Poked through the FIFO directly rather than over the HTTP API because the
    HA screenshot endpoint is authenticated and the admin listener has no
    screenshot route — this is the same poke the daemon makes.
    """
    shell.run("rm -f /run/dashboard-assistant/screenshot.jpg")
    shell.run_check(
        "printf 'shot\n' > /var/lib/dashboard-assistant/screenshot.fifo"
    )
    shell.run_check(
        "sh -c 'for i in $(seq 50); do "
        "test -s /run/dashboard-assistant/screenshot.jpg && exit 0; "
        "sleep 0.2; done; exit 1'"
    )
    assert shell.run_check("findmnt -no FSTYPE -T /run/dashboard-assistant") == [
        "tmpfs"
    ]
    # ...and the old path stays empty. A frame here means the Nix writer and the
    # Go reader drifted apart and the card is taking a JPEG per HA poll again.
    shell.run_check("test ! -e /var/lib/dashboard-assistant/screenshot.jpg")


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
    only: the staging rides on systemd-boot's extraFiles, i.e. on the bootloader
    installer having run inside disko's image build, which is worth asserting on
    the real artifact.
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

        # The ESP must stay big enough for the firmware *plus* a kernel and
        # initrd per retained generation (~70 MiB each, configurationLimit 3).
        # dashboardAssistant.diskLayout.espSize is 512 MiB for that reason, and
        # a silent revert to the old 64 MiB would not fail until the third
        # update.
        size = shell.run_check("lsblk -bno SIZE $(findmnt -no SOURCE /boot)")
        assert int(size[0]) > 400 * 1024 * 1024, f"ESP is only {size[0]} B"
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


def test_journal_archive_survives_a_reboot(shell, _bench):
    """The journal is in RAM, and the previous boot is still readable afterwards.

    This is the half of modules/core/flash-wear.nix with no upstream NixOS
    module behind it, so it is the half that has to be exercised rather than
    declared. The payoff being asserted is specifically that a *plain*
    `journalctl -b -1` finds the archive — no -D, no --merge — because "send me
    journalctl -b -1" is the entire remote-support story for a misbehaving
    device, and Storage=volatile is exactly the setting that would quietly end
    it.

    Costs a real boot, so it goes after test_seed_file_reimported_after_edit
    and invalidates the console transcript for anything following it.
    """
    mid = shell.run_check("cat /etc/machine-id")[0]
    shell.run_check("systemctl start dashboard-assistant-journal-sync.service")

    # Sealed files archived...
    shell.run_check(f"ls /var/log/journal/{mid}/*@*.journal")
    # ...the live one not (copying an mmap-written journal yields a torn file
    # journalctl reports as corrupt, so the `@` in the glob is load-bearing)...
    shell.run_check(f"test ! -e /var/log/journal/{mid}/system.journal")
    # ...and no half-written temp file left behind, which is what the
    # copy-to-temp-then-rename in the sync script buys.
    leftovers = shell.run_check(
        f"find /var/log/journal/{mid} -maxdepth 1 -name '.*.tmp'"
    )
    assert leftovers == [], leftovers

    # On btrfs the archive directory must be NOCOW, or the journal becomes the
    # worst case the filesystem has: many small appends, each a fresh extent.
    # This is the trick that finally works -- journald never creates anything
    # under /var/log/journal when Storage=volatile, so the sync script owns the
    # directory and can set +C before the first file lands. See the three
    # reverted attempts named in flash-wear.nix's header.
    attrs = shell.run_check(f"lsattr -d /var/log/journal/{mid}")
    assert "C" in attrs[0].split()[0], attrs

    _bench.reboot()

    out = shell.run_check("journalctl -b -1 --no-pager | wc -l")
    assert int(out[0]) > 0, "previous boot's journal was lost across a reboot"
