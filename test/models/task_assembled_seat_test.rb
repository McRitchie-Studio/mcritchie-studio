# frozen_string_literal: true

require "test_helper"

# Avi's crew seat — the ASSEMBLED lane's displayed duration.
#
# Its own file rather than an append to task_test.rb: that file is a declared
# APPEND HOTSPOT (config/test_health.yml), and the ratchet's advice is to name a
# new file for its concern instead of growing one everybody collides in.
class TaskAssembledSeatTest < ActiveSupport::TestCase
  # --- Avi's seat: measured from PICKUP, not from the reviewed handover ---
  #
  # THE DEFECT THIS REPLACES, measured on rel-20260818-63bdb8: all four members
  # assembled at the same second, yet the board reported 148m, 134m, 120m and
  # 49m. Those differ ONLY by when each task entered the lane — Avi ran one
  # batch sweep across all four — so the card read as if he spent 148 minutes on
  # one task and 49 on another. The number was queue-wait wearing a work label.

  def assembled_pair(reviewed_at:, pickup_at:, assembled_at:, record_pickup: true)
    task = Task.create!(title: "Avi Seat #{SecureRandom.hex(4)}", stage: "assembled")
    # update_columns, not create: the model stamps its own stage timestamps on
    # save, so passing them to create! is silently overwritten with Time.current.
    task.update_columns(reviewed_at: reviewed_at, assembled_at: assembled_at)
    # The TRANSITION event carries the same moment. Production writes both, and
    # the reader prefers the event so the card and the model cannot disagree —
    # a fixture that sets only the column models a state that never occurs.
    task.task_events.transitions.where(to_stage: "assembled")
        .update_all(occurred_at: assembled_at)
    if record_pickup
      task.task_events.create!(kind: TaskEvent::INTENT, from_stage: "reviewed",
                               to_stage: "assembled", occurred_at: pickup_at, actor: "avi")
    end
    task
  end

  test "[unit] the assembled seat measures from Avi's pickup, not from reviewed" do
    reviewed  = 3.hours.ago
    pickup    = 30.minutes.ago
    assembled = 10.minutes.ago

    task = assembled_pair(reviewed_at: reviewed, pickup_at: pickup, assembled_at: assembled)

    assert_in_delta 20 * 60, task.assembled_seconds_from_pickup, 1,
                    "must measure pickup -> assembled (20m), not reviewed -> assembled (2h50m)"
    refute_in_delta (assembled - reviewed), task.assembled_seconds_from_pickup, 60,
                    "must NOT be the reviewed-to-assembled figure — that is the queue-wait this replaces"
  end

  test "[unit] every member of one sweep reports the SAME assembled seat" do
    # One sweep: one pickup instant, one assemble instant, members that entered
    # the lane hours apart. Equal durations are the POINT — a batch operation
    # took the same time for every member.
    pickup    = 40.minutes.ago
    assembled = 10.minutes.ago
    members = [4.hours.ago, 2.hours.ago, 20.minutes.ago].map do |reviewed|
      assembled_pair(reviewed_at: reviewed, pickup_at: pickup, assembled_at: assembled)
    end

    seats = members.map(&:assembled_seconds_from_pickup)
    assert_equal 1, seats.uniq.size,
                 "one sweep must report one duration; got #{seats.inspect} — that spread is queue-wait"
    assert_in_delta 30 * 60, seats.first, 1
  end

  test "[unit] no pickup row falls back rather than rendering blank" do
    task = assembled_pair(reviewed_at: 2.hours.ago, pickup_at: nil,
                          assembled_at: 10.minutes.ago, record_pickup: false)

    assert_nil task.assembled_seconds_from_pickup,
               "with no intent row it must return nil so the caller can fall back to the transition figure"
  end

  test "[unit] a pickup recorded after the assemble is never used" do
    # Defensive: a clock skew or a re-recorded intent must not produce a
    # negative seat. The window is bounded at assembled_at.
    task = assembled_pair(reviewed_at: 3.hours.ago, pickup_at: 1.minute.from_now,
                          assembled_at: 10.minutes.ago)

    assert_nil task.assembled_seconds_from_pickup
  end
end
