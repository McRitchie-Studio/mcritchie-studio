require "test_helper"

# Task#assembled_seconds_from_pickup — Avi's seat time, measured from HIS pickup
# intent rather than the reviewed handover (the transition figure is mostly
# queue-wait). Read once per assembled/shipped board card.
#
# Its own file rather than the bottom of task_test.rb: that file is one of the
# suite's APPEND hotspots and is ratcheted in config/test_health.yml.
class TaskAssembledSpanTest < ActiveSupport::TestCase
  def assembled_task
    task = Task.create!(title: "assembled span subject task", stage: "shipped")
    task.task_events.create!(kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 90.minutes.ago)
    task.task_events.create!(kind: "transition", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 30.minutes.ago)
    task
  end

  test "[unit] measures from the pickup intent to the landed transition" do
    assert_in_delta 3600, assembled_task.assembled_seconds_from_pickup, 2
  end

  test "[unit] costs no query when the caller already preloaded the events" do
    slug = assembled_task.slug
    # Exactly how the board loads it.
    preloaded = Task.where(slug: slug).includes(:task_events, :gate_runs).first
    assert preloaded.task_events.loaded?, "premise: the association must arrive loaded"

    queries = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _id, payload|
      queries += 1 unless payload[:cached] || payload[:name].to_s == "SCHEMA"
    end
    span = preloaded.assembled_seconds_from_pickup
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_in_delta 3600, span, 2
    # This is the whole point of the change. `task_events.transitions.where(...)`
    # issued SQL even here, because `.where` on a loaded association builds a new
    # relation rather than filtering the rows in memory — 2 queries per card,
    # 62 per production /deployments render.
    assert_equal 0, queries, "the reader must filter the preload, not re-query it"
  end

  test "[unit] still answers on a cold task, without a preload" do
    slug = assembled_task.slug

    assert_in_delta 3600, Task.find_by(slug: slug).assembled_seconds_from_pickup, 2
  end

  test "[unit] ignores a pickup recorded after the assemble landed" do
    task = assembled_task
    # A later intent belongs to a different cycle and must not shrink the span.
    task.task_events.create!(kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 5.minutes.ago)

    assert_in_delta 3600, task.reload.assembled_seconds_from_pickup, 2
  end

  test "[unit] is nil when nothing recorded a pickup" do
    task = Task.create!(title: "assembled span no pickup", stage: "shipped")
    task.task_events.create!(kind: "transition", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 30.minutes.ago)

    assert_nil task.assembled_seconds_from_pickup
  end
end
