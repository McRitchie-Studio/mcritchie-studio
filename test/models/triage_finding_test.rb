require "test_helper"

class TriageFindingTest < ActiveSupport::TestCase
  test "[unit] generates a finding slug on create" do
    finding = TriageFinding.create!(title: "Reconciler could report unreadable rows")
    assert_match(/\Afinding-[0-9a-f]{12}\z/, finding.slug)
    assert_equal "open", finding.status
  end

  test "[unit] rejects an unknown status" do
    finding = TriageFinding.new(title: "A finding", status: "someday")
    refute finding.valid?
    assert finding.errors[:status].any?
  end

  test "[unit] requires a title" do
    refute TriageFinding.new.valid?
  end

  test "[unit] promote! stamps linkage and leaves the inbox" do
    finding = TriageFinding.create!(title: "Cap drilldown actions")
    task = Task.create!(title: "Cap Drilldown Actions", stage: "designed")
    finding.promote!(task)

    assert_equal "promoted", finding.reload.status
    assert_equal task.slug, finding.promoted_task_slug
    assert_not_nil finding.resolved_at
    refute_includes TriageFinding.open_findings, finding
  end

  test "[unit] dismiss! retires the finding without a task" do
    finding = TriageFinding.create!(title: "Stale credential note")
    finding.dismiss!

    assert_equal "dismissed", finding.reload.status
    assert_nil finding.promoted_task_slug
    assert_not_nil finding.resolved_at
  end
end
