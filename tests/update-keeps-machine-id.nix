# VM test: a switch to another configuration, and the reboot after it, keep
# the device's machine-id.
#
# /etc/machine-id is the device's identity: the daemon derives its Home
# Assistant node_id from it (daemon/ha.go). An update is a switch to another
# configuration, and NixOS deletes every /etc file it manages that the new
# configuration does not declare. When the dev images pinned their machine-id
# with environment.etc, an update to the release configuration deleted it
# mid-switch; D-Bus could not start without it and the switch hung. So the
# file must never be NixOS's, on any image.
#
# The machine runs the dev configuration, because that is the one that pins
# a machine-id, which makes "unchanged" checkable against a known value. The
# `next` specialisation stands in for the release an update switches to.
{
  pkgs,
  version,
  ...
}:
let
  # The value modules/dev.nix pins.
  pinned = "0a03370b18534ab8b73e645ac4f95dee";
in
pkgs.testers.runNixOSTest {
  name = "update-keeps-machine-id";

  node.specialArgs = {
    inherit version;
    impermanence = null; # only referenced by the deferred impermanence scaffold
  };

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        ../modules/core/default.nix
        ../modules/dev.nix
      ];

      # Without a GPU the kiosk session crash-loops; it is not what this tests.
      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;

      specialisation.next.configuration = {
        environment.etc."dashboard-assistant/next-release".text = "next\n";
      };
    };

  testScript = ''
    def machine_id():
        return machine.succeed("cat /etc/machine-id").strip()

    def not_managed_by_nixos():
        # /etc/.clean lists the copied files NixOS manages and will delete.
        machine.fail("grep -qx machine-id /etc/.clean")

    machine.wait_for_unit("multi-user.target")
    assert machine_id() == "${pinned}", f"dev pin not applied: {machine_id()}"
    not_managed_by_nixos()

    # The update: switch to the next configuration while running.
    machine.succeed(
        "/run/current-system/specialisation/next/bin/switch-to-configuration test"
    )
    machine.succeed("test -e /etc/dashboard-assistant/next-release")
    assert machine_id() == "${pinned}", f"machine-id changed by the switch: {machine_id()}"
    not_managed_by_nixos()

    # ...and the reboot that follows an update.
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    assert machine_id() == "${pinned}", f"machine-id changed across the reboot: {machine_id()}"
  '';
}
