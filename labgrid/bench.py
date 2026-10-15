"""Shared bits of the hardware bench: where things live, and how to find an image.

Imported by conftest.py (pytest adds this directory to sys.path) and by flash.py
and preflight.py (run as scripts from here).
"""

import glob
import json
import os
import re
import shutil
import subprocess

import yaml
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

ENV_CONFIG = os.path.join(HERE, "bench.yaml")
LOG_DIR = os.path.join(HERE, "logs")

# Where `just build-rpi5-dev` leaves the uncompressed image. The filename carries
# the release version, so it cannot be written into bench.yaml.
# The Pi images are built by disko now, like the x86 ones: a single raw GPT
# image named after dashboardAssistant.diskLayout.imageName, directly in the
# derivation output. The old path was result-rpi5-dev/sd-image/*.img, from
# nixpkgs' sd-image builder.
IMAGE_GLOB = os.path.join(REPO_ROOT, "result-rpi5-dev", "*.raw")


#: `!template $LG_FOO` / `${LG_FOO}` in an environment file. Only LG_* is worth
#: looking for: labgrid maps nothing else from the environment into a template
#: (and `$BASE`, which it supplies itself), so any other name could never be
#: used even if it were set.
_TEMPLATE_VAR = re.compile(r"\$\{?(LG_[A-Z0-9_]+)\}?")


def templated_variables(text):
    """The LG_* variables an environment file's templates refer to.

    Used to demand exactly what the target under test needs, and nothing more.
    The bench environment templates the place it acquires; the QEMU one has no
    place and no coordinator, and refusing to run it without them would be
    asking for a bench in order to test something that needs no bench.
    """
    return set(_TEMPLATE_VAR.findall(text))


class _TemplateTolerantLoader(yaml.SafeLoader):
    """A YAML loader that does not choke on labgrid's `!template`.

    Only used to read an environment file's `options:` before labgrid has built
    an Environment from it. The tag's *value* is irrelevant here — this is for
    reading declarations, not for resolving anything.
    """


_TemplateTolerantLoader.add_constructor(
    "!template", lambda loader, node: loader.construct_scalar(node)
)


def declared_board(env_config):
    """The board an environment file declares, or None.

    Read here rather than through labgrid's config because it is needed at
    *collection* time. A test written for another board has to be skipped before
    its fixtures run: `shell` is session-scoped, so pytest would otherwise flash
    and boot a board on behalf of a test that was never going to run — and on a
    target where that test cannot pass, the attempt can break the strategy and
    take the rest of the run with it. Observed exactly that way.
    """
    try:
        with open(env_config, encoding="utf-8") as handle:
            data = yaml.load(handle, Loader=_TemplateTolerantLoader)
    except (OSError, yaml.YAMLError):
        return None
    if not isinstance(data, dict):
        return None
    return (data.get("options") or {}).get("board")


def find_image():
    """Newest image matching IMAGE_GLOB, or None.

    result-rpi5-dev is a single symlink so there is normally exactly one match;
    picking the newest keeps a stale file from being chosen at random.
    """
    matches = glob.glob(IMAGE_GLOB)
    if not matches:
        return None
    return max(matches, key=os.path.getmtime)


# Where `just build-x86-dev` leaves the uncompressed x86_64 image. Same disko
# single-raw layout as the Pi images; a separate out-link so the dev image never
# clobbers the release one.
X86_IMAGE_GLOB = os.path.join(REPO_ROOT, "result-x86-dev", "*.raw")

#: The writable disk QEMU boots from. Never the image itself: that comes out of
#: the Nix store, which is read-only and root-owned, and QEMU writes to its disk
#: in place. Lives beside this file and is gitignored.
QEMU_DISK = os.path.join(HERE, ".qemu-disk.raw")

#: How big to make that disk. Bigger than any image we build, because the point
#: is to leave first-boot growth something to grow into — a disk the size of the
#: image would let test_root_filesystem_grew pass without anything having grown.
#: Sparse, so it costs no disk until written to.
QEMU_DISK_BYTES = 8 * 1024**3


def find_x86_image():
    """Newest image matching X86_IMAGE_GLOB, or None. See find_image()."""
    matches = glob.glob(X86_IMAGE_GLOB)
    if not matches:
        return None
    return max(matches, key=os.path.getmtime)


def move_gpt_backup_header(path, run=None):
    """Put the GPT backup header back at the end of a disk that has grown.

    A GPT keeps a second copy of its header in the last sector, and the primary
    header records where that is. Growing the disk leaves the copy stranded in
    the middle, and Linux does not tolerate the inconsistency: it rejects the
    table outright, so the disk comes up with *no partitions at all* and the
    boot dies in the initrd waiting for a root device that can no longer be
    seen. Observed exactly that way on the first QEMU boot, which is a far more
    confusing symptom than "the disk is the wrong size".

    `sgdisk --move-second-header` is the one-line fix, and it also extends the
    last-usable-LBA so the free space is actually offered to the guest — which
    is the point of growing the disk in the first place.
    """
    (run or _run_checked)(["sgdisk", "--move-second-header", path])


def _run_checked(argv):
    """Run `argv`, raising with its output if it fails."""
    done = subprocess.run(argv, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise RuntimeError(
            f"{' '.join(argv)} failed ({done.returncode}): "
            f"{done.stdout.strip()} {done.stderr.strip()}"
        )


def prepare_qemu_disk(image, dest=QEMU_DISK, size=QEMU_DISK_BYTES, repair_gpt=None):
    """Copy `image` to a writable disk of `size` bytes and return its path.

    The QEMU equivalent of the Pi's "dd the image onto the card": it is what
    makes a run start from the image rather than from whatever the last run left
    behind. Replaced outright each time for exactly that reason — a disk that
    accumulated state would let a test pass against something it did not create.

    Grown rather than left at the image's size so first-boot growth has work to
    do, and the GPT repaired afterwards because a grown GPT disk is not a valid
    GPT disk. Sparse, so the extra bytes cost nothing until they are written.
    """
    actual = os.path.getsize(image)
    if size < actual:
        raise ValueError(
            f"disk of {size} B is smaller than the {actual} B image — "
            "truncating would cut the image in half"
        )
    if os.path.exists(dest):
        os.unlink(dest)
    # copyfile, not copy2: the image's read-only store permissions must not come
    # with it, or QEMU cannot write to its own disk.
    shutil.copyfile(image, dest)
    os.chmod(dest, 0o644)
    with open(dest, "r+b") as disk:
        disk.truncate(size)
    # Not optional, and not cosmetic: see move_gpt_backup_header.
    (repair_gpt or move_gpt_backup_header)(dest)
    return dest


#: How long to wait on the plug's own HTTP server. It is an ESP on Wi-Fi, so
#: generous, but short enough that a plug that has dropped off the network fails
#: the test rather than hanging the run.
PLUG_TIMEOUT = 10


def _shelly_gen1(host, path):
    """GET a Shelly Gen 1 endpoint and return the decoded JSON.

    labgrid's shelly_gen1 power backend does on/off/get and nothing else, so the
    one thing it cannot give us is the measurement: how much current the board is
    actually drawing. That is what separates "the board is not running" from "the
    serial console is lying to us", which is a distinction this bench has needed
    more than once (see README.md). So this reads the plug directly.

    `host` comes off the acquired NetworkPowerPort, never from a constant here —
    the plug's address is declared once, in the bench host's exporter config.
    """
    with urllib.request.urlopen(f"{host}{path}", timeout=PLUG_TIMEOUT) as response:
        return json.load(response)


def plug_draw(host):
    """Active power draw in watts, as a float."""
    return float(_shelly_gen1(host, "/meter/0")["power"])


def plug_state(host):
    """Whether the relay is closed, as "ON" or "OFF"."""
    return "ON" if _shelly_gen1(host, "/relay/0")["ison"] else "OFF"
