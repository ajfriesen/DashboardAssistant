# Sendspin player: the device as a synchronized multi-room audio client.
#
# Sendspin (https://sendspin-audio.com, Open Home Foundation) splits into a
# *server* that sources music — in practice Music Assistant — and *players* that
# receive it and stay in sync to well under a millisecond. This module ships the
# player half only, sendspin-cli (see packages/sendspin-cpp-cli/).
#
# Discovery is server-initiated: the player advertises itself as _sendspin._tcp
# on `port` and listens there, and the server finds it and connects in. So
# nothing has to be configured for the common case, and the port is open in the
# firewall. The player never browses for servers. That is what the previous
# player (sendspin-go) did, and its browse loop leaked 2.8 GB on a device in the
# field (#16). The advertisement goes through the Avahi daemon ha-api.nix already
# runs, so one process owns UDP 5353.
#
# Every connection is encrypted, and by default a server has to pair with the
# player before it can play. The device allows unpaired servers, so any Music
# Assistant on the LAN can play to it with nothing to type, as before. Pairing
# through Home Assistant can come later.
#
# Audio goes through PipeWire in *system-wide* mode. That is off the beaten path
# for a desktop, but this is an appliance: the player runs as a system service
# with no login session, and the kiosk's Chromium runs as a different user. A
# per-user PipeWire would give each of them a private instance fighting over the
# same sound card. One system instance, with both users in the `pipewire` group,
# is the arrangement that actually lets HA media and Sendspin share the device.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashboardAssistant.sendspin;

  sendspin-cli = pkgs.callPackage ../../packages/sendspin-cpp-cli/sendspin-cpp-cli.nix { };

  # The player's own default name is the hostname, which on this image is the
  # MAC-derived "dashboard-assistant-ab12cd": accurate but unreadable in a Music
  # Assistant player list. Default instead to the same label the daemon uses
  # for the HA device (see daemon/ha.go deviceName), so one physical box reads
  # the same in both places. Resolved at start rather than at build time
  # because the hostname only exists at runtime (default.nix derives it from
  # the primary NIC's MAC).
  playerName = pkgs.writeShellScript "sendspin-player-name" ''
    set -eu
    host=$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)
    case "$host" in
      dashboard-assistant-*) echo "Dashboard Assistant (''${host##*-})" ;;
      *) echo "Dashboard Assistant" ;;
    esac
  '';

  launcher = pkgs.writeShellScript "sendspin-player-launch" ''
    set -eu
    name=${lib.escapeShellArg cfg.name}
    if [ -z "$name" ]; then name=$(${playerName}); fi
    exec ${lib.getExe sendspin-cli} \
      --name "$name" \
      --output ${lib.escapeShellArg cfg.output} \
      --port ${toString cfg.port} \
      --buffer-ms ${toString cfg.bufferMs} \
      --allow-unpaired \
      --state-dir /var/lib/sendspin-player \
      --control-socket /run/sendspin-player/control.sock \
      ${lib.optionalString (cfg.server != "") "--server ${lib.escapeShellArg cfg.server}"} \
      ${lib.escapeShellArgs cfg.extraArgs}
  '';
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "dashboardAssistant" "sendspin" "audioDevice" ] ''
      The Sendspin player is now sendspin-cli, which names devices differently.
      Set dashboardAssistant.sendspin.output instead, e.g. "pipewire:<node name>".
    '')
  ];

  options.dashboardAssistant.sendspin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the Sendspin player, making the device a synchronized audio client
        (a speaker) for Music Assistant. On by default: a dashboard with a
        speaker or a headphone jack should just appear in Music Assistant.

        This is the build-time switch — it decides whether the service and the
        audio stack exist at all. Home Assistant's "Sendspin player" switch
        starts and stops the service at runtime and is only offered when this
        is enabled.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "Kitchen";
      description = ''
        Friendly name shown in Music Assistant. Empty derives it from the
        hostname as "Dashboard Assistant (<mac6>)", matching the HA device name.
      '';
    };

    server = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "ws://192.168.1.10:8927";
      description = ''
        Dial one Sendspin server instead of waiting for a server to find the
        player. Empty (the default) advertises the player over mDNS and listens
        on `port`. Anything set here turns the advertisement off, as the
        protocol requires. Set it on networks that block multicast.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8928;
      description = ''
        Port the player listens on for the server, advertised in its mDNS
        record. Open in the firewall unless `server` is set.
      '';
    };

    output = lib.mkOption {
      type = lib.types.str;
      default = "pipewire";
      example = "pipewire:alsa_output.usb-Generic_USB_Audio-00.analog-stereo";
      description = ''
        Playback device, as `sendspin-cli -o` takes it. The default is
        PipeWire's default sink, which is right unless a device has several
        outputs (e.g. HDMI plus a USB DAC) and picks the wrong one;
        `sendspin-cli -l` lists the others.
      '';
    };

    bufferMs = lib.mkOption {
      type = lib.types.ints.between 10 2000;
      default = 150;
      description = ''
        Audio the output keeps buffered, in milliseconds. Raise it if playback
        stutters on a busy device; it costs that much extra latency.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--fixed-volume" ];
      description = "Extra flags appended to the sendspin-cli command line.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System-wide instance: one daemon, shared by the kiosk session and the
    # player service. See the module header for why this is not the usual
    # per-user setup. rtkit lets PipeWire take the realtime priority its
    # sub-millisecond scheduling wants.
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      systemWide = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # Chromium in the kiosk goes through PipeWire's Pulse server. The system
    # instance's socket is /run/pulse/native (upstream's pipewire-pulse.socket
    # uses %t/pulse/native, and %t is /run for a system unit), not the per-user
    # path libpulse would otherwise look for under XDG_RUNTIME_DIR. Without this
    # HA dashboard media and TTS make no sound.
    environment.sessionVariables.PULSE_SERVER = "unix:/run/pulse/native";

    # Membership in `pipewire` is what the 0660 socket grants access to.
    users.users.kiosk.extraGroups = [ "pipewire" ];

    users.groups.sendspin = { };
    users.users.sendspin = {
      isSystemUser = true;
      group = "sendspin";
      extraGroups = [ "pipewire" ];
      description = "Sendspin audio player";
    };

    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.server == "") [ cfg.port ];

    systemd.services.sendspin-player = {
      description = "Sendspin synchronized audio player";
      # Deliberately not wantedBy multi-user.target: the daemon owns the runtime
      # on/off state (it is what Home Assistant's switch talks to) and starts
      # this unit on boot when the persisted state says on. One owner, one
      # source of truth, and the HA switch survives a reboot.
      #
      # The player retries Avahi and its network on a backoff, so ordering is
      # enough: neither has to be up for it to start.
      after = [
        "network.target"
        "avahi-daemon.service"
        "pipewire.service"
      ];
      requires = [ "pipewire.service" ];

      # The system PipeWire's socket is /run/pipewire/pipewire-0, and libpipewire
      # looks for it under XDG_RUNTIME_DIR. A system unit has none of its own.
      environment.XDG_RUNTIME_DIR = "/run/pipewire";

      serviceConfig = {
        ExecStart = launcher.outPath;
        User = "sendspin";
        Group = "sendspin";
        Restart = "on-failure";
        RestartSec = 5;

        # Its identity key, the last server, the output delay and its volume.
        # Small and rarely written, so it lives on the root filesystem like the
        # daemon's own state.
        StateDirectory = "sendspin-player";
        # The control socket `sendspin-cli status --control-socket
        # /run/sendspin-player/control.sock` talks to.
        RuntimeDirectory = "sendspin-player";

        # A cap kept from the sendspin-go player, which leaked to 2.8 GB RSS on
        # a device in the field and pushed the kiosk's Chromium into swap. Far
        # above what a player needs; if a leak ever recurs, the cgroup OOM
        # killer takes the player instead of the dashboard, and the SIGKILL
        # counts as a failure, so `Restart=on-failure` brings it back.
        MemoryAccounting = true;
        MemoryMax = "512M";

        # Same incident: the old player logged 398k lines in one boot, 2.87 GB
        # written to the SD card. This caps what any future upstream chattiness
        # can cost in flash wear.
        LogRateLimitIntervalSec = 30;
        LogRateLimitBurst = 100;

        # Upstream's own unit's hardening, plus PrivateDevices: the player
        # reaches the sound card through the PipeWire socket, never /dev/snd.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictSUIDSGID = true;
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = false; # audio scheduling
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
        # IPv4/IPv6 for the server's WebSocket, UNIX for PipeWire, Avahi's D-Bus
        # and the control socket, NETLINK for the MAC the player reports.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };

    # Tell the daemon the player exists, so it exposes the Sendspin switch to
    # Home Assistant. Absent (kiosks built with sendspin disabled) the entity is
    # never created.
    systemd.services.dashboard-assistant-daemon.environment.DASHBOARD_ASSISTANT_SENDSPIN = "1";

    # The daemon toggles the player over systemd's D-Bus API on behalf of the HA
    # switch. Same scoped-grant pattern as greetd/rollback in daemon.nix and the
    # update units in update.nix: this one unit, this one user, nothing else.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "dashboard-assistant") {
          if (action.id == "org.freedesktop.systemd1.manage-units") {
            if (action.lookup("unit") == "sendspin-player.service") return polkit.Result.YES;
          }
        }
      });
    '';
  };
}
