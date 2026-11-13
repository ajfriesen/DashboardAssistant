# VNC: see and drive the kiosk from another computer, for jobs a touchscreen is
# bad at, like signing in to Google Calendar on the dashboard.
#
# wayvnc is the VNC server for wlroots compositors such as Sway. It captures the
# output through the screencopy protocol and types and clicks through Sway's
# virtual keyboard and pointer protocols, so what the viewer does lands in the
# kiosk exactly as on the touchscreen.
#
# Off unless Home Assistant switches it on, and always off after a boot. The
# daemon owns on/off, the per-session password and the auto-close timer
# (daemon/vnc.go). It writes this session's wayvnc config, then "start" or
# "stop" to a FIFO. The agent below runs inside the Sway session, because
# wayvnc needs the Wayland socket and the daemon has none, and starts or kills
# wayvnc. Same handshake as the other in-session agents in kiosk.nix.
#
# Only encrypted security types are offered (RSA-AES and VeNCrypt/TLS). Clients
# that support them: TigerVNC 1.13+, RealVNC Viewer, Remmina. macOS's built-in
# Screen Sharing cannot encrypt this way and is refused on purpose.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashboardAssistant.vnc;

  # Must match daemon/config.go (vncFifo, vncConfigFile) and the reverse FIFO
  # in kiosk.nix.
  vncFifo = "/var/lib/dashboard-assistant/vnc.fifo";
  vncConfig = "/run/dashboard-assistant/wayvnc.conf";
  displayStateFifo = "/var/lib/dashboard-assistant/display-state.fifo";

  report = pkgs.writeShellScript "ha-vnc-report" ''
    ${pkgs.coreutils}/bin/printf '%s\n' "$*" \
      | ${pkgs.coreutils}/bin/timeout 1 ${pkgs.coreutils}/bin/tee ${displayStateFifo} >/dev/null 2>&1 || true
  '';

  agent = pkgs.writeShellScript "ha-vnc-agent" ''
    # Sway does not reap its exec'd children, so a kiosk restart orphans the
    # previous session's agent and wayvnc. Kill both: a new session never
    # starts with VNC on.
    for pid in $(${pkgs.procps}/bin/pgrep -f ha-vnc-agent); do
      [ "$pid" = "$$" ] || kill "$pid" 2>/dev/null || true
    done
    ${pkgs.procps}/bin/pkill -x wayvnc 2>/dev/null || true

    # The flag file and signal drive the "Remote access" marker on the bar
    # (kiosk.nix); waybar re-runs the module's script on SIGRTMIN+9.
    #
    # SIGRTMIN+9's default action is to terminate, so it only goes to a PID
    # that has installed a handler for it (its bit in SigCgt). A waybar still
    # starting up has none yet: signalling it then killed the bar for the rest
    # of the session. The check also spares whatever reused a stale PID.
    flag="''${XDG_RUNTIME_DIR:-/tmp}/ha-vnc-on"
    sig=$(kill -l RTMIN+9)
    bar() {
      pid=$(${pkgs.coreutils}/bin/cat "''${XDG_RUNTIME_DIR:-/tmp}/ha-kiosk-waybar.pid" 2>/dev/null)
      [ -n "$pid" ] || return 0
      mask=$(${pkgs.gawk}/bin/awk '/^SigCgt:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
      [ -n "$mask" ] || return 0
      if (( (16#$mask >> (sig - 1)) & 1 )); then
        kill -s "$sig" "$pid" 2>/dev/null || true
      fi
    }
    # No bar() here: this runs as the session starts, next to a waybar that is
    # starting too, and a fresh bar reads the (now absent) flag by itself.
    ${pkgs.coreutils}/bin/rm -f "$flag"
    ${report} vnc off

    keep=""
    exec 3<> ${vncFifo}
    while IFS= read -r cmd <&3; do
      case "$cmd" in
        start)
          [ -n "$keep" ] && kill "$keep" 2>/dev/null
          (
            # Trap before starting wayvnc, so a stop that arrives early never
            # leaves it running. Killed by "stop": exit quietly. Exited by
            # itself: tell the daemon, so the HA switch goes off.
            w=""
            trap '[ -n "$w" ] && kill "$w" 2>/dev/null; exit 0' TERM
            ${lib.getExe pkgs.wayvnc} \
              --config ${vncConfig} \
              --disable-resizing \
              --name "$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)" &
            w=$!
            wait "$w"
            ${pkgs.coreutils}/bin/rm -f "$flag"
            bar
            ${report} vnc off
          ) &
          keep=$!
          ${pkgs.coreutils}/bin/touch "$flag"
          bar
          ;;
        stop)
          [ -n "$keep" ] && kill "$keep" 2>/dev/null
          keep=""
          ${pkgs.coreutils}/bin/rm -f "$flag"
          bar
          ;;
      esac
    done
  '';
in
{
  options.dashboardAssistant.vnc = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ship the VNC server, so Home Assistant can switch on remote access to
        the kiosk. This is the build-time switch: it decides whether wayvnc and
        the Home Assistant entities exist at all. VNC itself is off until Home
        Assistant switches it on, is always off after a boot, and closes itself
        after the timeout set in Home Assistant.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5900;
      description = ''
        TCP port wayvnc listens on while VNC is on. Opened in the firewall
        permanently; nothing listens on it while VNC is off.
      '';
    };

    agent = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = agent;
      description = "The in-session agent that runs wayvnc; exec'd by the kiosk's Sway config.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.services.dashboard-assistant-daemon.environment = {
      DASHBOARD_ASSISTANT_VNC = "1";
      DASHBOARD_ASSISTANT_VNC_PORT = toString cfg.port;
    };

    systemd.tmpfiles.rules = [
      "p ${vncFifo} 0660 dashboard-assistant dashboard-assistant - -"
    ];
  };
}
