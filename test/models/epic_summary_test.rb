require "test_helper"

# [unit] EpicSummary — the read model behind /epics and the /epics/<slug> header.
# One grouped query over tasks.epic_slug, folded into counts by stage, a done count
# (shipped, or archived after shipping), time bounds, and newest-activity-first order.
class EpicSummaryTest < ActiveSupport::TestCase
  def make(title, stage:, epic:, created: 3.days.ago, updated: created, completed: nil)
    task = Task.create!(title: title, stage: stage, epic_slug: epic)
    # rubocop:disable Rails/SkipsModelValidations -- pin the clocks the summary reads
    task.update_columns(created_at: created, updated_at: updated, completed_at: completed)
    # rubocop:enable Rails/SkipsModelValidations
    task
  end

  test "[unit] counts an epic's tasks by stage and ignores tasks with no epic" do
    make("Epic sum designed", stage: "designed", epic: "sum-epic")
    make("Epic sum building one", stage: "building", epic: "sum-epic")
    make("Epic sum building two", stage: "building", epic: "sum-epic")
    Task.create!(title: "Epic sum loose task", stage: "building")

    epic = EpicSummary.find("sum-epic")

    assert_equal({ "designed" => 1, "building" => 2 }, epic.counts_by_stage)
    assert_equal 3, epic.total
    assert_equal [["designed", 1], ["building", 2]], epic.stage_counts, "board order, empty stages dropped"
    assert_not(EpicSummary.all.any? { |summary| summary.slug.nil? }, "a task with no epic is no epic")
  end

  test "[unit] done counts shipped tasks and archived-after-ship ones, never a dropped task" do
    make("Epic done shipped", stage: "shipped", epic: "done-epic", completed: 1.day.ago)
    make("Epic done archived shipped", stage: "archived", epic: "done-epic", completed: 2.days.ago)
    make("Epic done archived dropped", stage: "archived", epic: "done-epic")
    make("Epic done building", stage: "building", epic: "done-epic")

    epic = EpicSummary.find("done-epic")

    assert_equal 2, epic.done_count
    assert_equal 4, epic.total
    assert_equal 50, epic.progress_percent
    assert_not epic.complete?
  end

  test "[unit] progress rounds down so only a finished epic reads 100" do
    2.times { |i| make("Epic round shipped #{i}", stage: "shipped", epic: "round-epic", completed: 1.day.ago) }
    make("Epic round building", stage: "building", epic: "round-epic")
    assert_equal 66, EpicSummary.find("round-epic").progress_percent

    make("Epic whole shipped", stage: "shipped", epic: "whole-epic", completed: 1.day.ago)
    whole = EpicSummary.find("whole-epic")
    assert_equal 100, whole.progress_percent
    assert whole.complete?
  end

  test "[unit] elapsed runs from the first task created to the last task shipped" do
    start = Time.zone.local(2026, 9, 1, 9, 0)
    make("Epic span first", stage: "shipped", epic: "span-epic", created: start, completed: start + 2.days)
    make("Epic span last", stage: "shipped", epic: "span-epic", created: start + 1.day, completed: start + 5.days)
    make("Epic span open", stage: "building", epic: "span-epic", created: start + 3.days)

    epic = EpicSummary.find("span-epic")

    assert_equal start, epic.first_created_at
    assert_equal start + 5.days, epic.last_shipped_at
    assert_equal 5.days.to_i, epic.elapsed_seconds.to_i
  end

  test "[unit] elapsed is nil until something ships" do
    make("Epic unshipped fresh task", stage: "building", epic: "fresh-epic")
    assert_nil EpicSummary.find("fresh-epic").elapsed_seconds
  end

  test "[unit] all lists epics newest activity first" do
    make("Epic old stale task", stage: "building", epic: "old-epic", created: 10.days.ago, updated: 9.days.ago)
    make("Epic new fresh task", stage: "building", epic: "new-epic", created: 5.days.ago, updated: 1.hour.ago)

    slugs = EpicSummary.all.map(&:slug)
    assert_operator slugs.index("new-epic"), :<, slugs.index("old-epic")
  end

  test "[unit] find normalizes the handle and returns nil for an unknown or unparseable one" do
    make("Epic case check task", stage: "building", epic: "case-epic")

    assert_equal "case-epic", EpicSummary.find(" Case-Epic ").slug
    assert_nil EpicSummary.find("no-such-epic")
    assert_nil EpicSummary.find("")
  end

  test "[unit] the index is one query however many epics exist" do
    3.times { |i| make("Epic query #{i}", stage: "building", epic: "query-epic-#{i}") }

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { EpicSummary.all }
    assert_equal 1, queries
  end
end
