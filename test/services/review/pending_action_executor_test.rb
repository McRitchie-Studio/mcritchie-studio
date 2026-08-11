# frozen_string_literal: true

require "test_helper"

# MUTATION COVERAGE for the armed-merge guards.
#
# A guard that is not mutation-proven is decoration. Every test here starts from
# the ONE arrangement that legitimately merges (proven first, so a broken harness
# cannot make the refusals pass vacuously) and then changes exactly ONE thing —
# the CI conclusion, the head sha, the clock, the recorded verdict, the stage —
# and asserts the merge does NOT happen.
#
# CI state is driven through REAL ingested GithubWorkflowRun rows rather than a
# stubbed verdict, so these tests exercise the same Ci::ReviewGate fold the
# webhook path uses. The only double is GitHub itself.
class Review::PendingActionExecutorTest < ActiveSupport::TestCase
  SLUG = "autopilot-subject"
  REPO = "McRitchie-Studio/mcritchie-studio"
  BRANCH = "feat/autopilot-subject"
  PINNED = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  MOVED  = "ffffffffffffffffffffffffffffffffffffffff"

  # A stand-in for Github::Client with exactly the two methods the executor uses.
  # Records what it was asked to do so the tests can assert that a refused action
  # never reached the merge endpoint — the assertion that actually matters.
  class FakeGithub
    attr_reader :merge_calls, :merge_body

    def initialize(pr: {}, merge_status: 200, merge_body: nil)
      @pr = pr
      @merge_status = merge_status
      @merge_body = merge_body || { "sha" => "merge0000000000000000000000000000000000" }
      @merge_calls = 0
    end

    def get(_path)
      @pr
    end

    def put_response(_path, body: nil)
      @merge_calls += 1
      @last_body = body
      Github::Client::Response.new(url: "https://api.github.com", status: @merge_status,
                                   headers: {}, body: @merge_body, raw_body: @merge_body.to_json)
    end

    attr_reader :last_body
  end

  def setup
    @task = Task.create!(
      title: "Autopilot Subject Task",
      slug: SLUG,
      stage: "submitted",
      metadata: {
        "devops" => {
          "repositories" => ["mcritchie-studio"],
          "branch" => BRANCH,
          "pr_url" => "https://github.com/#{REPO}/pull/4242"
        }
      }
    )
    @verdict = record_merge_ready_verdict
  end

  # The recorded decision an armed merge executes — the same scout-report activity
  # `bin/devops-cycle --record-scout-report` writes.
  def record_merge_ready_verdict(outcome: "merge-ready")
    Activity.create!(
      task_slug: SLUG,
      agent_slug: "carl",
      activity_type: "comment",
      description: "Scout report: #{outcome} - clean",
      metadata: { "kind" => "scout_report", "outcome" => outcome, "reporter" => "carl" }
    )
  end

  # An ingested CI run — the board's ONLY source of CI truth (Ci::ReviewGate is
  # DB-native). `conclusion: nil` models a lane still running; NO row at all
  # models the "no checks reported" case a CONFLICTING PR produces.
  def ingest_ci(sha: PINNED, status: "completed", conclusion: "success", run_id: 900_001)
    GithubWorkflowRun.create!(
      run_id: run_id, repo: REPO, workflow_name: "CI", head_branch: BRANCH,
      head_sha: sha, status: status, conclusion: conclusion,
      run_started_at: Time.current, run_attempt: 1
    )
  end

  def arm(head_sha: PINNED, ttl: ReviewPendingAction::DEFAULT_TTL, now: Time.current)
    ReviewPendingAction.arm!(
      task: @task.reload, repo: REPO, pr_number: 4242, head_sha: head_sha,
      pr_url: "https://github.com/#{REPO}/pull/4242", authorized_by: "carl",
      now: now, ttl: ttl
    )
  end

  def open_pr(sha: PINNED, mergeable: true, state: "open", merged: false, base: "accepted")
    {
      "state" => state, "merged" => merged, "mergeable" => mergeable,
      "mergeable_state" => mergeable ? "clean" : "dirty",
      "head" => { "sha" => sha }, "base" => { "ref" => base }
    }
  end

  def run_executor(action, github: FakeGithub.new(pr: open_pr), now: Time.current)
    [Review::PendingActionExecutor.call(action, client: github, now: now), github]
  end

  # ── THE CONTROL ─────────────────────────────────────────────────────────────
  # Proven first and in full. Every refusal below is this arrangement with one
  # thing changed, so a refusal can never pass because the harness was broken.

  test "CONTROL: green CI on the pinned head merges, stamps accepted, and moves reviewed" do
    ingest_ci
    action = arm
    result, github = run_executor(action)

    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls
    # GitHub's own head pin travels with the request — the last line of defence.
    assert_equal PINNED, github.last_body[:sha]

    action.reload
    assert_equal ReviewPendingAction::EXECUTED, action.state
    assert action.executed_at.present?

    @task.reload
    assert_equal "accepted", @task.merged, "merged stamp must land before the stage move"
    assert_equal "reviewed", @task.stage
  end

  # ── MUTATION 1: GREEN → EVERY OTHER CI STATE ────────────────────────────────
  # "Act ONLY on green." Each of these is the control with the CI conclusion (or
  # the row itself) changed, and NONE of them may reach the merge endpoint.

  {
    "red"       => { conclusion: "failure" },
    "cancelled" => { conclusion: "cancelled" },
    "timed out" => { conclusion: "timed_out" },
    "pending"   => { status: "in_progress", conclusion: nil }
  }.each do |label, attrs|
    test "REFUSES a #{label} CI lane — never merges" do
      ingest_ci(**attrs)
      action = arm
      result, github = run_executor(action)

      refute_equal :executed, result.status
      assert_equal 0, github.merge_calls, "a #{label} lane must never reach the merge endpoint"
      assert_equal ReviewPendingAction::PENDING, action.reload.state
      assert_equal "submitted", @task.reload.stage
      assert_nil @task.merged
    end
  end

  # The CONFLICTING-PR trap, stated as its own test because it is the one that
  # looks like success from the outside: GitHub stops firing workflows entirely
  # rather than going red, so the board holds NO run at all. Absence is not a pass.
  test "REFUSES absent check-runs — 'no checks reported' is not green" do
    # deliberately ingest nothing
    action = arm
    result, github = run_executor(action)

    assert_equal :waiting, result.status
    assert_match(/not green/, result.reason)
    assert_match(/absent check-runs are not a pass/, result.reason)
    assert_equal 0, github.merge_calls
    assert_equal "submitted", @task.reload.stage
  end

  # The re-run-replays-an-old-SHA trap: a green run exists, but it describes a
  # DIFFERENT tree than the one the verdict was formed against.
  test "REFUSES a green run that concluded for a different sha than the pin" do
    ingest_ci(sha: MOVED)
    action = arm(head_sha: PINNED)
    result, github = run_executor(action)

    assert_equal :waiting, result.status
    assert_match(/not the pinned #{PINNED}/, result.reason)
    assert_equal 0, github.merge_calls
    assert_equal "submitted", @task.reload.stage
  end

  # ── MUTATION 2: THE HEAD MOVED ──────────────────────────────────────────────
  # "The verdict described a different tree." Green CI, valid verdict, live
  # action — only the live PR head differs from the pin.

  test "REFUSES when the live PR head moved off the pin — the verdict described another tree" do
    ingest_ci
    action = arm
    github = FakeGithub.new(pr: open_pr(sha: MOVED))
    result, = run_executor(action, github: github)

    assert_equal :refused, result.status
    assert_match(/head moved from the reviewed #{PINNED} to #{MOVED}/, result.reason)
    assert_equal 0, github.merge_calls, "a moved head must never reach the merge endpoint"
    assert_equal ReviewPendingAction::REFUSED, action.reload.state
    assert_equal "submitted", @task.reload.stage
    assert_nil @task.merged
  end

  # Defence in depth: even if every local guard were fooled, GitHub re-checks the
  # pin and answers 409. The action must settle refused, not retry forever.
  test "REFUSES when GitHub itself rejects the pinned sha with 409" do
    ingest_ci
    action = arm
    github = FakeGithub.new(pr: open_pr, merge_status: 409, merge_body: { "message" => "Head branch was modified" })
    result, = run_executor(action, github: github)

    assert_equal :refused, result.status
    assert_match(/head moved off the pinned/, result.reason)
    assert_equal ReviewPendingAction::REFUSED, action.reload.state
    assert_equal "submitted", @task.reload.stage
  end

  test "REFUSES a PR GitHub reports as not mergeable — the CONFLICTING case" do
    ingest_ci
    action = arm
    github = FakeGithub.new(pr: open_pr(mergeable: false))
    result, = run_executor(action, github: github)

    assert_equal :refused, result.status
    assert_match(/not mergeable/, result.reason)
    assert_equal 0, github.merge_calls
    assert_equal "submitted", @task.reload.stage
  end

  test "WAITS while GitHub is still computing mergeability" do
    ingest_ci
    action = arm
    github = FakeGithub.new(pr: open_pr(mergeable: nil))
    result, = run_executor(action, github: github)

    assert_equal :waiting, result.status
    assert_equal 0, github.merge_calls
    assert_equal ReviewPendingAction::PENDING, action.reload.state
  end

  test "REFUSES a PR based on something other than the authorised branch" do
    ingest_ci
    action = arm
    github = FakeGithub.new(pr: open_pr(base: "main"))
    result, = run_executor(action, github: github)

    assert_equal :refused, result.status
    assert_match(/base is main/, result.reason)
    assert_equal 0, github.merge_calls
  end

  # ── MUTATION 3: EXPIRY ──────────────────────────────────────────────────────
  # "Expire stale pending actions rather than executing them late." Everything
  # else is exactly the merging control — only the clock has moved.

  test "EXPIRES rather than executing late, even with green CI on the pinned head" do
    ingest_ci
    action = arm(ttl: 1.hour)
    result, github = run_executor(action, now: 2.hours.from_now)

    assert_equal :expired, result.status
    assert_equal 0, github.merge_calls, "an expired action must never reach the merge endpoint"
    assert_equal ReviewPendingAction::EXPIRED, action.reload.state
    assert_equal "submitted", @task.reload.stage
    assert_nil @task.merged
  end

  test "executes at the very edge of its window but not one second past it" do
    ingest_ci
    action = arm(ttl: 1.hour)
    just_inside = action.expires_at - 1.second
    result, = run_executor(action, now: just_inside)
    assert_equal :executed, result.status, "the window must still be open one second before expiry"
  end

  # ── MUTATION 4: NEVER INVENT A VERDICT ──────────────────────────────────────

  test "cannot be ARMED without a recorded merge-ready verdict" do
    @verdict.destroy!
    error = assert_raises(ReviewPendingAction::Unauthorised) { arm }
    assert_match(/no recorded merge-ready scout report/, error.message)
    assert_equal 0, ReviewPendingAction.count
  end

  # The sibling outcomes are not authorisations: `wait-for-ci` is a deferral,
  # `request-changes` a block, `conductor-review` an escalation to a human.
  ["wait-for-ci", "request-changes", "conductor-review"].each do |outcome|
    test "a recorded #{outcome} verdict does NOT authorise an armed merge" do
      @verdict.destroy!
      record_merge_ready_verdict(outcome: outcome)
      assert_raises(ReviewPendingAction::Unauthorised) { arm }
    end
  end

  test "REFUSES at execution time when the authorising verdict was withdrawn" do
    ingest_ci
    action = arm
    @verdict.destroy!
    result, github = run_executor(action)

    assert_equal :refused, result.status
    assert_match(/no longer on the record/, result.reason)
    assert_equal 0, github.merge_calls
    assert_equal "submitted", @task.reload.stage
  end

  # ── MUTATION 5: THE WORLD MOVED ON ──────────────────────────────────────────

  test "REFUSES once the task has left the submitted seam" do
    ingest_ci
    action = arm
    @task.update!(stage: "reviewed")
    result, github = run_executor(action)

    assert_equal :refused, result.status
    assert_match(/not submitted/, result.reason)
    assert_equal 0, github.merge_calls
  end

  test "WAITS while a live reviewer holds the review claim — the autopilot is for the reviewer that is GONE" do
    ingest_ci
    action = arm
    TaskReviewClaim.acquire(task_slug: SLUG, session: "sess-live", nonce: "inst-live", reviewer: "carl")
    result, github = run_executor(action)

    assert_equal :waiting, result.status
    assert_match(/live reviewer/, result.reason)
    assert_equal 0, github.merge_calls
    assert_equal ReviewPendingAction::PENDING, action.reload.state
  end

  test "acts once the reviewer's lease has lapsed" do
    ingest_ci
    action = arm
    TaskReviewClaim.acquire(task_slug: SLUG, session: "sess-dead", nonce: "inst-dead", reviewer: "carl",
                            now: 3.hours.ago, ttl: 60)
    result, github = run_executor(action)

    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls
  end

  # ── IDEMPOTENCY ─────────────────────────────────────────────────────────────

  test "a settled action never executes twice" do
    ingest_ci
    action = arm
    first, = run_executor(action)
    assert_equal :executed, first.status

    second, github = run_executor(action.reload)
    assert_equal :refused, second.status
    assert_equal 0, github.merge_calls
    assert_equal ReviewPendingAction::EXECUTED, action.reload.state,
                 "the re-run must not overwrite the real outcome with its own bookkeeping"
  end

  test "a PR already merged by someone else settles as executed without merging again" do
    ingest_ci
    action = arm
    github = FakeGithub.new(pr: open_pr(merged: true).merge("merge_commit_sha" => "deadbeef"))
    result, = run_executor(action, github: github)

    assert_equal :executed, result.status
    assert_equal 0, github.merge_calls
    assert_match(/already merged/, result.reason)
  end

  # ── FAILURE PATHS ───────────────────────────────────────────────────────────

  test "a GitHub API failure stays pending and lands in an ErrorLog" do
    ingest_ci
    action = arm
    boom = Object.new
    def boom.get(*) = raise(Github::Client::HttpError, "GitHub API HTTP 503: upstream")

    assert_difference -> { ErrorLog.count }, 1 do
      result = Review::PendingActionExecutor.call(action, client: boom)
      assert_equal :error, result.status
    end
    assert_equal ReviewPendingAction::PENDING, action.reload.state,
                 "a transient blip must not burn an authorised merge"
  end

  # THE CREDENTIAL-ROT PATH — the one that fires at 3am with nobody watching.
  # Github::AppToken.resolve DEGRADES rather than raising: with no App creds and no
  # fallback it returns nil, the request goes out unauthenticated, and GitHub
  # answers 401. "Cannot authenticate" must land exactly where "red CI" lands — no
  # merge — rather than escaping as an unhandled crash from the component whose
  # whole job is to act unattended.
  test "REFUSES to merge when GitHub authentication fails — a rotten credential is not a green light" do
    ingest_ci
    action = arm
    unauthorized = Object.new
    def unauthorized.get(*)
      raise(Github::Client::HttpError, %(GitHub API HTTP 401: {"message":"Bad credentials"}))
    end
    def unauthorized.put_response(*, **) = raise("the executor tried to MERGE without valid credentials")

    assert_difference -> { ErrorLog.count }, 1 do
      result = Review::PendingActionExecutor.call(action, client: unauthorized)
      assert_equal :error, result.status
      assert_match(/401/, result.reason)
    end

    assert_equal ReviewPendingAction::PENDING, action.reload.state,
                 "an auth failure must leave the order standing, not burn or execute it"
    @task.reload
    assert_equal "submitted", @task.stage
    assert_nil @task.merged
  end

  # The token resolver itself must never be the thing that raises into a caller.
  test "AppToken degrades to nil rather than raising when no credential can be obtained" do
    assert_nil Github::AppToken.new(app_id: nil, private_key_pem: nil, fallback_token: nil).resolve
  end

  test "a re-arm supersedes the live action rather than stacking a second merge order" do
    first = arm(head_sha: PINNED)
    second = arm(head_sha: MOVED)

    assert_equal ReviewPendingAction::DISARMED, first.reload.state
    assert_equal ReviewPendingAction::PENDING, second.reload.state
    assert_equal 1, ReviewPendingAction.pending.where(task_slug: SLUG).count
  end
end
