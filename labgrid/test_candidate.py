"""Unit tests for candidate.py — no bench, no board, no network.

The verdicts here are what decides whether the update phase runs at all, so
they are worth testing against nix's real output rather than a paraphrase of
it: every `OUTPUT_*` constant below was captured from `nix-store --realise
--dry-run` (nix 2.34.9) rather than written from memory.
"""

import pathlib
import re

import pytest
import yaml

import candidate

WORKFLOWS = pathlib.Path(__file__).resolve().parent.parent / ".github/workflows"


def _boards_matrixed_by(job):
    """Which boards a job fans out over, if it does. Both spellings: an
    `include` table of entries carrying a `board`, and a bare `board:` list."""
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    boards = {e["board"] for e in matrix.get("include") or [] if "board" in e}
    listed = matrix.get("board") or []
    return boards | {b for b in listed if isinstance(b, str)}


#: A closure nix can substitute in full. The one answer that lets the update
#: phase run.
OUTPUT_FETCH = (
    "these 1274 paths will be fetched (456.7 MiB download, 1.2 GiB unpacked):\n"
    "  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-dashboard-1.2.0\n"
    "  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-linux-6.12\n"
)


def test_a_closure_nix_will_fetch_is_substitutable():
    assert candidate.plan(OUTPUT_FETCH).substitutable


#: A closure with something nix would compile. The answer the whole ticket
#: exists to prevent: on a Raspberry Pi this is an overnight job.
OUTPUT_BUILD = (
    "these 3 derivations will be built:\n"
    "  /nix/store/cccccccccccccccccccccccccccccccc-linux-6.12.drv\n"
    "these 42 paths will be fetched (12.0 MiB download, 40.0 MiB unpacked):\n"
    "  /nix/store/dddddddddddddddddddddddddddddddd-glibc-2.40\n"
)

#: Nothing knows the path at all — no cache has it and no .drv is on the board.
#: What a candidate that was never pushed looks like from here.
OUTPUT_UNKNOWN = (
    "don't know how to build these paths:\n"
    "  /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-nixos-system-dashboard-1.2.0\n"
)

#: nix says nothing at all when the path is already in the local store.
OUTPUT_PRESENT = ""


def test_a_closure_nix_would_compile_is_not_substitutable():
    """The failure this whole check exists to catch, and it hides behind a
    fetch section — most of the closure substitutes fine and three derivations
    do not, which is exactly the shape that reads as success at a glance."""
    assert not candidate.plan(OUTPUT_BUILD).substitutable


def test_a_path_no_cache_knows_is_not_substitutable():
    assert not candidate.plan(OUTPUT_UNKNOWN).substitutable


def test_a_closure_already_on_the_board_is_substitutable():
    """Nothing to fetch and nothing to build is the best possible answer, and
    nix says it by saying nothing."""
    assert candidate.plan(OUTPUT_PRESENT).substitutable


def test_the_download_size_is_carried_so_a_phase_can_state_its_cost():
    assert candidate.plan(OUTPUT_FETCH).download == "456.7 MiB"


def test_how_much_would_be_built_is_counted_not_just_noticed():
    """A phase that says "3 derivations" sends someone to the right place; one
    that says "not substitutable" does not."""
    assert candidate.plan(OUTPUT_BUILD).build == 3


def test_a_single_path_reads_as_one_rather_than_none():
    """nix drops the count when there is exactly one — "this path will be
    fetched" — and a parser keyed on the digits alone reads that as zero."""
    one = "this path will be fetched (12.5 KiB download, 46.9 KiB unpacked):\n"
    assert candidate.plan(one).fetch == 1


# --------------------------------------------------------------------------- #
# Which closure, exactly
#
# The point of asking at all is that the path checked here is the path the
# update will build. A near-miss — the wrong attribute, the wrong flake, the
# tag resolved differently — would produce a green check in front of a phase
# that then compiles a kernel on a Pi.
# --------------------------------------------------------------------------- #


def test_the_installable_is_the_one_the_update_builds():
    """Spelled out rather than assembled from the parts, so a change to the
    shape has to be made here too, where update.nix's own string is in view:

        target="${cfg.flakeRef}/$ref#${cfg.flakeAttr}"
    """
    assert candidate.toplevel_installable("v1.2.0", "rpi5") == (
        "github:ajfriesen/DashboardAssistant/v1.2.0"
        "#nixosConfigurations.dashboard-assistant-rpi5.config.system.build.toplevel"
    )


def test_a_board_this_bench_does_not_know_is_a_configuration_error():
    """Never a silent pass: an unknown board that resolved to some default
    would check one board's closure and clear another board's phase."""
    with pytest.raises(KeyError):
        candidate.toplevel_installable("v1.2.0", "nosuchboard")


def test_every_board_resolves_to_the_attribute_its_module_declares():
    """The drift guard. This mapping is a second copy of what
    `dashboardAssistant.update.flakeAttr` says in modules/hardware/, and a
    device updates using the module's value, not this one — so if they ever
    disagree, this check is pointing at a closure no device will ever install.
    """
    declared = set()
    modules = pathlib.Path(__file__).resolve().parent.parent / "modules" / "hardware"
    for path in sorted(modules.glob("*.nix")):
        declared.update(
            re.findall(
                r'dashboardAssistant\.update\.flakeAttr\s*=\s*"([^"]+)"',
                path.read_text(encoding="utf-8"),
            )
        )
    assert declared, "no flakeAttr found in modules/hardware — did the option move?"
    assert set(candidate.BOARD_ATTRS.values()) <= declared


# --------------------------------------------------------------------------- #
# What the phase says instead of silently building
# --------------------------------------------------------------------------- #

PATH = "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-nixos-system-dashboard-1.2.0"


def test_a_missing_candidate_is_reported_as_missing_from_the_cache():
    """Not as a flaky board, not as a slow phase. The cause and the fix are
    the same sentence or somebody re-runs it and waits out the build."""
    message = candidate.not_in_cache("v1.2.0", "rpi5", PATH, candidate.plan(OUTPUT_UNKNOWN))

    assert "v1.2.0" in message
    assert PATH in message
    assert "cache" in message


def test_the_message_says_what_would_happen_if_it_ran_anyway():
    """The reason this is a hard stop rather than a warning."""
    message = candidate.not_in_cache("v1.2.0", "rpi5", PATH, candidate.plan(OUTPUT_BUILD))

    assert "build" in message
    assert "3" in message


def test_the_message_says_who_pushes_a_candidate_and_when():
    """Nobody reading this failure knows that a tag is what populates the
    cache. Without it the next move is to build the thing by hand on the board,
    which is the exact outcome the check exists to prevent."""
    message = candidate.not_in_cache("v1.2.0", "rpi5", PATH, candidate.plan(OUTPUT_UNKNOWN))

    assert candidate.CACHE_WORKFLOW in message
    assert "`v*` tag" in message


def test_a_substitutable_closure_has_nothing_to_report():
    assert candidate.not_in_cache("v1.2.0", "rpi5", PATH, candidate.plan(OUTPUT_FETCH)) is None


# --------------------------------------------------------------------------- #
# Whether this run is gating a candidate at all
# --------------------------------------------------------------------------- #


def test_a_run_given_no_candidate_skips_and_says_how_to_give_it_one():
    """The everyday case: `just hw-test` on a working tree is not gating a
    release, and must not fail for not being one."""
    reason = candidate.missing_candidate("")

    assert candidate.TAG_ENV in reason


def test_a_run_given_a_candidate_does_not_skip():
    assert candidate.missing_candidate("v1.2.0") is None


# --------------------------------------------------------------------------- #
# The two commands: resolve the path off the board, ask the board about it
#
# Resolving is a pure evaluation and so gives the same store path on any
# machine — which is what lets it happen on the host, where it takes seconds
# rather than minutes and cannot run a Pi out of memory. The *question* is
# always asked on the board: whether a closure is reachable depends on the
# board's own substituters and trusted keys, and nothing off the board can
# answer that for it.
# --------------------------------------------------------------------------- #


def test_the_board_is_asked_about_the_path_and_builds_nothing():
    command = candidate.dry_run_command(PATH)

    assert "--dry-run" in command
    assert PATH in command


def test_the_verdict_is_not_lost_on_stderr():
    """nix writes "these N paths will be fetched" to stderr and exits 0 either
    way, so a command that only captures stdout reads every answer as "already
    in the store" — the one verdict that lets the phase run."""
    assert "2>&1" in candidate.dry_run_command(PATH)


def test_a_stale_negative_answer_cannot_decide_the_gate():
    """nix remembers a cache miss for an hour by default. A check that ran
    while the tag's CI was still building would then keep reporting the
    candidate missing long after it arrived."""
    assert "narinfo-cache-negative-ttl 0" in candidate.dry_run_command(PATH)


def test_resolving_the_path_evaluates_and_does_not_build():
    command = candidate.store_path_command("github:x/y/v1#attr.toplevel")

    assert command.startswith("nix eval ")
    assert "github:x/y/v1#attr.toplevel.outPath" in command


def test_resolving_re_reads_the_tag_rather_than_a_cached_copy():
    """update.nix passes --refresh for the same reason: a tag is a moving
    reference, and the harness has to resolve the revision the board would."""
    assert "--refresh" in candidate.store_path_command("github:x/y/v1#attr.toplevel")


def test_a_resolved_path_is_stripped_of_the_noise_around_it():
    run = lambda command: f"  {PATH}\n"  # noqa: E731

    assert candidate.store_path("github:x/y/v1#a.toplevel", run) == PATH


def test_an_evaluation_that_answers_with_anything_but_a_store_path_is_an_error():
    """A warning on stdout, an empty answer, a half-written path: all of them
    would be handed to the board as a path to look for, and the board would
    dutifully report it missing — blaming the cache for a broken resolve."""
    run = lambda command: "warning: ignoring untrusted substituter\n"  # noqa: E731

    with pytest.raises(ValueError, match="store path"):
        candidate.store_path("github:x/y/v1#a.toplevel", run)


# --------------------------------------------------------------------------- #
# Which board's closure, and who fills the cache for it
#
# One answer for every board now. .github/workflows/boards.yml builds each
# board's closure on a runner of its own architecture and pushes it — the
# linux-rpi kernel above all, which is on no public cache and costs hours under
# emulation, but equally the x86_64 toplevel, which no public cache has either
# because it is this repository's own output. Before that workflow existed the
# two halves of the fleet were built in two different shapes and only the Pis
# were pushed (issue #55).
# --------------------------------------------------------------------------- #


def test_a_board_is_told_which_run_was_supposed_to_push_its_closure():
    message = candidate.not_in_cache(
        "v1.2.0", "rpi5", PATH, candidate.plan(OUTPUT_UNKNOWN)
    )

    assert "boards.yml" in message


def test_every_board_is_told_the_same_thing():
    """No board is left with "nothing pushes for this one", which is what x86_64
    was told until the flows were unified. A board that cannot be pushed for
    cannot have its update phase gated at all, so if that ever becomes true
    again it needs saying here rather than being implied by a silence."""
    for board in candidate.BOARD_ATTRS:
        message = candidate.not_in_cache(
            "v1.2.0", board, PATH, candidate.plan(OUTPUT_UNKNOWN)
        )

        assert candidate.CACHE_WORKFLOW in message, board
        assert board in message


def test_the_workflow_named_in_the_failure_exists():
    """The message sends somebody to a path. A rename that left this behind
    would send them to a file that is not there — which is exactly what
    happened to `cache-rpi.yml`."""
    workflow = (
        pathlib.Path(__file__).resolve().parent.parent / candidate.CACHE_WORKFLOW
    )

    assert workflow.is_file(), workflow


def test_no_board_waits_on_another_boards_closure():
    """`needs` takes a whole job and never one leg of its matrix, and
    `fail-fast: false` does not change that. So a workflow that matrixes a job
    over the boards and then has another job `needs` it gates *every* board on
    every board: one flaky arm64 runner, and a `v*` tag publishes no images at
    all, x86_64's included, however green its own closure was. That is why
    boards.yml calls board.yml once per board instead of matrixing two jobs
    (issue #55, PR #57).

    Stated over every workflow rather than over boards.yml alone, because the
    cheap way to reintroduce this is to inline board.yml back."""
    offenders = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        jobs = yaml.safe_load(path.read_text()).get("jobs") or {}
        for name, job in jobs.items():
            needs = job.get("needs") or []
            for upstream in [needs] if isinstance(needs, str) else needs:
                boards = _boards_matrixed_by(jobs.get(upstream) or {})
                if boards:
                    offenders.append(f"{path.name}: {name} needs {upstream}, "
                                     f"which is matrixed over {sorted(boards)}")

    assert not offenders, "\n".join(offenders)


def test_the_flake_reference_is_the_one_a_device_updates_from():
    """The other half of the drift guard. A device resolves a release through
    `dashboardAssistant.update.flakeRef`, which defaults to `repo` — so a
    check pointed at a different repository would resolve a closure nothing
    will ever install, and the cache it then blames would be the wrong one."""
    update = (
        pathlib.Path(__file__).resolve().parent.parent
        / "modules"
        / "core"
        / "update.nix"
    ).read_text(encoding="utf-8")
    repo = re.search(r'default = "(ajfriesen/[^"]+)"', update)

    assert repo, "update.nix no longer defaults `repo` — has the option moved?"
    assert candidate.FLAKE_REF == f"github:{repo.group(1)}"


def test_a_tag_that_is_not_a_tag_never_reaches_a_command_line():
    """`BENCH_CANDIDATE` comes from the environment and is spliced into a
    command the harness runs with a shell, so it is an injection point.

    modules/core/update.nix validates the ref the same way before splicing it
    into its own flake reference ("only safe git-tag characters, no shell
    metachars"), and for the same reason — so the harness refuses exactly what
    a device would refuse, rather than resolving something no device could
    install.
    """
    with pytest.raises(ValueError, match="not a release tag"):
        candidate.toplevel_installable("v1.2.0; rm -rf ~", "rpi5")


def test_a_tag_with_the_characters_a_release_actually_uses_is_accepted():
    """The validation has to let a real tag through: release-please cuts
    `v1.2.0` and `v1.2.0-rc.1`, so dots and hyphens are not optional."""
    assert "v1.2.0-rc.1" in candidate.toplevel_installable("v1.2.0-rc.1", "rpi5")
