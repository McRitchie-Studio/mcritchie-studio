require "test_helper"

class Github::CommitSearchPlanTest < ActiveSupport::TestCase
  test "builds deterministic query specs for login and email aliases by calendar year" do
    plan = Github::CommitSearchPlan.new(
      login: "amcritchie",
      emails: ["alex@planomatic.com"],
      start_date: "2024-01-20",
      end_date: "2025-02-10",
      roles: [:author]
    )

    specs = plan.query_specs

    assert_equal 4, specs.size
    assert_equal(
      [
        "author:amcritchie author-date:2024-01-20..2024-12-31 merge:false is:public",
        "author:amcritchie author-date:2025-01-01..2025-02-10 merge:false is:public",
        "author-email:alex@planomatic.com author-date:2024-01-20..2024-12-31 merge:false is:public",
        "author-email:alex@planomatic.com author-date:2025-01-01..2025-02-10 merge:false is:public"
      ],
      specs.map(&:q)
    )
  end

  test "includes committer variants for login and email aliases" do
    plan = Github::CommitSearchPlan.new(
      login: "amcritchie",
      emails: ["alex@planomatic.com"],
      start_date: "2024-01-20",
      end_date: "2024-04-19",
      roles: [:committer]
    )

    assert_equal(
      [
        "committer:amcritchie committer-date:2024-01-20..2024-04-19 merge:false is:public",
        "committer-email:alex@planomatic.com committer-date:2024-01-20..2024-04-19 merge:false is:public"
      ],
      plan.query_specs.map(&:q)
    )
  end

  test "splits year windows to quarters then months then seven day windows" do
    plan = Github::CommitSearchPlan.new(
      login: "amcritchie",
      start_date: "2024-01-20",
      end_date: "2024-04-19"
    )

    year_window = plan.initial_windows.first
    quarter_windows = plan.next_windows(year_window)
    month_windows = plan.next_windows(quarter_windows.first)
    week_windows = plan.next_windows(month_windows.first)

    assert_equal [
      Date.new(2024, 1, 20)..Date.new(2024, 3, 31),
      Date.new(2024, 4, 1)..Date.new(2024, 4, 19)
    ], quarter_windows.map(&:to_range)
    assert_equal [
      Date.new(2024, 1, 20)..Date.new(2024, 1, 31),
      Date.new(2024, 2, 1)..Date.new(2024, 2, 29),
      Date.new(2024, 3, 1)..Date.new(2024, 3, 31)
    ], month_windows.map(&:to_range)
    assert_equal [
      Date.new(2024, 1, 20)..Date.new(2024, 1, 26),
      Date.new(2024, 1, 27)..Date.new(2024, 1, 31)
    ], week_windows.map(&:to_range)
  end

  test "uses fixed search result threshold for operator decisions" do
    plan = Github::CommitSearchPlan.new(
      login: "amcritchie",
      start_date: "2024-01-01",
      end_date: "2024-12-31"
    )

    assert plan.safe_to_fetch?(900)
    refute plan.safe_to_fetch?(901)
  end

  test "query specs expose fixed probe and fetch params" do
    plan = Github::CommitSearchPlan.new(
      login: "amcritchie",
      start_date: "2024-01-01",
      end_date: "2024-12-31",
      roles: [:author]
    )

    spec = plan.query_specs.first

    assert_equal 1, spec.probe_params.fetch(:per_page)
    assert_equal 100, spec.fetch_params.fetch(:per_page)
    assert_equal spec.q, spec.probe_params.fetch(:q)
    assert_equal spec.q, spec.fetch_params.fetch(:q)
  end
end
