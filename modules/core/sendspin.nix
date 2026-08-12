# Sendspin player: the device as a synchronized multi-room audio client.
#
# Sendspin (https://sendspin-audio.com, Open Home Foundation) splits into a
# *server* that sources music — in practice Music Assistant — and *players* that
# receive it and stay in sync to well under a millisecond. This module ships the
# player half only; the device is a speaker, never a music source, so
# sendspin-go's `sendspin-server` binary is not packaged (see packages/sendspin-go/).
#
# Discovery is mDNS: the player browses for _sendspin-server._tcp and dials the
# server it finds, so nothing has to be configured for the common case and no
# inbound port is needed (the Go player has no WebSocket listener of its own —
# it only ever dials out). It also advertises itself as _sendspin._tcp on
# `port`, which servers that support server-initiated discovery browse for.
#
# The player speaks mDNS itself (hashicorp/mdns) rather than going through the
# Avahi daemon ha-api.nix already runs, so two processes share UDP 5353. They
# are expected to coexist — both bind with address reuse — but if discovery ever
# turns flaky on a device, that overlap is the first thing to suspect, and
# `server` pins the player to an address as a way out.
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

  sendspin-player = pkgs.callPackage ../../packages/sendspin-go/sendspin-go.nix { };

  # The player's own default name is "<hostname>-sendspin-player", which on this
  # image expands to the MAC-derived "dashboard-assistant-ab12cd-sendspin-player"
  # — accurate but unreadable in a Music Assistant player list. Default instead
  # to the same label the daemon uses for the HA device (see daemon/ha.go
  # deviceName), so one physical box reads the same in both places. Resolved at
  # start rather than at build time because the hostname only exists at runtime
  # (default.nix derives it from the primary NIC's MAC).
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
    exec ${lib.getExe sendspin-player} \
      --daemon \
      --name "$name" \
      --port ${toString cfg.port} \
      --buffer-ms ${toString cfg.bufferMs} \
      ${lib.optionalString (cfg.server != "") "--server ${lib.escapeShellArg cfg.server}"} \
      ${
        lib.optionalString (cfg.audioDevice != "") "--audio-device ${lib.escapeShellArg cfg.audioDevice}"
      } \
      ${lib.escapeShellArgs cfg.extraArgs}
  '';
in
{
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
        Pin the player to one Sendspin server instead of discovering it. Empty
        (the default) browses for _sendspin-server._tcp over mDNS. Set this on
        networks that block multicast, or where several servers are visible and
        the device must pick one.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8927;
      description = ''
        Port advertised in the player's own mDNS record. Nothing listens on it —
        the Go player always dials the server — so it is not opened in the
        firewall; it exists for servers that browse for clients.
      '';
    };

    bufferMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 150;
      description = ''
        Jitter buffer in milliseconds. Raise it on flaky Wi-Fi if playback
        stutters; it costs that much extra latency before audio starts.
      '';
    };

    audioDevice = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "USB Audio Device";
      description = ''
        Playback device name, matched exactly as `sendspin-player
        --list-audio-devices` prints it. Empty uses PipeWire's default sink,
        which is right unless a box has several outputs (e.g. HDMI plus a USB
        DAC) and picks the wrong one.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--preferred-codec"
        "opus"
      ];
      description = "Extra flags appended to the sendspin-player command line.";
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

    # miniaudio (via malgo, inside the player) prefers its PulseAudio backend,
    # which libpulse resolves from PULSE_SERVER. The system instance's socket is
    # /run/pulse/native (upstream's pipewire-pulse.socket uses %t/pulse/native,
    # and %t is /run for a system unit) — not the per-user path libpulse would
    # otherwise look for under XDG_RUNTIME_DIR. Set session-wide so Chromium in
    # the kiosk finds it too and HA dashboard media/TTS actually makes sound.
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

    systemd.services.sendspin-player = {
      description = "Sendspin synchronized audio player";
      # Deliberately not wantedBy multi-user.target: the daemon owns the runtime
      # on/off state (it is what Home Assistant's switch talks to) and starts
      # this unit on boot when the persisted state says on. One owner, one
      # source of truth, and the HA switch survives a reboot.
      after = [
        "network-online.target"
        "pipewire.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "pipewire.service" ];

      environment = {
        PULSE_SERVER = "unix:/run/pulse/native";
        # Without a login session there is no XDG_RUNTIME_DIR; libpulse probes
        # it before PULSE_SERVER on some paths, and an unset one is cleaner than
        # a stale /run/user/0.
        XDG_RUNTIME_DIR = "/run/pipewire";
      };

      serviceConfig = {
        ExecStart = launcher.outPath;
        User = "sendspin";
        Group = "sendspin";
        Restart = "on-failure";
        RestartSec = 5;

        # The player writes nothing: --daemon logs to stdout, and with no
        # writable config file the client_id falls back to the primary NIC's MAC
        # (pkg/sendspin/client_id.go), which is stable across reboots without
        # any state to persist. So it can run fully sealed off.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = false; # audio scheduling
        SystemCallArchitectures = "native";
        # IPv4/IPv6 for the server WebSocket, UNIX for the PipeWire socket,
        # NETLINK for the MAC lookup behind client_id.
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
