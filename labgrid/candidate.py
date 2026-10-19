"""Whether a **candidate**'s closure can be fetched, asked of the board.

Without this an update phase does not fail — it compiles a whole system on a
Raspberry Pi. The `linux-rpi` kernel is on no public cache, so the difference
between a cached candidate and an uncached one is the difference between a
**release gate** of minutes and one of a night, and a gate nobody runs holds
nothing back.

The check is split across two machines, and the split is the design:

  * the candidate's closure is resolved to a store path on the machine running
    the suite, because evaluation is pure and so gives the same path anywhere
    (store_path). On the board it would mean a full nixpkgs evaluation driven
    over a serial console.
  * whether that path can be *fetched* is asked on the board, because the
    answer depends on the board's own substituters and trusted keys
    (modules/core/binary-cache.nix). Nothing off the board can answer it — a
    cache the bench host can reach says nothing about a device
    (dry_run_command).

Everything here is pure: a command to run somewhere else, or a verdict parsed
from what came back. That is what lets nix's actual output decide the shape of
the parser rather than somebody's memory of it — the outputs in
test_candidate.py were captured from nix 2.34.9, and two of them are
counter-intuitive enough to have been worth capturing (see dry_run_command).

See README.md, "The candidate has to be in the cache", for who pushes a
candidate and when.
"""

import collections
import re


class Plan(collections.namedtuple("Plan", "fetch build unknown download unpacked")):
    """What nix would do to realise a path, and so whether the phase can run.

    `fetch` and `build` are counts of paths and derivations; `unknown` is 1
    when nix knew the path neither to fetch nor to build, which is what a
    candidate that was never pushed looks like. `download` and `unpacked` are
    nix's own size strings, kept as text so a phase can state its cost without
    re-deriving it — and None when there is nothing to fetch.
    """

    @property
    def substitutable(self):
        """Whether every missing path can come from a cache rather than a build."""
        return not self.build and not self.unknown


#: nix drops the count when there is exactly one ("this path will be fetched"),
#: so the digits are optional and their absence means one, never none.
_FETCH = re.compile(
    r"^(?:this path|these (\d+) paths) will be fetched "
    r"\(([^,]+) download, ([^)]+) unpacked\):"
)
_BUILD = re.compile(r"^(?:this derivation|these (\d+) derivations) will be built:")
_UNKNOWN = re.compile(r"^don't know how to build these paths")


def plan(output):
    """What nix says it would do, parsed from `nix-store --realise --dry-run`."""
    fetch = build = unknown = 0
    download = unpacked = None
    for line in output.splitlines():
        line = line.strip()
        match = _FETCH.match(line)
        if match:
            fetch = int(match.group(1) or 1)
            download, unpacked = match.group(2), match.group(3)
            continue
        match = _BUILD.match(line)
        if match:
            build = int(match.group(1) or 1)
            continue
        if _UNKNOWN.match(line):
            unknown = 1
    return Plan(fetch, build, unknown, download, unpacked)


#: Which nixosConfigurations attribute each board the bench drives is built
#: from, keyed by the `board` an environment file declares (labgrid/bench.yaml,
#: labgrid/qemu-x86.yaml).
#:
#: A second copy of `dashboardAssistant.update.flakeAttr` in
#: modules/hardware/, which is the value a device actually updates with. It
#: cannot be read off the board — nothing writes it to /etc, and the update
#: unit only has it spliced into a shell script — so the copy is guarded
#: instead: test_candidate.py reads the modules and fails if the two disagree.
BOARD_ATTRS = {
    "rpi4": "dashboard-assistant-rpi4",
    "rpi5": "dashboard-assistant-rpi5",
    "x86_64": "dashboard-assistant-x86-disk",
}

#: Where a device fetches a release from, as modules/core/update.nix defaults
#: `dashboardAssistant.update.flakeRef`.
FLAKE_REF = "github:ajfriesen/DashboardAssistant"

#: What a release tag may contain. The same rule modules/core/update.nix
#: applies to the ref the daemon hands it ("only safe git-tag characters, no
#: shell metachars"), for the same two reasons: the tag arrives from outside
#: and is spliced into a command line, and a tag this rejects is a tag no
#: device would install either.
_TAG = re.compile(r"^[A-Za-z0-9._-]+$")


def toplevel_installable(tag, board, flake_ref=FLAKE_REF):
    """The system closure a device updating to `tag` would build.

    The same `<flakeRef>/<tag>#<flakeAttr>` the update script assembles, with
    the attribute path down to the toplevel that `nix build` is given there.

    Raises on anything it cannot vouch for. An unknown board must not default
    to one: checking one board's closure and clearing another board's phase is
    worse than no check. And a tag that is not a tag must not reach a command
    line at all — it comes from the environment, and the harness runs the
    resolve through a shell.
    """
    if not _TAG.match(tag):
        raise ValueError(
            f"{tag!r} is not a release tag: only letters, digits, dots, "
            "hyphens and underscores, as modules/core/update.nix requires of "
            "the ref a device updates to"
        )
    attr = BOARD_ATTRS[board]
    return (
        f"{flake_ref}/{tag}"
        f"#nixosConfigurations.{attr}.config.system.build.toplevel"
    )


#: The candidate this run is gating, as a release tag. Not defaulted here, like
#: every other BENCH_*/LG_* variable: unset has to read as "this run is not
#: gating a release", never as a guess at one. The gate sets it; `just hw-test`
#: on a working tree does not.
TAG_ENV = "BENCH_CANDIDATE"

#: Which run is supposed to have put a board's closure in the cache, per board,
#: or None for a board nothing pushes for.
#:
#: Named in the failure because the fix is not discoverable from the board. A
#: `v*` tag runs .github/workflows/cache-rpi.yml, whose `build` job builds each
#: aarch64 system on a native arm64 runner and pushes the whole closure to
#: Attic — the linux-rpi kernel above all, which is on no public cache and
#: costs hours under emulation. Nothing a developer does locally pushes, and a
#: plain branch push warms the cache without producing a candidate.
#:
#: x86_64 is None, and that is the state of the world rather than an omission
#: here: .github/workflows/release-image.yml builds the image and never pushes
#: the closure, so an x86 candidate is not substitutable and the update phase
#: cannot be gated on that board. See README.md, "The candidate has to be in
#: the cache".
CACHE_WORKFLOW = ".github/workflows/cache-rpi.yml"
CACHE_SOURCES = {
    "rpi4": CACHE_WORKFLOW,
    "rpi5": CACHE_WORKFLOW,
    "x86_64": None,
}


def configured_tag(environ):
    """The candidate this run is gating, or "" if it is not gating one."""
    return environ.get(TAG_ENV, "")


def missing_candidate(tag):
    """Reason to skip a test that needs a candidate, or None if there is one.

    A skip rather than a failure: the suite runs against a working tree far
    more often than against a release, and a local run is not a broken gate.
    """
    if tag:
        return None
    return (
        f"this run is gating no candidate (${TAG_ENV} unset) — set it to the "
        "release tag under test to check its closure is in the cache"
    )


def not_in_cache(tag, board, path, verdict):
    """Why the update phase must not start, or None if the closure is there.

    Says the three things the next person needs: that the closure is missing
    rather than the board misbehaving, what running anyway would cost, and who
    was supposed to put it there. Without the last one the obvious next move
    is to let it build, which on a Raspberry Pi is the overnight job this
    check exists to prevent.
    """
    if verdict.substitutable:
        return None
    if verdict.unknown:
        did = "no cache this board trusts has heard of it"
    else:
        did = (
            f"{verdict.build} of its derivations are not in any cache this "
            "board trusts and would be compiled on the board"
        )
    workflow = CACHE_SOURCES[board]
    if workflow:
        whose = (
            f"A `v*` tag populates the cache for {board} through {workflow}, "
            f"on a native arm64 runner — so either that run has not finished, "
            f"or it failed, or {tag} was never tagged."
        )
    else:
        whose = (
            f"And nothing pushes the {board} closure to the cache: no "
            "workflow in this repository does, so this is not a run that "
            "failed — it is a gap, and the update phase cannot be gated on "
            "this board until something fills it."
        )
    return (
        f"candidate {tag} is not substitutable from this board: {did} "
        f"({path}). Running the update phase anyway would build a system on "
        f"the board instead of fetching one. {whose}"
    )


# --------------------------------------------------------------------------- #
# The two commands, and which machine each one runs on
# --------------------------------------------------------------------------- #

#: A store path, as nix prints one. Checked rather than trusted: whatever the
#: evaluation resolves to is handed to the board as the thing to look for, and
#: a board asked about a warning message reports it missing — which reads as an
#: empty cache rather than as a broken resolve.
_STORE_PATH = re.compile(r"^/nix/store/[a-z0-9]{32}-\S+$")


def store_path_command(installable):
    """Resolve `installable` to a store path, evaluating and building nothing.

    Run on the host rather than the board. Evaluation is pure, so the path is
    the same wherever it happens — while on the board it would mean a full
    nixpkgs evaluation driven over a serial console, on a machine with a few
    gigabytes of RAM.

    `--refresh` for the same reason modules/core/update.nix passes it: a tag is
    a moving reference, and resolving a cached copy of one would check a
    closure the board is not going to install.
    """
    return f"nix eval --raw --refresh {installable}.outPath"


def store_path(installable, run):
    """The store path `installable` evaluates to, as resolved by `run`.

    `run` takes a command and returns its output, so the subprocess stays with
    the caller and this stays testable with no nix anywhere near it.
    """
    output = run(store_path_command(installable)).strip()
    if not _STORE_PATH.match(output):
        raise ValueError(
            f"resolving {installable} produced no store path, but: {output!r}"
        )
    return output


def dry_run_command(path):
    """Ask the board what it would take to realise `path`, building nothing.

    Deliberately `nix-store --realise --dry-run` on a *path* rather than
    `nix build --dry-run` on a flake: the question is then answered from the
    board's own substituters and trusted keys with no evaluation at all, so it
    costs round trips instead of a nixpkgs evaluation.

    Two things about nix's behaviour this has to work around, both measured
    rather than remembered (the outputs in test_candidate.py were captured
    from nix 2.34.9):

      * the verdict goes to **stderr**, and the exit status is 0 whatever the
        answer — so stderr is merged in, and the text is what decides. A
        command reading only stdout sees every answer as the empty one, which
        means "already in the store", which is the one verdict that lets the
        phase run.
      * a cache miss is remembered for `narinfo-cache-negative-ttl`, an hour by
        default. A candidate checked while the workflow that fills the cache was still pushing would
        otherwise stay "missing" long after it had arrived, so this asks the
        cache rather than nix's memory of it.
    """
    return (
        "nix-store --realise --dry-run "
        "--option narinfo-cache-negative-ttl 0 "
        f"{path} 2>&1"
    )
