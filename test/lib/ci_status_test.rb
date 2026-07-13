# frozen_string_literal: true

# Unit test for bin/lib/ci_status.rb — the GitHub-CI verdict the dor-check merge gate
# reads. Pure mapping (gh `bucket` → state); no network. Run directly:
#   ruby -Itest test/lib/ci_status_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/ci_status"

class CiStatusTest < Minitest::Test
  def test_red_when_a_check_fails
    v = CiStatus.parse('[{"name":"test","bucket":"fail"},{"name":"lint","bucket":"pass"}]')
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_red_on_a_cancelled_check
    assert_equal :red, CiStatus.parse('[{"name":"e2e","bucket":"cancel"}]')[:state]
  end

  def test_pending_when_running_and_nothing_failed
    v = CiStatus.parse('[{"name":"e2e","bucket":"pending"},{"name":"lint","bucket":"pass"}]')
    assert_equal :pending, v[:state]
    assert_equal ["e2e"], v[:pending]
  end

  def test_a_failure_outranks_a_still_running_check
    # fail + pending together is RED, not pending — a known-bad PR is never "not yet".
    assert_equal :red, CiStatus.parse('[{"name":"test","bucket":"fail"},{"name":"e2e","bucket":"pending"}]')[:state]
  end

  def test_green_when_every_check_passed_or_skipped
    v = CiStatus.parse('[{"name":"lint","bucket":"pass"},{"name":"scan","bucket":"skipping"}]')
    assert_equal :green, v[:state]
    assert_equal 2, v[:count]
  end

  def test_none_when_empty_or_no_checks_reported
    assert_equal :none, CiStatus.parse("[]")[:state]
    assert_equal :none, CiStatus.parse("no checks reported on the 'feat/x' branch")[:state]
  end

  def test_unverified_on_a_gh_or_network_error
    v = CiStatus.parse("gh: command not found")
    assert_equal :unverified, v[:state]
    assert_includes v[:reason], "command not found"
  end

  def test_a_bare_token_short_circuits_the_gh_call
    # the DOR_CHECK_CI_STATUS injection seam — used by the dor-check CLI tests. Includes
    # closed/merged: a non-open PR is its own verdict, never green (carl's review catch).
    # Includes conflicted: a merge-conflicted PR (mergeStateStatus DIRTY) gets NO CI at
    # all, and must be its own verdict — never folded into :none (the PR-#509 stall).
    %i[green red pending none unverified no_pr closed merged conflicted].each do |state|
      assert_equal state, CiStatus.evaluate("https://github.com/x/pull/1", state.to_s)[:state]
    end
  end

  # --- the `gh pr view` payload → early verdict (view_verdict) -----------------
  # A PR with merge conflicts against its base reports mergeStateStatus DIRTY, and
  # GitHub CANNOT compute the merge commit — so the pull_request workflow never
  # fires. That PR has NO CI, not a pending one: reading only the checks folds it
  # into :none ("defer until CI reports") and the PR stalls in submitted forever
  # (PR #509, 2026-07-12). view_verdict reads state + mergeStateStatus in one gh
  # call and surfaces :conflicted as its own state.

  def view(state, merge_state)
    JSON.generate("state" => state, "mergeStateStatus" => merge_state)
  end

  def test_view_verdict_conflicted_when_the_open_pr_is_dirty
    v = CiStatus.view_verdict(view("OPEN", "DIRTY"))
    assert_equal :conflicted, v[:state]
    assert_equal "DIRTY", v[:merge_state]
  end

  def test_view_verdict_proceeds_to_the_checks_read_when_mergeable
    # nil = "no early verdict — go read the checks". BEHIND/UNSTABLE/BLOCKED are
    # CI/branch-protection colour, not conflicts; UNKNOWN is GitHub still
    # computing mergeability — never invented as a conflict.
    %w[CLEAN BEHIND UNSTABLE BLOCKED HAS_HOOKS UNKNOWN DRAFT].each do |merge_state|
      assert_nil CiStatus.view_verdict(view("OPEN", merge_state)),
                 "OPEN + #{merge_state} must fall through to `gh pr checks`"
    end
  end

  def test_view_verdict_closed_and_merged_outrank_dirty
    # A closed/merged PR is its own verdict even when it also reads DIRTY —
    # "rebase and resubmit" is the wrong instruction for a dead review target.
    assert_equal :closed, CiStatus.view_verdict(view("CLOSED", "DIRTY"))[:state]
    assert_equal :merged, CiStatus.view_verdict(view("MERGED", "UNKNOWN"))[:state]
  end

  def test_view_verdict_unverified_on_a_gh_error_body
    v = CiStatus.view_verdict("gh: Not Found (HTTP 404)")
    assert_equal :unverified, v[:state]
    assert_includes v[:reason], "Not Found"
  end

  def test_no_pr_when_url_blank_and_nothing_injected
    assert_equal :no_pr, CiStatus.evaluate("", nil)[:state]
    assert_equal :no_pr, CiStatus.evaluate(nil, "")[:state]
  end

  def test_names_a_check_by_its_state_when_the_name_is_missing
    v = CiStatus.parse('[{"state":"FAILURE","bucket":"fail"}]')
    assert_equal :red, v[:state]
    assert_equal ["FAILURE"], v[:failing]
  end

  # --- SHA-addressed CI (G3's auditor): the check-runs payload ----------------
  #
  # `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` returns the RAW GitHub
  # pair status+conclusion, not gh's `bucket`. These pin the mapping shim — the
  # only new logic between the release gate and a verdict it already understands.

  # The API envelope a real gh api call returns.
  def check_runs(*runs)
    JSON.generate("total_count" => runs.size, "check_runs" => runs)
  end

  def test_check_runs_red_when_a_completed_run_failed
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "failure" },
                                    { "name" => "lint", "status" => "completed", "conclusion" => "success" }
                                  ))
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_check_runs_red_on_cancelled_timed_out_and_action_required
    %w[cancelled timed_out action_required startup_failure stale].each do |conclusion|
      v = CiStatus.parse_check_runs(check_runs({ "name" => "e2e", "status" => "completed", "conclusion" => conclusion }))
      assert_equal :red, v[:state], "a #{conclusion} run is a FAILED run"
    end
  end

  def test_check_runs_pending_while_a_run_is_queued_or_in_progress
    %w[queued in_progress].each do |status|
      v = CiStatus.parse_check_runs(check_runs(
                                      { "name" => "test", "status" => status, "conclusion" => nil },
                                      { "name" => "lint", "status" => "completed", "conclusion" => "success" }
                                    ))
      assert_equal :pending, v[:state], "a #{status} run has not reported a verdict yet"
      assert_equal ["test"], v[:pending]
    end
  end

  def test_check_runs_a_failure_outranks_a_still_running_run
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "failure" },
                                    { "name" => "e2e", "status" => "in_progress", "conclusion" => nil }
                                  ))
    assert_equal :red, v[:state]
  end

  def test_check_runs_green_when_every_run_passed_neutral_or_skipped
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                    { "name" => "scan", "status" => "completed", "conclusion" => "skipped" },
                                    { "name" => "lint", "status" => "completed", "conclusion" => "neutral" }
                                  ))
    assert_equal :green, v[:state]
    assert_equal 3, v[:count]
  end

  def test_check_runs_none_when_the_sha_has_no_runs
    # THE STATE OF THE WORLD TODAY: ci.yml triggers on pull_request + push:main, so
    # a release-tip SHA has NO check-runs. GitHub answers 200 with an empty list —
    # "no data", never a failure. It stays valid after run-ci-on-release-branch
    # lands (any SHA CI simply never built).
    assert_equal :none, CiStatus.parse_check_runs(check_runs)[:state]
    assert_equal :none, CiStatus.parse_check_runs('{"total_count":0,"check_runs":[]}')[:state]
  end

  def test_check_runs_unverified_on_a_404_or_gh_error_never_a_red
    # An auditor that cannot READ the record reports that — it never invents a red
    # (which would alarm on every un-pushed SHA and every gh outage).
    v = CiStatus.parse_check_runs('{"message":"Not Found","status":"404"}')
    assert_equal :unverified, v[:state]
    assert_equal "Not Found", v[:reason]

    v = CiStatus.parse_check_runs("gh: command not found")
    assert_equal :unverified, v[:state]
    assert_includes v[:reason], "command not found"
  end

  def test_check_runs_reports_a_TRUNCATED_read_rather_than_folding_a_false_green
    # The query asks for one page of 100 (no --paginate: gh emits concatenated JSON
    # documents past page 1 on an OBJECT endpoint, which JSON.parse rejects — the
    # auditor would go silently blind on the BIGGEST suites). So a suite larger than
    # the page must SAY it could not see the whole record: a green fold over a
    # partial list could be hiding a red on the page we never read.
    partial = JSON.generate("total_count" => 120,
                            "check_runs" => [{ "name" => "test", "status" => "completed", "conclusion" => "success" }])
    v = CiStatus.parse_check_runs(partial)
    assert_equal :unverified, v[:state], "a partial read is NO DATA, not a green"
    assert_includes v[:reason], "read only 1 of 120"
  end

  def test_check_runs_a_truncated_read_that_ALREADY_found_a_failure_is_still_red
    # A failure outranks everything, so more runs cannot un-fail it — this partial
    # fold IS trustworthy, and downgrading it to :unverified would throw away a
    # true red.
    partial = JSON.generate("total_count" => 120,
                            "check_runs" => [{ "name" => "test:system", "status" => "completed",
                                               "conclusion" => "failure" }])
    v = CiStatus.parse_check_runs(partial)
    assert_equal :red, v[:state]
    assert_equal ["test:system"], v[:failing]
  end

  def test_check_runs_accepts_a_bare_array_of_runs_too
    v = CiStatus.parse_check_runs('[{"name":"test","status":"completed","conclusion":"failure"}]')
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_check_runs_names_an_unnamed_run_by_its_conclusion
    v = CiStatus.parse_check_runs(check_runs({ "status" => "completed", "conclusion" => "failure" }))
    assert_equal ["failure"], v[:failing]
  end

  def test_for_sha_bare_token_short_circuits_the_gh_call
    # The RELEASE_CI_STATUS injection seam — the G3 twin of DOR_CHECK_CI_STATUS.
    # No nwo, no sha, no network: a canned verdict comes straight back.
    assert_equal :green, CiStatus.for_sha("", "", "green")[:state]
    assert_equal :none, CiStatus.for_sha("", "", "none")[:state]

    red = CiStatus.for_sha("o/r", "abc", "red")
    assert_equal :red, red[:state]
    assert_equal ["ci"], red[:failing]

    pending = CiStatus.for_sha("o/r", "abc", "pending")
    assert_equal :pending, pending[:state]
    assert_equal ["ci"], pending[:pending]
  end

  def test_for_sha_accepts_an_injected_check_runs_payload
    v = CiStatus.for_sha("o/r", "abc", check_runs({ "name" => "test", "status" => "completed", "conclusion" => "failure" }))
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_for_sha_is_unverified_rather_than_shelling_out_without_a_repo_or_sha
    assert_equal :unverified, CiStatus.for_sha("", "abc123", nil)[:state]
    assert_equal :unverified, CiStatus.for_sha("owner/repo", "", nil)[:state]
  end

  def test_name_with_owner_reads_every_github_remote_form
    assert_equal "amcritchie/mcritchie-studio", CiStatus.name_with_owner("git@github.com:amcritchie/mcritchie-studio.git")
    assert_equal "amcritchie/mcritchie-studio", CiStatus.name_with_owner("https://github.com/amcritchie/mcritchie-studio.git")
    assert_equal "amcritchie/mcritchie-studio", CiStatus.name_with_owner("https://github.com/amcritchie/mcritchie-studio")
    assert_equal "amcritchie/turf-monster", CiStatus.name_with_owner("ssh://git@github.com/amcritchie/turf-monster.git\n")
  end

  def test_name_with_owner_is_blank_for_a_non_github_remote
    # → for_sha :unverified (no data), never a red: a repo GitHub doesn't host has
    # no CI verdict to disagree with.
    assert_equal "", CiStatus.name_with_owner("/srv/mirrors/mcritchie-studio.git")
    assert_equal "", CiStatus.name_with_owner("")
  end
end
