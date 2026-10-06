# frozen_string_literal: true

# `bin/release status`: the ladder report and --clean-only.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_status_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliStatusTest < ReleaseCliHarness
  def test_status_clean_ladder_reports_both_rungs_level
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]),
                  call: "status")

    assert_includes out, "release == main", "a clean ladder reports release == main"
    assert_includes out, "accepted == release", "…and the rung beneath it"
    assert_includes out, "safe to expedite one task"
    assert_includes out, "deploy-with-task", "the hint names the registered launcher phrase"
    refute_includes out, "refused", "a genuinely clean ladder is NOT refused — the lane stays usable"
  end

  def test_status_clean_only_refuses_a_dirty_release_and_offers_the_composition
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [{ "slug" => "other-work", "title" => "Other feature" }], ahead: []),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message.to_s); end")

    assert_includes out, "refused", "a dirty release is refused"
    assert_includes out, "other-work", "the refusal lists the pending assembled task"
    assert_includes out, "full-cycle", "it offers shipping the whole release instead"
    assert_includes out, "ABORTED", "--clean-only gates: a dirty release aborts the expedite (non-zero exit)"
    refute_includes out, "NO-ABORT", "the expedite must not fall through past the guard"
  end

  def test_status_clean_only_refuses_when_release_is_ahead_of_main
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 2 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "ahead of main", "the git signal alone (a stray release commit) makes it dirty"
    assert_includes out, "mcritchie-studio (+2)"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  def test_status_without_clean_only_reports_but_never_aborts
    out = run_cli(["status"],
                  setup: status_stub(pending: [{ "slug" => "other-work", "title" => "Other feature" }], ahead: []),
                  call: "status; puts('DONE-NO-ABORT')")

    assert_includes out, "other-work", "plain status still reports the dirty state"
    assert_includes out, "DONE-NO-ABORT", "plain status is informational — it reports but never aborts"
  end

  def test_status_withholds_the_production_claim_when_a_repo_has_no_checkout
    out = run_cli(["status"], setup: uncloned_repo_stub, call: "status")

    refute_includes out, "ALREADY BE IN PRODUCTION",
                    "rolio produced no reading — the guard must not speak for the whole ladder"
    assert_includes out, "NOT verified: rolio", "…and it must name the repo it never opened"
  end

  # DIRECTION 2 — the one people skip. With every repo readable the sentence must
  # STILL fire. A fix that merely suppressed the claim, or that keyed off the
  # presence of a scope rather than a gap in it, passes the test above and quietly
  # destroys the most consequential finding this guard can report.
  def test_status_still_reports_the_interrupted_ship_when_every_repo_is_read
    out = run_cli(["status"], setup: uncloned_repo_stub(clone_rolio: true), call: "status")

    assert_includes out, "ALREADY BE IN PRODUCTION", "a COMPLETE read keeps its explanation"
    refute_includes out, "NOT verified", "nothing went unread, so nothing is disclaimed"
  end

  # --- the ACCEPTED rung, end to end through the CLI -----------------------
  # The hole: `status` read only the tasks riding `release`, so a task sitting
  # `reviewed` with merged:"accepted" was invisible — and the sweep promotes ALL
  # of `accepted`, so it rode to production alongside an expedite with the guard
  # GREEN. These prove the CLI now aborts on that state, and (the other half)
  # that a genuinely clean ladder still exits 0.

  def test_status_clean_only_refuses_a_task_parked_on_accepted
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted: [{ "slug" => "parked-work", "title" => "Reviewed, not swept" }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 3 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "parked on `accepted`", "the guard now SEES the accepted rung"
    assert_includes out, "parked-work"
    assert_includes out, "full-cycle"
    assert_includes out, "ABORTED", "a task parked on `accepted` aborts the expedite"
    refute_includes out, "NO-ABORT", "the expedite must not fall through past the guard"
  end

  def test_status_clean_only_refuses_when_accepted_is_ahead_with_no_stamp
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 2 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "mcritchie-studio (+2)", "git is PRIMARY on this rung — a missing stamp cannot pass"
    assert_includes out, "DISAGREE", "the board/git disagreement is itself reported"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  def test_status_clean_only_does_not_refuse_on_the_expedited_task_itself
    out = run_cli(["status", "--clean-only", "--task", "my-expedite"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted: [{ "slug" => "my-expedite", "title" => "The one task" }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 4 }]),
                  call: "status; puts('NO-ABORT')")

    assert_includes out, "NO-ABORT", "re-running the act after review merged YOUR task must still pass"
    assert_includes out, "attributed to the expedited task `my-expedite`",
                    "the tolerated count is stated, never silently swallowed"
    refute_includes out, "refused"
  end

  def test_status_clean_only_refuses_a_second_task_landed_beside_the_expedite
    out = run_cli(["status", "--clean-only", "--task", "my-expedite"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted: [{ "slug" => "my-expedite", "title" => "" },
                                                { "slug" => "autopilot-landed", "title" => "Merged mid-review" }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 6 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "autopilot-landed", "the autopilot race is named"
    refute_includes out, "my-expedite —", "the operator's own task is not listed against them"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  def test_status_clean_only_refuses_an_unreadable_rung
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     unreadable: [{ "repo" => "turf-monster", "rung" => "accepted" }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "could NOT be read", "a failed read is not a read that came back clean"
    assert_includes out, "turf-monster/accepted"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end
end
