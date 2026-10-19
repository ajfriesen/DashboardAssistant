# What counts as a good boot, and what happens without one (docs/adr/0009).
#
# A device updates by building a release into a new NixOS generation and
# switching to it (./update.nix). The safety net under that is systemd's
# Automatic Boot Assessment: systemd-boot writes a new generation's boot entry
# with a counter in its filename, decrements it on every attempt, and once the
# counter reaches zero boots the previous entry instead. The counter is removed
# — the entry "blessed" — by systemd-bless-boot.service, which runs only once
# the booted system reaches boot-complete.target.
#
# So the whole policy decision is: what must be true before this device admits
# the boot worked? Here, that the daemon answers /healthz. That is deliberately
# a low bar, and each thing left out of it is left out for a reason:
#
#   * Not the kiosk session. A board whose GPU the kernel cannot drive has no
#     greetd, every boot would count as bad, and the device would roll back and
#     roll back again — on a fault no older generation fixes. This gate used to
#     require greetd and that is exactly the trap it set.
#   * Not Home Assistant being reachable. It can be down, moved or re-addressed
#     for reasons that have nothing to do with the release, and a device must
#     not reinstall its own past over somebody's weekend outage.
#   * Not the screen showing anything. A blank screen is not the update's fault
#     often enough that treating it as one would be a worse bug than the one
#     being guarded against.
#
# What is left is the only thing that actually matters for recovery: the daemon
# is up, so the admin page is up, so a human can reach the device and fix it by
# hand. A **good boot** is a reachable device, nothing more (CONTEXT.md).
#
# Lives in core/ rather than in each hardware target because it was per-target
# once, and the Raspberry Pi boards simply never got a copy — the gate existed,
# and on two of three boards nothing was gating anything. Every board boots
# systemd-boot (docs/adr/0003), so there is no target this does not apply to.
{ pkgs, ... }:
{
  # 3 attempts, per ADR 0009. Three is also the nixpkgs default; it is written
  # out because it is a decision here, not an inherited one. Inert on a target
  # without systemd-boot — the option lives under the loader's own `enable`.
  boot.loader.systemd-boot.bootCounting.enable = true;
  boot.loader.systemd-boot.bootCounting.tries = 3;

  # Named for what it decides, and with the project's own prefix (CONTEXT.md):
  # this was `ha-boot-health` when it lived in the x86 target, which read as a
  # Home Assistant unit checking boot "health" — and both halves were wrong.
  # Home Assistant reachability is deliberately not part of the decision, and
  # the decision is whether this was a **good boot**.
  systemd.services.dashboard-assistant-good-boot = {
    description = "Gate boot success on the device being reachable";
    # This is what makes the gate load-bearing: boot-complete.target requires it
    # and is ordered after it, and systemd-bless-boot.service in turn requires
    # boot-complete.target. A failure here therefore leaves the counter in place
    # and spends one of the generation's three attempts.
    before = [ "boot-complete.target" ];
    requiredBy = [ "boot-complete.target" ];
    after = [ "dashboard-assistant-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "dashboard-assistant-good-boot" ''
        # Wait up to ~3 min for the daemon to answer. Generous on purpose: a
        # cold Raspberry Pi on a slow card takes its time, and a gate that is
        # impatient rolls back a release that was fine.
        i=0
        while [ "$i" -lt 90 ]; do
          if ${pkgs.curl}/bin/curl -fsS --max-time 3 http://localhost:8080/healthz >/dev/null 2>&1; then
            echo "daemon healthy; blessing this boot"
            exit 0
          fi
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 2
        done
        echo "daemon did not answer in time; not blessing this boot" >&2
        exit 1
      '';
    };
  };
}
