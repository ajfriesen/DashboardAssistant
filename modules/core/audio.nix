# Audio output and input: which sink the device plays to and which source it
# records from, both picked from Home Assistant.
#
# They are PipeWire's default sink and default source, so one choice moves
# everything on that side: the Sendspin player (`-o pipewire`,
# modules/core/sendspin.nix) and the kiosk's browser play to the default sink,
# and a voice assistant (linux-voice-assistant without --audio-input-device)
# records from the default source. WirePlumber remembers a default someone
# set, so the choices survive a reboot without any state of ours.
#
# The daemon must not reach PipeWire itself: the socket that lists devices also
# records from the microphone, and the daemon is the process on the network.
# So this agent, in the `pipewire` group, does that side. It republishes the
# sinks, the sources and the current defaults to devicesFile whenever the graph
# changes (a USB DAC or microphone plugged in, a card's profile switched), and
# applies "output <name>" / "input <name>" lines from fifo, as
# `wpctl set-default` does. The daemon reads the file and writes the FIFO
# (daemon/audio.go). Paths must match daemon/config.go.
#
# The audio stack exists only with the Sendspin player built in, so this does
# too.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  devicesFile = "/run/audio-agent/devices.json";
  fifo = "/var/lib/dashboard-assistant/audio.fifo";

  jq = lib.getExe pkgs.jq;

  # Each side's devices with their labels, and the default WirePlumber settled
  # on ("" before it has picked one, or with nothing to pick, e.g. no
  # microphone). The shape is the daemon's snapshot slice, as is. A sink's
  # monitor is a port on the sink, not an Audio/Source node, so it never shows
  # up as an input.
  devices = pkgs.writeText "audio-devices.jq" ''
    def side($class; $key; $graph):
      {
        current: (
          [ $graph[]
            | select(.type == "PipeWire:Interface:Metadata" and .props["metadata.name"] == "default")
            | .metadata[]?
            | select(.key == $key)
            | .value.name
          ][0] // ""
        ),
        options: [ $graph[]
          | select(.type == "PipeWire:Interface:Node" and .info.props["media.class"] == $class)
          | .info.props
          | { name: .["node.name"], description: (.["node.description"] // .["node.name"]) }
        ]
      };
    . as $graph
    | {
        output: side("Audio/Sink"; "default.audio.sink"; $graph),
        input: side("Audio/Source"; "default.audio.source"; $graph)
      }
  '';

  # Turns pw-dump --monitor's stream of batches into one line per batch that
  # changed something worth republishing. Clients coming and going are not:
  # publish() itself connects as a client, so reacting to that would republish
  # forever (it did, at most of a CPU). A removal is just {id, info: null}, so
  # client ids are remembered to tell their removals from a sink's.
  changes = pkgs.writeText "audio-changes.jq" ''
    foreach inputs as $batch ({clients: {}};
      .changed = false
      | reduce $batch[] as $o (.;
          ($o.id | tostring) as $id
          | if $o.type == "PipeWire:Interface:Client" then .clients[$id] = true
            elif ($o | has("type")) then .changed = true
            elif .clients[$id] then del(.clients[$id])
            else .changed = true
            end);
      select(.changed) | 1)
  '';

  agent = pkgs.writeShellScript "audio-agent" ''
    set -u
    publish() {
      ${pkgs.pipewire}/bin/pw-dump 2>/dev/null | ${jq} -f ${devices} > ${devicesFile}.tmp \
        && ${pkgs.coreutils}/bin/mv ${devicesFile}.tmp ${devicesFile}
    }

    # pw-dump --monitor prints the whole graph, then every change. Changes come
    # in bursts, so wait for one to settle, then republish the whole picture.
    # If the monitor dies, take the agent down with it, and systemd starts a
    # fresh one.
    (
      ${pkgs.pipewire}/bin/pw-dump --monitor --no-colors 2>/dev/null \
        | ${jq} --unbuffered -nc -f ${changes} \
        | while IFS= read -r _; do
            while IFS= read -r -t 0.3 _; do :; done
            publish
          done
      kill $$
    ) &

    exec 3<> ${fifo}
    while IFS=' ' read -r kind name <&3; do
      case "$kind" in
        output) key=default.configured.audio.sink ;;
        input) key=default.configured.audio.source ;;
        *) continue ;;
      esac
      [ -n "$name" ] || continue
      ${pkgs.pipewire}/bin/pw-metadata -n default 0 "$key" \
        "$(${jq} -cn --arg n "$name" '{name: $n}')" Spa:String:JSON >/dev/null
    done
  '';
in
{
  config = lib.mkIf config.dashboardAssistant.sendspin.enable {
    users.groups.audio-agent = { };
    users.users.audio-agent = {
      isSystemUser = true;
      group = "audio-agent";
      # pipewire for the graph; dashboard-assistant for the FIFO in the
      # daemon's state dir, like the kiosk user.
      extraGroups = [
        "pipewire"
        "dashboard-assistant"
      ];
      description = "Audio agent";
    };

    systemd.tmpfiles.rules = [
      "p ${fifo} 0660 dashboard-assistant dashboard-assistant - -"
    ];

    systemd.services.audio-agent = {
      description = "Publishes the audio outputs and inputs and applies the ones Home Assistant picks";
      # Wanted by PipeWire too, so a restarted PipeWire brings it back: BindsTo
      # stops it with PipeWire, and Restart= does not cover that.
      wantedBy = [
        "multi-user.target"
        "pipewire.service"
      ];
      after = [
        "pipewire.service"
        "wireplumber.service"
        "systemd-tmpfiles-setup.service"
      ];
      bindsTo = [ "pipewire.service" ];
      # The system PipeWire's socket is /run/pipewire/pipewire-0.
      environment.PIPEWIRE_RUNTIME_DIR = "/run/pipewire";
      serviceConfig = {
        ExecStart = agent;
        User = "audio-agent";
        Group = "audio-agent";
        Restart = "always";
        RestartSec = 2;
        RuntimeDirectory = "audio-agent";
        RuntimeDirectoryMode = "0755";

        ProtectSystem = "strict";
        ReadWritePaths = [ fifo ];
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
