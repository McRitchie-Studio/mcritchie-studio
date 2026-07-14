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

  # --- :unreadable — a gate that cannot SEE must say WHY it cannot see ---------
  #
  # THE BUG (task dor-check-misses-rolio-ci, verified 2026-07-13): a PERMISSION
  # denial and a genuinely-un-run CI both collapsed into "no verdict". A blind gate
  # that cannot name its blindness gets ignored, then routed around — and that is
  # how a genuinely RED CI eventually slips through. So an auth/permission failure
  # is its OWN state, carrying its own cause.
  #
  # :unreadable is NOT more lenient than :unverified — it blocks exactly the same
  # routes (notably it does NOT unlock the fast-cert credit). It is more HONEST.

  # The VERBATIM body from `gh pr checks 23 --repo amcritchie/rolio` (2026-07-13):
  # rolio is a PRIVATE repo and the fine-grained PAT lacks Checks: Read on it, so
  # the statusCheckRollup nodes come back denied.
  ROLIO_GRAPHQL_403 = "GraphQL: Resource not accessible by personal access token " \
                      "(node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0), " \
                      "Resource not accessible by personal access token " \
                      "(node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.1)"

  def test_parse_a_permission_denial_is_unreadable_never_none
    # THE REGRESSION. Folding this into :none would be the worst outcome: :none is
    # "the workflow hasn't reported yet", which tells the builder to WAIT for a CI
    # that is already green, and tells pr-review's supervisor to DEFER the wave
    # forever. It must never be :none.
    v = CiStatus.parse(ROLIO_GRAPHQL_403)
    refute_equal :none, v[:state], "a permission denial is not an absent CI"
    assert_equal :unreadable, v[:state]
    assert_includes v[:reason], "not accessible", "the cause must be NAMED, not swallowed"
  end

  def test_check_runs_a_403_is_unreadable_never_a_bare_unverified
    # The VERBATIM body from `gh api repos/amcritchie/<repo>/branches/main/protection`
    # and the check-runs endpoint on a repo the token cannot read: gh prints the JSON
    # error on stdout AND its own line on stderr, and we capture 2>&1 — so the raw
    # text is CONCATENATED and JSON.parse rejects it. Detection must read the RAW
    # body, not just a cleanly-parsed `message`.
    raw = '{"message":"Resource not accessible by personal access token",' \
          '"documentation_url":"https://docs.github.com/rest","status":"403"}' \
          "gh: Resource not accessible by personal access token (HTTP 403)"
    v = CiStatus.parse_check_runs(raw)
    assert_equal :unreadable, v[:state]
    assert_includes v[:reason], "not accessible"
  end

  def test_check_runs_a_clean_json_403_or_401_is_unreadable
    v = CiStatus.parse_check_runs('{"message":"Resource not accessible by integration","status":"403"}')
    assert_equal :unreadable, v[:state]
    assert_equal :permissions, v[:cause]

    v = CiStatus.parse_check_runs('{"message":"Bad credentials","status":"401"}')
    assert_equal :unreadable, v[:state]
    assert_equal "Bad credentials", v[:reason]
    assert_equal :credentials, v[:cause]
  end

  def test_unreadable_remedy_matches_the_actual_denial_cause
    repo = "amcritchie/rolio"

    permissions = CiStatus.parse("GraphQL: Resource not accessible by personal access token")
    assert_equal :permissions, permissions[:cause]
    assert_includes CiStatus.unreadable_remedy(repo, cause: permissions[:cause]), "Checks: Read"

    credentials = CiStatus.parse("gh: Bad credentials (HTTP 401)")
    assert_equal :credentials, credentials[:cause]
    credential_remedy = CiStatus.unreadable_remedy(repo, cause: credentials[:cause])
    assert_includes credential_remedy, "gh auth status"
    refute_includes credential_remedy, "Checks: Read"

    rate_limit = CiStatus.parse("gh: API rate limit exceeded (HTTP 403)")
    assert_equal :rate_limit, rate_limit[:cause]
    rate_remedy = CiStatus.unreadable_remedy(repo, cause: rate_limit[:cause])
    assert_includes rate_remedy, "gh api rate_limit"
    refute_includes rate_remedy, "Checks: Read"

    forbidden = CiStatus.parse("gh: Forbidden (HTTP 403)")
    assert_equal :forbidden, forbidden[:cause]
    forbidden_remedy = CiStatus.unreadable_remedy(repo, cause: forbidden[:cause])
    assert_includes forbidden_remedy, "gh auth status"
    refute_includes forbidden_remedy, "Checks: Read"
  end

  def test_gate_evidence_preserves_unreadable_state_cause_reason_and_repo
    verdict = CiStatus.parse("GraphQL: Resource not accessible by personal access token")
    evidence = CiStatus.gate_evidence(verdict, repo: "amcritchie/rolio")

    assert_equal "unreadable", evidence["state"]
    assert_equal "permissions", evidence["cause"]
    assert_equal "amcritchie/rolio", evidence["repo"]
    assert_includes evidence["reason"], "not accessible"
  end

  def test_a_404_stays_unverified_and_is_NOT_promoted_to_unreadable
    # 404 is genuinely AMBIGUOUS (a SHA that was force-pushed away answers 404 too),
    # so it keeps its old meaning. Only an explicit auth/permission denial — 401/403,
    # "not accessible", "bad credentials" — is :unreadable. Narrow on purpose: a
    # state that cries "fix your token" at every missing SHA would be its own lie.
    assert_equal :unverified, CiStatus.parse_check_runs('{"message":"Not Found","status":"404"}')[:state]
    assert_equal :unverified, CiStatus.parse("gh: command not found")[:state]
  end

  def test_no_checks_reported_is_STILL_none
    # Guard the other direction: the honest "no run yet" must not get swept into
    # :unreadable. :none keeps meaning exactly what it meant.
    assert_equal :none, CiStatus.parse("no checks reported on the 'feat/x' branch")[:state]
    assert_equal :none, CiStatus.parse_check_runs('{"total_count":0,"check_runs":[]}')[:state]
  end

  def test_unreadable_is_an_injectable_token
    # the DOR_CHECK_CI_STATUS / RELEASE_CI_STATUS seam — so every CLI test can drive
    # the unreadable path without a network or a broken token.
    assert_includes CiStatus::TOKENS, "unreadable"
    assert_equal :unreadable, CiStatus.evaluate("https://github.com/x/pull/1", "unreadable")[:state]
    assert_equal :unreadable, CiStatus.for_sha("owner/repo", "abc123", "unreadable")[:state]
  end

  def test_view_verdict_a_permission_denial_is_unreadable
    # `gh pr view` is the FIRST gh call evaluate makes — on a repo the token cannot
    # read, it fails there and must already name the cause rather than degrade.
    v = CiStatus.view_verdict("gh: Resource not accessible by personal access token (HTTP 403)")
    assert_equal :unreadable, v[:state]
  end
end
