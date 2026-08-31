# frozen_string_literal: true

# The build claim as a STAGE INVARIANT, and the attribution of durable progress.
#
# Two failures from 2026-08-13 live here, and they share a cause: the claim keys
# in metadata["devops"] were treated as ordinary client data.
#
#   RELEASE — every other lease in this app (DevopsShift, TaskReviewClaim,
#   ReleaseConductorClaim, MigrationLaneClaim) has an explicit release that nils
#   its columns. The devops build claim had none: sessions stopped heartbeating
#   and walked away, leaving a dead holder on the row.
#
#   PRESERVE — Api::V1::TasksController assigns metadata WHOLESALE, so any PATCH
#   carrying `devops` deletes the keys it does not echo, and the board's own edit
#   form echoes none of them. A board save silently destroyed a LIVE claim, which
#   is why two readers of "the same fact" disagreed 20 seconds apart: the fact was
#   being erased and rewritten underneath them.
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
    @claim = ClaimLease.renewed(session: HOLDER, nonce: "inst-A", now: @now)
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(@claim) })
    TaskEvent.where(task_slug: @task.slug).delete_all
    GateRun.where(subject_slug: @task.slug).delete_all
  end

  def claim_keys(task = @task)
    task.reload.devops.slice(*ClaimLease::CLAIM_KEYS)
  end

  # --- PRESERVE: a client that forgets the claim must not destroy it ---------

  # The board's edit form permits no claim keys, so this payload is the shape a board
  # save USED TO leave at the model. Before the invariant it wiped a live lease and
  # the desk read as unclaimed — inviting a second agent onto a desk someone was
  # working at. Both write paths fold through Task.merge_devops_into_metadata since
  # api-devops-patch-replaces, so this now drives the model write directly.
  test "a wholesale devops replace that omits the claim keys does not destroy a live claim" do
    @task.update!(metadata: { "devops" => { "kind" => "feature", "branch" => "feat/x" } })

    assert_equal @claim, claim_keys, "an omitted key is not a released claim"
    assert @task.reload.claim_live?(now: @now), "the desk is still held by its holder"
  end

  # Preserving is not extending. The lease keeps lapsing on its own TTL clock —
  # restoring an omitted key must never push the expiry out.
  test "preserving an omitted claim does not renew its lease" do
    lapsed = ClaimLease.renewed(session: HOLDER, nonce: "inst-A", now: @now - 10.minutes)
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(lapsed) })

    @task.update!(metadata: { "devops" => { "kind" => "feature" } })

    assert_equal lapsed["claim_expires_at"], claim_keys["claim_expires_at"],
                 "the expiry is carried forward verbatim, not refreshed"
    refute @task.reload.claim_live?(now: @now), "a lapsed lease stays lapsed"
  end

  # An explicit re-claim still wins — preservation only fills what was omitted.
  test "an incoming claim overwrites the stored one" do
    fresh = ClaimLease.renewed(session: STEALER, nonce: "inst-B", now: @now)
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(fresh) })

    assert_equal STEALER, claim_keys["claimed_session"]
    assert_equal "inst-B", claim_keys["claim_nonce"]
  end

  # The preservation must not become inheritance ACROSS holders. A steal names a
  # new session, SessionIdentity.nonce degrades to "" whenever the agent process
  # cannot be resolved, and normalize_devops_metadata drops blanks — so a real
  # steal arrives naming a new holder with NO nonce. Completing it from the old
  # record would staple the previous instance's token to the new holder's claim,
  # and the two-terminals guard would then be comparing one agent's identity
  # against another's.
  test "a claim naming a different session never inherits the previous holders nonce" do
    stolen = { "claimed_session" => STEALER, "claim_expires_at" => (@now + 120).utc.iso8601 }
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(stolen) })

    assert_equal STEALER, claim_keys["claimed_session"]
    assert_nil claim_keys["claim_nonce"], "one instance's token must never ride another instance's claim"
    assert_equal stolen["claim_expires_at"], claim_keys["claim_expires_at"],
                 "and the stealer's own lease stands, not the previous holder's"
  end

  # --- RELEASE: the claim is a BUILD-stage lease ----------------------------

  test "moving out of building releases the claim" do
    @task.update!(stage: "submitted")

    assert_empty claim_keys, "a submitted task is not being built — nobody holds a build claim on it"
    refute @task.reload.claim_live?(now: @now)
  end

  # Stated as an invariant rather than hung off the submitted transition, so every
  # exit releases — including the ones a `submitted`-only guard would miss.
  # Read from Task::STAGES rather than a hand-listed copy: a stage added later
  # must inherit the invariant automatically, or this test silently stops covering
  # the newest exit from `building`.
  test "every non-building stage releases the claim" do
    (Task::STAGES - %w[building]).each do |stage|
      @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(@claim) }, stage: "building")
      @task.update!(stage: stage)

      assert_empty claim_keys, "stage #{stage} is not a build — the claim must be released"
    end
  end

  # The invariant heals rows that already carry a dead claim, without needing the
  # stage to move: a save of any kind re-asserts it.
  test "a non-building task sheds a stale claim on any save" do
    @task.update_columns(stage: "submitted") # bypass callbacks: seed the bad row
    assert_equal HOLDER, @task.reload.devops["claimed_session"], "precondition: the stale claim is on the row"

    @task.update!(title: "Retitled Task Here")

    assert_empty claim_keys, "the stale holder is shed the next time the row is written"
  end

  test "the claim survives saves that keep the task building" do
    @task.update!(title: "Still Building This")

    assert_equal @claim, claim_keys
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

  # THE CIRCULAR REFUSAL, at its source. A challenger's own full-suite-check lands
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

  # The board chip asks the same question the gate does, so it must not be
  # answerable with someone else's work either.
  test "a challengers cert does not make a quiet holder read as healthy" do
    checkpoint!(session: HOLDER, at: @now - (ClaimLease::PROGRESS_QUIET_SECONDS + 30.minutes))
    gate!(session: CHALLENGER, at: @now - 2.minutes)

    assert @task.claim_progress_quiet?(now: @now),
           "the holder has been silent for longer than the threshold — a stranger's cert does not revive it"
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
  # full-suite-check on the held slug, landing a checkpoint AND opening a g1_cert.
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
