# VM test for the Wi-Fi setup access point and its captive portal.
#
# This flow is a state machine over an asynchronous D-Bus API driving a radio, so
# it is exactly the kind of thing that reads correct and behaves otherwise. A
# plain VM has no wireless hardware, which is why none of it could be exercised
# before; mac80211_hwsim gives the kernel a pair of virtual radios that support AP
# mode, so NetworkManager sees a real wireless device and the whole path runs.
#
# The machine has no Ethernet on purpose (virtualisation.vlans = [ ]): a device
# with a working uplink must never raise an AP, so a test VM with one would pass
# vacuously.
{
  pkgs,
  version,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "wifi-onboarding";

  node.specialArgs = {
    inherit version;
    impermanence = null; # only referenced by the deferred impermanence scaffold
  };

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/core/default.nix ];

      # Virtual radios. The default is two, and the daemon takes the first.
      boot.kernelModules = [ "mac80211_hwsim" ];

      # qemu-vm.nix turns wpa_supplicant off with mkVMOverride (priority 10), which
      # outranks the NetworkManager module's own `wireless.enable = true`. Without
      # undoing it NetworkManager cannot D-Bus-activate a supplicant and every
      # radio sits in `unavailable` forever, so the test would fail for a reason
      # that has nothing to do with this feature. nixpkgs' own wireless tests use
      # the same escape hatch.
      networking.wireless.enable = lib.mkOverride 9 true;

      # No uplink: this is the stranded device the feature exists for. Dropping the
      # VLANs is not enough — qemu-vm.nix still attaches a user-mode eth0 that
      # picks up a DHCP lease, which NetworkManager counts as a perfectly good
      # connection, so the device reports itself online and never onboards. Hand
      # eth0 to nobody so the machine is genuinely without a network.
      virtualisation.vlans = [ ];
      networking.networkmanager.unmanaged = [ "interface-name:eth0" ];
      virtualisation.memorySize = 2048;

      # The kiosk session is irrelevant here and would crash-loop without a GPU,
      # burying the daemon's own logs in restart noise.
      systemd.services.greetd.enable = lib.mkForce false;

      # A second address to prove the AP guard is scoped rather than blanket: the
      # admin listener must refuse on the AP address and still answer elsewhere.
      networking.interfaces.lo.ipv4.addresses = [
        {
          address = "127.0.0.2";
          prefixLength = 8;
        }
      ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.iw # inspect the virtual radio's capabilities and mode
      ];
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("NetworkManager.service")
    machine.wait_for_unit("dashboard-assistant-daemon.service")

    # The virtual radio must actually be there and be AP-capable, or every
    # assertion below would pass for the wrong reason.
    machine.succeed("nmcli -t -f DEVICE,TYPE device | grep -q ':wifi'")
    machine.succeed("iw list | grep -q 'AP$' || iw list | grep -qE '^\\s+\\* AP$'")

    # The socket unit binds 10.42.0.1:80 before NetworkManager has created that
    # address. If FreeBind were missing or the address were wrong, this fails here
    # rather than mysteriously later when a phone gets no portal.
    machine.wait_for_unit("dashboard-assistant-portal.socket")
    machine.succeed("ss -tlnp | grep -q '10.42.0.1:80'")

    with subtest("the setup AP comes up on a stranded device"):
        # The manager deliberately waits: a 60s floor plus a 15s settle window, so
        # that a slow DHCP lease is never mistaken for a dead network.
        try:
            machine.wait_until_succeeds(
                "curl -sf localhost:8080/api/state | grep -q ONBOARDING", timeout=180
            )
        except Exception:
            # The manager declines to raise the AP for several distinct reasons and
            # says which in its log. Without this dump a failure here is just a
            # timeout with nothing to act on.
            print(machine.succeed("journalctl -u dashboard-assistant-daemon --no-pager | tail -40"))
            print(machine.succeed("nmcli general status; nmcli device status"))
            print(machine.succeed("journalctl -u NetworkManager --no-pager | tail -30"))
            print(machine.succeed("systemctl status wpa_supplicant --no-pager || true"))
            print(machine.succeed("rfkill list || true"))
            print(machine.succeed("curl -s localhost:8080/api/state; echo"))
            raise
        machine.succeed("nmcli -t -f NAME,TYPE connection show --active | grep -q 'dashboard-assistant-setup'")
        machine.succeed("iw dev | grep -q 'type AP'")
        machine.wait_until_succeeds("ip -4 addr show | grep -q '10.42.0.1'")

    with subtest("the AP is not mistaken for being online"):
        # The trap this whole feature turns on. An AP-mode connection is itself an
        # ACTIVATED active connection, so if NetInfo counted it the device would
        # read as online, flip to SETUP, and markOnline would write a marker that
        # only a factory reset clears: one boot would cost this device the ability
        # to ever show the AP again.
        state = machine.succeed("curl -sf localhost:8080/api/state")
        assert "ONBOARDING" in state, f"expected ONBOARDING, got {state}"
        machine.fail("test -e /var/lib/dashboard-assistant/online-once")

    with subtest("the splash has something to show"):
        info = json.loads(machine.succeed("curl -sf localhost:8080/api/onboarding"))
        assert info["active"], info
        assert info["ssid"], "no SSID for the splash to display"
        assert len(info["psk"]) >= 8, f"unusable AP passphrase: {info['psk']!r}"
        assert info["portal_url"] == "http://10.42.0.1/", info
        assert info["qr_payload"].startswith("WIFI:T:WPA;S:"), info["qr_payload"]
        assert info["qr_payload"].endswith(";;"), info["qr_payload"]
        # The QR is generated per device at runtime, unlike the static build-time
        # codes on the other pages.
        machine.succeed("curl -sf localhost:8080/api/onboarding/qr.png -o /tmp/qr.png")
        machine.succeed("test -s /tmp/qr.png")

    with subtest("the portal answers and announces itself"):
        page = machine.succeed("curl -sf http://10.42.0.1/")
        assert "Connect this display to Wi-Fi" in page, page[:400]

        # A captive portal is detected by failing the OS probes in the right way.
        # Serving nothing makes a phone mark the network dead and leave; serving a
        # redirect is the signal that means "sign in here".
        for probe in [
            "/generate_204",
            "/connecttest.txt",
            "/canonical.html",
            "/check_network_status.txt",
        ]:
            code = machine.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}}' http://10.42.0.1{probe}"
            ).strip()
            assert code == "302", f"{probe} returned {code}, expected a 302 redirect"

        # Apple's Captive Network Assistant renders the body it gets back, so that
        # one is served directly rather than redirected.
        apple = machine.succeed("curl -sf http://10.42.0.1/hotspot-detect.html")
        assert "Connect this display to Wi-Fi" in apple, apple[:400]
        assert "Success" not in apple, "serving Apple's success body would hide the portal"

    with subtest("the AP is not a back door into the admin page"):
        # The admin listener is unauthenticated because reaching it is supposed to
        # mean you are on the owner's LAN. The setup AP is a network where that is
        # false and whose password is printed on the tablet's screen.
        machine.succeed(
            "test $(curl -s -o /dev/null -w '%{http_code}' http://10.42.0.1:8099/) = 403"
        )
        machine.succeed(
            "test $(curl -s -o /dev/null -w '%{http_code}' -X POST http://10.42.0.1:8099/api/admin/reset) = 403"
        )
        # …and is still reachable from anywhere else, so the guard is scoped.
        machine.succeed(
            "test $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.2:8099/) = 200"
        )

    with subtest("a wrong password is reported, not swallowed"):
        machine.succeed(
            "curl -sf -X POST http://10.42.0.1/api/portal/join "
            "-H 'Content-Type: application/json' "
            "-d '{\"ssid\":\"no-such-network\",\"psk\":\"correcthorse\"}'"
        )
        # The join fails (nothing is broadcasting that SSID), and the AP has to
        # come back so the user can rejoin and be told why.
        machine.wait_until_succeeds(
            "curl -sf localhost:8080/api/onboarding | grep -q '\"last_error\":\"[^\"]'",
            timeout=120,
        )
        info = json.loads(machine.succeed("curl -sf localhost:8080/api/onboarding"))
        assert info["active"], "the AP did not come back after a failed join"
        assert "no-such-network" in info["last_error"], info["last_error"]
        assert info["ssid_attempt"] == "no-such-network", info

        # A short passphrase is rejected before the radio is touched at all.
        machine.succeed(
            "curl -sf -X POST http://10.42.0.1/api/portal/join "
            "-H 'Content-Type: application/json' "
            "-d '{\"ssid\":\"whatever\",\"psk\":\"short\"}'"
        )
        machine.wait_until_succeeds(
            "curl -sf localhost:8080/api/onboarding | grep -q '8 and 63 characters'",
            timeout=60,
        )

    with subtest("a failed join leaves no profile behind"):
        # NetworkManager persists a profile at activation time, before it knows the
        # passphrase works. A typo must not leave a saved network that NM keeps
        # retrying and that fights the AP after every reboot.
        machine.fail("nmcli -t -f NAME connection show | grep -q '^no-such-network$'")
  '';
}
