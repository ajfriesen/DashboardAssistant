#!/usr/bin/env bash
# Run a command with the bench place acquired — the prelude every `just hw-*`
# recipe shares.
#
# labgrid's acquire is not idempotent: acquiring a place you already hold is an
# error ("You have already acquired place ..."), so a recipe that unconditionally
# acquires breaks the `just hw-acquire` + `pytest --lg-initial-state shell`
# workflow, where the point is to hold the place across several runs. Hence
# acquire-if-nobody-holds-it, release-only-what-we-acquired:
#
#   nobody holds it   acquire, run, release on the way out (even on failure)
#   we hold it        run, and leave it held
#   someone else      refuse, and say who
#
# The last case is the one worth being strict about. A bench with two users is
# exactly where "it passed for me" comes from.
set -euo pipefail

: "${LG_PLACE:?set LG_PLACE (the place to acquire)}"
: "${LG_COORDINATOR:?set LG_COORDINATOR (host:port of the coordinator)}"

if [ "$#" -eq 0 ]; then
  echo "usage: with-place.sh COMMAND [ARGS...]" >&2
  exit 2
fi

# Same identity string labgrid builds for place ownership — socket.gethostname()
# and getpass.getuser(), both overridable through LG_HOSTNAME / LG_USERNAME.
mine="${LG_HOSTNAME:-$(hostname)}/${LG_USERNAME:-$(id -un)}"
owner=$(labgrid-client -p "$LG_PLACE" show | awk '$1 == "acquired:" { print $2; exit }')

case "$owner" in
  None)
    labgrid-client -p "$LG_PLACE" acquire
    # Release whatever happens next, including a failed test run — an abandoned
    # lock on a shared bench is worse than a lost run.
    trap 'labgrid-client -p "$LG_PLACE" release' EXIT
    ;;
  "$mine") ;;
  *)
    echo "place $LG_PLACE is held by $owner, not $mine" >&2
    echo "ask them to release it, or run: labgrid-client -p $LG_PLACE allow $mine" >&2
    exit 1
    ;;
esac

"$@"
