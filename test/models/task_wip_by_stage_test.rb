# frozen_string_literal: true

require "test_helper"

# Task.wip_by_stage — the WIP count split by stage, for the /deployments DevOps sidebar.
# Its own file rather than another test at the bottom of test/models/task_test.rb, a
# frozen append hotspot (config/test_health.yml): this concern is new, so it gets a
# home named for it.
class TaskWipByStageTest < ActiveSupport::TestCase
  # The DevOps sidebar's split of the same number. Every live stage is PRESENT, a
  # zero included, in board order — the sidebar draws one tile per stage and must not
  # have to guess which stages exist — and the split sums to wip_count exactly.
  test "[unit] wip_by_stage splits WIP by stage, in board order, zeros included" do
    Task.delete_all
    2.times { |i| Task.create!(title: "wip split designed #{i}", stage: "designed") }
    Task.create!(title: "wip split building task", stage: "building")
    Task.create!(title: "wip split reviewed task", stage: "reviewed")
    Task.create!(title: "wip split shipped task", stage: "shipped")
    Task.create!(title: "wip split archived task", stage: "archived")

    split = Task.wip_by_stage

    assert_equal %w[designed building submitted reviewed assembled], split.keys
    assert_equal({ "designed" => 2, "building" => 1, "submitted" => 0, "reviewed" => 1, "assembled" => 0 }, split)
    assert_equal Task.wip_count, split.values.sum
  end

  # A blocked task is a building task wearing a block marker, not a stage of its own —
  # so it counts under Building, exactly as it does in wip_count.
  test "[unit] wip_by_stage counts a blocked task under building" do
    Task.delete_all
    Task.create!(title: "wip split blocked task", stage: "building",
                 blocked_at: Time.current, blocked_from: "submitted",
                 blocked_by: "avi", block_kind: "rework")

    assert_equal 1, Task.wip_by_stage["building"]
    assert_equal Task.wip_count, Task.wip_by_stage.values.sum
  end
end
