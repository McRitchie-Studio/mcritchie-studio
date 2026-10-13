# frozen_string_literal: true

# [unit] ShipClock (bin/lib/ship_clock.rb): the phase splitter that sorts every second
# from T0 to production into hands-on, fixed wait and rework; the timeline built from
# board and GitHub records; and the ledger writer. The record fixtures are the shape of
# team-tier-nine-hundred's real records (2026-10-13), trimmed; the failing test's path is
# renamed so the citation ratchet does not read it as a path:line citation.
#
#   ruby -Itest test/lib/ship_clock_test.rb
require "minitest/autorun"
require "tmpdir"
require "csv"
require_relative "../../bin/lib/ship_clock"

class ShipClockTest < Minitest::Test
  def t(clock) = Time.iso8601("2026-10-13T#{clock}Z")

  # --- Phases.split ---------------------------------------------------------

  def test_uncovered_time_is_hands_on
    split = ShipClock::Phases.split(t0: t("14:00:00"), finish: t("14:10:00"), intervals: [])

    assert_equal({ hands_on: 600, wait: 0, rework: 0, total: 600 }, split)
  end

  def test_wait_and_rework_intervals_land_in_their_buckets
    split = ShipClock::Phases.split(
      t0: t("14:00:00"), finish: t("15:00:00"),
      intervals: [{ bucket: :wait, from: t("14:10:00"), to: t("14:20:00") },
                  { bucket: :rework, from: t("14:30:00"), to: t("14:35:00") }]
    )

    assert_equal 600, split[:wait]
    assert_equal 300, split[:rework]
    assert_equal 2700, split[:hands_on]
    assert_equal 3600, split[:hands_on] + split[:wait] + split[:rework]
  end

  def test_rework_wins_an_overlap_with_wait_and_nothing_is_counted_twice
    split = ShipClock::Phases.split(
      t0: t("14:00:00"), finish: t("14:30:00"),
      intervals: [{ bucket: :wait, from: t("14:05:00"), to: t("14:20:00") },
                  { bucket: :rework, from: t("14:15:00"), to: t("14:25:00") }]
    )

    assert_equal 600, split[:wait], "wait keeps only 14:05-14:15; rework owns the overlap"
    assert_equal 600, split[:rework]
    assert_equal 1800, split.values_at(:hands_on, :wait, :rework).sum
  end

  def test_intervals_outside_the_window_are_clipped
    split = ShipClock::Phases.split(
      t0: t("14:00:00"), finish: t("14:10:00"),
      intervals: [{ bucket: :wait, from: t("13:50:00"), to: t("14:05:00") },
                  { bucket: :rework, from: t("14:08:00"), to: t("16:00:00") }]
    )

    assert_equal({ hands_on: 180, wait: 300, rework: 120, total: 600 }, split)
  end

  def test_a_finish_before_t0_refuses
    assert_raises(ShipClock::Error) do
      ShipClock::Phases.split(t0: t("15:00:00"), finish: t("14:00:00"), intervals: [])
    end
  end

  # --- Timeline.build ------------------------------------------------------

  def task
    { "slug" => "team-tier-nine-hundred", "title" => "Team Tier Nine Hundred", "stage" => "shipped",
      "branch" => "feat/team-tier-nine-hundred", "release_slug" => "rel-20261013-e521b1",
      "created_at" => "2026-10-13T14:23:14Z", "started_at" => "2026-10-13T14:23:31Z",
      "submitted_at" => "2026-10-13T14:43:35Z", "reviewed_at" => "2026-10-13T14:44:59Z",
      "assembled_at" => "2026-10-13T15:03:35Z", "completed_at" => "2026-10-13T15:18:35Z", "archived_at" => nil }
  end

  def ci_runs
    [{ "databaseId" => 2, "headSha" => "5bf00c9aaa", "conclusion" => "success",
       "createdAt" => "2026-10-13T14:35:00Z", "startedAt" => "2026-10-13T14:35:00Z", "updatedAt" => "2026-10-13T14:43:18Z" },
     { "databaseId" => 1, "headSha" => "7a86edaaaa", "conclusion" => "failure",
       "createdAt" => "2026-10-13T14:27:00Z", "startedAt" => "2026-10-13T14:27:00Z", "updatedAt" => "2026-10-13T14:34:48Z" }]
  end

  def gate(key, attempt, from, to, success, sops: [], metadata: {})
    { "key" => key, "attempt" => attempt, "started_at" => "2026-10-13T#{from}Z",
      "finished_at" => "2026-10-13T#{to}Z", "success" => success, "sops" => sops, "metadata" => metadata }
  end

  def records(**over)
    {
      task: task, t0: { at: t("14:15:00"), source: "estimated" },
      ci_runs: ci_runs, ci_causes: { 1 => "ci / rails (2): test/views/price_card_sample_test.rb:32" },
      pr: { "createdAt" => "2026-10-13T14:26:53Z", "mergedAt" => "2026-10-13T14:44:55Z" },
      task_gates: [gate("dor", 1, "14:32:43", "14:32:44", false,
                        sops: [{ "sop" => "ci", "result" => "fail" }]),
                   gate("dor", 2, "14:43:34", "14:43:34", true)],
      release_gates: [gate("g3_candidate", 1, "14:50:25", "15:04:12", true),
                      gate("g4_ship", 1, "15:06:04", "15:09:22", false, metadata: { "aborted" => true }),
                      gate("g4_ship", 2, "15:11:41", "15:18:09", true)],
      log_lines: []
    }.merge(over)
  end

  def test_the_seed_run_splits_into_the_known_three_parts
    report = ShipClock::Timeline.build(records)

    assert_equal "2026-10-13T15:18:09Z", report["production_at"], "production = the green g4_ship's finish"
    assert_equal "g4_ship", report["production_source"]
    assert_equal 3789, report["total_s"] # 08:15:00 → 09:18:09 MDT
    # rework: red CI round 14:27:00→14:35:00 (480) + failed ship 15:06:04→15:11:41 (337)
    assert_equal 817, report["rework_s"]
    # wait: green CI 14:35:00→14:43:18 (498) + QA 14:50:25→15:04:12 (827) + ship 15:11:41→15:18:09 (388)
    assert_equal 1713, report["wait_s"]
    assert_equal 3789 - 817 - 1713, report["hands_on_s"]
    assert_equal 1, report["red_ci_rounds"]
    assert_equal 2, report["ci_rounds"]
  end

  def test_rework_rows_carry_their_cause
    rows = ShipClock::Timeline.build(records)["rework"]

    red = rows.find { |r| r["kind"] == "red CI" }
    assert_equal "ci / rails (2): test/views/price_card_sample_test.rb:32", red["cause"]
    assert_equal 480, red["seconds"], "a red round runs to the next round's start: the fix rides inside it"
    assert_equal "ci failed", rows.find { |r| r["kind"] == "failed dor #1" }["cause"]
    assert_match(/aborted/, rows.find { |r| r["kind"] == "failed g4_ship #1" }["cause"])
  end

  def test_a_log_cause_fills_a_failed_ship_that_recorded_none
    lines = ["  partial-ship: abort", "✗ could not mint the DEPLOYER token for the push — the push was NOT attempted",
             "✗ could not mint the DEPLOYER token for the push — the push was NOT attempted"]
    rows = ShipClock::Timeline.build(records(log_lines: lines))["rework"]

    assert_equal "could not mint the DEPLOYER token for the push (from --log)",
                 rows.find { |r| r["kind"] == "failed g4_ship #1" }["cause"]
  end

  def test_refused_prechecks_are_counted_from_the_logs
    lines = ["✗ shape is missing", "ship: the DoR pre-check refused — fix what it printed above"]
    report = ShipClock::Timeline.build(records(log_lines: lines))

    assert_equal 1, report["refused_prechecks"]
    assert_equal "✗ shape is missing", report["rework"].last["cause"]
  end

  def test_milestones_mark_what_falls_after_production
    report = ShipClock::Timeline.build(records)
    shipped = report["milestones"].find { |m| m["label"] == "shipped" }

    refute shipped["counted"], "the shipped stamp (15:18:35) lands after the ship's finish"
    assert(report["milestones"].each_cons(2).all? { |a, b| a["at"] <= b["at"] }, "milestones are in time order")
  end

  def test_without_a_green_ship_the_shipped_stamp_is_production
    report = ShipClock::Timeline.build(records(release_gates: []))

    assert_equal "2026-10-13T15:18:35Z", report["production_at"]
    assert_equal "task completed_at", report["production_source"]
  end

  def test_a_task_not_yet_in_production_refuses
    unshipped = task.merge("stage" => "submitted", "completed_at" => nil)

    assert_raises(ShipClock::Error) { ShipClock::Timeline.build(records(task: unshipped, release_gates: [])) }
  end

  # --- Ledger --------------------------------------------------------------

  def test_the_ledger_row_has_the_header_columns_in_order
    row = ShipClock::Ledger.row(ShipClock::Timeline.build(records), note: "T0 estimated")

    assert_equal ShipClock::Ledger::HEADER.size, row.size
    assert_equal ["2026-10-13", "team-tier-nine-hundred", "2026-10-13T14:15:00Z", "estimated",
                  "2026-10-13T15:18:09Z", "63.2", "21.0", "28.6", "13.6", 1], row.first(10)
    assert_match(/red CI 8m00s ci \/ rails/, row.last)
    assert row.last.end_with?("T0 estimated"), row.last
  end

  def test_the_writer_appends_and_replaces_a_slugs_earlier_row
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ship-clock.csv")
      row = ShipClock::Ledger.row(ShipClock::Timeline.build(records))

      assert_equal :appended, ShipClock::Ledger.write!(path, row)
      assert_equal :appended, ShipClock::Ledger.write!(path, row.dup.tap { |r| r[1] = "other-task" })
      assert_equal :replaced, ShipClock::Ledger.write!(path, row.dup.tap { |r| r[10] = "re-run" })

      rows = CSV.read(path)
      assert_equal ShipClock::Ledger::HEADER, rows.first
      assert_equal %w[team-tier-nine-hundred other-task], rows.drop(1).map { |r| r[1] }
      assert_equal "re-run", rows[1][10]
    end
  end

  def test_the_writer_refuses_a_file_that_is_not_the_ledger
    Dir.mktmpdir do |dir|
      path = File.join(dir, "other.csv")
      File.write(path, "a,b\n1,2\n")

      assert_raises(ShipClock::Error) { ShipClock::Ledger.write!(path, %w[x]) }
      assert_equal "a,b\n1,2\n", File.read(path), "a refused write leaves the file alone"
    end
  end

  # --- formatting ----------------------------------------------------------

  def test_denver_and_duration_render
    assert_equal "08:15:00", ShipClock.denver(t("14:15:00"))
    assert_equal "21m03s", ShipClock.duration(1263)
    assert_equal "1h03m09s", ShipClock.duration(3789)
  end

  def test_repo_from_pr
    assert_equal "McRitchie-Studio/mcritchie-studio",
                 ShipClock.repo_from_pr("https://github.com/McRitchie-Studio/mcritchie-studio/pull/2075")
    assert_nil ShipClock.repo_from_pr(nil)
  end
end
