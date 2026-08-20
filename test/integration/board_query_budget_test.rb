require "test_helper"

# Does the board's query count STAY FLAT as cards are added?
#
# That is the question, not "is it under N". A fixed threshold passes the day
# someone reintroduces a per-card query on a small fixture board and only fails
# later in production, which is exactly how this bug survived: the boards preload
# :task_events, and then `task_events.transitions.where(to_stage: …)` re-queried
# per card anyway, because `.where` on a loaded association builds a new relation
# instead of filtering the rows already in memory. Measured on production
# 2026-08-19: 62 of the 149 uncached queries a /deployments render made were that
# one call, 2 per assembled or shipped card.
#
# So these tests render the SAME page twice with different card counts and assert
# the difference. A per-card query makes the second render cost more; nothing else
# here does.
class BoardQueryBudgetTest < ActionDispatch::IntegrationTest
  # Count a render's queries from a COLD query cache, the way production starts
  # every request. Without the clear this measures nothing: an integration test
  # holds one connection for the whole test, so the ActiveRecord query cache
  # survives between `get`s and a second identical render reports ZERO queries.
  # The first version of this test compared a fully-cached render against a
  # cold one and "found" 20 phantom queries.
  #
  # Clearing between renders is enough, and leaving the cache live WITHIN a render
  # is correct: a genuine per-card query carries a different task_slug per card, so
  # distinct binds mean distinct cache keys and every one still executes.
  def render_query_count(path)
    ActiveRecord::Base.connection.clear_query_cache
    count = count_uncached_queries { get path }
    assert_response :success
    count
  end

  def count_uncached_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _id, payload|
      next if payload[:cached]
      next if payload[:name].to_s == "SCHEMA"
      next if payload[:sql].to_s.start_with?("BEGIN", "COMMIT", "ROLLBACK", "RELEASE", "SAVEPOINT")

      count += 1
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # THE FIXTURE IS THE TEST. A differential design proves nothing if the cards it
  # creates cannot reach the code under test, and the first version of this file
  # made exactly that mistake: it used only SHIPPED cards on /deployments and
  # event-less BUILDING cards on /tasks. NEXT_INTENT_STAGE["shipped"] is nil, so
  # Task#open_intents_for returns [] before it queries, and a card with no events
  # reaches nothing at all. Both boards therefore read as proof of a board-wide
  # property neither had tested, while submitted cards still cost 2 queries each.
  #
  # So every stage that reaches a per-card reader gets a card here.

  # A SUBMITTED card: an open →reviewed intent, which is what open_intents_for and
  # current_stage_entry_event read.
  def create_submitted_task(index)
    task = Task.create!(title: "query budget submitted #{index}", stage: "submitted")
    task.task_events.create!(kind: "transition", from_stage: "building", to_stage: "submitted",
                             actor: "pikachu", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "intent", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 1.hour.ago)
    task
  end

  # A REVIEWED card: an open →assembled intent, the same readers one stage on.
  def create_reviewed_task(index)
    task = Task.create!(title: "query budget reviewed #{index}", stage: "reviewed")
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "reviewed",
                             actor: "carl", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 1.hour.ago)
    task
  end

  # A card in a stage whose crew cluster asks for the assembled span — the reader
  # that carried the N+1.
  def create_shipped_task(index)
    task = Task.create!(title: "query budget shipped #{index}", stage: "shipped")
    task.task_events.create!(kind: "intent", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 3.hours.ago)
    task.task_events.create!(kind: "transition", from_stage: "reviewed", to_stage: "assembled",
                             actor: "avi", occurred_at: 2.hours.ago)
    task.task_events.create!(kind: "transition", from_stage: "assembled", to_stage: "shipped",
                             actor: "steffon", occurred_at: 1.hour.ago)
    task
  end

  test "[integration] the deployments board's query count does not grow with cards" do
    Task.delete_all
    3.times { |i| create_shipped_task(i) }
    3.times { |i| create_submitted_task(i) }
    3.times { |i| create_reviewed_task(i) }

    few = render_query_count(deployments_path)

    5.times do |i|
      create_shipped_task(100 + i)
      create_submitted_task(100 + i)
      create_reviewed_task(100 + i)
    end
    many = render_query_count(deployments_path)

    assert_equal few, many,
                 "5 more cards cost #{many - few} more queries — something on the card path " \
                 "is querying per card instead of reading the board's preload"
  end

  test "[integration] the tasks board's query count does not grow with cards" do
    Task.delete_all
    3.times { |i| Task.create!(title: "query budget building #{i}", stage: "building") }
    3.times { |i| create_submitted_task(i) }

    few = render_query_count(tasks_path)

    5.times do |i|
      Task.create!(title: "query budget building #{100 + i}", stage: "building")
      create_submitted_task(100 + i)
    end
    many = render_query_count(tasks_path)

    assert_equal few, many,
                 "5 more cards cost #{many - few} more queries on /tasks"
  end
end
