# Memory-pressure resilience for the Chromium kiosk. This is a RAM concern, not
# a disk one — it does NOT shrink the image or the store. The goal: a runaway
# browser degrades into a fast, clean session restart instead of freezing on
# disk swap or being OOM-killed uncleanly. Shared by every target that runs the
# kiosk.
{ ... }:
{
  # Compressed swap in RAM. Chromium's anonymous pages compress well (~2-3x with
  # zstd), so this holds cold browser memory with zero writes to flash/eMMC —
  # the right kind of swap for an appliance on flash storage. It essentially
  # never activates when RAM is ample; it's a genuine cushion on low-RAM tablets.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    # max *uncompressed* data = 50% of RAM (actual RAM used is the compressed
    # size). Raise toward 100 for 2 GB-class tablets since the data is compressed.
    memoryPercent = 50;
  };

  # Reclaim tuning for a system whose only swap is compressed RAM. NixOS'
  # zramSwap module writes zram-generator.conf and nothing else; Fedora ships
  # these two sysctls separately (zram-generator-defaults), so this fills a gap
  # upstream fills elsewhere rather than deviating from it.
  #
  # HONEST ACCOUNTING, because this sits next to a flash-wear module and is not
  # one: this writes nothing to flash and saves nothing directly — zram never
  # touches the card. The flash benefit is second-order and small (tilting
  # reclaim away from page-cache eviction means fewer re-READS later). The real
  # reasons to take it are responsiveness under pressure on a 2 GB Pi 4 and
  # fewer oomd kills of the kiosk session. On a 4 GB Pi 5 or an x86 box, where
  # swap essentially never activates, it buys nothing measurable.
  #
  # Deliberately NOT here: vm.dirty_writeback_centisecs / vm.dirty_expire_centisecs.
  # They are the VM-layer analogue of Armbian's ext4 `commit=600` and look like
  # an obvious win, but on a btrfs root they are a no-op — btrfs forces a
  # transaction commit every 30s regardless of writeback settings.
  boot.kernel.sysctl = {
    # The stock 60 is balanced for a disk swap ~1000x slower than RAM. With zstd
    # zram the cost of swapping an anon page is one compression, so reclaim
    # should tilt hard toward swapping anon pages instead of evicting page
    # cache. 180 is Fedora's value for exactly this configuration (the ceiling
    # was raised from 100 to 200 in 5.8 to allow it).
    "vm.swappiness" = 180;
    # Swap readahead exists to amortise disk seeks; zram has none, so every
    # extra page read is a wasted decompression. The kernel's zram
    # documentation recommends 0 and ChromeOS has shipped it for years.
    "vm.page-cluster" = 0;
  };

  # Proactive OOM handling: when memory pressure spikes, kill the offending
  # cgroup instead of letting the box thrash. For a single-app kiosk the offender
  # is Chromium, and killing its session makes greetd relaunch a fresh dashboard
  # — a ~2s blip, no flash writes, versus a frozen screen.
  #
  # enableUserSlices lets oomd act on the kiosk's graphical session (greetd opens
  # a logind session, so it lives under user-<uid>.slice). System services are
  # deliberately left unmanaged so oomd can never kill something load-bearing.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };
}
