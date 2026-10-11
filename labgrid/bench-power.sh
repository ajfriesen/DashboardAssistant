#!/usr/bin/env bash
# Power control for the board on the bench, via an ESPHome smart plug.
#
# labgrid's ExternalPowerDriver calls this (see bench.yaml). It is not wired
# through NetworkPowerDriver because ESPHome's web server wants POST for actions,
# while labgrid's built-in REST backends speak GET (simplerest) or PUT (rest) —
# and NetworkPowerDriver only imports backends from inside its own package, so a
# custom one would mean patching labgrid.
#
# The plug is an Athom Plug V3 (ESP32-C3) running ESPHome with web_server v2.
# Entity ids come from its own /events stream:
#   switch-switch   the relay
#   sensor-power    active power draw in W
#
# Override the defaults per bench:
#   DA_PLUG_URL=http://10.0.0.5 DA_PLUG_SWITCH=relay ./bench-power.sh on
set -euo pipefail

url="${DA_PLUG_URL:-http://192.168.178.245}"
switch="${DA_PLUG_SWITCH:-switch}"

usage() {
  cat >&2 <<'USAGE'
usage: bench-power.sh {on|off|cycle|state|draw}

  on      energise the plug
  off     de-energise the plug
  cycle   off, settle, on
  state   print ON or OFF
  draw    print active power draw in watts

env: DA_PLUG_URL (default http://192.168.178.245), DA_PLUG_SWITCH (default switch)
USAGE
}

# --fail so a 404 (wrong entity id) is an error rather than a silent no-op, which
# would otherwise look like "the board did not boot".
post() { curl -fsS -m 10 -X POST "$url/switch/$switch/$1" >/dev/null; }
get() { curl -fsS -m 10 "$url$1"; }

case "${1:-}" in
  on) post turn_on ;;
  off) post turn_off ;;
  # Only used when driving the plug by hand; labgrid's ExternalPowerDriver does
  # its own off/delay/on, so bench.yaml deliberately does not set cmd_cycle.
  cycle)
    post turn_off
    sleep 5
    post turn_on
    ;;
  state) get "/switch/$switch" | jq -r '.state' ;;
  draw) get "/sensor/power" | jq -r '.value' ;;
  *)
    usage
    exit 2
    ;;
esac
