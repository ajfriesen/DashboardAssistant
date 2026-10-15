"""Unit tests for bench.py's image handling — no bench, no board, no network."""

import os

import pytest

import bench

#: The GPT repair is exercised on its own below; these tests use stub files with
#: no partition table, where running it would be meaningless.
NO_REPAIR = lambda path: None  # noqa: E731


def test_the_scratch_disk_carries_the_image_bytes(tmp_path):
    image = tmp_path / "image.raw"
    image.write_bytes(b"BOOTSECTOR" + b"\0" * 1014)
    disk = tmp_path / "scratch.raw"

    bench.prepare_qemu_disk(str(image), dest=str(disk), size=4096, repair_gpt=NO_REPAIR)

    assert disk.read_bytes()[:10] == b"BOOTSECTOR"


def test_the_scratch_disk_is_grown_so_growfs_has_work(tmp_path):
    """A disk the same size as the image leaves first-boot growth nothing to do,
    so the one assertion that only hardware can make would pass vacuously."""
    image = tmp_path / "image.raw"
    image.write_bytes(b"\0" * 1024)
    disk = tmp_path / "scratch.raw"

    bench.prepare_qemu_disk(str(image), dest=str(disk), size=8192, repair_gpt=NO_REPAIR)

    assert disk.stat().st_size == 8192


def test_the_scratch_disk_is_writable_even_though_the_image_is_not(tmp_path):
    """The image comes out of the Nix store, which is read-only and owned by
    root. QEMU writes to its disk in place, so a copy is not optional."""
    image = tmp_path / "image.raw"
    image.write_bytes(b"\0" * 1024)
    os.chmod(image, 0o444)
    disk = tmp_path / "scratch.raw"

    bench.prepare_qemu_disk(str(image), dest=str(disk), size=4096, repair_gpt=NO_REPAIR)

    assert os.access(disk, os.W_OK)


def test_a_scratch_disk_smaller_than_the_image_is_refused(tmp_path):
    """Truncating down would silently cut the image in half."""
    image = tmp_path / "image.raw"
    image.write_bytes(b"\0" * 8192)
    disk = tmp_path / "scratch.raw"

    with pytest.raises(ValueError, match="smaller"):
        bench.prepare_qemu_disk(
            str(image), dest=str(disk), size=1024, repair_gpt=NO_REPAIR
        )


def test_the_scratch_disk_is_replaced_not_appended_to(tmp_path):
    """Two runs in a row must not leave the previous run's filesystem behind —
    that is how a test passes against state it did not create."""
    image = tmp_path / "image.raw"
    image.write_bytes(b"NEW" + b"\0" * 1021)
    disk = tmp_path / "scratch.raw"
    disk.write_bytes(b"OLD" + b"\xff" * 8189)

    bench.prepare_qemu_disk(str(image), dest=str(disk), size=4096, repair_gpt=NO_REPAIR)

    data = disk.read_bytes()
    assert data[:3] == b"NEW"
    assert len(data) == 4096
    assert b"\xff" not in data


# --------------------------------------------------------------------------- #
# Which variables an environment file actually needs
# --------------------------------------------------------------------------- #


def test_the_bench_environment_needs_the_coordinator_and_the_place():
    text = """
    targets:
      main:
        resources:
          - RemotePlace:
              name: !template $LG_PLACE
    """
    assert bench.templated_variables(text) == {"LG_PLACE"}


def test_several_variables_are_all_found():
    text = "a: !template $LG_PLACE\nb: !template $LG_OVMF_FD\n"
    assert bench.templated_variables(text) == {"LG_PLACE", "LG_OVMF_FD"}


def test_an_environment_that_templates_nothing_needs_nothing():
    """The QEMU target has no place and no coordinator, so demanding them would
    make a target that needs no bench refuse to run without one."""
    assert bench.templated_variables("targets:\n  main:\n    drivers: []\n") == set()


def test_braced_and_repeated_references_are_handled():
    text = "a: !template ${LG_PLACE}\nb: !template $LG_PLACE/x\n"
    assert bench.templated_variables(text) == {"LG_PLACE"}


def test_only_labgrid_variables_count():
    """labgrid substitutes LG_* and BASE only, so nothing else can be required —
    demanding it would be asking for something that could never be used."""
    text = "a: !template $OVMF_FD\nb: !template $BASE/x\nc: !template $LG_PLACE\n"
    assert bench.templated_variables(text) == {"LG_PLACE"}


# --------------------------------------------------------------------------- #
# A grown GPT disk is not a valid GPT disk until its backup header moves
# --------------------------------------------------------------------------- #


def test_the_grown_disk_has_its_gpt_repaired(tmp_path):
    """Growing the disk strands the GPT backup header in the middle, and Linux
    rejects the whole table rather than tolerating it: the boot then dies in the
    initrd waiting for a root partition it can no longer see. Measured, not
    theorised — this is what the first QEMU boot actually did."""
    image = tmp_path / "image.raw"
    image.write_bytes(b"\0" * 1024)
    disk = tmp_path / "scratch.raw"
    repaired = []

    bench.prepare_qemu_disk(
        str(image), dest=str(disk), size=4096, repair_gpt=repaired.append
    )

    assert repaired == [str(disk)]


def test_the_gpt_repair_moves_the_backup_header_to_the_new_end():
    ran = []
    bench.move_gpt_backup_header("/tmp/x.raw", run=ran.append)
    assert ran[0][0] == "sgdisk"
    assert "--move-second-header" in ran[0]
    assert ran[0][-1] == "/tmp/x.raw"


# --------------------------------------------------------------------------- #
# Which board an environment declares, read without labgrid
# --------------------------------------------------------------------------- #


def test_the_declared_board_is_read_from_the_environment(tmp_path):
    """Needed at collection time, before labgrid builds an Environment: a test
    for another board has to be skipped *before* the session-scoped shell
    fixture flashes and boots something on its behalf."""
    env = tmp_path / "env.yaml"
    env.write_text("targets:\n  main:\n    drivers: []\noptions:\n  board: x86_64\n")
    assert bench.declared_board(str(env)) == "x86_64"


def test_the_templates_in_an_environment_do_not_break_the_board_lookup(tmp_path):
    """The real files are full of `!template $LG_*`, which a plain YAML loader
    refuses outright."""
    env = tmp_path / "env.yaml"
    env.write_text(
        "targets:\n  main:\n    resources:\n"
        "      - RemotePlace:\n          name: !template $LG_PLACE\n"
        "options:\n  board: rpi5\n"
    )
    assert bench.declared_board(str(env)) == "rpi5"


def test_an_environment_with_no_board_reads_as_none(tmp_path):
    env = tmp_path / "env.yaml"
    env.write_text("targets:\n  main:\n    drivers: []\n")
    assert bench.declared_board(str(env)) is None


def test_an_unreadable_environment_reads_as_none(tmp_path):
    assert bench.declared_board(str(tmp_path / "nope.yaml")) is None
