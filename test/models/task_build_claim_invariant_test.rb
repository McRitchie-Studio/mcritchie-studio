# frozen_string_literal: true

# The build claim's server half, and the attribution of durable progress.
#
# THE DESK IS THE BUILD CLAIM (devops-v3 piece 4b-i; bin/lib/desk_claim.rb). The
# 120s lease is gone. The board keeps ONE key, devops.claimed_session, as an
# attribution record stamped by a build claim (a PATCH naming `stage: building`
# with the mover's session on its event) — Task#stamp_build_claim_session. It is
# cleared when the task leaves `building`, and the retired lease keys
# (claim_nonce, claim_expires_at) are dropped on every save, which is the
# one-release tolerance for rows an older CLI wrote.
require "test_helper"

class TaskBuildClaimInvariantTest < ActiveSupport::TestCase
  # Session ids are UUIDs, and that SHAPE is load-bearing: Task#disowned? treats an
  # actor matching Task::SOUL_SLUG (carl, shannon — what a block and bin/pr-review
  # write) as an unknown owner rather than a stranger. A soul-shaped stand-in like
  # "sess-holder" would take that branch and quietly stop testing the real one.
  HOLDER = "s1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  STEALER = "s2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"
  CHALLENGER = "s3f2a4c5-6d7e-4f80-9b12-c3d4e5f6a7b8"

  setup do
    @now = Time.current
    @task = tasks(:in_progress_task) # stage: building
    claim!(HOLDER)
    TaskEvent.where(task_slug: @task.slug).delete_all
    GateRun.where(subject_slug: @task.slug).delete_all
  end

  # A build claim exactly as the API delivers one: `stage: building` on the PATCH
  # (Current.task_build_claim) and the mover's session on the event.
  def claim!(session, devops: { "kind" => "feature" })
    Current.set(task_build_claim: true, task_event_session: session) do
      @task.update!(stage: "building", metadata: { "devops" => devops })
    end
  end

  def claimed(task = @task)
    task.reload.devops["claimed_session"]
  end

  # --- STAMP: a claim names its session, and writes no lease -------------------

  test "a build claim stamps the claiming session and writes no lease" do
    assert_equal HOLDER, claimed
    assert_nil @task.devops["claim_nonce"], "no per-instance nonce: the desk is the claim"
    assert_nil @task.devops["claim_expires_at"], "no TTL: nothing renews or expires a build claim"
    refute @task.claim_live?(now: @now), "readers see no live lease"
  end

  test "a re-claim by another session re-points the claimer" do
    claim!(STEALER)

    assert_equal STEALER, claimed
  end

  # Only a claim may change who claimed. A write that posts a different session, or
  # blanks it, or omits it, is not a claim.
  test "a non-claim write cannot re-point or erase the claimer" do
    @task.update!(metadata: { "devops" => { "kind" => "feature", "claimed_session" => STEALER } })
    assert_equal HOLDER, claimed, "a posted session is not a claim"

    @task.update!(metadata: { "devops" => { "kind" => "feature", "branch" => "feat/x" } })
    assert_equal HOLDER, claimed, "an omitted session is not a released claim"
  end

  # The one-release tolerance: a row an older CLI wrote sheds its lease keys on the
  # next save, and keeps the claimer.
  test "retired lease keys are dropped on any save" do
    old = @task.metadata.deep_dup
    old["devops"].merge!("claim_nonce" => "inst-A", "claim_expires_at" => (@now + 90).utc.iso8601)
    @task.update_columns(metadata: old)

    @task.update!(title: "Retitled Task Here")

    assert_nil @task.reload.devops["claim_nonce"]
    assert_nil @task.devops["claim_expires_at"]
    assert_equal HOLDER, claimed
  end

  # --- RELEASE: the claimer is a BUILD-stage fact ----------------------------

  test "moving out of building clears the claimer" do
    @task.update!(stage: "submitted")

    assert_nil claimed, "a submitted task is not being built — nobody holds a build claim on it"
  end

  # Read from Task::STAGES rather than a hand-listed copy: a stage added later must
  # inherit the rule automatically.
  test "every non-building stage clears the claimer" do
    (Task::STAGES - %w[building]).each do |stage|
      claim!(HOLDER)
      @task.update!(stage: stage)

      assert_nil claimed, "stage #{stage} is not a build — the claimer must be cleared"
    end
  end

  test "a non-building task sheds a stale claimer on any save" do
    @task.update_columns(stage: "submitted") # bypass callbacks: seed the bad row
    assert_equal HOLDER, @task.reload.devops["claimed_session"], "precondition: the stale claim is on the row"

    @task.update!(title: "Retitled Task Here")

    assert_nil claimed, "the stale holder is shed the next time the row is written"
  end

  test "the claimer survives saves that keep the task building" do
    @task.update!(title: "Still Building This")

    assert_equal HOLDER, claimed
  end

  # --- ATTRIBUTION: progress belongs to whoever produced it ------------------

  def checkpoint!(session:, at:, name: "cert", status: "passed")
    metadata = { "status" => status }
    metadata["session"] = session if session
    TaskEvent.create!(task_slug: @task.slug, kind: TaskEvent::CHECKPOINT, occurred_at: at,
                      from_stage: "building", to_stage: name, metadata: metadata)
  end

  def gate!(session:, at:, key: "g1_cert")
    metadata = session ? { "session" => session } : {}
    GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: key, attempt: 1,
                    started_at: at, finished_at: at, success: true, metadata: metadata,
                    created_at: at, updated_at: at)
  end

  # THE CIRCULAR REFUSAL, at its source. A challenger's own local cert (since retired) lands
  # a g1_cert on a task it does not hold; the holder has produced nothing. The
  # holder-scoped fact must stay EMPTY rather than absorb the challenger's work.
  test "a challengers cert is not counted as the holders progress" do
    gate!(session: CHALLENGER, at: @now - 2.minutes)

    assert_equal CHALLENGER, @task.last_progress_actor
    assert_in_delta 120, @task.progress_seconds_ago(now: @now), 5, "the task did see an artifact"
    assert_nil @task.holder_progress_seconds_ago(now: @now),
               "the holder produced nothing — crediting it would manufacture the evidence for its own lease"
    assert_nil @task.holder_progress_label
  end

  test "the holders own artifact is reported as the holders progress" do
    checkpoint!(session: HOLDER, at: @now - 30.minutes)

    assert_in_delta 1_800, @task.holder_progress_seconds_ago(now: @now), 5
    assert_equal "cert passed", @task.holder_progress_label
  end

  # The holder's own progress is found even when someone else's artifact is newer.
  test "a newer foreign artifact does not hide the holders older one" do
    checkpoint!(session: HOLDER, at: @now - 30.minutes)
    gate!(session: CHALLENGER, at: @now - 2.minutes)

    assert_equal CHALLENGER, @task.last_progress_actor, "the newest artifact is still reported as theirs"
    assert_in_delta 1_800, @task.holder_progress_seconds_ago(now: @now), 5,
                    "the holder's own progress is its own, whatever landed after it"
  end

  # An unowned row names nobody, and nobody must not become the holder.
  test "an unattributed artifact is reported as unowned rather than as the holders" do
    gate!(session: nil, at: @now - 2.minutes)

    assert_nil @task.last_progress_actor
    assert_nil @task.holder_progress_seconds_ago(now: @now)
  end

  # `actor` already carries the session id on a CLI stage move (bin/task), so that
  # attribution works without any new plumbing on the oldest evidence path.
  test "a stage moves actor attributes it to the moving session" do
    TaskEvent.create!(task_slug: @task.slug, kind: TaskEvent::TRANSITION, occurred_at: @now - 5.minutes,
                      from_stage: "designed", to_stage: "building", actor: HOLDER)

    assert_equal HOLDER, @task.last_progress_actor
    assert_in_delta 300, @task.holder_progress_seconds_ago(now: @now), 5
  end

  # --- REAPING: the same rule, pointed the other way -------------------------
  #
  # The attribution above is strict: an unowned row is never claimed AS the
  # holder's, because the refusal message must not invent evidence that the holder
  # is alive. These invert on exactly one point, and only that one: the reaping
  # decision must not invent evidence that the holder is GONE, so an unowned row
  # protects here. Only a row DEMONSTRABLY another session's stops counting.

  def open_gate!(session:, at:, key: "g1_cert")
    metadata = session ? { "session" => session } : {}
    GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: key, attempt: 1,
                    started_at: at, finished_at: nil, success: nil, metadata: metadata,
                    created_at: at, updated_at: at)
  end

  # The decision bin/task actually makes, composed from the two facts it reads. The
  # CLI tier (test/lib/task_cli_test.rb) proves bin/task feeds these in; this proves
  # the model derives them from real TaskEvent/GateRun rows. Neither alone shows
  # the incident is closed.
  def reaps?(now: @now)
    ClaimLease.abandoned?(desk_touched: false,
                          progress_age: @task.holder_liveness_seconds_ago(now: now),
                          gate_in_flight: @task.holder_gate_in_flight?(now: now),
                          awaiting_approval: false)
  end

  # THE REGRESSION. The holder is long gone; a queued challenger runs its own
  # the local cert on the held slug, landing a checkpoint AND opening a g1_cert.
  # Task-wide both signals now say "busy", and reading them renewed the dead lease
  # for another 1h29m. The lease must still reap.
  test "a challengers own cert does not revive an abandoned lease" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes))
    checkpoint!(session: CHALLENGER, at: @now - 2.minutes)
    open_gate!(session: CHALLENGER, at: @now - 2.minutes)

    assert @task.gate_in_flight?(now: @now), "precondition: task-wide, a gate IS running"
    assert_in_delta 120, @task.progress_seconds_ago(now: @now), 5, "precondition: task-wide, progress IS recent"

    refute @task.holder_gate_in_flight?(now: @now), "the running gate is the challenger's, not the holder's"
    assert reaps?, "a challenger's own cert must not renew the lease it is queued behind"
  end

  # The converse, and the reason the channel is FILTERED rather than dropped: a
  # cert writes nothing into the desk for up to the measured 94-minute p99, so a
  # holder mid-cert looks identical to a walked-away terminal from the desk alone.
  test "a holder mid cert with a silent desk is not reaped" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes))
    open_gate!(session: HOLDER, at: @now - 20.minutes)

    assert @task.holder_gate_in_flight?(now: @now), "the holder's own cert is running"
    refute reaps?, "reaping a holder mid-certification is the expensive error, and this is it"
  end

  # UNKNOWN KEEPS THE DESK. A gate run written before bin/gate stamped its session
  # names nobody. Nobody is not "somebody else", and reading a missing field as
  # proof of absence would evict a live worker on a schema gap.
  test "an unsigned gate in flight still protects the holder" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes))
    open_gate!(session: nil, at: @now - 20.minutes)

    assert @task.holder_gate_in_flight?(now: @now), "an unattributed gate is an unknown, and unknowns protect"
    refute reaps?
  end

  # The same rule on the progress channel. Split from its converse below rather
  # than sequenced in one case: holder_liveness_seconds_ago memoizes its evidence
  # per instance (as holder_progress_* does), and `reload` does not clear a plain
  # ivar — so a second scenario in the same test would silently assert against the
  # first one's cached answer.
  test "an unsigned artifact keeps the holders liveness clock warm" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes))
    checkpoint!(session: nil, at: @now - 3.minutes)

    assert_in_delta 180, @task.holder_liveness_seconds_ago(now: @now), 5, "nobody's work might be the holder's"
    refute reaps?, "an unknown owner may never be the reason a desk is freed"
  end

  # A SOUL SLUG IS NOT A SESSION. `actor` carries a soul on a block and on
  # bin/pr-review's gate rows, and "carl" differs from a session UUID for a reason
  # that says nothing about who acted. Comparing the two namespaces would mark
  # every soul-attributed row a stranger's and reap the holder on it — the same
  # "unknown read as absence" this guard exists to refuse.
  test "a soul attributed artifact is an unknown owner rather than a stranger" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes))
    TaskEvent.create!(task_slug: @task.slug, kind: TaskEvent::TRANSITION, occurred_at: @now - 3.minutes,
                      from_stage: "building", to_stage: "building", actor: "carl")

    assert_in_delta 180, @task.holder_liveness_seconds_ago(now: @now), 5,
                    "a soul name cannot prove the row belongs to another session"
    refute reaps?
  end

  test "a challengers artifact does not keep the holders liveness clock warm" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::DESK_IDLE_SECONDS + 10.minutes))
    checkpoint!(session: CHALLENGER, at: @now - 3.minutes)

    assert_operator @task.holder_liveness_seconds_ago(now: @now), :>, ClaimLease::DESK_IDLE_SECONDS,
                    "a named stranger's work is demonstrably not the holder's"
    assert reaps?
  end
end
