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
#   :ci_less        — ZERO check-runs AND GitHub will not confirm the PR is mergeable
#                     (mergeStateStatus UNKNOWN/DIRTY, or mergeable CONFLICTING). The
#                     base drifted far enough that GitHub cannot compute a merge
#                     commit, so it runs NO CI AT ALL → BLOCK, remedy "rebase onto
#                     <base>". See the THIRD STATE section below.
#   :closed/:merged — the PR is not OPEN                  → BLOCK (its green checks are
#                     HISTORICAL, not a live review target — a stale/abandoned pr_url)
#   :green          — every check passed/skipped         → pass
#   :none           — the PR reports no checks yet        → note (non-blocking)
#   :no_pr          — no pr_url yet                       → silent (gate re-runs after push)
#   :unreadable     — the TOKEN cannot read CI (401/403)  → note, but NAMES the cause
#                     and the repo. See the blindness section below.
#   :unverified     — gh/network error                    → note (never a hard block;
#                     don't trade a flaky CI lane for a flaky gate)
#
# A BLIND GATE MUST SAY WHY IT IS BLIND (task dor-check-misses-rolio-ci, 2026-07-13).
# :unreadable and :unverified are BOTH "no verdict", and neither hard-blocks — but
# they are not the same fact, and collapsing them was a real bug:
#   * :none / :unverified say "CI has nothing to tell you YET" → the fix is to WAIT.
#   * :unreadable says "CI has plenty to tell you and this TOKEN may not hear it" →
#     waiting is futile; the fix is a CREDENTIAL, and no amount of re-running helps.
# Told the first story, a rolio builder pushes, re-runs dor-check, reads "push the
# branch and open the PR" for a PR that is already open and already GREEN, and
# learns to ignore the gate. That is how a gate stops being read at all — and an
# ignored gate is exactly how a genuinely RED CI ships. Honesty, not leniency:
# :unreadable is NOT easier to pass than :unverified. It unlocks nothing (notably
# not the fast-cert credit); it only tells the truth about why it cannot see.
#
# `injected` is dor-check's DOR_CHECK_CI_STATUS seam: a bare token
# (green/red/pending/none/unreadable/unverified/no_pr) OR the raw `gh pr checks
# --json` array — so the tests never shell out to gh (mirrors
# DOR_CHECK_SUITE_EVIDENCE).
#
# TWO SUBJECTS, ONE VOCABULARY. `evaluate` asks about a PR (the merge gate's
# subject); `for_sha` asks about a COMMIT (the G3 release-gate's subject — the
# release tip belongs to no PR). Both fold into the states above. See the
# SHA-addressed section below.
module CiStatus
  TOKENS = %w[green red pending none unverified unreadable no_pr closed merged conflicted ci_less].freeze

  # The `gh pr view` fields evaluate needs. `mergeable` and `baseRefName` joined
  # state+mergeStateStatus for the THIRD STATE below: mergeStateStatus alone cannot
  # separate "GitHub is still computing" from "GitHub gave up", and the remedy has to
  # NAME the branch to rebase onto or the reader must go derive it.
  VIEW_FIELDS = "state,mergeStateStatus,mergeable,baseRefName"

  # --- THE THIRD STATE: a PR that will NEVER get CI ---------------------------
  #
  # A CI verdict has always had two "not green yet" shapes — :red (it ran, it failed)
  # and :pending (it is running). Task detect-ci-less-stale-prs (2026-07-20) named a
  # THIRD: CI is never going to run at all.
  #
  # When a PR's base drifts far enough that GitHub cannot compute a merge commit,
  # GitHub does not queue the `pull_request` workflow — the head SHA gets ZERO
  # check-runs and mergeStateStatus reads UNKNOWN/DIRTY. Read through the checks
  # alone that is indistinguishable from a slow CI, so every watcher in the fleet
  # folds it into :none/"pending" and waits forever on checks that will never exist.
  # That burned a full rework cycle: a watcher armed at 05:47Z on a commit that never
  # got checks, and the cure was a rebase, which triggered CI green 8/8 immediately.
  #
  # :pending and :ci_less demand OPPOSITE actions — one says wait, one says act — so
  # collapsing them is not a cosmetic loss. :ci_less is deliberately neither: not
  # green (nothing was verified), not red (nothing failed), not pending (nothing is
  # coming).
  #
  # THE CONJUNCTION IS LOAD-BEARING. Zero checks ALONE is not ci-less — a PR GitHub
  # affirms is mergeable simply has not started its run yet, and that IS a wait. Only
  # "no checks AND a REFUTED merge" is the third state. Likewise a PR that HAS checks
  # is never ci-less however ugly its merge state: the checks prove CI ran.
  #
  # --- ABSENCE OF SIGNAL IS NOT NEGATIVE SIGNAL (round 2) ---------------------
  #
  # The round-1 predicate asked a YES/NO question — "is the merge confirmed?" — and a
  # two-valued answer cannot represent "GitHub has not decided yet". It also answered
  # that question INCONSISTENTLY: an ABSENT `mergeable` counted as confirmed while an
  # explicit "UNKNOWN" did not, though both mean the same thing.
  #
  # That was not cosmetic. GitHub computes mergeability ASYNCHRONOUSLY after every
  # push, answering UNKNOWN until it lands, and a brand-new head SHA has zero
  # check-runs in that SAME window — so both halves of the conjunction go true at once
  # for a perfectly HEALTHY PR. That window is exactly when builders run these tools
  # ("push, open a PR, then run bin/dor-check"), and PRs #588/#601/#602 were all
  # observed flipping to UNKNOWN within seconds of an unrelated merge and settling
  # back with NO push. The harm is not the stale verdict — it is the INSTRUCTION the
  # verdict carries, "rebase and --force-with-lease", which a compliant agent obeys,
  # force-pushing a healthy branch and cancelling its in-flight CI.
  #
  # So mergeability is THREE-VALUED — :affirmed / :refuted / :unknown — and :unknown
  # is NEVER converted into an actionable negative. It means "look again", and only a
  # STABLE unknown (still unknown after a bounded re-read, with zero checks) is
  # reported as ci-less. That is also the staleness floor this task's name always
  # implied: a transient UNKNOWN settles on its own, a genuinely stale base never does.
  #
  # FAIL DIRECTION: uncertainty about GITHUB'S KNOWLEDGE falls toward wait; only an
  # affirmative negative blocks. The asymmetry justifies it — a wrong block
  # force-pushes a healthy branch, a wrong wait costs a bounded timeout.

  # mergeStateStatus values that prove GitHub COMPUTED the merge commit. Their
  # presence is settlement, whatever `mergeable` says: DIRTY is the computed NEGATIVE
  # (handled as :refuted / :conflicted), and UNKNOWN is the only "still computing"
  # answer. Keying off this field rather than `mergeable` is what makes {CLEAN +
  # mergeable UNKNOWN} — a self-contradictory input that round 1 called ci-less —
  # resolve correctly to "GitHub computed it; the run just has not started".
  SETTLED_MERGE_STATES = %w[CLEAN BLOCKED BEHIND UNSTABLE HAS_HOOKS DRAFT].freeze

  # How long to wait before the second look at an UNDETERMINED mergeability, and how
  # many looks in total. Bounded on purpose: this is the only place the fleet sleeps
  # on CI, and a transient UNKNOWN settles in seconds. Env-overridable so tests never
  # sleep (CI_STATUS_RECHECK_SECONDS=0).
  def self.recheck_seconds
    raw = ENV["CI_STATUS_RECHECK_SECONDS"]
    return 5.0 if raw.nil? || raw.to_s.strip.empty?

    [raw.to_f, 0.0].max
  end

  # PURE. What does GitHub say about this PR's mergeability — :affirmed, :refuted, or
  # :unknown? A SETTLED mergeStateStatus affirms on its own; DIRTY and CONFLICTING are
  # the affirmative negatives; everything else (UNKNOWN, absent, unparseable) is
  # :unknown, which is a request to look again, never a verdict.
  def self.mergeability(view_raw)
    data = parse_view(view_raw)
    return :unknown unless data

    merge_state = data["mergeStateStatus"].to_s.upcase
    mergeable = data["mergeable"].to_s.upcase
    return :refuted if merge_state == "DIRTY" || mergeable == "CONFLICTING"
    return :affirmed if SETTLED_MERGE_STATES.include?(merge_state)
    return :affirmed if mergeable == "MERGEABLE"

    :unknown
  end

  # PURE. The `gh pr view` payload as a Hash, or nil when it is not JSON.
  def self.parse_view(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    data.is_a?(Hash) ? data : nil
  end

  # PURE. The WHOLE PR verdict: the view payload's early verdict, else the checks
  # fold, with the ci-less upgrade applied to a bare :none. This is the seam the unit
  # vectors drive (pending / ci-less / green / red) without touching the network.
  #
  # `stable` is the SECOND look — see the three-valued section above. On the first
  # read an UNDETERMINED mergeability returns the plain :none carrying `recheck: true`
  # ("look again"), and only when the caller has re-read and found it STILL undecided
  # does it become :ci_less. It is a second look, NOT a lower bar: an :affirmed merge
  # stays a wait however many times it is read.
  def self.combine(view_raw, checks_raw, stable: false)
    early = view_verdict(view_raw)
    return early if early

    verdict = parse(checks_raw)
    return verdict unless verdict[:state] == :none

    case mergeability(view_raw)
    when :affirmed
      # GitHub computed the merge — the workflow just has not started. A real wait.
      verdict
    when :refuted
      # An affirmative negative: GitHub says it cannot merge, so no CI is coming.
      # Actionable on the FIRST read — this is a fact, not a pending computation.
      ci_less_verdict(view_raw)
    else
      # `mergeability`, not `merge_state`: what is undetermined is GitHub's ANSWER,
      # and naming it after the raw mergeStateStatus field would report a value
      # GitHub may never have sent.
      stable ? ci_less_verdict(view_raw) : verdict.merge(recheck: true, mergeability: :unknown)
    end
  end

  # PURE. The :ci_less verdict with the evidence a reader needs to act: what GitHub
  # reported, and the base to rebase onto.
  def self.ci_less_verdict(view_raw)
    data = parse_view(view_raw) || {}
    {
      state: :ci_less,
      merge_state: data["mergeStateStatus"].to_s.upcase,
      mergeable: data["mergeable"].to_s.upcase,
      base: data["baseRefName"].to_s
    }
  end

  # THE ONE REMEDY STRING for :ci_less. dor-check, pr-review and session-preflight all
  # CALL this (session-preflight requires this file for exactly that reason — round 2
  # caught it hand-rolling a rival message), so one PR cannot collect three cures.
  # Names (a) that no CI is coming, (b) why, and (c) the exact command — because
  # "pending" taught the reader to wait, and only a named action unteaches it.
  def self.ci_less_remedy(verdict = nil)
    v = verdict.is_a?(Hash) ? verdict : {}
    base = v[:base].to_s.strip
    base = "the base branch" if base.empty?
    detail = [v[:merge_state], v[:mergeable]].map(&:to_s).reject(&:empty?).join("/")
    detail = detail.empty? ? "" : " (GitHub reports #{detail})"
    "NO CI WILL RUN on this PR#{detail}: its base has drifted far enough that GitHub cannot compute a " \
      "merge commit, so it never queues the pull_request workflow and the head SHA has ZERO check-runs. " \
      "This is NOT a slow CI — waiting can never clear it. Fix: rebase onto #{base} " \
      "(git fetch origin && git rebase origin/#{base} && git push --force-with-lease), which makes GitHub " \
      "compute the merge commit and fires CI immediately."
  end

  # An AUTH/PERMISSION denial — the token is understood and REFUSED, as opposed to a
  # 404 (ambiguous: a force-pushed SHA answers 404 too) or a transport error. Matched
  # against the RAW gh output, because `gh api` prints the JSON error body on stdout
  # and its own "gh: … (HTTP 403)" line on stderr: we capture 2>&1, so the two arrive
  # CONCATENATED and JSON.parse rejects the result — a parsed-`message`-only check
  # would miss the very case that motivated this state.
  #
  # Deliberately NARROW. A state that cried "fix your token" at every missing SHA
  # would be its own species of lie, so 404/timeouts/`gh: command not found` keep
  # their old :unverified meaning.
  #
  # ORDER IS LOAD-BEARING — first match wins, and the patterns OVERLAP. GitHub
  # answers a rate limit with an HTTP 403, so :rate_limit MUST precede :forbidden;
  # reverse them and "API rate limit exceeded (HTTP 403)" prescribes a scope grant
  # for a token whose scopes are fine. Each cause and what it catches:
  #   :rate_limit     — "rate limit" / "abuse detection"; a 403 that is NOT a denial
  #   :credentials    — "bad credentials", an expired/revoked token, HTTP 401
  #   :authentication — "requires authentication"; no token presented at all
  #   :permissions    — "resource not accessible by …" (a fine-grained PAT or GitHub
  #                     App refused the scope — the rolio case, REST and GraphQL
  #                     alike) / "must have admin rights" (the branch-protection read)
  #   :forbidden      — a bare HTTP 403 with no stated cause. AMBIGUOUS ON PURPOSE:
  #                     the remedy REFUSES to guess a scope here (see unreadable_remedy).
  UNREADABLE_CAUSES = [
    [:rate_limit, /(?:api|secondary)?\s*rate limit|abuse detection/i],
    [:credentials, /bad credentials|token[^\n]*(?:expired|revoked)|\bHTTP 401\b|"status"\s*:\s*"?401"?/i],
    [:authentication, /requires authentication|authentication required/i],
    [:permissions, /resource not accessible by|must have admin rights/i],
    [:forbidden, /\bHTTP 403\b|"status"\s*:\s*"?403"?|\bforbidden\b/i]
  ].freeze

  def self.unreadable_cause(raw)
    text = raw.to_s
    UNREADABLE_CAUSES.each do |cause, pattern|
      return cause if pattern.match?(text)
    end
    nil
  end

  # Does this raw gh body say "your token was refused"?
  def self.permission_denied?(raw)
    !unreadable_cause(raw).nil?
  end

  # The :unreadable verdict, carrying the cause. `reason` is the first line of the
  # denial, trimmed — enough for the gate to print WHAT was refused, while the gate
  # itself supplies WHICH repo and WHICH scope to grant.
  def self.unreadable(raw)
    data = JSON.parse(raw) rescue nil
    reason = data.is_a?(Hash) ? data["message"].to_s : raw.to_s.lines.first.to_s.strip
    { state: :unreadable, cause: unreadable_cause(raw), reason: reason[0, 140] }
  end

  # PURE. "owner/repo" out of a PR URL (https://github.com/amcritchie/rolio/pull/23),
  # so a gate can NAME the repo whose CI it could not read. name_with_owner is
  # anchored at the end of the string and matches a REMOTE, not a PR URL.
  def self.repo_from_pr_url(pr_url)
    match = pr_url.to_s.strip.match(%r{github\.com[:/]+([^/\s]+)/([^/\s]+)/pull/\d+}i)
    match ? "#{match[1]}/#{match[2]}" : ""
  end

  # THE ONE REMEDY STRING, so dor-check, pr-review, and the release auditor all tell
  # the operator the same thing. A gate that cannot see must name (a) that it is a
  # CREDENTIAL fault, (b) the repo, (c) the exact grant, and (d) the verify command —
  # otherwise the reader's only move is to re-run it, which can never help.
  def self.unreadable_remedy(repo = nil, cause: nil)
    where = repo.to_s.strip.empty? ? "this repo" : repo.to_s.strip
    fix = case cause&.to_sym
          when :permissions
            "The GitHub token cannot read check runs on #{where}. Fix: grant the token `Checks: Read` on " \
              "#{where} (fine-grained PAT → Repository permissions → Checks → Read-only; the repo must also " \
              "be in the token's selected repositories). Verify: gh pr checks <pr> --repo #{where}."
          when :credentials
            "GitHub rejected the active credential for #{where}. Fix: run `gh auth status --hostname " \
              "github.com`, then refresh or replace the expired/revoked credential and retry the exact check read."
          when :authentication
            "No accepted GitHub credential reached #{where}. Fix: run `gh auth status --hostname github.com`, " \
              "authenticate the CLI, then retry the exact check read."
          when :rate_limit
            "GitHub refused the read because its API rate limit was exhausted. Fix: inspect `gh api rate_limit`, " \
              "wait for the named reset or use an authorized credential with remaining quota, then retry."
          else
            "GitHub returned a forbidden response for #{where} without identifying a missing permission. Do not " \
              "guess a scope: run `gh auth status --hostname github.com`, reproduce the exact check read, and use " \
              "GitHub's response to choose the credential or permission fix."
          end
    "This is a CREDENTIAL fault or API limit, NOT a missing CI — re-running will never clear it. #{fix} " \
      "Until the check read works, the FAST-cert route cannot be credited on this repo (a fast cert needs a " \
      "GREEN CI it can actually read) — certify in full instead: bin/full-suite-check <task>."
  end

  def self.gate_evidence(verdict, repo: nil)
    return {} unless verdict && verdict[:state] == :unreadable

    {
      "state" => "unreadable",
      "cause" => verdict[:cause].to_s,
      "reason" => verdict[:reason].to_s,
      "repo" => repo.to_s
    }
  end

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
      #   * a PR whose base drifted past GitHub's merge computation gets no checks
      #     EITHER, without ever reading DIRTY — the ci-less third state, which needs
      #     `mergeable` + `baseRefName` from this same call to name its remedy.
      view = `gh pr view #{Shellwords.escape(pr)} --json #{VIEW_FIELDS} 2>&1`.to_s.strip
      verdict = view_verdict(view)
      return verdict if verdict

      raw = `gh pr checks #{Shellwords.escape(pr)} --json name,state,bucket 2>&1`.to_s.strip
      # combine, not parse: a bare :none here may be the THIRD STATE (no CI will ever
      # run), and only the view payload can tell the difference.
      verdict = combine(view, raw)
      # An UNDETERMINED mergeability is not a verdict — it is a request to look again
      # (the three-valued rule above). Back off once, re-read BOTH payloads, and only
      # then let a STILL-undecided merge settle into :ci_less. A transient clears here;
      # a genuinely stale base does not.
      return verdict unless verdict[:recheck]

      sleep(recheck_seconds)
      view = `gh pr view #{Shellwords.escape(pr)} --json #{VIEW_FIELDS} 2>&1`.to_s.strip
      settled = view_verdict(view)
      return settled if settled

      raw = `gh pr checks #{Shellwords.escape(pr)} --json name,state,bucket 2>&1`.to_s.strip
      return combine(view, raw, stable: true)
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
    unless %w[OPEN CLOSED MERGED].include?(state)
      # `gh pr view` is the FIRST gh call evaluate makes, so on a repo the token
      # cannot read we fail HERE — and must already name the cause.
      return unreadable(raw) if permission_denied?(raw)

      return { state: :unverified, reason: raw.to_s.lines.first.to_s.strip[0, 140] }
    end
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
      # ORDER MATTERS: the permission check runs BEFORE the "no checks" match. The
      # denial body is the rolio case verbatim (a GraphQL statusCheckRollup refusal),
      # and reading it as :none would tell the builder to wait for a CI that is
      # already green.
      return unreadable(raw) if permission_denied?(raw)
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

      raw = check_runs_raw(repo, commit)
    end
    parse_check_runs(raw)
  end

  # The ONE check-runs read, shared by the verdict fold (for_sha) and the G3 credit
  # probe (credit_for_sha). NO --paginate. This endpoint returns an OBJECT
  # ({total_count, check_runs}), and past page 1 gh emits CONCATENATED JSON
  # documents, which JSON.parse rejects → :unverified. The auditor would go
  # SILENTLY BLIND on exactly the biggest suites (>30 runs) — the opposite of its
  # job. One page of 100 covers every suite in this ecosystem, and parse_check_runs
  # cross-checks the count it read against `total_count`, so a truncated read
  # reports itself instead of folding a partial list into a false green.
  def self.check_runs_raw(repo, commit)
    path = "repos/#{repo}/commits/#{commit}/check-runs?per_page=100"
    `gh api #{Shellwords.escape(path)} 2>&1`.to_s.strip
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
      # A 401/403 is a REFUSED token, not an absent record — say so. Checked against
      # the raw body (gh's stdout JSON + stderr line arrive concatenated under 2>&1),
      # then reported with the clean `message` when there was one to parse.
      return unreadable(raw).merge(reason: reason.strip[0, 140]) if permission_denied?(raw)

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

  # --- G3 CREDIT: an existing green conclusion for the SAME SHA ---------------
  #
  # The dedupe read for the pre-QA gate (task dedupe-hub-release-suite). When the
  # accepted→release promote FAST-FORWARDED, origin/release IS the accepted head
  # GitHub CI already built and greened at the PR/accepted seam — but the release
  # push queues a DUPLICATE run of the same checks on the same SHA, so `for_sha`
  # folds the commit :pending and the gate would wait out a suite that already
  # concluded. This probe answers ONE narrow question: does this exact SHA already
  # carry a COMPLETED green conclusion that the still-pending runs merely re-run?
  #
  # It returns a GREEN verdict carrying the credited source (`:credited`), or nil
  # ("no credit — take the normal path"). The caller asserts the fast-forward
  # itself (bin/release's pre_qa_gate); this half only reads the check-run record.
  #
  # The injection seam mirrors for_sha (RELEASE_CI_STATUS): a RAW check-runs
  # payload exercises the credit fold; a BARE token names a folded state, not
  # runs — no evidence of an existing conclusion, so it NEVER credits.
  def self.credit_for_sha(nwo, sha, injected = nil)
    raw = injected.to_s.strip
    return nil if TOKENS.include?(raw)

    if raw.empty?
      repo = nwo.to_s.strip
      commit = sha.to_s.strip
      return nil if repo.empty? || commit.empty?

      raw = check_runs_raw(repo, commit)
    end
    credited_verdict(raw)
  end

  # PURE. A check-runs payload → a credited GREEN verdict, or nil. Credits ONLY
  # when ALL of the following hold — anything else falls through to the normal
  # poll (pending still waits, red still aborts, missing checks still fail closed):
  #   * the read saw the WHOLE record (a truncated page could hide a red);
  #   * NO run failed or was cancelled — a red is never re-read as anything else;
  #   * at least one completed run PASSED (an all-skipped set certifies nothing);
  #   * something IS still pending (else the plain fold is already green — nothing
  #     to credit, the normal read passes on its own); and
  #   * every pending run re-runs a check NAME that already holds a completed
  #     pass/skip conclusion for this SHA. A pending check with NO completed
  #     counterpart (or no name to match on) is the ORIGINAL suite still running —
  #     a genuine wait, not a duplicate — so NO credit.
  def self.credited_verdict(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    runs = data.is_a?(Hash) ? data["check_runs"] : data
    return nil unless runs.is_a?(Array)

    total = data.is_a?(Hash) && data["total_count"] ? data["total_count"].to_i : runs.size
    return nil if runs.size < total

    folded = runs.map { |run| { name: run["name"].to_s, bucket: check_run_bucket(run) } }
    return nil if folded.any? { |run| %w[fail cancel].include?(run[:bucket]) }

    concluded = folded.select { |run| %w[pass skipping].include?(run[:bucket]) }
    passed    = concluded.select { |run| run[:bucket] == "pass" }
    pending   = folded.select { |run| run[:bucket] == "pending" }
    return nil if passed.empty? || pending.empty?

    covered = concluded.map { |run| run[:name] }.reject(&:empty?)
    return nil unless pending.all? { |run| !run[:name].empty? && covered.include?(run[:name]) }

    { state: :green, count: concluded.size,
      credited: "#{concluded.size} completed check-run#{concluded.size == 1 ? '' : 's'} already green " \
                "(#{passed.size} passed); the #{pending.size} pending run#{pending.size == 1 ? '' : 's'} " \
                "duplicate#{pending.size == 1 ? 's' : ''} them" }
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
