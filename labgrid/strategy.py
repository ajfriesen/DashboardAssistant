"""labgrid strategy for the dashboard-assistant OS hardware bench.

Encodes the flash-and-boot dance once, so tests can just ask for what they need:

    off      board de-energised, console released
    flashed  card taken by the host, image dd'd onto it, card handed to the board
    booted   board powered up, the whole boot captured — no login attempted
    shell    logged in over the UART

`booted` exists so boot-chain assertions do not depend on a working login. That is
precisely when the serial transcript is most valuable: userspace broken, the
console on an unexpected tty, the prompt regex wrong.

Loaded via the `imports:` key in bench.yaml, which is what registers
DashboardAssistantStrategy with labgrid's target factory.
"""

import enum

import attr
from labgrid.factory import target_factory
from labgrid.step import step
from labgrid.strategy import Strategy, StrategyError
from labgrid.strategy.common import never_retry


class Status(enum.Enum):
    unknown = 0
    off = 1
    flashed = 2
    booted = 3
    shell = 4


@target_factory.reg_driver
@attr.s(eq=False)
class DashboardAssistantStrategy(Strategy):
    """Takes one Raspberry Pi from cold to a logged-in serial console."""

    bindings = {
        "power": "PowerProtocol",
        "mux": "USBSDMuxDriver",
        "storage": "USBStorageDriver",
        "console": "ConsoleProtocol",
        "shell": "ShellDriver",
    }

    # Path to the .img to flash. Left out of bench.yaml on purpose: the built
    # image's filename carries the release version, so conftest.py resolves it
    # (from --image, or by globbing result-rpi5-dev/) and assigns it here.
    image = attr.ib(
        default=None,
        validator=attr.validators.optional(attr.validators.instance_of(str)),
    )

    # How long to keep reading the console after power-on while reaching `booted`.
    boot_timeout = attr.ib(default=420.0, validator=attr.validators.instance_of(float))

    # How much console silence counts as "the boot has finished and the board is
    # sitting at a login prompt". Long enough to ride out the quiet stretches of
    # first boot — growing the filesystem and generating a TLS keypair both print
    # nothing while they work.
    boot_quiet_time = attr.ib(default=10.0, validator=attr.validators.instance_of(float))

    status = attr.ib(default=Status.unknown)

    @never_retry
    @step(args=["status"])
    def transition(self, status, *, step):  # pylint: disable=redefined-outer-name
        if not isinstance(status, Status):
            status = Status[status]

        if status == Status.unknown:
            raise StrategyError(f"can not transition to {status}")

        if status == self.status:
            step.skip("nothing to do")
            return

        # `booted` is implied by `shell`, so asking for it from a logged-in board
        # is a no-op rather than an error. Without this, requesting the console
        # transcript after something has already taken a shell would fail — and
        # the order tests happen to run in is not something they should have to
        # care about.
        if status == Status.booted and self.status == Status.shell:
            step.skip("already booted")
            return

        if status == Status.off:
            # Drop the shell and console before cutting power. The serial port
            # itself survives a power cut fine; a ShellDriver that still believes
            # it has a live shell does not, and its next command would hang until
            # the login timeout.
            self.target.deactivate(self.shell)
            self.target.deactivate(self.console)
            self.target.activate(self.power)
            self.power.off()

        elif status == Status.flashed:
            if not self.image:
                raise StrategyError(
                    "no image set — pass --image, or run `just build-rpi5-dev` so "
                    "conftest.py can find one under result-rpi5-dev/"
                )
            # Power down first: the card is about to be pulled out from under
            # whatever is running on the board.
            self.transition(Status.off)
            self.target.activate(self.mux)
            # "host" routes the card to this machine, where it shows up as the
            # mux's block device.
            self.mux.set_mode("host")
            self.target.activate(self.storage)
            # Whole-image dd, partition table included. disko emits a single
            # uncompressed .raw, which is what write_image needs — it does not
            # decompress, so it would happily dd a .zst onto the card verbatim.
            # (The sd-image builder used to produce .img.zst and the dev image
            # had to force that off; there is no such knob, or need, now.)
            # USBStorageDriver waits for the medium to enumerate after the mode
            # switch, so no sleep here.
            self.storage.write_image(self.image)
            self.target.deactivate(self.storage)
            # ...and hand the card back to the board.
            self.mux.set_mode("dut")

        elif status == Status.booted:
            self.transition(Status.flashed)
            # Open the console *before* energising, so the whole boot is there to
            # be read: GPU firmware, U-Boot, systemd-boot, kernel.
            self.target.activate(self.console)
            self.target.activate(self.power)
            self.power.on()
            # Then actually read it. labgrid only touches the serial port inside
            # read()/expect(), and the ConsoleLoggingReporter logs what those reads
            # return — so without this the console log would sit almost empty
            # until something else came along and read the port.
            #
            # settle() reads until the board goes quiet, which beats expecting a
            # specific marker: it makes no assumption about what the boot prints
            # or which tty the getty landed on, and it leaves nothing matched for
            # ShellDriver to trip over. Returning False just means the board was
            # still chattering when we ran out of patience — not fatal, since the
            # transcript is captured either way and it is the assertions' job to
            # say what went wrong.
            if not self.console.settle(self.boot_quiet_time, timeout=self.boot_timeout):
                self.logger.warning(
                    "console still busy after %ss — transcript may be partial",
                    self.boot_timeout,
                )

        elif status == Status.shell:
            self.transition(Status.booted)
            # ShellDriver answers the login prompt itself — credential and timeout
            # live in bench.yaml — then silences the kernel (the images boot with
            # loglevel=7, which would otherwise interleave with command output and
            # break prompt matching). settle() above consumed the login prompt
            # that was already printed; _await_login sends a newline when the
            # console is idle, which makes agetty print a fresh one.
            self.target.activate(self.shell)
            # The VM tests get this for free from wait_for_unit(); here it stops
            # assertions from racing units that are still starting. Deliberately
            # not run through run_check: `is-system-running` exits non-zero when
            # anything is degraded, and reporting *which* unit failed is the job
            # of the tests, not of the strategy.
            self.shell.run("systemctl is-system-running --wait", timeout=600)

        else:
            raise StrategyError(f"no transition found from {self.status} to {status}")

        self.status = status

    @step()
    def reboot(self, *, step):  # pylint: disable=unused-argument
        """Warm-reboot the board in place and come back to a logged-in shell.

        For assertions about what the device does *across* a boot — the seed
        file's content-hash gating, which only means anything if the second boot
        really is a second boot. A reflash would also prove it and costs ~4 GiB
        of dd plus a growfs, so this reuses the card as it stands.

        Must already be at `shell`: the reboot is issued from it.

        The shell driver is dropped before the board goes away, for the same
        reason the `off` transition does it — the serial port survives, but a
        ShellDriver that still believes it has a live shell does not, and its next
        command hangs until the login timeout. The console stays activated, so the
        second boot lands in the same transcript.
        """
        if self.status != Status.shell:
            raise StrategyError(f"reboot needs a shell, not {self.status}")

        # Fire and let go. systemd tears the console down mid-command, so the
        # prompt that would acknowledge this never arrives; a short timeout and a
        # swallowed error is the honest way to express that.
        try:
            self.shell.run("systemctl reboot", timeout=5)
        except Exception:  # noqa: BLE001 - the command cannot complete by design
            pass

        self.target.deactivate(self.shell)
        self.status = Status.booted

        if not self.console.settle(self.boot_quiet_time, timeout=self.boot_timeout):
            self.logger.warning(
                "console still busy after %ss — transcript may be partial",
                self.boot_timeout,
            )

        self.target.activate(self.shell)
        self.shell.run("systemctl is-system-running --wait", timeout=600)
        self.status = Status.shell

    @never_retry
    @step(args=["status"])
    def force(self, status, *, step):  # pylint: disable=redefined-outer-name
        """Claim a state without doing the work — `pytest --lg-initial-state shell`.

        The point is iterating on assertions against a board that is already up,
        without paying for a reflash every run. Nothing verifies the claim, so if
        it is wrong you get confusing failures rather than a clear error. Note that
        forcing `booted` or `shell` skips the console capture, so `console_log`
        will only hold whatever is read from then on.
        """
        if not isinstance(status, Status):
            status = Status[status]

        if status == Status.unknown:
            raise StrategyError(f"can not force state {status}")

        if status == Status.off:
            self.target.deactivate(self.shell)
            self.target.activate(self.power)
        elif status == Status.flashed:
            self.target.activate(self.power)
            self.target.activate(self.mux)
        elif status == Status.booted:
            self.target.activate(self.power)
            self.target.activate(self.console)
        elif status == Status.shell:
            self.target.activate(self.power)
            self.target.activate(self.console)
            self.target.activate(self.shell)
        else:
            raise StrategyError(f"no setup found for {status}")

        self.status = status


@target_factory.reg_driver
@attr.s(eq=False)
class QEMUStrategy(Strategy):
    """The same four states, for an x86_64 image booted under QEMU.

    Not a convenience: it is the only way the x86_64 image gets tested against
    anything resembling hardware. The bench has one Raspberry Pi 5 in it, and a
    second board is a purchase; a UEFI firmware, a GPT partition table, a real
    ESP, a btrfs root and first-boot growth are not. Everything in
    test_first_boot.py that is not specifically about the Pi's boot chain holds
    here too, and the tests say which is which with the `board` marker.

    The states mean what they do on the bench, with the hardware swapped out:

        off      no QEMU process
        flashed  a writable disk prepared from the image — the dd equivalent
        booted   QEMU started, the whole boot read off the emulated serial port
        shell    logged in over that serial port

    `flashed` is where the two differ most. There is no card and no mux, so
    "flash" means copying the image to a scratch disk and growing it — see
    bench.prepare_qemu_disk for why a copy is not optional and why it is grown.
    """

    bindings = {
        "qemu": "QEMUDriver",
        "shell": "ShellDriver",
    }

    # Path to the .raw to boot. Resolved by conftest.py, exactly as for the
    # bench strategy; the image's filename carries the release version.
    image = attr.ib(
        default=None,
        validator=attr.validators.optional(attr.validators.instance_of(str)),
    )

    # Shorter than the bench's 420 s — there is no SD card to be slow about —
    # but not as short as it first looks like it could be. First boot still
    # grows the filesystem and generates a TLS keypair, and both print nothing
    # at all while they work, so a quiet time of 5 s let `settle()` call the
    # boot finished while growpart was still running. The ShellDriver then
    # started pressing Enter at a console that was not at a login prompt yet,
    # and `never_retry` marked the strategy broken when the login timed out —
    # which skips every shell-dependent test and reports as a harness fault
    # rather than a slow boot. Same lesson as the bench: be patient through the
    # quiet stretches.
    boot_timeout = attr.ib(default=300.0, validator=attr.validators.instance_of(float))
    boot_quiet_time = attr.ib(default=10.0, validator=attr.validators.instance_of(float))

    status = attr.ib(default=Status.unknown)

    @never_retry
    @step(args=["status"])
    def transition(self, status, *, step):  # pylint: disable=redefined-outer-name
        if not isinstance(status, Status):
            status = Status[status]

        if status == Status.unknown:
            raise StrategyError(f"can not transition to {status}")

        if status == self.status:
            step.skip("nothing to do")
            return

        # Same reason as the bench strategy: asking for the transcript after
        # something has taken a shell must not be an error.
        if status == Status.booted and self.status == Status.shell:
            step.skip("already booted")
            return

        if status == Status.off:
            self.target.deactivate(self.shell)
            # Deactivating the driver kills the process and takes the machine
            # with it, so there is no separate power-off to do.
            self.target.deactivate(self.qemu)

        elif status == Status.flashed:
            if not self.image:
                raise StrategyError(
                    "no image set — pass --image, or run `just build-x86-dev` so "
                    "conftest.py can find one under result-x86-dev/"
                )
            self.transition(Status.off)
            # The disk has to exist before the driver is activated: QEMUDriver
            # resolves it from the environment's `images:` when it builds its
            # command line.
            import bench

            bench.prepare_qemu_disk(self.image)

        elif status == Status.booted:
            self.transition(Status.flashed)
            self.target.activate(self.qemu)
            self.qemu.on()
            if not self.qemu.settle(self.boot_quiet_time, timeout=self.boot_timeout):
                self.logger.warning(
                    "console still busy after %ss — transcript may be partial",
                    self.boot_timeout,
                )

        elif status == Status.shell:
            self.transition(Status.booted)
            self.target.activate(self.shell)
            self.shell.run("systemctl is-system-running --wait", timeout=600)

        else:
            raise StrategyError(f"no transition found from {self.status} to {status}")

        self.status = status

    @step()
    def reboot(self, *, step):  # pylint: disable=unused-argument
        """Warm-reboot the machine in place and come back to a logged-in shell.

        The counterpart of the bench strategy's reboot, and it has to be a real
        reset rather than a restart of QEMU: the scratch disk is rebuilt from
        the image on every `flashed`, so restarting the process would throw away
        the state the across-a-boot assertions exist to check.
        """
        if self.status != Status.shell:
            raise StrategyError(f"reboot needs a shell, not {self.status}")

        try:
            self.shell.run("systemctl reboot", timeout=5)
        except Exception:  # noqa: BLE001 - the command cannot complete by design
            pass

        self.target.deactivate(self.shell)
        self.status = Status.booted

        if not self.qemu.settle(self.boot_quiet_time, timeout=self.boot_timeout):
            self.logger.warning(
                "console still busy after %ss — transcript may be partial",
                self.boot_timeout,
            )

        self.target.activate(self.shell)
        self.shell.run("systemctl is-system-running --wait", timeout=600)
        self.status = Status.shell

    @never_retry
    @step(args=["status"])
    def force(self, status, *, step):  # pylint: disable=redefined-outer-name
        """Claim a state without doing the work — `pytest --lg-initial-state shell`.

        Less useful here than on the bench, where it exists to skip a reflash
        that costs minutes. A QEMU machine does not survive the end of the
        pytest process that started it, so there is rarely one already running
        to attach to. Kept for symmetry.
        """
        if not isinstance(status, Status):
            status = Status[status]

        if status == Status.unknown:
            raise StrategyError(f"can not force state {status}")

        if status == Status.off:
            self.target.deactivate(self.shell)
        elif status == Status.flashed:
            pass
        elif status == Status.booted:
            self.target.activate(self.qemu)
        elif status == Status.shell:
            self.target.activate(self.qemu)
            self.target.activate(self.shell)
        else:
            raise StrategyError(f"no setup found for {status}")

        self.status = status
