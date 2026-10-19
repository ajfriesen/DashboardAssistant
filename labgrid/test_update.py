"""The update phase, and the precondition that makes it tolerable.

An update test's subject is the upgrade path a device in someone's hallway
takes: Home Assistant triggers it, the device resolves the release, installs a
**generation** and reaches a **good boot**. None of that is here yet — see
issue #44.

What is here is the precondition, because without it an update test does not
fail, it *compiles a system on a Raspberry Pi*. The linux-rpi kernel is on no
public cache; a **release gate** that takes a night is a release gate nobody
runs, and a gate nobody runs does not hold anything back. So this file starts
by asking the board whether the **candidate**'s closure can be fetched, and
says plainly when it cannot.

Runs on any target, bench or VM: the question is about a closure and a cache,
not about a panel or a plug. It skips itself when the run is gating no
candidate, which is most runs. See candidate.py and README.md, "The candidate
has to be in the cache".
"""

import candidate


def test_the_candidates_closure_is_substitutable_from_the_board(
    candidate_tag, board, candidate_closure
):
    """The acceptance criterion, asked where it matters.

    Asked *on the board* rather than inferred from a cache the bench host can
    reach: what a device can fetch is decided by the device's own substituters
    and trusted signing keys (modules/core/binary-cache.nix), and a bench host
    with a developer's nix.conf answers a different question entirely.

    `build == 0` is the bar rather than "mostly cached". A closure that is 99%
    cached and 1% compiled is still a kernel build on a Pi, and that is the
    whole cost this check exists to refuse.
    """
    path, verdict = candidate_closure

    assert verdict.substitutable, candidate.not_in_cache(
        candidate_tag, board, path, verdict
    )


def test_the_whole_closure_is_accounted_for(candidate_closure):
    """A verdict nix did not actually give must not read as a pass.

    Every other answer here is a count that defaults to zero, so a command
    that silently produced nothing — a shell that ate it, a console that lost
    it, a timeout — arrives as "nothing to fetch and nothing to build", which
    is indistinguishable from the best possible answer. A freshly flashed
    board does not have a release's closure in its store, so something has to
    be fetched; if nothing is, the question was not asked.
    """
    path, verdict = candidate_closure

    assert verdict.fetch, (
        f"nix said nothing about {path} — it reports an empty plan only when "
        "the closure is already in the local store, which a board that was "
        "just flashed cannot be. Treat this as the query having failed, not "
        "as a cache hit."
    )
