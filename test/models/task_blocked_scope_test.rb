# frozen_string_literal: true

require "test_helper"

# `blocked` is NOT a stage — it is an ATTRIBUTE of a `building` task (blocked_at
# set). Task.blocked encodes that; Task.by_stage did not, so every caller that
# asked the board for stage=blocked got an empty list rather than an error. That
# is the query an OPERATOR runs to ask "what is blocked?", so the failure landed
# on the person least able to work around it.
#
# These assert the two scopes AGREE. by_stage("blocked") must resolve through the
# blocked scope, and must keep resolving every real stage by column equality.
class TaskBlockedScopeTest < ActiveSupport::TestCase
  def building(title)
    Task.create!(title: title, stage: "building")
  end

  test "by_stage blocked returns a live-blocked task" do
    task = building("Live Blocked Listing Task")
    task.block!(by: "avi", kind: "rework")

    assert_includes Task.by_stage("blocked"), task,
                    "the listing must return what the model calls blocked"
  end

  test "by_stage blocked agrees with the blocked scope" do
    task = building("Agreement Blocked Listing Task")
    task.block!(by: "avi", kind: "rework")

    assert_equal Task.blocked.order(:id).to_a,
                 Task.by_stage("blocked").order(:id).to_a,
                 "by_stage(blocked) and Task.blocked must describe the same set"
  end

  test "by_stage blocked EXCLUDES a building task carrying no block" do
    task = building("Unblocked Building Listing Task")

    refute_includes Task.by_stage("blocked"), task,
                    "a plain building task is not blocked"
  end

  test "by_stage blocked EXCLUDES a task whose block was resolved" do
    task = building("Resolved Block Listing Task")
    task.block!(by: "avi", kind: "rework")
    task.unblock!

    refute_includes Task.by_stage("blocked"), task,
                    "unblock! clears blocked_at, so the task leaves the set"
  end

  # The guard against fixing `blocked` by breaking every other stage: a real
  # stage must still resolve by column equality, and must NOT pick up a blocked
  # task merely because that task's stage column reads `building`.
  test "by_stage building still resolves by the stage column" do
    plain = building("Plain Building Stage Task")
    blocked = building("Blocked But Still Building Task")
    blocked.block!(by: "avi", kind: "rework")

    result = Task.by_stage("building")
    assert_includes result, plain
    assert_includes result, blocked, "a blocked task's stage column still reads building"
  end

  test "by_stage designed is unaffected" do
    task = Task.create!(title: "Designed Listing Scope Task", stage: "designed")

    assert_includes Task.by_stage("designed"), task
    refute_includes Task.by_stage("blocked"), task
  end
end
