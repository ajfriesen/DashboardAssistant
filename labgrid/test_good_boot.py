"""Automatic rollback, armed on real hardware (docs/adr/0009).

The hardware counterpart of tests/good-boot.nix, and it exists because the VM
test cannot answer the Raspberry Pi half of the question. Boot counting works by
systemd-boot setting LoaderBootCountPath, a volatile EFI variable, at runtime.
On the Pi the UEFI environment is U-Boot's, and U-Boot's own documentation says
"as of U-Boot v2020.10 UEFI variables cannot be set at runtime" — which is
already why `bootctl` installs with `--no-variables` here
(modules/hardware/rpi-disk-image.nix). Whether that sentence also means
systemd-boot cannot set a *volatile* variable while boot services are still
live, and whether Linux can then read it back through efivarfs, is not something
a VM with OVMF in it can be asked.

So these assertions are Pi-marked and skip themselves on the QEMU x86 target,
where the same ground is covered by `nix build .#checks.x86_64-linux.good-boot`.

What is checked is that the mechanism is *armed*, not that a rollback happens: a
real rollback costs four boots of a board that takes minutes to flash, and the
sequence itself is already asserted in the VM test. The useful thing to learn
from a board is whether boot counting is live at all, because every way it can
be dead is silent — no counter is written, nothing is ever blessed, no unit
fails, and the device simply has no safety net under its updates while appearing
to have one.
"""

import pytest

#: Where systemd-boot records which boot entry carries this boot's counter. The
#: GUID is systemd's loader interface vendor GUID, fixed by
#: https://systemd.io/BOOT_LOADER_INTERFACE/ — not a per-device value.
BOOT_COUNT_PATH_VAR = (
    "/sys/firmware/efi/efivars/"
    "LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
)


@pytest.mark.board("rpi4", "rpi5")
def test_the_loader_counted_this_boot(shell):
    """systemd-boot must have set LoaderBootCountPath.

    The variable is the entire contract between the loader and userland: it
    names the entry whose counter this boot is spending. Absent, nothing
    downstream happens and nothing complains — systemd-bless-boot's generator
    simply does not enable the service, so there is no failed unit to find and
    no counter on the ESP to notice.

    This is the assertion that settles the concern
    modules/hardware/rpi-disk-image.nix raises: the loader was installed with
    --no-variables at the removable fallback path, and if that cost it runtime
    variable access then automatic rollback is off on this board no matter what
    the configuration says.
    """
    shell.run_check(f"test -e {BOOT_COUNT_PATH_VAR}")


@pytest.mark.board("rpi4", "rpi5")
def test_this_boot_was_blessed(shell):
    """The good-boot gate must have passed and the boot been marked good.

    Two units in one assertion because neither means anything alone:
    ha-boot-health is the project's definition of a good boot
    (modules/core/good-boot.nix), and systemd-bless-boot is what acts on it.
    Both are oneshots with RemainAfterExit, so "active" is the record that they
    ran and succeeded.

    A board that reaches this test is reachable over its network by definition,
    so a failure here is the gate being wrong about a device that is fine —
    which is the expensive direction of wrong. It would spend a freshly
    installed release's three attempts and roll back a working update.
    """
    shell.run_check("systemctl is-active --quiet ha-boot-health.service")
    shell.run_check("systemctl is-active --quiet systemd-bless-boot.service")


@pytest.mark.board("rpi4", "rpi5")
def test_no_entry_is_left_counting(shell):
    """No boot entry on the ESP may still carry a counter.

    Blessing removes the "+N" suffix from the entry's filename, so a flashed
    board that has reached a good boot must have none left. A leftover counter
    means the bless never happened — and an entry that keeps its counter is one
    that will eventually be marked bad and skipped, on a board where nothing is
    actually wrong.

    `ls` rather than a glob tested with `test -e`: a glob that matches nothing
    is passed through verbatim by the shell, so `test -e '...+*.conf'` would
    quietly report "no such file" either way round.
    """
    entries = shell.run_check("ls /boot/loader/entries")
    counting = [name for name in entries if "+" in name]
    assert not counting, (
        f"boot entries still carry a counter: {counting}. This boot was never "
        "blessed, so systemd-boot will spend the remaining attempts and fall "
        "back to an older generation even though this one is healthy. Check "
        "ha-boot-health.service and systemd-bless-boot.service."
    )
