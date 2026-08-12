require "test_helper"

# Pure decision logic for prepare's STALE-TREE GATE. No git/board/network here —
# same IO-free contract as CleanCheck/MergePlan/ShipSequence, so the verdict and
# every word of the refusal are unit-testable and the shell stays thin.
#
# THE DEFECT UNDER TEST (measured live 2026-08-11): a commit that reached
# `accepted` with no task behind it is invisible to prepare's board-stamp-driven
# promote, so the promote is SKIPPED, the deploy half succeeds on the OLD tree,
# and prepare prints `✓ Assembled`. Both printed sentences were true — of a tree
# that did not contain the fix. This module is what turns that into a refusal.
#
# BOTH DIRECTIONS ARE PROVEN HERE, and the second is the one that matters just as
# much: a genuinely up-to-date candidate must still PASS, or every interrupted
# sweep (common — they get killed by shell timeouts) becomes a manual repair.
class Release::StaleTreeCheckTest < ActiveSupport::TestCase
  S = Release::StaleTreeCheck

  ZAP = [{ "sha" => "ed4d16a", "subject" => "Correct the public price claim" }].freeze

  # --- direction 1: a stranded commit is CAUGHT ------------------------------

  test "stale when a repo's accepted is ahead of release after the promote" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }])

    refute v["fresh"], "an accepted commit missing from release makes the candidate's tree stale"
    assert_equal ["mcritchie-studio"], v["stale_repos"].map { |r| r["repo"] }
    assert_includes v["message"], "prepare refused"
    assert_includes v["message"], "does NOT contain `accepted`"
  end

  test "the refusal names the stranded commits, not just a count" do
    v = S.evaluate(
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }],
      stranded_commits: { "mcritchie-studio" => ZAP }
    )

    assert_includes v["message"], "1 commit stranded on `accepted`"
    assert_includes v["message"], "ed4d16a", "the SHA the operator has to go land"
    assert_includes v["message"], "Correct the public price claim", "…and what it was"
  end

  test "the refusal spells out the exact recovery with the repo and the SHA filled in" do
    v = S.evaluate(
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }],
      stranded_commits: { "mcritchie-studio" => ZAP },
      repo_nwo: { "mcritchie-studio" => "McRitchie-Studio/mcritchie-studio" },
      release_slug: "rel-0812"
    )

    msg = v["message"]
    # A refusal that does not name its remedy just moves the confusion.
    assert_includes msg, "gh pr create --repo McRitchie-Studio/mcritchie-studio --base release --head accepted"
    assert_includes msg, "watch that PR's CI", "the operator must not merge a red batch PR"
    assert_includes msg, "gh pr merge --repo McRitchie-Studio/mcritchie-studio <pr-url> --merge " \
                         "--match-head-commit ed4d16a"
    assert_includes msg, "bin/release prepare", "…and the re-run that finishes the job"
  end

  test "the recovery merge is pinned at the NEWEST stranded commit" do
    v = S.evaluate(
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }],
      stranded_commits: { "mcritchie-studio" => [{ "sha" => "newest1", "subject" => "Later" },
                                                 { "sha" => "older22", "subject" => "Earlier" }] }
    )

    # git log is newest-first, and the pin must be the accepted HEAD the recovery
    # PR's CI ran against — pinning the older commit would reject the real merge.
    assert_includes v["message"], "--match-head-commit newest1"
    refute_includes v["message"], "--match-head-commit older22"
  end

  test "a refusal without a commit list still refuses and says how to look them up" do
    v = S.evaluate(accepted_states: [{ "repo" => "turf-monster", "ahead" => 3 }])

    refute v["fresh"], "an unavailable commit list must never soften the verdict"
    assert_includes v["message"], "3 commits stranded on `accepted`"
    assert_includes v["message"], "git log --oneline origin/release..origin/accepted"
  end

  test "every stale repo in a multi-repo candidate is named with its own recovery" do
    v = S.evaluate(
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 },
                        { "repo" => "turf-monster", "ahead" => 0 },
                        { "repo" => "rolio", "ahead" => 2 }],
      repo_nwo: { "mcritchie-studio" => "McRitchie-Studio/mcritchie-studio",
                  "rolio" => "McRitchie-Studio/rolio" }
    )

    assert_equal %w[mcritchie-studio rolio], v["stale_repos"].map { |r| r["repo"] }
    assert_includes v["message"], "--repo McRitchie-Studio/mcritchie-studio"
    assert_includes v["message"], "--repo McRitchie-Studio/rolio"
    refute_includes v["message"], "turf-monster", "a level repo is not part of the refusal"
  end

  # --- direction 2: a genuinely current candidate must still PASS ------------
  #
  # If re-runs start refusing, resumability breaks and every interrupted sweep
  # becomes a manual repair. These are the tests that keep the lane usable.

  test "fresh when every measured repo's release already carries accepted" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 },
                                     { "repo" => "turf-monster", "ahead" => 0 }])

    assert v["fresh"], "a level ladder is the NORMAL post-promote state — it must not refuse"
    assert_empty v["stale_repos"]
    assert_includes v["message"], "carries every `accepted` commit"
    assert_includes v["message"], "mcritchie-studio, turf-monster", "the OK names what it verified"
    refute_includes v["message"], "refused"
  end

  test "an assembled candidate that is genuinely current still passes" do
    # The resumability case: prepare re-run over an untouched assembled RC (an
    # interrupted sweep, a QA re-deploy). `assembled` is not itself suspicious —
    # only a stale TREE is.
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                   release_slug: "rel-0812", release_state: "assembled")

    assert v["fresh"], "an up-to-date assembled candidate must re-run, not refuse"
    refute_includes v["message"], "refused"
  end

  # --- a failed read is not a clean read -------------------------------------

  test "an unreadable rung is stale, never skipped" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                   unreadable_repos: [{ "repo" => "turf-monster", "rung" => "accepted" }])

    refute v["fresh"], "a rung the gate could not measure is unverified, and unverified is stale"
    assert_equal ["turf-monster"], v["unreadable_repos"].map { |r| r["repo"] }
    assert_includes v["message"], "could NOT be read"
    assert_includes v["message"], "a failed read is not a clean read"
  end

  test "no signals at all is fresh — an unmeasured gate reports nothing to refuse" do
    # The --dry-run shape: bin/release skips the gate entirely rather than
    # feeding it empty input, but the module must not invent a refusal from
    # silence either.
    v = S.evaluate

    assert v["fresh"]
    assert_includes v["message"], "no three-rung repo in the deploy plan"
  end

  # --- the argument, encoded in the message ----------------------------------

  test "an assembled candidate is told WHY prepare will not just re-promote for it" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }],
                   stranded_commits: { "mcritchie-studio" => ZAP },
                   release_slug: "rel-0812", release_state: "assembled")

    # Option (a) — silently re-promoting onto a QA-green candidate — is the
    # convenient fix and the wrong one; the tool owes the operator the reason.
    assert_includes v["message"], "already `assembled` (QA-green)"
    assert_includes v["message"], "will NOT silently promote onto it"
    assert_includes v["message"], "a tree nobody tested"
  end

  test "a not-yet-assembled candidate is spared the QA-verdict paragraph" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }],
                   release_slug: "rel-0812", release_state: "assembling")

    refute_includes v["message"], "QA-green", "no QA verdict exists yet to protect"
    assert_includes v["message"], "prepare refused", "…but it still refuses"
  end

  test "the refusal explains why the promote missed the commit" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }])

    # Without this the operator reads the refusal as a malfunction and re-runs,
    # which changes nothing.
    assert_includes v["message"], "BOARD STAMPS"
    assert_includes v["message"], %(merged:"accepted")
    assert_includes v["message"], "conductor zap"
  end

  test "the refusal states that nothing was deployed" do
    v = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }])

    assert_includes v["message"], "NOTHING was published, gated, or deployed"
    assert_includes v["message"], "members keep their stage"
  end

  # --- shared plumbing --------------------------------------------------------

  test "the ahead filter is CleanCheck's, so the two ladder guards cannot drift" do
    # A second implementation of "which repos are ahead" is how this gate and the
    # clean-ladder guard would end up disagreeing about the same rung.
    states = [{ "repo" => "a", "ahead" => 0 }, { "repo" => "b", "ahead" => 4 }]
    assert_equal Release::CleanCheck.ahead_repos(states),
                 S.evaluate(accepted_states: states)["stale_repos"]
  end

  test "symbol keys are tolerated on states and commits alike" do
    v = S.evaluate(accepted_states: [{ repo: "mcritchie-studio", ahead: 1 }],
                   stranded_commits: { "mcritchie-studio" => [{ sha: "abc1234", subject: "Zap" }] })

    refute v["fresh"]
    assert_includes v["message"], "abc1234 Zap"
  end
end
