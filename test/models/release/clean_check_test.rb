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

  # Both rungs are named — each by the signal that was actually measured. The
  # release rung's git read IS taken here (clean_ladder passes repo_states) and
  # comes back LEVEL, so the headline reports that rung's BOARD count and must not
  # claim `release ≠ main` — git said the opposite. (An earlier version of this
  # comment said the read was never taken, which the shared `clean_ladder` fixture
  # flatly contradicts; the assertion was right for the wrong stated reason, and a
  # wrong reason is what a later reader edits the code against.)
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
    refute_includes headline, "release ≠ main",
                    "that rung's git read came back LEVEL — the headline must not assert otherwise"
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

  # --- a PARTIAL read may not speak for the rung ---------------------------
  #
  # THE DEFECT. Both conflict checks gated on `states.any?`, so ONE readable repo
  # made the read look complete while another sat in `unreadable_repos`. The
  # release rung then asserted "NO repo's `release` is ahead of `main` — the trees
  # are identical" and concluded the code "may ALREADY BE IN PRODUCTION", having
  # never looked at the repo that could have been ahead. That is the most
  # dangerous output this module can produce: specific, confident, and wrong, at
  # the exact moment the operator is deciding whether to ship.
  #
  # The guard's REFUSAL never depended on the sentence (an unreadable repo is
  # dirty on its own), so withholding it costs nothing and asserting it cost the
  # truth.

  test "[unit] a PARTIAL release read never claims the trees are identical" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "riding-release" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      unreadable_repos: [{ "repo" => "turf-monster", "rung" => "release" }]
    )

    refute v["clean"], "an unreadable rung is dirty regardless — that part never changed"
    assert_nil v["release_signal_conflict"],
               "turf-monster's `release` was never read, so `the trees are identical` is unearned"
    refute_includes v["message"], "the trees are identical"
    refute_includes v["message"], "INTERRUPTED SHIP"
    refute_includes v["message"], "ALREADY BE IN PRODUCTION",
                    "telling an operator their code is live on an unread repo is the worst case"
    assert_includes v["message"], "could NOT be read", "the real finding still reaches them"
  end

  test "[unit] a PARTIAL accepted read never claims the stamp is stale" do
    v = C.evaluate(
      accepted_tasks: [{ "slug" => "parked" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      unreadable_repos: [{ "repo" => "turf-monster", "rung" => "accepted" }]
    )

    refute v["clean"]
    assert_nil v["signal_conflict"],
               "`no repo's accepted is ahead` is a claim about EVERY repo, and one went unread"
  end

  # The other DIRECTION survives a partial read, and must: "git says `accepted`
  # carries commits" names repos that were measured, and a repo nobody could read
  # cannot falsify a count that came back positive. Suppressing this one too would
  # be fail-closed theatre that throws away a true finding.
  test "[unit] a PARTIAL accepted read still names the git-side disagreement" do
    v = C.evaluate(
      accepted_tasks: [],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 3 }],
      unreadable_repos: [{ "repo" => "turf-monster", "rung" => "accepted" }]
    )

    refute_nil v["signal_conflict"], "a positive count is still a positive count"
    assert_includes v["signal_conflict"], "NO task is stamped"
    assert_includes v["signal_conflict"], "mcritchie-studio (+3)"
  end

  # PRECISION, not blanket suppression: completeness is per RUNG, derived from the
  # repo sets. turf-monster's ACCEPTED read failed while its RELEASE read landed,
  # so the release rung is complete and keeps its sentence. A coarse "any
  # unreadable repo mutes everything" rule passes every test above and fails this
  # one.
  test "[unit] a failure on ONE rung does not mute the other rung's conflict" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "riding-release" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 },
                    { "repo" => "turf-monster", "ahead" => 0 }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      unreadable_repos: [{ "repo" => "turf-monster", "rung" => "accepted" }]
    )

    refute_nil v["release_signal_conflict"],
               "every repo reported a RELEASE count — that rung's read is complete"
    assert_includes v["release_signal_conflict"], "INTERRUPTED SHIP"
  end

  # And completeness reads the REPO SETS, never the `rung` label. bin/release
  # records a missing checkout as ONE row labelled `accepted (no checkout at …)`
  # though NEITHER rung was read there, so a label match would call the release
  # rung complete and re-open the same hole through a string compare.
  test "[unit] a repo with no reading on either rung makes BOTH rungs partial" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "riding-release" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      accepted_tasks: [{ "slug" => "parked" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      unreadable_repos: [{ "repo" => "turf-monster", "rung" => "accepted (no checkout at /x)" }]
    )

    assert_nil v["release_signal_conflict"], "the label says `accepted`; the RELEASE read is missing too"
    assert_nil v["signal_conflict"]
  end

  # --- the residual half: a repo that produced NO reading and NO row ---------
  #
  # Deriving completeness from the repo sets (rather than the `rung` label) closed
  # every absence that was WRITTEN DOWN. This is the other half, and it is the
  # ecosystem guard's DEFAULT path: `ladder_ahead_states(require_checkout: false)`
  # SKIPS a repo with no local checkout — `next unless require_checkout` — leaving
  # no state row on either rung and NO `unreadable_repos` row either. With nothing
  # recorded, the sets AGREED, the read graded `:complete`, and the guard told the
  # operator their code "may ALREADY BE IN PRODUCTION" about a ladder holding a
  # repo it had never looked at.
  #
  # The rule that closes both halves at once: completeness is measured against the
  # repos the read was SUPPOSED to cover. A repo that produced no reading is unread
  # whether or not anything remembered to record why. Absence of a marker is not
  # evidence of a read — the same disease as trusting a declaration over a
  # measurement, one layer down.
  test "[unit] a repo absent from the reading makes the rung partial with NO marker of any kind" do
    measured = [{ "repo" => "mcritchie-studio", "ahead" => 0 }]

    assert_equal :partial, C.rung_read(measured, [], %w[mcritchie-studio rolio]),
                 "`rolio` was in scope and produced no reading — nothing recorded why, and it is still unread"
    # PRECISION, not blanket suppression: the same call over a scope it fully
    # covered is still complete. A rule that just downgraded everything to
    # :partial would pass the assertion above and destroy every true sentence.
    assert_equal :complete, C.rung_read(measured, [], %w[mcritchie-studio]),
                 "a read that covered its whole scope is complete"
  end

  # The consequential one, end to end. This is the exact state the ecosystem guard
  # produces with a sibling repo uncloned, and the sentence it must NOT say.
  test "[unit] the interrupted-ship claim is withheld when a repo went unread and unrecorded" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "riding-release", "title" => "Swept, QA in flight" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      unreadable_repos: [],
      expected_repos: %w[mcritchie-studio rolio]
    )

    assert_nil v["release_signal_conflict"],
               "`the trees are identical` is a claim about EVERY repo, and rolio was never read"
    assert_equal ["rolio"], v["unread_repos"], "the verdict names what it did not read"
  end

  # The accepted rung's UNIVERSAL branch needs the same complete read. Its
  # existential twin is asserted below.
  test "[unit] the accepted rung's universal claim is withheld on a silently dropped repo" do
    v = C.evaluate(
      accepted_tasks: [{ "slug" => "parked" }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      expected_repos: %w[mcritchie-studio rolio]
    )

    assert_nil v["signal_conflict"],
               "`no repo's accepted is ahead` cannot be said over a repo that produced no count"
  end

  # DIRECTION 2 — the one people skip. An unread repo must NOT flip the verdict to
  # dirty. `require_checkout: false` exists precisely so a repo nobody cloned does
  # not refuse the lane ("not evidence of pending work"), and most operators do not
  # clone every sibling. Routing the drop into `unreadable_repos` — the naive fix —
  # would make the guard refuse on every partial workstation and is why this is a
  # SEPARATE signal: it governs COMPLETENESS only, never DIRTINESS.
  test "[unit] an unread repo reports its gap without making the ladder dirty" do
    v = C.evaluate(
      pending_tasks: [],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
      expected_repos: %w[mcritchie-studio rolio]
    )

    assert v["clean"], "an uncloned sibling is not evidence of pending work — the lane stays usable"
    assert_empty v["unreadable_repos"], "and it is NOT laundered into the failed-read list"
    # But the ✓ must stop over-claiming: it says `accepted == release == main`,
    # which is a claim about every repo. Name the ones it never measured.
    assert_includes v["message"], "rolio", "the pass names the repo it did not verify"
    assert_includes v["message"], "NOT verified"
  end

  # The read-state classifier itself, at its three boundaries.
  test "[unit] rung_read distinguishes unmeasured, partial and complete" do
    assert_equal :unmeasured, C.rung_read([], []), "a --dry-run takes no fetch at all"
    assert_equal :partial, C.rung_read([], [{ "repo" => "a", "rung" => "release" }]),
                 "every repo failing is a partial read, not an absent one"
    assert_equal :partial,
                 C.rung_read([{ "repo" => "a", "ahead" => 0 }], [{ "repo" => "b", "rung" => "release" }])
    assert_equal :complete,
                 C.rung_read([{ "repo" => "a", "ahead" => 0 }], []),
                 "every repo reported"
    assert_equal :complete,
                 C.rung_read([{ "repo" => "a", "ahead" => 0 }], [{ "repo" => "a", "rung" => "accepted" }]),
                 "`a` failed on the OTHER rung but still reported here"
  end
end
