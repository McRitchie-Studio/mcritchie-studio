# frozen_string_literal: true

require "json"
require "shellwords"

# The REAL GitHub CI state of a PR, reduced to one verdict so bin/dor-check's merge
# gate can refuse to hand a red PR to review — the #1 blocker class (a PR green
# LOCALLY but red on CI, because bin/full-suite-check certifies `bin/rails test` and
# NOT the browser `test:system` lane GitHub also runs). Reads
# `gh pr checks <pr> --json name,state,bucket` and folds gh's normalized `bucket`
# (pass/fail/pending/skipping/cancel) into one state:
#   :red            — a check failed/cancelled          → BLOCK the gate
#   :pending        — a check running, none failed yet   → BLOCK (not green YET)
#   :conflicted     — mergeStateStatus DIRTY: the PR has merge conflicts against its
#                     base, so GitHub CANNOT compute the merge commit and the
#                     pull_request workflow NEVER fires — the PR has NO CI, not a
#                     pending one → BLOCK, with "rebase/merge release" as the fix.
#                     Folding this into :none is the PR-#509 stall (2026-07-12): the
#                     review wave deferred it forever while the board looked healthy.
#   :closed/:merged — the PR is not OPEN                  → BLOCK (its green checks are
#                     HISTORICAL, not a live review target — a stale/abandoned pr_url)
#   :green          — every check passed/skipped         → pass
#   :none           — the PR reports no checks yet        → note (non-blocking)
#   :no_pr          — no pr_url yet                       → silent (gate re-runs after push)
#   :unverified     — gh/network error                    → note (never a hard block;
#                     don't trade a flaky CI lane for a flaky gate)
#
# `injected` is dor-check's DOR_CHECK_CI_STATUS seam: a bare token
# (green/red/pending/none/unverified/no_pr) OR the raw `gh pr checks --json` array —
# so the tests never shell out to gh (mirrors DOR_CHECK_SUITE_EVIDENCE).
#
# TWO SUBJECTS, ONE VOCABULARY. `evaluate` asks about a PR (the merge gate's
# subject); `for_sha` asks about a COMMIT (the G3 release-gate's subject — the
# release tip belongs to no PR). Both fold into the states above. See the
# SHA-addressed section below.
module CiStatus
  TOKENS = %w[green red pending none unverified no_pr closed merged conflicted].freeze

  def self.evaluate(pr_url, injected = nil)
    pr = pr_url.to_s.strip
    raw = injected.to_s.strip
    return { state: raw.to_sym, failing: ["ci"], pending: ["ci"] } if TOKENS.include?(raw)

    if raw.empty?
      return { state: :no_pr } if pr.empty?

      # Verify the PR is OPEN and MERGEABLE before trusting its checks:
      #   * `gh pr checks` returns the HEAD commit's checks even for a CLOSED/MERGED
      #     PR, so a stale/abandoned pr_url with green historical checks would
      #     otherwise pass as a live green (carl's review catch);
      #   * a merge-CONFLICTED PR (mergeStateStatus DIRTY) gets NO checks at all —
      #     GitHub cannot compute the merge commit, so reading only the checks folds
      #     it into :none and the PR stalls forever (PR #509). One gh call reads both.
      view = `gh pr view #{Shellwords.escape(pr)} --json state,mergeStateStatus 2>&1`.to_s.strip
      verdict = view_verdict(view)
      return verdict if verdict

      raw = `gh pr checks #{Shellwords.escape(pr)} --json name,state,bucket 2>&1`.to_s.strip
    end
    parse(raw)
  end

  # PURE. The `gh pr view --json state,mergeStateStatus` payload → an EARLY verdict
  # (:closed / :merged / :conflicted / :unverified), or nil when the PR is OPEN and
  # mergeable — "no verdict here, go read the checks". Closed/merged outrank DIRTY:
  # "rebase and resubmit" is the wrong instruction for a dead review target. Only
  # DIRTY means conflicts — BEHIND/UNSTABLE/BLOCKED are CI/branch-protection colour
  # the checks read already covers, and UNKNOWN is GitHub still computing
  # mergeability (never invented as a conflict).
  def self.view_verdict(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    state = data.is_a?(Hash) ? data["state"].to_s : ""
    return { state: :unverified, reason: raw.to_s.lines.first.to_s.strip[0, 140] } unless %w[OPEN CLOSED MERGED].include?(state)
    return { state: state.downcase.to_sym } unless state == "OPEN"
    return { state: :conflicted, merge_state: "DIRTY" } if data["mergeStateStatus"].to_s.upcase == "DIRTY"

    nil
  end

  # gh's --json array → verdict. A non-array (an error message like "no checks
  # reported on the 'X' branch", or a `gh: command not found`) can't be a red gate,
  # so it degrades to :none / :unverified rather than blocking.
  def self.parse(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    unless data.is_a?(Array)
      return { state: :none } if raw.to_s =~ /no checks|no commit statuses/i

      return { state: :unverified, reason: raw.to_s.lines.first.to_s.strip[0, 140] }
    end

    fold(data)
  end

  # PURE. The verdict fold, shared by BOTH payload shapes: an array of checks
  # carrying a normalized `bucket` (pass/fail/pending/skipping/cancel). A failure
  # OUTRANKS a still-running check — a known-bad tree is never "not yet".
  def self.fold(checks)
    return { state: :none } if checks.empty?

    name = ->(c) { c["name"].to_s.empty? ? c["state"].to_s : c["name"].to_s }
    failing = checks.select { |c| %w[fail cancel].include?(c["bucket"].to_s) }.map(&name)
    pending = checks.select { |c| c["bucket"].to_s == "pending" }.map(&name)
    return { state: :red, failing: failing } if failing.any?
    return { state: :pending, pending: pending } if pending.any?

    { state: :green, count: checks.size }
  end

  # --- SHA-addressed CI: G3's AUDITOR ----------------------------------------
  #
  # `evaluate` above is PR-scoped, and a PR is the wrong subject for the release
  # tip: the SHA the G3 pre-QA gate certifies (`origin/release`) belongs to no PR.
  # So the gate asks GitHub about the COMMIT instead —
  # `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` — and folds the answer
  # through the SAME verdict states above, so both callers speak one language.
  #
  # The payloads differ, hence the shim: `gh pr checks` hands back gh's normalized
  # `bucket`, while the check-runs API hands back the RAW GitHub pair
  # `status` (queued|in_progress|completed) + `conclusion` (success|failure|
  # neutral|cancelled|skipped|timed_out|action_required|stale|startup_failure|null).
  # CHECK_RUN_BUCKETS maps conclusion → bucket exactly as gh's own bucketing does;
  # anything not yet `completed` (and any conclusion GitHub adds later that we
  # don't know) is `pending` — never invented as a pass or a fail.
  #
  # NO CI DATA IS NOT A FAILURE. A release-tip SHA with no workflow run answers
  # `{"total_count":0,"check_runs":[]}` → `:none`. That is the state of the world
  # TODAY: ci.yml triggers on `pull_request` + `push: main`, so `release` builds
  # nothing until task `run-ci-on-release-branch` adds it. `:none` (and
  # `:unverified`, and `:pending` — a push-triggered run that has not settled) are
  # "no data", and no-data NEVER blocks a local gate.
  CHECK_RUN_BUCKETS = {
    "success" => "pass",
    "neutral" => "skipping",
    "skipped" => "skipping",
    "cancelled" => "cancel",
    "failure" => "fail",
    "timed_out" => "fail",
    "action_required" => "fail",
    "startup_failure" => "fail",
    "stale" => "fail"
  }.freeze

  # GitHub CI's verdict for ONE COMMIT. `nwo` is the "owner/repo" name-with-owner
  # (see name_with_owner); `injected` is the RELEASE_CI_STATUS seam — a bare token
  # (green/red/pending/none/unverified) or a raw check-runs payload — so the tests
  # never shell out to gh (mirrors DOR_CHECK_CI_STATUS / PR_REVIEW_CI_STATUS).
  def self.for_sha(nwo, sha, injected = nil)
    raw = injected.to_s.strip
    if TOKENS.include?(raw)
      return { state: :red, failing: ["ci"] } if raw == "red"
      return { state: :pending, pending: ["ci"] } if raw == "pending"

      return { state: raw.to_sym }
    end

    if raw.empty?
      repo = nwo.to_s.strip
      commit = sha.to_s.strip
      return { state: :unverified, reason: "no GitHub owner/repo resolved" } if repo.empty?
      return { state: :unverified, reason: "no SHA to query" } if commit.empty?

      # NO --paginate. This endpoint returns an OBJECT ({total_count, check_runs}),
      # and past page 1 gh emits CONCATENATED JSON documents, which JSON.parse
      # rejects → :unverified. The auditor would go SILENTLY BLIND on exactly the
      # biggest suites (>30 runs) — the opposite of its job. One page of 100 covers
      # every suite in this ecosystem, and parse_check_runs cross-checks the count
      # it read against `total_count`, so a truncated read reports itself instead
      # of folding a partial list into a false green.
      path = "repos/#{repo}/commits/#{commit}/check-runs?per_page=100"
      raw = `gh api #{Shellwords.escape(path)} 2>&1`.to_s.strip
    end
    parse_check_runs(raw)
  end

  # PURE. A check-runs API payload → verdict. Accepts the API's envelope
  # (`{"total_count":…, "check_runs":[…]}`) or a bare array of runs, and degrades
  # a 404 / gh error / non-JSON body to :unverified — an auditor that cannot read
  # the record reports that it cannot read it, and never invents a red.
  def self.parse_check_runs(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    runs = data.is_a?(Hash) ? data["check_runs"] : data
    unless runs.is_a?(Array)
      reason = data.is_a?(Hash) ? data["message"].to_s : raw.to_s.lines.first.to_s.strip
      return { state: :unverified, reason: reason.strip[0, 140] }
    end

    verdict = fold(runs.map do |run|
      { "name" => run["name"].to_s, "state" => check_run_state(run), "bucket" => check_run_bucket(run) }
    end)

    # A PARTIAL read can only be trusted when it found a FAILURE (a fail outranks
    # everything, so more runs cannot un-fail it). Any other fold over a truncated
    # list could be hiding a red on the page we never read — so report that we
    # could not see the whole record rather than manufacture a green.
    total = data.is_a?(Hash) && data["total_count"] ? data["total_count"].to_i : runs.size
    if runs.size < total && verdict[:state] != :red
      return { state: :unverified, reason: "read only #{runs.size} of #{total} check-runs" }
    end

    verdict
  end

  # PURE. status + conclusion → gh's bucket vocabulary. Not-yet-`completed` (and
  # any unknown conclusion) is `pending`: a run still in flight is not a verdict.
  def self.check_run_bucket(run)
    return "pending" unless run["status"].to_s.downcase == "completed"

    CHECK_RUN_BUCKETS.fetch(run["conclusion"].to_s.downcase, "pending")
  end

  # The fallback label for an unnamed run (fold names a check by its `state` when
  # `name` is blank) — the raw GitHub word, so the alarm text stays diagnosable.
  def self.check_run_state(run)
    conclusion = run["conclusion"].to_s
    conclusion.empty? ? run["status"].to_s : conclusion
  end

  # PURE. A git remote URL → "owner/repo" for the gh api path, or "" when the
  # remote is not GitHub (a fork host, a local path). Handles the SSH
  # (git@github.com:owner/repo.git), HTTPS, and ssh:// forms.
  def self.name_with_owner(remote_url)
    match = remote_url.to_s.strip.match(%r{github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?\z})
    return "" unless match

    "#{match[1]}/#{match[2]}"
  end
end
