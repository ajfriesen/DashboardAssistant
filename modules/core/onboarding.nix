# Wi-Fi onboarding: the setup access point and its captive portal.
#
# A device flashed from a released image, with no seed file and no Ethernet, has
# no way to be told about your network: the LAN admin page needs the network it
# cannot join. Such a device raises its own WPA2 access point instead, shows the
# name, passphrase and a scannable join code on its screen, and serves a captive
# portal that asks for your network's name and password.
#
# The AP only ever exists on a device that has never been online and is not
# provisioned (see daemon/onboarding.go). It is unauthenticated by nature, so it
# must only exist while there is nothing on the device worth taking, and the
# daemon refuses admin and pairing requests that arrive over it.
{
  config,
  lib,
  ...
}:
let
  cfg = config.dashboardAssistant.onboarding;

  # Kept in step with apAddress in daemon/network.go. Pinned rather than left to
  # NetworkManager: NM documents 10.42.x.0/24 as the subnet it picks when a shared
  # connection carries no manual address, which is a default and not a promise,
  # and everything below hardcodes the result.
  apAddress = "10.42.0.1";
in
{
  options.dashboardAssistant.onboarding = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Raise a Wi-Fi setup access point on a device that has never been online.
        On by default: without it, a Wi-Fi-only device flashed without a seed file
        has no way to be configured at all.
      '';
    };

    channel = lib.mkOption {
      type = lib.types.ints.between 1 11;
      default = 6;
      description = ''
        2.4 GHz channel for the setup access point. Restricted to 1-11 because the
        device runs in the world regulatory domain, where beaconing on 5 GHz and on
        2.4 GHz channels 12-14 is forbidden.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The firewall rules below are iptables-specific. Fail the build rather than
    # silently ship a portal that no phone can reach.
    assertions = [
      {
        assertion = !config.networking.nftables.enable;
        message = ''
          dashboardAssistant.onboarding uses networking.firewall.extraCommands,
          which the nftables firewall backend ignores. Port the rules in
          modules/core/onboarding.nix to extraInputRules before enabling nftables.
        '';
      }
    ];

    systemd.services.dashboard-assistant-daemon = {
      environment.DASHBOARD_ASSISTANT_AP_CHANNEL = toString cfg.channel;
      # Take delivery of the pre-bound port-80 descriptor. Declared here rather
      # than in daemon.nix so the whole feature stays in one file and the daemon
      # module does not have to know onboarding exists.
      serviceConfig.Sockets = "dashboard-assistant-portal.socket";
    };

    # The portal listener, handed to the daemon as an already-bound file descriptor.
    #
    # Socket activation is doing two jobs here. It binds port 80 as root and passes
    # the fd down, so the daemon needs no CAP_NET_BIND_SERVICE and its hardening is
    # untouched. And FreeBind lets the bind succeed *before* NetworkManager has
    # created the address, which is what makes the portal open by itself: a phone
    # fires its connectivity probe about a second after its DHCP lease lands, and
    # if nothing answers that first probe, both iOS and Android conclude there is
    # no portal here and will not ask again for a long time.
    #
    # Binding to the AP address rather than 0.0.0.0 also means the portal is
    # unreachable from the LAN once the device is deployed, by construction rather
    # than by a rule someone has to remember to remove.
    systemd.sockets.dashboard-assistant-portal = {
      description = "Dashboard Assistant Wi-Fi setup portal socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "${apAddress}:80";
        FreeBind = true;
        Service = "dashboard-assistant-daemon.service";
      };
    };

    # Wildcard DNS plus the captive-portal URI, for the dnsmasq instance
    # NetworkManager spawns for ipv4.method=shared. NM passes this directory to it
    # as --conf-dir; the sibling dnsmasq.d is for the system-wide DNS plugin and is
    # not read here.
    #
    # address=/#/ points every probe hostname (captive.apple.com,
    # connectivitycheck.gstatic.com, msftconnecttest.com …) at the device, so the
    # probes reach the portal and fail in the specific way that means "sign in".
    #
    # DHCP option 114 is the RFC 8910 captive-portal URI. iOS 14+ and Android 11+
    # take it at face value and open the portal without any probe guessing, which
    # is also the only thing that works for a phone with Private DNS set to strict.
    #
    # Note this applies to every shared-mode connection, not just the setup AP. It
    # is the only one today; a second would need this revisited.
    environment.etc."NetworkManager/dnsmasq-shared.d/dashboard-assistant-captive.conf".text = ''
      address=/#/${apAddress}
      dhcp-option=114,http://${apAddress}/
    '';

    # NixOS is default-deny on INPUT, and NetworkManager's shared mode only sets up
    # masquerading, not INPUT accepts. Without these the phone's DHCP DISCOVER and
    # its DNS queries are dropped, it never gets an address, and nothing else in
    # the flow happens. This is the first thing to check if the AP appears but the
    # phone cannot join it properly.
    #
    # Scoped by destination address rather than by interface name on purpose: the
    # Wi-Fi interface is wlan0 on the Pi targets but wlpXsY on x86, and the address
    # only exists while the AP is up, so these rules are self-limiting.
    networking.firewall.extraCommands = ''
      # DHCP cannot be scoped by address: a client that has no lease yet sends
      # from 0.0.0.0 to 255.255.255.255, so neither endpoint is the AP. Accepting
      # it on every interface is safe here because NetworkManager runs its
      # shared-mode dnsmasq with --bind-interfaces scoped to the AP interface, so
      # there is no DHCP server listening on the LAN side for this to expose.
      iptables -I nixos-fw 1 -p udp --dport 67 -j nixos-fw-accept
      iptables -I nixos-fw 1 -d ${apAddress} -p udp --dport 53 -j nixos-fw-accept
      iptables -I nixos-fw 1 -d ${apAddress} -p tcp --dport 53 -j nixos-fw-accept
      iptables -I nixos-fw 1 -d ${apAddress} -p tcp --dport 80 -j nixos-fw-accept

      # The admin and Home Assistant API listeners bind every interface, and their
      # authorization story is "reaching this port means you are on the owner's
      # LAN". The setup AP is a network where that is false and whose password is
      # printed on the tablet's screen, so drop them there. The daemon also refuses
      # these requests itself (notOnSetupAP in daemon/main.go); this is the second
      # lock on the same door.
      iptables -I nixos-fw 1 -d ${apAddress} -p tcp --dport 8099 -j nixos-fw-refuse
      iptables -I nixos-fw 1 -d ${apAddress} -p tcp --dport 8081 -j nixos-fw-refuse
    '';

    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw -p udp --dport 67 -j nixos-fw-accept 2>/dev/null || true
      iptables -D nixos-fw -d ${apAddress} -p udp --dport 53 -j nixos-fw-accept 2>/dev/null || true
      iptables -D nixos-fw -d ${apAddress} -p tcp --dport 53 -j nixos-fw-accept 2>/dev/null || true
      iptables -D nixos-fw -d ${apAddress} -p tcp --dport 80 -j nixos-fw-accept 2>/dev/null || true
      iptables -D nixos-fw -d ${apAddress} -p tcp --dport 8099 -j nixos-fw-refuse 2>/dev/null || true
      iptables -D nixos-fw -d ${apAddress} -p tcp --dport 8081 -j nixos-fw-refuse 2>/dev/null || true
    '';
  };
}
