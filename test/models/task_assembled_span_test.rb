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

  def count_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _id, payload|
      count += 1 unless payload[:cached] || payload[:name].to_s == "SCHEMA"
    end
    result = yield
    [result, count]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  test "[unit] costs no query when the caller passes its preloaded events" do
    slug = assembled_task.slug
    # Exactly how the board loads it.
    preloaded = Task.where(slug: slug).includes(:task_events, :gate_runs).first
    assert preloaded.task_events.loaded?, "premise: the association must arrive loaded"

    span, queries = count_queries do
      preloaded.assembled_seconds_from_pickup(events: preloaded.task_events.to_a)
    end

    assert_in_delta 3600, span, 2
    # The whole point of the parameter. `task_events.transitions.where(...)` issued
    # SQL even on a loaded association, because `.where` builds a new relation
    # rather than filtering the rows in memory — 2 queries per assembled/shipped
    # card, 62 per production /deployments render.
    assert_equal 0, queries, "the passed-in events must be filtered, not re-queried"
  end

  # THE SAFETY PROPERTY, and the reason `events:` is a parameter instead of a
  # `task_events.loaded?` sniff. A loaded association can be STALE — the model
  # stamps its own transition event on save, so rows rewritten afterwards by
  # update_all or another instance leave the OLD occurred_at in memory, and reading
  # it returns a wrong DURATION rather than failing. Sniffing would have opted every
  # such caller in silently; CI caught exactly that against TaskAssembledSeatTest.
  test "[unit] a caller that passes nothing reads the database, even when loaded" do
    task = assembled_task
    task.task_events.load
    assert task.task_events.loaded?, "premise: the association is loaded and now stale-able"

    # Rewrite the landing behind the in-memory rows, the way a fixture or a sibling
    # instance would.
    task.task_events.transitions.where(to_stage: "assembled")
        .update_all(occurred_at: 10.minutes.ago)

    _span, queries = count_queries { task.assembled_seconds_from_pickup }
    assert_operator queries, :>, 0, "the default path must go to the database, not the stale preload"

    # 90 minutes ago pickup → 10 minutes ago landing.
    assert_in_delta 80 * 60, task.assembled_seconds_from_pickup, 2
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
