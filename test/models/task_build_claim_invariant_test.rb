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
  setup do
    @now = Time.current
    @task = tasks(:in_progress_task) # stage: building
    @claim = ClaimLease.renewed(session: "sess-holder", nonce: "inst-A", now: @now)
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(@claim) })
    TaskEvent.where(task_slug: @task.slug).delete_all
    GateRun.where(subject_slug: @task.slug).delete_all
  end

  def claim_keys(task = @task)
    task.reload.devops.slice(*ClaimLease::CLAIM_KEYS)
  end

  # --- PRESERVE: a client that forgets the claim must not destroy it ---------

  # The board's edit form permits no claim keys, so this payload IS what a board
  # save sends. Before the invariant it wiped a live lease and the desk read as
  # unclaimed — inviting a second agent onto a desk someone was working at.
  test "a wholesale devops replace that omits the claim keys does not destroy a live claim" do
    @task.update!(metadata: { "devops" => { "kind" => "feature", "branch" => "feat/x" } })

    assert_equal @claim, claim_keys, "an omitted key is not a released claim"
    assert @task.reload.claim_live?(now: @now), "the desk is still held by its holder"
  end

  # Preserving is not extending. The lease keeps lapsing on its own TTL clock —
  # restoring an omitted key must never push the expiry out.
  test "preserving an omitted claim does not renew its lease" do
    lapsed = ClaimLease.renewed(session: "sess-holder", nonce: "inst-A", now: @now - 10.minutes)
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(lapsed) })

    @task.update!(metadata: { "devops" => { "kind" => "feature" } })

    assert_equal lapsed["claim_expires_at"], claim_keys["claim_expires_at"],
                 "the expiry is carried forward verbatim, not refreshed"
    refute @task.reload.claim_live?(now: @now), "a lapsed lease stays lapsed"
  end

  # An explicit re-claim still wins — preservation only fills what was omitted.
  test "an incoming claim overwrites the stored one" do
    fresh = ClaimLease.renewed(session: "sess-stealer", nonce: "inst-B", now: @now)
    @task.update!(metadata: { "devops" => { "kind" => "feature" }.merge(fresh) })

    assert_equal "sess-stealer", claim_keys["claimed_session"]
    assert_equal "inst-B", claim_keys["claim_nonce"]
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
    assert_equal "sess-holder", @task.reload.devops["claimed_session"], "precondition: the stale claim is on the row"

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
    gate!(session: "sess-challenger", at: @now - 2.minutes)

    assert_equal "sess-challenger", @task.last_progress_actor
    assert_in_delta 120, @task.progress_seconds_ago(now: @now), 5, "the task did see an artifact"
    assert_nil @task.holder_progress_seconds_ago(now: @now),
               "the holder produced nothing — crediting it would manufacture the evidence for its own lease"
    assert_nil @task.holder_progress_label
  end

  test "the holders own artifact is reported as the holders progress" do
    checkpoint!(session: "sess-holder", at: @now - 30.minutes)

    assert_in_delta 1_800, @task.holder_progress_seconds_ago(now: @now), 5
    assert_equal "cert passed", @task.holder_progress_label
  end

  # The holder's own progress is found even when someone else's artifact is newer.
  test "a newer foreign artifact does not hide the holders older one" do
    checkpoint!(session: "sess-holder", at: @now - 30.minutes)
    gate!(session: "sess-challenger", at: @now - 2.minutes)

    assert_equal "sess-challenger", @task.last_progress_actor, "the newest artifact is still reported as theirs"
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
                      from_stage: "designed", to_stage: "building", actor: "sess-holder")

    assert_equal "sess-holder", @task.last_progress_actor
    assert_in_delta 300, @task.holder_progress_seconds_ago(now: @now), 5
  end

  # The board chip asks the same question the gate does, so it must not be
  # answerable with someone else's work either.
  test "a challengers cert does not make a quiet holder read as healthy" do
    checkpoint!(session: "sess-holder", at: @now - (ClaimLease::PROGRESS_QUIET_SECONDS + 30.minutes))
    gate!(session: "sess-challenger", at: @now - 2.minutes)

    assert @task.claim_progress_quiet?(now: @now),
           "the holder has been silent for longer than the threshold — a stranger's cert does not revive it"
  end
end
