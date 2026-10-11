# The nixos-unstable flavour of the x86 on-disk target — best-effort, for hardware
# the pinned stable image cannot bring up.
#
# A thin leaf over ./generic-x86-disk.nix: identical disko GPT layout, identical
# systemd-boot-at-the-removable-fallback-path boot chain, identical initrd module
# set, identical core config. Everything else must stay shared so the two x86
# flavours cannot drift apart.
#
# WHY THIS IS NOT JUST A CHANNEL SWAP. Measured at the lock this landed with:
#
#                      nixos-26.05     nixos-unstable
#   linuxPackages        6.18.53         6.18.53      <- identical
#   linuxPackages_latest  7.2.7           7.2.7
#   linux-firmware      20260916        20260916      <- identical
#   mesa                 26.1.8          26.2.3
#
# 26.05 had only just branched, so swapping the channel alone would have moved a
# mesa minor and nothing else — a no-op for the very users this flavour exists
# for, who would have flashed a byte-different image with the same kernel and
# concluded the whole thing was pointless. boot.kernelPackages below is therefore
# not optional; it is what makes this image do its job.
#
# Keeping *both* (unstable channel AND linuxPackages_latest) is still the right
# pairing rather than redundant: on a stable release `linuxPackages_latest` stops
# advancing as the branch ages and mesa/firmware never move at all, whereas on
# unstable all three keep tracking upstream. The channel is the long game, the
# kernel line is today.
#
# NOT included: the out-of-tree linux-surface patch set. This is mainline only.
# Surface devices get whatever upstream has landed; what upstream has not landed
# (notably the IPTS/IPU6 cameras and some touch controllers) does not work. The
# promise is "a newer kernel", not "Surface support".
{ pkgs, ... }:
{
  imports = [ ./generic-x86-disk.nix ];

  # Its own update target, so `nixos-rebuild switch` on a device flashed with this
  # image rebuilds *this* attr. Without it a deployed unstable box would pull the
  # stable flavour on its first in-place update and silently change channel. Both
  # this and imageName are mkDefault in the base module for exactly this override.
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-x86-disk-unstable";

  # Distinct artifact basename so the two x86 `.raw` files can sit side by side in
  # a build directory and in the R2 bucket. Matches the `x86_64-unstable` board
  # token used by the release workflow.
  dashboardAssistant.diskLayout.imageName = "dashboard-assistant-x86_64-unstable";

  # The actual point of this flavour: mainline-latest rather than the channel's
  # conservative default (6.18 -> 7.2 at the lock above). This is what gives a
  # 2026 mini-PC, laptop or x86 tablet a chance of bringing up its display, Wi-Fi
  # and touch controller.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # DELIBERATELY NOT ENABLED HERE: boot.loader.systemd-boot.bootCounting.
  #
  # The base module (see its comment on automatic boot assessment) wants it, and
  # unlike 26.05 this channel does have the option — so it is tempting, and a
  # best-effort kernel is exactly where an update that won't come up is most
  # likely. It is left off because it cannot be verified without hardware, and
  # getting it wrong lands on the least-equipped users:
  #
  #   - systemd-bless-boot reads LoaderBootCountPath, a volatile EFI variable
  #     systemd-boot sets at runtime. This target installs with --no-variables
  #     (boot.loader.efi.canTouchEfiVariables = false) at the *removable* fallback
  #     path to work around ODROID H2-class firmware. That combination is untested.
  #   - A freshly flashed image has exactly one generation, so there is nothing to
  #     revert to; the base module's bless condition also requires greetd to be
  #     active, and a dead GPU is the *expected* failure mode here — so the stock
  #     condition would mark precisely the target hardware as bad.
  #
  # Enabling it is a one-line follow-up once it can be tested on a real board
  # (`bootctl status` must report boot-loader-set ESP information and
  # systemd-bless-boot must succeed rather than skip). Doing it in the same change
  # as the kernel bump would make a boot failure impossible to attribute.
}
