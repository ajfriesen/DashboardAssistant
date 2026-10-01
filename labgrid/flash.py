#!/usr/bin/env python3
"""Flash the bench board's SD card and stop — `just hw-flash`.

Takes the strategy to `flashed`: power off, card to this host, image dd'd on, card
handed back to the board. Leaves the power off; nothing is asserted. For bringing
a board up by hand, or bisecting a boot failure where the tests are not the
interesting part.

Must run under $LABGRID_PYTHON (see flake.nix) — bare python3 in the dev shell is
whichever interpreter landed on PATH first, which is usually not the one holding
labgrid.
"""

import argparse
import os
import sys

from labgrid import Environment

import bench


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--image",
        help=f"image to flash (default: newest match of {bench.IMAGE_GLOB})",
    )
    args = parser.parse_args()

    image = args.image or bench.find_image()
    if not image:
        sys.exit(
            "no image under result-rpi5-dev/sd-image/ — run `just build-rpi5-dev`"
        )
    image = os.path.abspath(image)
    if not os.path.isfile(image):
        sys.exit(f"{image}: no such file")

    env = Environment(config_file=bench.ENV_CONFIG)
    strategy = env.get_target().get_driver("Strategy")
    strategy.image = image

    print(f"flashing {image}")
    strategy.transition("flashed")
    print("done — card handed back to the board, power still off")


if __name__ == "__main__":
    main()
