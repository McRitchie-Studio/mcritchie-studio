# frozen_string_literal: true

# The PROGRESS fact, which is not the LIVENESS fact.
#
# Task#claim_live? answers "is a terminal painting?" — bin/statusline renews the
# lease every ~5s, so it stays green through a wedged agent. These tests cover the
# second, independent fact: what has this task actually PRODUCED, read from the
# durable evidence we already write (TaskEvents + GateRuns).
#
# The load-bearing pair is the regression from 2026-07-13:
#   * a live lease with no durable write reads QUIET, and
#   * a live lease whose task is landing cert checkpoints does NOT —
# and NEITHER is ever auto-reclaimed (nothing here is destructive).
require "test_helper"

class TaskProgressTest < ActiveSupport::TestCase
  setup do
    @now = Time.current
    @task = tasks(:in_progress_task) # stage: building
    @task.update!(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: @now) })
    TaskEvent.where(task_slug: @task.slug).delete_all
  end

  def task_event!(kind:, at:, metadata: {})
    TaskEvent.create!(task_slug: @task.slug, kind: kind, occurred_at: at,
                      from_stage: "building", to_stage: "building", metadata: metadata)
  end

  # `updated_at` is the evidence timestamp: the moment this gate row last WROTE
  # something (opened, recorded a lane, closed). Real rows are written as the work
  # happens, so a fabricated row must backdate its timestamps the same way.
  def gate!(key: "g1_cert", started_at:, finished_at: nil, success: nil)
    GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: key, attempt: 1,
                    started_at: started_at, finished_at: finished_at, success: success,
                    created_at: started_at, updated_at: finished_at || started_at)
  end

  test "last_progress_at reads the most recent durable artifact" do
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 20.minutes, metadata: { "status" => "started" })
    gate!(started_at: @now - 5.minutes)

    assert_in_delta (@now - 5.minutes).to_i, @task.last_progress_at.to_i, 2
    assert_equal "g1_cert running", @task.last_progress_label
    assert_in_delta 300, @task.progress_seconds_ago(now: @now), 2
  end

  test "a cert checkpoint is durable progress and names itself" do
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 3.minutes, metadata: { "status" => "started" })

    assert_equal "cert started", @task.last_progress_label
  end

  test "a closed gate reports its verdict as the artifact" do
    gate!(started_at: @now - 30.minutes, finished_at: @now - 22.minutes, success: false)

    assert_equal "g1_cert failed", @task.last_progress_label
  end

  # --- The 2026-07-13 regression, both halves -------------------------------

  test "a live lease that has made no durable write reads quiet" do
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 5.hours, metadata: { "status" => "completed" })

    assert @task.claim_live?(now: @now), "precondition: the lease is live (terminal painting)"
    assert @task.claim_progress_quiet?(now: @now), "a held desk producing nothing must read quiet"
  end

  test "a live lease making cert-checkpoint writes does not read quiet" do
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 2.minutes, metadata: { "status" => "started" })

    assert @task.claim_live?(now: @now)
    refute @task.claim_progress_quiet?(now: @now)
  end

  # THE TRAP: a legitimate long cert makes zero board writes for many minutes
  # (prod: p90 13m, p99 94m). An in-flight gate proves work is running, so a long
  # silent build keeps its desk and wears no chip.
  test "a long-running cert with an open gate is never quiet" do
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 5.hours, metadata: { "status" => "started" })
    gate!(started_at: @now - 5.hours) # opened, never closed: still running

    assert @task.gate_in_flight?(now: @now)
    refute @task.claim_progress_quiet?(now: @now), "a healthy long build must never be flagged"
  end

  # Open gate rows latch forever when a run crashes, so "in flight" is BOUNDED —
  # an ancient open gate is not evidence that anything is running.
  test "an ancient open gate is not evidence of work in flight" do
    gate!(started_at: @now - 3.days)

    refute @task.gate_in_flight?(now: @now)
  end

  # --- Fail safe -------------------------------------------------------------

  test "a task with no durable artifact reads unknown, never quiet" do
    assert_nil @task.last_progress_at
    assert_nil @task.progress_seconds_ago(now: @now)
    refute @task.claim_progress_quiet?(now: @now), "absence of evidence must never read as trouble"
  end

  test "quiet is only ever said about a live claim" do
    @task.update!(metadata: { "devops" => ClaimLease.renewed(session: "sess-1", nonce: "inst-A", now: @now - 3.hours) })
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 5.hours, metadata: { "status" => "started" })

    refute @task.claim_live?(now: @now), "precondition: the lease has lapsed"
    refute @task.claim_progress_quiet?(now: @now)
  end

  # Nothing in this feature may become destructive. Quiet is informational: the
  # lease is untouched, so the claim gate and the reclaim guard behave exactly as
  # they did before — a quiet desk is still a HELD desk.
  test "a quiet task keeps its lease and still reads as held by its live instance" do
    task_event!(kind: TaskEvent::CHECKPOINT, at: @now - 5.hours, metadata: { "status" => "started" })
    before = @task.devops.slice(*ClaimLease::CLAIM_KEYS)

    assert @task.claim_progress_quiet?(now: @now)

    assert_equal before, @task.reload.devops.slice(*ClaimLease::CLAIM_KEYS), "quiet must not touch the lease"
    assert @task.claim_live?(now: @now), "a quiet desk is still occupied"
    assert_equal :held_by_other,
                 ClaimLease.evaluate(@task.devops_claim, session: "other-sess", nonce: "inst-B", now: @now),
                 "another agent still sees the desk as held — quiet never frees it"
  end
end
