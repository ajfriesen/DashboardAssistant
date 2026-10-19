"""Unit tests for preflight.py's verdicts — no bench, no board, no network.

The preflight exists to say "the bench is sick" instead of letting a sick bench
be read as a bad image, so its verdicts are exactly the part worth testing
without a bench attached.
"""

import preflight


# --------------------------------------------------------------------------- #
# Is there a card in the mux?
# --------------------------------------------------------------------------- #


def test_a_non_zero_medium_size_means_a_card_is_present():
    check = preflight.card_verdict("30535680")
    assert check.status == "ok"
    assert "GiB" in check.detail


def test_a_zero_medium_size_means_an_empty_slot():
    check = preflight.card_verdict("0")
    assert check.status == "fail"
    assert "no card" in check.detail.lower()


def test_an_unreadable_medium_size_is_a_failure_not_a_crash():
    check = preflight.card_verdict("cat: /sys/block/sdb/size: No such file")
    assert check.status == "fail"


# --------------------------------------------------------------------------- #
# Are the probe and the mux on the same USB controller?
# --------------------------------------------------------------------------- #

PROBE_USB1 = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/tty/ttyACM0"
MUX_USB1 = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-4/1-4:1.0/host4/target4:0:0"
MUX_USB2 = "/sys/devices/pci0000:00/0000:00:0d.0/usb2/2-1/2-1:1.0/host4/target4:0:0"


def test_separate_controllers_are_healthy():
    check = preflight.controller_verdict(PROBE_USB1, MUX_USB2)
    assert check.status == "ok"
    assert "usb1" in check.detail and "usb2" in check.detail


def test_a_shared_controller_warns_rather_than_fails():
    """A shared controller cost this bench 34% of its serial bytes once, but it is
    not always fatal and on a single-controller host it cannot be avoided. The
    byte-loss measurement is the authority; this only says where to look."""
    check = preflight.controller_verdict(PROBE_USB1, MUX_USB1)
    assert check.status == "warn"
    assert "usb1" in check.detail


def test_an_unrecognisable_path_does_not_claim_health():
    assert preflight.controller_verdict("not-a-sysfs-path", MUX_USB2).status == "warn"


# --------------------------------------------------------------------------- #
# How much of the serial console actually arrives?
# --------------------------------------------------------------------------- #


def test_every_line_intact_is_healthy():
    check = preflight.serial_verdict(40, 40)
    assert check.status == "ok"
    assert "40/40" in check.detail


def test_lost_bytes_fail_and_name_usb_topology():
    check = preflight.serial_verdict(23, 40)
    assert check.status == "fail"
    assert "23/40" in check.detail
    assert "USB topology" in check.detail


def test_an_unmeasured_console_is_reported_as_unmeasured():
    check = preflight.serial_verdict(None, 40)
    assert check.status == "skip"
    assert "not measured" in check.detail.lower()


# --------------------------------------------------------------------------- #
# The overall verdict
# --------------------------------------------------------------------------- #


def ck(status):
    return preflight.Check(name=status, status=status, detail="…")


def test_all_ok_is_a_healthy_bench():
    assert preflight.is_healthy([ck("ok"), ck("ok")])


def test_a_warning_alone_does_not_make_the_bench_unhealthy():
    assert preflight.is_healthy([ck("ok"), ck("warn"), ck("skip")])


def test_any_failure_makes_the_bench_unhealthy():
    assert not preflight.is_healthy([ck("ok"), ck("fail")])


def test_the_report_says_bench_and_names_every_check():
    report = preflight.report([ck("ok"), ck("fail")])
    assert "bench" in report.lower()
    assert report.count("\n") >= 2


# --------------------------------------------------------------------------- #
# The medium does not appear the instant the mux is switched
# --------------------------------------------------------------------------- #


class Reads:
    """A fake `cat /sys/block/<dev>/size` that returns a scripted sequence."""

    def __init__(self, *values):
        self.values = list(values)
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return self.values[min(self.calls - 1, len(self.values) - 1)]


def test_a_medium_that_is_already_there_is_not_waited_for():
    read = Reads("31116288")
    slept = []
    assert preflight.read_medium_size(read, sleep=slept.append) == "31116288"
    assert read.calls == 1
    assert slept == []


def test_a_medium_that_is_still_enumerating_is_waited_for():
    """Measured on this bench: the block device reports 0 for the first second or
    so after the mux is switched, then its real size. Reading once gets a false
    "the slot is empty" — which is the worst answer this tool can give, because
    it sends someone looking for a card that is already in it."""
    read = Reads("0", "0", "31116288")
    assert preflight.read_medium_size(read, sleep=lambda _: None) == "31116288"
    assert read.calls == 3


def test_a_medium_that_never_appears_gives_up_and_says_zero():
    read = Reads("0")
    assert preflight.read_medium_size(read, attempts=4, sleep=lambda _: None) == "0"
    assert read.calls == 4


def test_an_unreadable_medium_is_returned_for_the_verdict_to_judge():
    read = Reads("cat: /sys/block/sdb/size: No such file")
    out = preflight.read_medium_size(read, attempts=2, sleep=lambda _: None)
    assert preflight.card_verdict(out).status == "fail"
