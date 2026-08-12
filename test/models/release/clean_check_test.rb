require "test_helper"

# Pure decision logic for the clean-LADDER GUARD behind `deploy-with-task`
# (`bin/release status --clean-only` and `bin/release prepare --expedite`). No
# git/board/network here — same IO-free contract as MergePlan/ShipSequence, so
# it's trivially unit-tested and the shell stays thin. The FOUR signals (a board
# and a git read on each of the `accepted` and `release` rungs) are gathered by
# bin/release; this only decides clean vs dirty and writes the message.
class Release::CleanCheckTest < ActiveSupport::TestCase
  C = Release::CleanCheck

  # --- clean: release == main (nothing else pending) -----------------------

  test "clean when there are no pending tasks and no repo is ahead of main" do
    v = C.evaluate(pending_tasks: [], repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }])
    assert v["clean"]
    assert_empty v["pending_tasks"]
    assert_empty v["ahead_repos"]
    assert_includes v["message"], "release == main"
    # The registered launcher phrase (docs/agents/agents/avi/sops/deploy-with-task.md),
    # not the retired "Deploy with Task <task>" wording.
    assert_includes v["message"], "deploy-with-task"
  end

  test "clean when both signals are empty" do
    v = C.evaluate
    assert v["clean"]
    assert_includes v["message"], "safe to expedite one task"
  end

  # --- dirty via the BOARD signal (assembled-but-unshipped tasks) ----------

  test "dirty when a task is already assembled and pending ship" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "other-work", "title" => "Some other feature" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]
    )
    refute v["clean"]
    assert_equal ["other-work"], v["pending_tasks"].map { |t| t["slug"] }
  end

  test "the dirty message REFUSES and OFFERS full-cycle, listing the pending task" do
    v = C.evaluate(pending_tasks: [{ "slug" => "other-work", "title" => "Some other feature" }])
    msg = v["message"]
    assert_includes msg, "refused", "the guard refuses on a dirty release"
    assert_includes msg, "full-cycle", "it offers shipping the whole release instead"
    assert_includes msg, "other-work", "it lists the pending task slug"
    assert_includes msg, "Some other feature", "it lists the pending task title"
    refute_includes msg, "safe to expedite"
  end

  test "a pending task with no title is listed by slug alone (no trailing dash)" do
    v = C.evaluate(pending_tasks: [{ "slug" => "bare-slug", "title" => "" }])
    assert_includes v["message"], "- bare-slug"
    refute_includes v["message"], "bare-slug —"
  end

  # --- dirty via the GIT signal (release ahead of main) --------------------

  test "dirty when a repo's release is ahead of main even with no assembled task" do
    v = C.evaluate(
      pending_tasks: [],
      repo_states: [
        { "repo" => "mcritchie-studio", "ahead" => 2 },
        { "repo" => "turf-monster", "ahead" => 0 }
      ]
    )
    refute v["clean"], "a stray commit on release with no task is still dirty (fail-closed)"
    assert_equal [{ "repo" => "mcritchie-studio", "ahead" => 2 }], v["ahead_repos"]
    assert_includes v["message"], "mcritchie-studio (+2)"
    assert_includes v["message"], "full-cycle"
  end

  test "ahead_repos excludes repos that are even with main" do
    v = C.evaluate(repo_states: [
      { "repo" => "a", "ahead" => 0 },
      { "repo" => "b", "ahead" => 3 },
      { "repo" => "c", "ahead" => 0 }
    ])
    assert_equal ["b"], v["ahead_repos"].map { |r| r["repo"] }
  end

  # --- normalization / robustness ------------------------------------------

  test "tolerates symbol keys from a board payload" do
    v = C.evaluate(pending_tasks: [{ slug: "sym-task", title: "Symbol keyed" }])
    refute v["clean"]
    assert_equal "sym-task", v["pending_tasks"].first["slug"]
    assert_equal "Symbol keyed", v["pending_tasks"].first["title"]
  end

  test "coerces a string ahead count from a shell read" do
    v = C.evaluate(repo_states: [{ "repo" => "r", "ahead" => "4" }])
    refute v["clean"]
    assert_equal 4, v["ahead_repos"].first["ahead"]
  end

  test "the verdict is JSON round-trippable (string keys, plain values)" do
    v = C.evaluate(pending_tasks: [{ "slug" => "x", "title" => "y" }])
    assert_equal v, JSON.parse(v.to_json)
  end

  # --- the ACCEPTED rung — the hole this class was blind to ----------------
  # `deploy-with-task` carries PRODUCTION AUTHORITY for one task and its whole
  # safety argument is this guard. Under the `accepted → release → main` ladder a
  # reviewed task's code already sits on `accepted`, and the sweep promotes ALL of
  # `accepted` — so a reviewed-but-unswept task rode to production alongside an
  # expedite with the guard fully GREEN, because the guard only ever looked at the
  # `release` rung. Both signals on the new rung must refuse, and (the half that
  # gets skipped) a genuinely clean ladder must still PASS.

  # The clean baseline every accepted-rung test perturbs: both rungs level, both
  # git reads actually taken.
  def clean_ladder(**overrides)
    C.evaluate(**{
      pending_tasks: [],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      accepted_tasks: [],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]
    }.merge(overrides))
  end

  test "a genuinely clean ladder still PASSES — the half that gets skipped" do
    v = clean_ladder
    assert v["clean"], "both rungs level ⇒ the express lane must stay usable"
    assert_empty v["accepted_tasks"]
    assert_empty v["accepted_ahead_repos"]
    assert_nil v["signal_conflict"], "two agreeing signals are not a conflict"
    assert_includes v["message"], "accepted == release == main"
    assert_includes v["message"], "safe to expedite one task"
    refute_includes v["message"], "refused"
  end

  test "BOARD signal: a reviewed task stamped merged:accepted makes the ladder dirty" do
    v = clean_ladder(
      accepted_tasks: [{ "slug" => "parked-work", "title" => "Reviewed, not swept" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 3 }]
    )
    refute v["clean"], "a reviewed task parked on `accepted` rides out with the expedite"
    assert_equal ["parked-work"], v["accepted_tasks"].map { |t| t["slug"] }
    assert_includes v["message"], "parked on `accepted`"
    assert_includes v["message"], "parked-work"
    assert_includes v["message"], "Reviewed, not swept"
    assert_includes v["message"], "accepted ≠ release", "the headline names the dirty rung"
    assert_includes v["message"], "full-cycle", "it offers shipping the whole release instead"
    refute_includes v["message"], "safe to expedite"
  end

  test "GIT signal: accepted ahead of release is dirty even with an empty board" do
    v = clean_ladder(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }])
    refute v["clean"], "git is the PRIMARY signal on this rung — a missing stamp must not pass"
    assert_equal [{ "repo" => "mcritchie-studio", "ahead" => 2 }], v["accepted_ahead_repos"]
    assert_includes v["message"], "`accepted` ahead of `release`"
    assert_includes v["message"], "mcritchie-studio (+2)"
  end

  test "the two accepted signals catch each other: git-only disagreement is NAMED" do
    v = clean_ladder(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }])
    refute v["clean"]
    assert_includes v["signal_conflict"], "DISAGREE"
    assert_includes v["signal_conflict"], "NO task is stamped"
    assert_includes v["message"], "DISAGREE", "a disagreement is information, so the operator sees it"
  end

  test "the two accepted signals catch each other: board-only disagreement is NAMED" do
    v = clean_ladder(accepted_tasks: [{ "slug" => "stale-stamp", "title" => "" }])
    refute v["clean"], "a stamp with no commits behind it is still fail-closed"
    assert_includes v["signal_conflict"], "DISAGREE"
    assert_includes v["signal_conflict"], "stale"
  end

  test "an UNMEASURED git signal reports no disagreement (a --dry-run preview)" do
    v = C.evaluate(accepted_tasks: [{ "slug" => "parked", "title" => "" }], accepted_states: [])
    refute v["clean"], "the board signal alone still refuses"
    assert_nil v["signal_conflict"], "a signal never taken can neither agree nor disagree"
  end

  # Both rungs are named — each by the signal that was actually measured. This
  # setup takes NO git read on the release rung (no repo_states), so the headline
  # reports that rung's BOARD count; asserting `release ≠ main` here is what the
  # old headline did, and it was claiming a tree relation nobody had read.
  test "both rungs dirty names both in the headline, by measured signal" do
    v = clean_ladder(
      pending_tasks: [{ "slug" => "riding-release", "title" => "" }],
      accepted_tasks: [{ "slug" => "parked", "title" => "" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }]
    )
    headline = v["message"].lines.first

    refute v["clean"]
    assert_includes headline, "accepted ≠ release", "the accepted rung's git signal WAS measured"
    assert_includes headline, %(1 task(s) stamped merged:"accepted")
    assert_includes headline, "1 task(s) still recorded as riding `release`"
    refute_includes headline, "release ≠ main", "that rung's git signal was never read"
    assert_includes v["message"], "riding-release"
    assert_includes v["message"], "parked"
  end

  # The same both-rungs case WITH both git reads taken: every signal is named.
  test "both rungs dirty on both signals names all four" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "riding-release" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 4 }],
      accepted_tasks: [{ "slug" => "parked" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }]
    )
    headline = v["message"].lines.first

    assert_includes headline, %(1 task(s) stamped merged:"accepted")
    assert_includes headline, "accepted ≠ release"
    assert_includes headline, "1 task(s) still recorded as riding `release`"
    assert_includes headline, "release ≠ main"
  end

  # --- the expedited task itself must not trip its own guard ---------------
  # The SOP allows re-running `deploy-with-task` on a task review already merged
  # onto `accepted`. If the guard refused on the operator's OWN task the express
  # lane would be unusable, and an unusable guard gets routed around — worse than
  # the hole, because the hole was at least documented.

  test "--task excludes the expedited task from the accepted board signal" do
    v = clean_ladder(
      accepted_tasks: [{ "slug" => "my-expedite", "title" => "The one task" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 4 }],
      expedited: "my-expedite"
    )
    assert v["clean"], "the expedited task is the ONE thing allowed on the rung"
    assert_empty v["accepted_tasks"]
    assert_equal [{ "repo" => "mcritchie-studio", "ahead" => 4 }], v["attributed_ahead_repos"]
    assert_nil v["signal_conflict"]
    assert_includes v["message"], "attributed to the expedited task `my-expedite`",
                    "a tolerated commit count is never a SILENT pass"
  end

  test "attribution does NOT extend to a second task parked alongside the expedite" do
    v = clean_ladder(
      accepted_tasks: [{ "slug" => "my-expedite", "title" => "" },
                       { "slug" => "autopilot-landed", "title" => "Merged mid-review" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 6 }],
      expedited: "my-expedite"
    )
    refute v["clean"], "the autopilot race is exactly what the promote-time guard must catch"
    assert_equal ["autopilot-landed"], v["accepted_tasks"].map { |t| t["slug"] }
    assert_equal [{ "repo" => "mcritchie-studio", "ahead" => 6 }], v["accepted_ahead_repos"]
    assert_empty v["attributed_ahead_repos"], "attribution needs SOLE occupancy, not just a name"
  end

  test "--task naming an unstamped task attributes nothing (git stays primary)" do
    v = clean_ladder(
      accepted_tasks: [],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }],
      expedited: "not-on-accepted-yet"
    )
    refute v["clean"], "commits with no stamped owner are never attributed away"
    assert_equal [{ "repo" => "mcritchie-studio", "ahead" => 2 }], v["accepted_ahead_repos"]
    assert_empty v["attributed_ahead_repos"]
  end

  test "a bare guard with no --task attributes nothing" do
    v = clean_ladder(
      accepted_tasks: [{ "slug" => "some-task", "title" => "" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 1 }]
    )
    refute v["clean"], "without an operator-named task there is nothing to attribute to"
    assert_empty v["attributed_ahead_repos"]
  end

  # --- a failed read is not a clean read -----------------------------------

  test "an unreadable rung is DIRTY, never silently skipped" do
    v = clean_ladder(unreadable_repos: [{ "repo" => "turf-monster", "rung" => "accepted" }])
    refute v["clean"], "a rung that could not be measured must not report clean"
    assert_equal [{ "repo" => "turf-monster", "rung" => "accepted" }], v["unreadable_repos"]
    assert_includes v["message"], "could NOT be read"
    assert_includes v["message"], "turf-monster/accepted"
    assert_includes v["message"], "a rung could not be read"
  end

  # --- normalization on the new inputs -------------------------------------

  test "the accepted rung tolerates symbol keys and string counts" do
    v = C.evaluate(accepted_tasks: [{ slug: "sym", title: "Symbol keyed" }],
                   accepted_states: [{ repo: "r", ahead: "5" }])
    assert_equal "sym", v["accepted_tasks"].first["slug"]
    assert_equal 5, v["accepted_ahead_repos"].first["ahead"]
  end

  test "the widened verdict is still JSON round-trippable" do
    v = clean_ladder(
      accepted_tasks: [{ "slug" => "a", "title" => "b" }],
      accepted_states: [{ "repo" => "r", "ahead" => 1 }],
      unreadable_repos: [{ "repo" => "q", "rung" => "release" }]
    )
    assert_equal v, JSON.parse(v.to_json)
  end

  # --- the headline names the SIGNAL MEASURED, not a tree relation ---------
  #
  # Each rung is judged by TWO signals (board + git). The headline used to OR them
  # and label the result with the GIT relation, so a rung dirty on the BOARD signal
  # alone asserted a tree relation nobody read. During rel-20260812-3f1f9b it
  # asserted one that was FALSE: `git ls-remote` had every repo identical across
  # all three rungs while three tasks were still recorded as riding `release`.

  # THE INCIDENT. Board dirty, git clean — the line must not claim release ≠ main.
  test "board-only dirt on the release rung reports the board count, NOT `release ≠ main`" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "a" }, { "slug" => "b" }, { "slug" => "c" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 },
                    { "repo" => "studio-engine", "ahead" => 0 }]
    )
    headline = v["message"].lines.first

    refute v["clean"]
    assert_includes headline, "3 task(s) still recorded as riding `release`"
    refute_includes headline, "release ≠ main",
                    "git said the trees are IDENTICAL — the headline must not assert otherwise"
  end

  test "git-only dirt on the release rung still reports the tree relation" do
    v = C.evaluate(repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }])
    headline = v["message"].lines.first

    assert_includes headline, "release ≠ main"
    refute_includes headline, "recorded as riding", "no task was on the board to report"
  end

  # Both signals dirty is the NORMAL case — both are named, separately.
  test "both release signals dirty reports both, separately" do
    v = C.evaluate(pending_tasks: [{ "slug" => "a" }],
                   repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }])
    headline = v["message"].lines.first

    assert_includes headline, "1 task(s) still recorded as riding `release`"
    assert_includes headline, "release ≠ main"
  end

  test "board-only dirt on the accepted rung reports the stamp count, NOT `accepted ≠ release`" do
    v = C.evaluate(accepted_tasks: [{ "slug" => "parked" }],
                   accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }])
    headline = v["message"].lines.first

    assert_includes headline, %(1 task(s) stamped merged:"accepted")
    refute_includes headline, "accepted ≠ release"
  end

  test "git-only dirt on the accepted rung still reports the tree relation" do
    v = C.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 3 }])
    assert_includes v["message"].lines.first, "accepted ≠ release"
  end

  # --- the release rung's signal conflict = an INTERRUPTED SHIP ------------

  test "board-dirty + git-clean on the release rung names the interrupted ship" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "a" }, { "slug" => "b" }, { "slug" => "c" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]
    )
    conflict = v["release_signal_conflict"]

    refute_nil conflict, "the disagreement IS the signal — it must be reported"
    assert_includes conflict, "INTERRUPTED SHIP"
    assert_includes conflict, "ALREADY BE IN PRODUCTION",
                    "this is the one moment the operator needs to know the code is out"
    assert_includes conflict, "git ls-remote", "and how to confirm it in one command"
    assert_includes v["message"], conflict, "it reaches the operator-facing message"
  end

  test "no release conflict when both signals agree that the rung is dirty" do
    v = C.evaluate(pending_tasks: [{ "slug" => "a" }],
                   repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }])
    assert_nil v["release_signal_conflict"], "board and git agree — there is no disagreement to name"
  end

  # An unmeasured signal can neither corroborate nor contradict — same rule the
  # accepted rung already follows (--dry-run takes no git read at all).
  test "no release conflict when the git read did not run" do
    v = C.evaluate(pending_tasks: [{ "slug" => "a" }], repo_states: [])
    assert_nil v["release_signal_conflict"]
  end

  test "a clean ladder reports no release conflict" do
    v = C.evaluate(repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }])
    assert v["clean"]
    assert_nil v["release_signal_conflict"]
  end
end
