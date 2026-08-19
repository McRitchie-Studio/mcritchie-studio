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

  # The unattended move is the one transition on the whole spine with no human,
  # CLI, or form behind it — so it was landing ANONYMOUS, on precisely the row an
  # audit of this feature reads first. `autopilot` names the lane; the actor stays
  # the reviewer, because the authority is theirs and only the execution is ours.
  test "the unattended stage move is ATTRIBUTED, not anonymous" do
    ingest_ci
    run_executor(arm)

    event = TaskEvent.where(task_slug: SLUG, to_stage: "reviewed").transitions.chronological.last
    assert event, "the merge must land a submitted → reviewed transition"
    assert_equal "autopilot", event.source
    assert_equal "carl", event.actor, "the reviewer whose recorded verdict authorised the merge"
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

  # ── MUTATION 1b: A SECOND LANE ON THE SAME TREE ─────────────────────────────
  #
  # [integration] The armed merge of studio-engine PR #111 (2026-08-13) fired at
  # 21:06:02Z while `Consumer CI` was still in_progress — it concluded at 21:09:36Z,
  # three and a half minutes AFTER the merge. `Engine CI` had concluded green at
  # 21:03:47Z, and that conclusion is what triggered the executor.
  #
  # The suite lane above already covered a pending SUITE. It could not have caught
  # this: the fold was scoped to ONE workflow name, so the second lane never reached
  # CiStatus at all. These tests seed a lane whose workflow differs from the repo's
  # resolved suite — the exact shape the old query discarded — and drive the WHOLE
  # executor, so what is proven is that no merge request leaves the building.
  #
  # This is the case the autopilot exists for, which is what makes the leak serious
  # rather than academic: a reviewer arms and leaves precisely BECAUSE a slow
  # consumer lane is outstanding.

  # A lane on the same head that is NOT the repo's suite workflow.
  def ingest_sibling(status: "in_progress", conclusion: nil, workflow: "Consumer CI", run_id: 900_002)
    assert_not_equal GithubWorkflowRun.ci_workflow_for("mcritchie-studio"), workflow,
                     "precondition: #{workflow} must not be the resolved suite, or the old single-workflow " \
                     "read would have caught it and this test proves nothing"
    GithubWorkflowRun.create!(
      run_id: run_id, repo: REPO, workflow_name: workflow, head_branch: BRANCH,
      head_sha: PINNED, status: status, conclusion: conclusion,
      run_started_at: Time.current, run_attempt: 1
    )
  end

  {
    "still running" => { status: "in_progress", conclusion: nil },
    "still queued"  => { status: "queued", conclusion: nil },
    "failed"        => { status: "completed", conclusion: "failure" },
    "cancelled"     => { status: "completed", conclusion: "cancelled" }
  }.each do |label, attrs|
    test "[integration] REFUSES to merge while a SECOND lane on the pinned tree is #{label}" do
      ingest_ci # the suite lane, concluded green — the trigger that fired PR #111's merge
      ingest_sibling(**attrs)
      action = arm
      result, github = run_executor(action)

      assert_equal 0, github.merge_calls,
                   "a lane that is #{label} must never reach the merge endpoint — PR #111 did"
      assert_equal :waiting, result.status
      assert_match(/Consumer CI/, result.reason,
                   "the blocking lane must be NAMED — proof it reached the verdict rather than being dropped")
      assert_equal ReviewPendingAction::PENDING, action.reload.state
      assert_equal "submitted", @task.reload.stage
      assert_nil @task.merged
    end
  end

  # THE OTHER HALF, and the one that keeps the fix from being "block everything":
  # the armed merge must still land once the slow lane concludes. Same action, same
  # pin, driven twice — exactly how the webhook retriggers it.
  test "[integration] the armed merge lands once the slow second lane concludes green" do
    ingest_ci
    sibling = ingest_sibling(status: "in_progress", conclusion: nil)
    action = arm

    waiting, blocked_github = run_executor(action)
    assert_equal :waiting, waiting.status
    assert_equal 0, blocked_github.merge_calls
    assert_equal "submitted", @task.reload.stage

    # The consumer suite finishes — the second trigger the ingest fires on a conclusion.
    sibling.update!(status: "completed", conclusion: "success")

    result, github = run_executor(action.reload)
    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls, "the merge must still happen — a gate that never opens is not a gate"
    assert_equal "reviewed", @task.reload.stage
    assert_equal Task::MERGED_ACCEPTED, @task.merged
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

  # ── MUTATION 4b: THE VERDICT WAS REVISED ────────────────────────────────────
  #
  # THE DEFECT THIS CLOSES, and it is the probe that found it: arm on a
  # merge-ready verdict, record a `request-changes` afterwards, settle CI green on
  # the pin — and the merge fired anyway, while the task's record read
  # `request-changes`. Every other guard held; a wrong merge was never possible.
  # What broke is the ONE invariant the feature rests on — the autopilot carries
  # out an ALREADY-MADE decision, and a decision since revised is not that
  # decision.
  #
  # This is the exact mirror of the head-SHA pin. That pin is re-read at fire time
  # because the TREE may have changed since the verdict; this is re-read at fire
  # time because the VERDICT may have changed since the tree.
  #
  # An explicit disarm always worked. It is not what people DO: a reviewer who
  # changes their mind records `request-changes`; nobody thinks "I must disarm the
  # robot". The guard has to cover the action that is actually taken.

  test "REFUSES when the verdict was REVISED after arming — the probe that found this" do
    ingest_ci
    action = arm
    revision = record_merge_ready_verdict(outcome: "request-changes")

    result, github = run_executor(action)

    assert_equal :refused, result.status
    assert_equal 0, github.merge_calls,
                 "a revised decision must never reach the merge endpoint"
    assert_match(/revised to request-changes/, result.reason)
    assert_match(/#{revision.created_at.utc.iso8601}/, result.reason,
                 "the refusal must name WHEN the decision changed")
    assert_equal ReviewPendingAction::REFUSED, action.reload.state

    @task.reload
    assert_equal "submitted", @task.stage
    assert_nil @task.merged, "the task must not read merged while its record reads request-changes"
  end

  # Every non-authorising outcome revises the decision, not just the blocking one:
  # `wait-for-ci` is a reviewer stepping BACK from merge-ready, and `conductor-review`
  # is an escalation to a human. Neither is consent to merge now.
  ["wait-for-ci", "conductor-review"].each do |outcome|
    test "REFUSES when the verdict was revised to #{outcome} after arming" do
      ingest_ci
      action = arm
      record_merge_ready_verdict(outcome: outcome)

      result, github = run_executor(action)

      assert_equal :refused, result.status
      assert_equal 0, github.merge_calls
      assert_match(/revised to #{outcome}/, result.reason)
      assert_equal "submitted", @task.reload.stage
    end
  end

  # THE OVER-BROAD CHECK, ruled out. A guard that refuses everything is as wrong as
  # one that refuses nothing, and it would fail exactly where the real pipeline
  # lives: the primary and the light reviewer each record their own scout report,
  # so a second merge-ready lands routinely AFTER the arm. That is a re-affirmation
  # and must still merge.
  test "a later merge-ready report re-affirms the decision and STILL merges" do
    ingest_ci
    action = arm
    record_merge_ready_verdict

    result, github = run_executor(action)

    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls
    assert_equal "reviewed", @task.reload.stage
  end

  # Ordering, not existence: the SAME two reports in the other order must merge.
  # If this passed while the refusal above also passed by accident, the guard would
  # be reading "a request-changes exists anywhere" rather than "the LATEST report".
  test "a request-changes that came BEFORE the authorising verdict does not block" do
    ingest_ci
    record_merge_ready_verdict(outcome: "request-changes")
    @verdict = record_merge_ready_verdict
    action = arm

    result, github = run_executor(action)

    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls
  end

  # ── MUTATION 4c: THE DESTINATION ────────────────────────────────────────────
  # `MERGE_TO_ACCEPTED` may only merge to `accepted`. The fire-time half exists
  # because rows written BEFORE the validation are still in the table, so the
  # probe here writes one the same way the world would: straight past validation.

  test "REFUSES a row whose destination is not the one its action type names" do
    ingest_ci
    action = arm
    action.update_column(:base_branch, "main") # rubocop:disable Rails/SkipsModelValidations

    github = FakeGithub.new(pr: open_pr(base: "main"))
    result, = run_executor(action.reload, github: github)

    assert_equal :refused, result.status
    assert_match(/may only merge into accepted/, result.reason)
    assert_equal 0, github.merge_calls,
                 "an armed merge must never reach the merge endpoint for a branch it may not touch"
    assert_equal ReviewPendingAction::REFUSED, action.reload.state
    assert_equal "submitted", @task.reload.stage
    assert_nil @task.merged
  end

  test "cannot be ARMED against a destination this action type may not merge into" do
    error = assert_raises(ReviewPendingAction::Unauthorised) do
      ReviewPendingAction.arm!(task: @task.reload, repo: REPO, pr_number: 4242,
                               head_sha: PINNED, base_branch: "main", authorized_by: "carl")
    end
    assert_match(/may only merge into accepted/, error.message)
    assert_equal 0, ReviewPendingAction.count
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
    # NOT :refused. `:refused` means "this run SETTLED the action refused"; a run
    # that wrote nothing must not report the same status as one that did, on the
    # very record an incident review reads to find out what the machine decided.
    assert_equal :already_settled, second.status
    assert_equal 0, github.merge_calls
    assert_equal ReviewPendingAction::EXECUTED, action.reload.state,
                 "the re-run must not overwrite the real outcome with its own bookkeeping"
  end

  # ── TWO EXECUTIONS OF ONE ARMED MERGE ───────────────────────────────────────
  #
  # The claim lock is released before the GitHub round trip ON PURPOSE (holding it
  # would pin one Postgres connection per in-flight merge against a 20-connection
  # pool), so TWO jobs can both pass `pending?` and both reach the settle. That is
  # the whole premise of this section: neither test below is the sequential
  # "second run finds it settled" case above — in both, the second execution has
  # ALREADY CLAIMED a pending row before the first one writes.
  #
  # The merge was never the risk: GitHub's `sha` pin makes a double merge
  # impossible. The ACCOUNTING was. These assert the record.
  #
  # MUTATION PROOF: drop `.where(state: PENDING)` from ReviewPendingAction#settle!
  # and both tests fail — the row ends up naming the loser's outcome.

  test "[unit] both executions claim, the MERGER loses the settle, and its real sha still lands" do
    ingest_ci
    action = arm

    # The sibling is a SECOND, INDEPENDENT execution of the same row, run at the
    # exact moment the merge is in flight. The row is still pending, so it claims
    # legitimately; it reads a PR GitHub already reports as merged but with no
    # merge_commit_sha yet, and that is the SHORTER path — no PUT — so it reaches
    # the settle first and records a truthful `executed` that names no sha.
    sibling_action = ReviewPendingAction.find(action.id)
    sibling_client = FakeGithub.new(pr: open_pr(state: "closed", merged: true, mergeable: nil))
    sibling_result = nil

    merger = FakeGithub.new(pr: open_pr, merge_body: { "sha" => "realmergesha000" })
    merger.define_singleton_method(:put_response) do |path, body: nil|
      sibling_result = Review::PendingActionExecutor.call(sibling_action, client: sibling_client)
      super(path, body: body)
    end

    result, = run_executor(action, github: merger)

    assert_equal :executed, sibling_result.status, "the sibling settled first, on a pending row"
    assert_equal :already_settled, result.status, "the merger must not overwrite the settled row"
    assert_match(/supplied the missing merge sha/, result.reason)
    assert_match(/would have written executed/, result.reason)

    action.reload
    assert_equal ReviewPendingAction::EXECUTED, action.state
    assert_equal "realmergesha000", action.merge_sha,
                 "the sha of the merge that actually happened is the one fact the row must not lose"
    assert_equal 2, action.attempts, "a double execution is COUNTED, never silently swallowed"
  end

  test "[unit] a claimed sibling that refuses LATE writes nothing over an EXECUTED row" do
    ingest_ci
    action = arm

    # This executor claims a pending row, then the world moves under it: the other
    # job merges, stamps, and settles while this one is still reading GitHub. Its
    # own reading is then a refusal ("head moved") — and that opinion must never
    # become the record of a merge that happened.
    real_sha = "realmergesha000"
    winner_row = ReviewPendingAction.find(action.id)
    winning_task = @task

    late = FakeGithub.new(pr: open_pr(sha: MOVED))
    late.define_singleton_method(:get) do |path|
      # What the OTHER job's finish_merge does, landing while this one is mid-read.
      winner_row.settle!(state: ReviewPendingAction::EXECUTED,
                         reason: "merged a1b2c3d into accepted on the recorded merge-ready verdict by carl",
                         merge_sha: real_sha)
      winning_task.update!(merged: "accepted", stage: "reviewed")
      super(path)
    end

    result, = run_executor(action, github: late)

    assert_equal :already_settled, result.status
    assert_match(/already settled executed by a concurrent execution/, result.reason)
    assert_match(/would have written refused: head moved/, result.reason,
                 "the discarded opinion is RECORDED in the log line, just never in the row")

    action.reload
    assert_equal ReviewPendingAction::EXECUTED, action.state,
                 "a merge that happened must never read as refused"
    assert_equal real_sha, action.merge_sha, "a recorded merge sha is never nulled by a retry"
    assert_equal "reviewed", @task.reload.stage
  end

  # THE ANTI-TRAP. The guard must not trap its own subject — the prior art is the
  # blanket base_branch validation that also rejected the executor's own settle!,
  # so the one row it existed to catch could never settle and retried as pending
  # forever. A FIRST attempt on a genuinely pending row must still settle.
  test "[unit] a genuinely pending row still settles REFUSED on its first attempt" do
    ingest_ci
    action = arm
    result, = run_executor(action, github: FakeGithub.new(pr: open_pr(sha: MOVED)))

    assert_equal :refused, result.status, "a first refusal WRITES — it is not a lost race"
    assert_equal ReviewPendingAction::REFUSED, action.reload.state
    assert_match(/head moved/, action.outcome_reason)
    refute action.pending?, "a refused action must never be left pending to retry forever"
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

  # ── MUTATION: THE TASK'S SECOND REPO ────────────────────────────────────────
  #
  # THE SHARP END of task review-gate-reads-one-repo. Ci::ReviewGate gated on
  # `repositories.first`, so on a task landing PRs in TWO repos this component —
  # the one that merges with NOBODY WATCHING — read repo #1's CI and merged on it
  # while repo #2 was red. There is no human between that verdict and `accepted`.
  #
  # Each case here is the CONTROL with exactly one thing changed: the task now has
  # a second PR, and that repo's CI is not green. Repo #1 stays green throughout —
  # asserted, because the same test with repo #1 red would pass on the broken code
  # and prove nothing.
  SECOND_REPO = "McRitchie-Studio/turf-monster"
  SECOND_PINNED = "cccccccccccccccccccccccccccccccccccccccc"

  # The shape `bin/task update <slug> --pr-url-for turf-monster=<url>` writes: a
  # second PR in the per-repo register, landing under the same reviewed task.
  def add_second_repo!(pr: 77)
    devops = @task.metadata.fetch("devops").merge(
      "repositories" => %w[mcritchie-studio turf-monster],
      "pr_urls" => { "turf-monster" => "https://github.com/#{SECOND_REPO}/pull/#{pr}" }
    )
    @task.update!(metadata: @task.metadata.merge("devops" => devops))
    @task.reload
  end

  def ingest_second_ci(sha: SECOND_PINNED, status: "completed", conclusion: "success", run_id: 900_777)
    GithubWorkflowRun.create!(
      run_id: run_id, repo: SECOND_REPO, workflow_name: "CI", head_branch: BRANCH,
      head_sha: sha, status: status, conclusion: conclusion,
      run_started_at: Time.current, run_attempt: 1
    )
  end

  {
    "red"     => { conclusion: "failure" },
    "pending" => { status: "in_progress", conclusion: nil }
  }.each do |label, attrs|
    test "REFUSES to merge while the task's SECOND repo is #{label} — never merges" do
      ingest_ci # repo #1 green on the pinned head
      add_second_repo!
      ingest_second_ci(**attrs)
      action = arm

      assert_equal :green, Ci::ReviewGate.verdict(@task.reload, repo: "mcritchie-studio")[:state],
                   "precondition: repo #1 IS green — this is the arrangement that used to auto-merge"

      result, github = run_executor(action)

      assert_equal :waiting, result.status
      assert_equal 0, github.merge_calls,
                   "a task is ONE reviewed change: half of it failing must never reach the merge endpoint"
      assert_match(/turf-monster/, result.reason, "the account of a merge that did not happen must NAME the repo")
      assert_equal ReviewPendingAction::PENDING, action.reload.state, "a wait keeps the order standing"
      assert_equal "submitted", @task.reload.stage
      assert_nil @task.merged
    end
  end

  # A repo the board holds NO run for is the wiring gap — and absence is not a
  # pass here either, for the same reason it is not within one repo.
  test "REFUSES to merge when the SECOND repo has no CI at all" do
    ingest_ci
    add_second_repo! # no runs ingested for turf
    action = arm

    result, github = run_executor(action)

    assert_equal :waiting, result.status
    assert_equal 0, github.merge_calls
    assert_match(/turf-monster/, result.reason)
  end

  # THE POSITIVE CONTROL for the multi-repo path. A guard that blocks every
  # two-repo merge would strand the shape it exists to protect.
  test "CONTROL: a two-repo task merges once BOTH repos are green" do
    ingest_ci
    add_second_repo!
    ingest_second_ci # green
    action = arm

    result, github = run_executor(action)

    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls
    assert_equal "reviewed", @task.reload.stage
  end

  # THE PIN IS PER REPO, and this is the other half of the same confusion. An armed
  # merge names ONE PR in one repo, so the head_sha it compares must come from THAT
  # repo's runs. Reading the fold's primary sha here would compare turf's pinned
  # head against the HUB's green — never equal, so an authorised merge would wait
  # out its TTL and expire for a reason that does not exist.
  test "the head-sha pin reads the ACTION's OWN repo, not the task's first" do
    ingest_ci # hub green at PINNED
    add_second_repo!
    ingest_second_ci # turf green at SECOND_PINNED
    action = ReviewPendingAction.arm!(
      task: @task.reload, repo: SECOND_REPO, pr_number: 77, head_sha: SECOND_PINNED,
      pr_url: "https://github.com/#{SECOND_REPO}/pull/77", authorized_by: "carl"
    )

    result, github = run_executor(action, github: FakeGithub.new(pr: open_pr(sha: SECOND_PINNED)))

    assert_equal :executed, result.status, result.reason
    assert_equal 1, github.merge_calls
    assert_equal SECOND_PINNED, github.last_body[:sha], "GitHub's own pin is the action's head, not the hub's"
  end

  # …and the pin still bites on the action's own repo: turf's head moved, the hub's
  # green is irrelevant, and no merge may fire.
  test "a moved head in the ACTION's own repo still blocks, with the other repo green" do
    ingest_ci
    add_second_repo!
    ingest_second_ci(sha: MOVED) # turf's green describes a DIFFERENT tree
    action = ReviewPendingAction.arm!(
      task: @task.reload, repo: SECOND_REPO, pr_number: 77, head_sha: SECOND_PINNED,
      pr_url: "https://github.com/#{SECOND_REPO}/pull/77", authorized_by: "carl"
    )

    result, github = run_executor(action, github: FakeGithub.new(pr: open_pr(sha: SECOND_PINNED)))

    assert_equal :waiting, result.status
    assert_equal 0, github.merge_calls
    assert_match(/not the pinned #{SECOND_PINNED}/, result.reason)
  end
end
