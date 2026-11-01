# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../../support/books_fixtures"

# [unit] AgentScopes::Lookups, the bounded board reads a scoped run may make:
# Mason's error groups across apps (health reports, stubbed), gate failures,
# review findings and grades; Mack's books status, waiting lines and month
# totals. Each is a fixed query over the test database, answered as text.
class AgentScopes::LookupsTest < ActiveSupport::TestCase
  include BooksFixtures

  L = AgentScopes::Lookups
  FakeApp = Struct.new(:slug, :name)
  NOW = Time.zone.parse("2026-10-31 20:00 MDT")

  def health(slug, name, groups: [], state: :ok, reason: nil)
    DailyAppReport::AppHealth.new(slug: slug, name: name, state: state, reason: reason,
                                  sections: [ { key: "errors", title: "Errors", count: groups.sum { |g| g[:count] } } ],
                                  error_groups: groups)
  end

  def with_health(apps, reports, &block)
    reader = ->(app, _ending, fetcher:, env:) { reports.fetch(app.slug) }
    DailyAppReport.stub(:apps, apps) { DailyAppReport.stub(:health_for, reader, &block) }
  end

  test "error_groups sums each app's groups, most frequent first, and names the apps it could not read" do
    apps = [ FakeApp.new("mcritchie-studio", "McRitchie Studio"), FakeApp.new("turf-monster", "Turf Monster"),
             FakeApp.new("cyvasse", "Cyvasse") ]
    reports = {
      "mcritchie-studio" => health("mcritchie-studio", "McRitchie Studio",
                                   groups: [ { error_class: "Google::Apis::AuthorizationError", message: "Unauthorized", count: 2 } ]),
      "turf-monster" => health("turf-monster", "Turf Monster",
                               groups: [ { error_class: "NoMethodError", message: "undefined method `slug' for nil", count: 9 },
                                         { error_class: "Faraday::TimeoutError", message: "timeout token=abcdef123456", count: 1 } ]),
      "cyvasse" => health("cyvasse", "Cyvasse", state: :unreachable, reason: "timeout")
    }
    text = with_health(apps, reports) { L.run("error_groups", { "days" => 2 }, now: NOW, fetcher: Object.new) }

    assert_match(/\AErrors across 3 apps, the 2 days to /, text)
    lines = text.lines.grep(/\A- /)
    assert_match(/Turf Monster: NoMethodError ×18 "undefined method `slug' for nil"/, lines.first, "summed over both days")
    assert_match(/McRitchie Studio: Google::Apis::AuthorizationError ×4/, lines.second)
    assert_match(/Not read: Cyvasse \(timeout\)\./, text)
    refute_includes text, "abcdef123456", "every answer is redacted on the way out"
  end

  test "error_groups narrows to one app, and refuses an app that has no health report" do
    apps = [ FakeApp.new("turf-monster", "Turf Monster") ]
    reports = { "turf-monster" => health("turf-monster", "Turf Monster") }
    text = with_health(apps, reports) { L.run("error_groups", { "days" => 1, "app" => "turf-monster" }, now: NOW, fetcher: Object.new) }
    assert_match(/Errors across 1 app, the day to .*: Turf Monster 0\./, text)
    assert_raises(L::Unavailable) do
      with_health(apps, reports) { L.run("error_groups", { "days" => 1, "app" => "rolio" }, now: NOW, fetcher: Object.new) }
    end
  end

  test "gate_failures counts attempts and failures per gate, the failing SOPs and the subjects" do
    fail_sops = [ { "sop" => "ci", "result" => "fail", "cause" => "red checks" }, { "sop" => "unit", "result" => "pass" } ]
    GateRun.create!(subject_type: "task", subject_slug: "a-task", key: "dor", attempt: 1, started_at: NOW - 2.hours,
                    finished_at: NOW - 1.hour, success: false, sops: fail_sops)
    GateRun.create!(subject_type: "task", subject_slug: "a-task", key: "dor", attempt: 2, started_at: NOW - 50.minutes,
                    finished_at: NOW - 40.minutes, success: true, sops: [])
    GateRun.create!(subject_type: "task", subject_slug: "b-task", key: "g2a_primary", attempt: 1, started_at: NOW - 3.hours,
                    finished_at: NOW - 2.hours, success: false, sops: fail_sops)
    GateRun.create!(subject_type: "task", subject_slug: "old-task", key: "dor", attempt: 1, started_at: NOW - 30.days,
                    finished_at: NOW - 30.days, success: false, sops: fail_sops)

    text = L.run("gate_failures", { "days" => 7 }, now: NOW)
    assert_includes text, "- DoR (builder): 2 attempts, 1 failed"
    assert_includes text, "- G2a Primary: 1 attempts, 1 failed"
    assert_includes text, "- ci ×2 (red checks)"
    refute_includes text, "old-task", "outside the window"
    assert_equal "No gate finished in the last 1 day.", L.run("gate_failures", { "days" => 1 }, now: NOW - 20.days)
  end

  test "review_findings lists open findings and the blocked tasks" do
    TriageFinding.create!(title: "Reconciler could report unreadable rows", repo: "mcritchie-studio", source: "pr-review")
    TriageFinding.create!(title: "Dismissed one", status: "dismissed")
    Task.create!(title: "Blocked thing", slug: "blocked-thing", stage: "building", blocked_at: 1.hour.ago,
                 block_kind: "rework", metadata: {})

    blocked = Task.where(stage: "building").where.not(blocked_at: nil).count
    text = L.run("review_findings", { "limit" => 20 })
    assert_match(/\AOpen triage findings: #{TriageFinding.where(status: 'open').count}/, text)
    assert_includes text, "Reconciler could report unreadable rows [mcritchie-studio] (pr-review)"
    refute_includes text, "Dismissed one"
    assert_match(/Blocked tasks now: #{blocked}\n- `blocked-thing` Blocked thing \(rework since/, text, "newest first")
  end

  test "grades counts verdicts and tripped thresholds and shows the newest learnings" do
    %w[t-1 t-2 t-3].each { |slug| Task.create!(title: "Graded #{slug}", slug: slug, stage: "shipped", metadata: {}) }
    TaskGrade.where(graded_at: (NOW - 14.days)..NOW).delete_all
    TaskGrade.create!(task_slug: "t-1", verdict: "learning", learning: "Cert bounced twice on fixtures.",
                      graded_at: NOW - 1.day, tripped: [ "bounces", "cycle_time" ])
    TaskGrade.create!(task_slug: "t-2", verdict: "nothing_to_learn", graded_at: NOW - 2.days, tripped: [])
    TaskGrade.create!(task_slug: "t-3", verdict: "learning", learning: "Too old to count.", graded_at: NOW - 40.days,
                      tripped: [ "bounces" ])

    text = L.run("grades", { "days" => 14 }, now: NOW)
    assert_match(/learning 1/, text)
    assert_match(/nothing to learn 1/, text)
    assert_includes text, "Tripped most: bounces ×1, cycle_time ×1."
    assert_includes text, "- `t-1`: Cert bounced twice on fixtures."
    refute_includes text, "Too old to count."
  end

  test "books lookups read the ledger: status, waiting lines and a month's totals by category and kind" do
    book_statement!(account: "savings", from: "2026-01-01", to: "2026-01-31", opening: 0, lines: [
      [ "2026-01-05", 5_000_00, "INCOMING FEDWIRETRANSFER", nil, nil ],
      [ "2026-01-31", 12_00, "INTEREST PAYMENT", "interest_income", nil ],
      [ "2026-01-20", -25_00, "SERVICE FEE", "bank_fees", nil ]
    ])

    status = L.run("books_status", { "entity" => "example" }, books: books_config)
    assert_match(/\AExample Studio LLC \(example\):/, status)
    assert_includes status, "1 statement, through 2026-01-31"
    assert_includes status, "Lines waiting for an answer: 1 (oldest 2026-01-05)"

    waiting = L.run("books_unclassified", { "entity" => "example", "limit" => 25 }, books: books_config)
    assert_match(/1 line waiting for a category:\n- #\d+ 2026-01-05 savings \$5,000\.00 INCOMING FEDWIRETRANSFER/, waiting)

    month = L.run("books_month", { "entity" => "example", "month" => "2026-01" }, books: books_config)
    assert_includes month, "3 lines, not closed."
    assert_match(/By kind: .*income \$12\.00/, month)
    assert_match(/expense -\$25\.00|expense \(\$25\.00\)|expense \$-25\.00/, month)
    assert_includes month, "- unclassified: $5,000.00"
    assert_equal "Example Studio LLC, 2026-02: no ledger lines.",
                 L.run("books_month", { "entity" => "example", "month" => "2026-02" }, books: books_config)
    assert_raises(L::Unavailable) { L.run("books_status", { "entity" => "nope" }, books: books_config) }
  end

  test "an unknown name is refused" do
    assert_raises(AgentMailbox::Scopes::Refused) { L.run("raw_sql", {}) }
  end
end
