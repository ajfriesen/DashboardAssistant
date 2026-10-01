"""Shared bits of the hardware bench: where things live, and how to find an image.

Imported by conftest.py (pytest adds this directory to sys.path) and by flash.py
(run as a script from here).
"""

import glob
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

ENV_CONFIG = os.path.join(HERE, "bench.yaml")
LOG_DIR = os.path.join(HERE, "logs")
POWER_SCRIPT = os.path.join(HERE, "bench-power.sh")

# Where `just build-rpi5-dev` leaves the uncompressed image. The filename carries
# the release version, so it cannot be written into bench.yaml.
IMAGE_GLOB = os.path.join(REPO_ROOT, "result-rpi5-dev", "sd-image", "*.img")


def find_image():
    """Newest image matching IMAGE_GLOB, or None.

    result-rpi5-dev is a single symlink so there is normally exactly one match;
    picking the newest keeps a stale file from being chosen at random.
    """
    matches = glob.glob(IMAGE_GLOB)
    if not matches:
        return None
    return max(matches, key=os.path.getmtime)


def plug(*args):
    """Run bench-power.sh and return its stripped stdout."""
    return subprocess.run(
        [POWER_SCRIPT, *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
