# Audio output: which sink the device plays to, picked from Home Assistant.
#
# It is PipeWire's default sink, so one choice moves everything: the Sendspin
# player (`-o pipewire`, modules/core/sendspin.nix) and the kiosk's browser both
# play there. WirePlumber remembers a default someone set, so the choice
# survives a reboot without any state of ours.
#
# The daemon must not reach PipeWire itself: the socket that lists sinks also
# records from the microphone, and the daemon is the process on the network.
# So this agent, in the `pipewire` group, does that side. It republishes the
# sinks and the current default to outputsFile whenever the graph changes (a
# USB DAC plugged in, a card's profile switched), and makes the sink named on
# outputFifo the default, as `wpctl set-default` does. The daemon reads the
# file and writes the FIFO (daemon/audio.go). Paths must match daemon/config.go.
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
  outputsFile = "/run/audio-output/outputs.json";
  outputFifo = "/var/lib/dashboard-assistant/audio-output.fifo";

  jq = lib.getExe pkgs.jq;

  # The sinks with their labels, and the default sink WirePlumber settled on
  # ("" before it has picked one).
  outputs = pkgs.writeText "audio-outputs.jq" ''
    {
      default: (
        [ .[]
          | select(.type == "PipeWire:Interface:Metadata" and .props["metadata.name"] == "default")
          | .metadata[]?
          | select(.key == "default.audio.sink")
          | .value.name
        ][0] // ""
      ),
      sinks: [ .[]
        | select(.type == "PipeWire:Interface:Node" and .info.props["media.class"] == "Audio/Sink")
        | .info.props
        | { name: .["node.name"], description: (.["node.description"] // .["node.name"]) }
      ]
    }
  '';

  # Turns pw-dump --monitor's stream of batches into one line per batch that
  # changed something worth republishing. Clients coming and going are not:
  # publish() itself connects as a client, so reacting to that would republish
  # forever (it did, at most of a CPU). A removal is just {id, info: null}, so
  # client ids are remembered to tell their removals from a sink's.
  changes = pkgs.writeText "audio-output-changes.jq" ''
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

  agent = pkgs.writeShellScript "audio-output-agent" ''
    set -u
    publish() {
      ${pkgs.pipewire}/bin/pw-dump 2>/dev/null | ${jq} -f ${outputs} > ${outputsFile}.tmp \
        && ${pkgs.coreutils}/bin/mv ${outputsFile}.tmp ${outputsFile}
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

    exec 3<> ${outputFifo}
    while IFS= read -r name <&3; do
      [ -n "$name" ] || continue
      ${pkgs.pipewire}/bin/pw-metadata -n default 0 default.configured.audio.sink \
        "$(${jq} -cn --arg n "$name" '{name: $n}')" Spa:String:JSON >/dev/null
    done
  '';
in
{
  config = lib.mkIf config.dashboardAssistant.sendspin.enable {
    users.groups.audio-output = { };
    users.users.audio-output = {
      isSystemUser = true;
      group = "audio-output";
      # pipewire for the graph; dashboard-assistant for the FIFO in the
      # daemon's state dir, like the kiosk user.
      extraGroups = [
        "pipewire"
        "dashboard-assistant"
      ];
      description = "Audio output agent";
    };

    systemd.tmpfiles.rules = [
      "p ${outputFifo} 0660 dashboard-assistant dashboard-assistant - -"
    ];

    systemd.services.audio-output-agent = {
      description = "Publishes the audio outputs and applies the one Home Assistant picks";
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
        User = "audio-output";
        Group = "audio-output";
        Restart = "always";
        RestartSec = 2;
        RuntimeDirectory = "audio-output";
        RuntimeDirectoryMode = "0755";

        ProtectSystem = "strict";
        ReadWritePaths = [ outputFifo ];
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
