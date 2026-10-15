# frozen_string_literal: true

require "test_helper"

# [unit] DreamHeat: the fire count per dream and its newest decisions, read from the
# `dream_fired` actions bin/dream fired writes.
class DreamHeatTest < ActiveSupport::TestCase
  def fire(slug, summary, at, kind: DreamHeat::KIND)
    AgentAction.create!(session_id: "heat-probe", kind: kind, event_slug: slug, summary: summary, occurred_at: at,
                        outcome: "ok")
  end

  test "[unit] counts every fire and keeps the newest three decisions, newest first" do
    4.times { |n| fire("hot-dream", "decision #{n}", n.days.ago) }
    fire("warm-dream", "only one", 1.hour.ago)
    fire("hot-dream", "not a fire", 1.minute.ago, kind: "bash")

    heat = DreamHeat.build

    assert_equal 4, heat.count("hot-dream")
    assert_equal 1, heat.count("warm-dream")
    assert_equal 0, heat.count("cold-dream")
    assert_equal 5, heat.total
    assert_equal [ "decision 0", "decision 1", "decision 2" ], heat.decisions("hot-dream").map(&:summary)
    assert_equal [], heat.decisions("cold-dream")
  end

  test "[unit] the read is two statements however many dreams have fired" do
    3.times { |n| fire("dream-#{n}", "d", 1.hour.ago) }
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/) || payload[:sql].start_with?("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { DreamHeat.build }

    assert_equal 2, count
  end
end
