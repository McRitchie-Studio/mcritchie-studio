# frozen_string_literal: true

# [unit] Devops::Windows — the derived operator windows (design section 6):
# window math, the lapse rule, the mm:ss clock, the config defaults and their
# refusals, and which block counts as an escalation. Rails-free, like the module.
#
#   ruby -Itest test/lib/devops_windows_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tempfile"
require_relative "../../app/models/devops/windows"

class DevopsWindowsTest < Minitest::Test
  NOW = Time.utc(2026, 9, 24, 20, 0, 0)

  def setup
    Devops::Windows.reload!
  end

  def teardown
    Devops::Windows.reload!
  end

  def with_config(yaml)
    file = Tempfile.new(["release_builder", ".yml"])
    file.write(yaml)
    file.flush
    yield Devops::Windows.config(file.path)
  ensure
    file&.close!
  end

  # --- the checked-in config -------------------------------------------------

  def test_the_checked_in_config_carries_the_three_windows_and_the_timed_default
    assert_equal 10, Devops::Windows.minutes("approval")
    assert_equal 20, Devops::Windows.minutes("escalation")
    assert_equal 30, Devops::Windows.minutes("production")
    assert_equal "timed", Devops::Windows.production_ship_mode
  end

  def test_missing_keys_fall_back_to_the_design_numbers
    with_config("auto_qa: {}\n") do |config|
      assert_equal 10, Devops::Windows.minutes("approval", config)
      assert_equal 30, Devops::Windows.minutes("production", config)
      assert_equal "timed", Devops::Windows.production_ship_mode(config)
    end
  end

  def test_a_changed_length_moves_the_window
    with_config("operator_windows:\n  approval_minutes: 3\n") do |config|
      window = Devops::Windows.approval(requested_at: NOW, waiting: true, config: config)
      assert_equal NOW + 180, window.ends_at
      assert_equal 3, window.minutes
    end
  end

  def test_a_non_positive_or_unreadable_length_is_refused_not_substituted
    with_config("operator_windows:\n  escalation_minutes: 0\n") do |config|
      assert_raises(ArgumentError) { Devops::Windows.minutes("escalation", config) }
    end
    with_config("operator_windows:\n  escalation_minutes: soon\n") do |config|
      assert_raises(ArgumentError) { Devops::Windows.minutes("escalation", config) }
    end
  end

  def test_an_unknown_ship_mode_in_config_is_refused
    with_config("production_ship:\n  mode: sometimes\n") do |config|
      error = assert_raises(ArgumentError) { Devops::Windows.production_ship_mode(config) }
      assert_match(/production_ship\.mode must be one of ask\|timed\|auto/, error.message)
    end
  end

  def test_validate_mode_normalises_case_and_refuses_the_rest
    assert_equal "auto", Devops::Windows.validate_mode!("AUTO")
    assert_raises(ArgumentError) { Devops::Windows.validate_mode!("yes") }
    assert_raises(ArgumentError) { Devops::Windows.validate_mode!("") }
  end

  def test_an_unknown_kind_is_refused
    assert_raises(ArgumentError) { Devops::Windows.minutes("lunch") }
  end

  # --- window math -----------------------------------------------------------

  def test_approval_window_is_requested_at_plus_the_length
    window = Devops::Windows.approval(requested_at: NOW.iso8601, waiting: true)
    assert_equal "approval", window.kind
    assert_equal NOW, window.opened_at
    assert_equal NOW + 600, window.ends_at
  end

  def test_no_approval_window_unless_waiting_or_without_a_timestamp
    assert_nil Devops::Windows.approval(requested_at: NOW, waiting: false)
    assert_nil Devops::Windows.approval(requested_at: nil, waiting: true)
    assert_nil Devops::Windows.approval(requested_at: "not a time", waiting: true)
  end

  def test_remaining_counts_down_and_floors_at_zero
    window = Devops::Windows.approval(requested_at: NOW, waiting: true)
    assert_equal 600, window.remaining_seconds(NOW)
    assert_equal 1, window.remaining_seconds(NOW + 599)
    assert_equal 0, window.remaining_seconds(NOW + 600)
    assert_equal 0, window.remaining_seconds(NOW + 9_999)
  end

  def test_lapsed_flips_exactly_at_the_end
    window = Devops::Windows.approval(requested_at: NOW, waiting: true)
    refute window.lapsed?(NOW + 599)
    assert window.lapsed?(NOW + 600)
  end

  def test_the_clock_reads_mm_ss_then_the_kinds_lapsed_label
    window = Devops::Windows.approval(requested_at: NOW, waiting: true)
    assert_equal "10:00", window.label(NOW)
    assert_equal "09:59", window.label(NOW + 1)
    assert_equal "00:07", window.label(NOW + 593)
    assert_equal "unanswered, proceeding", window.label(NOW + 600)

    escalation = Devops::Windows.escalation(blocked_at: NOW, block_kind: "dependency", summary: "Escalated: chip colour")
    assert_equal "20:00", escalation.label(NOW)
    assert_equal "lapsed, recommendation stands", escalation.label(NOW + 1200)

    production = Devops::Windows.production(requested_at: NOW)
    assert_equal "30:00", production.label(NOW)
    assert_equal "lapsed, shipping on green", production.label(NOW + 1800)
  end

  def test_to_h_carries_iso_times_and_the_derived_facts
    window = Devops::Windows.production(requested_at: NOW)
    hash = window.to_h(NOW + 60)
    assert_equal "production", hash["kind"]
    assert_equal "2026-09-24T20:00:00Z", hash["opened_at"]
    assert_equal "2026-09-24T20:30:00Z", hash["ends_at"]
    assert_equal 30, hash["minutes"]
    assert_equal 1740, hash["remaining_seconds"]
    assert_equal false, hash["lapsed"]
    assert_equal "29:00", hash["label"]
  end

  # --- escalation detection --------------------------------------------------

  def test_only_a_dependency_block_with_the_escalated_prefix_is_an_escalation
    assert Devops::Windows.escalation?(block_kind: "dependency", summary: "Escalated: spacing rule")
    assert Devops::Windows.escalation?(block_kind: "dependency", summary: "  Escalated: leading space")
    refute Devops::Windows.escalation?(block_kind: "rework", summary: "Escalated: spacing rule")
    refute Devops::Windows.escalation?(block_kind: "dependency", summary: "Waiting on studio-engine 0.77")
    refute Devops::Windows.escalation?(block_kind: "dependency", summary: nil)
    assert_nil Devops::Windows.escalation(blocked_at: NOW, block_kind: "rework", summary: "Escalated: x")
  end

  # --- for_task ----------------------------------------------------------------

  def task_hash(devops: {}, blocked_at: nil, block_kind: nil, stage: "building")
    { "stage" => stage, "blocked_at" => blocked_at, "block_kind" => block_kind,
      "metadata" => { "devops" => devops } }
  end

  def test_for_task_reads_an_api_shaped_hash_and_ranks_escalation_first
    task = task_hash(devops: { "approval_status" => "waiting", "approval_requested_at" => NOW.iso8601 },
                     blocked_at: (NOW - 60).iso8601, block_kind: "dependency")
    windows = Devops::Windows.for_task(task, unresolved: { "summary" => "Escalated: which default" })
    assert_equal %w[escalation approval], windows.map(&:kind)
    assert_equal NOW - 60 + 1200, windows.first.ends_at
  end

  def test_for_task_ignores_a_block_that_is_not_live
    task = task_hash(devops: {}, blocked_at: NOW.iso8601, block_kind: "dependency", stage: "submitted")
    assert_empty Devops::Windows.for_task(task, unresolved: { "summary" => "Escalated: stale" })
  end

  def test_for_task_is_empty_with_nothing_open
    assert_empty Devops::Windows.for_task(task_hash(devops: { "approval_status" => "approved" }))
  end
end
