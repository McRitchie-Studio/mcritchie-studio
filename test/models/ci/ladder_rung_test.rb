# frozen_string_literal: true

require "test_helper"

module Ci
  # The rung state machine, and above all the two states that exist to stop a
  # stale or absent verdict rendering as green.
  class LadderRungTest < ActiveSupport::TestCase
    # --- resolve_state: the safety core -------------------------------------

    test "no ingested verdict reads not_built, never green" do
      assert_equal :not_built,
                   Ci::LadderRung.resolve_state(raw: :none, run_at: nil, newest_parked_at: nil)
    end

    test "a green verdict older than parked work reads stale" do
      ran = 3.hours.ago
      merged_after = 1.hour.ago

      assert_equal :stale,
                   Ci::LadderRung.resolve_state(raw: :green, run_at: ran, newest_parked_at: merged_after)
    end

    test "a green verdict newer than parked work stays green" do
      ran = 1.hour.ago
      merged_before = 3.hours.ago

      assert_equal :green,
                   Ci::LadderRung.resolve_state(raw: :green, run_at: ran, newest_parked_at: merged_before)
    end

    test "green with no parked work is never stale" do
      assert_equal :green,
                   Ci::LadderRung.resolve_state(raw: :green, run_at: 5.days.ago, newest_parked_at: nil)
    end

    # A red rung that is ALSO out of date is still red. Demoting it to :stale
    # would file a failure under a bookkeeping label and hide it.
    test "a red verdict stays red even when it predates parked work" do
      assert_equal :red,
                   Ci::LadderRung.resolve_state(raw: :red, run_at: 3.hours.ago, newest_parked_at: 1.hour.ago)
    end

    test "pending and conflicted pass through untouched" do
      %i[pending conflicted].each do |raw|
        assert_equal raw,
                     Ci::LadderRung.resolve_state(raw: raw, run_at: 3.hours.ago, newest_parked_at: 1.hour.ago),
                     "#{raw} must not be reinterpreted"
      end
    end

    # An unreadable timestamp must not manufacture a verdict either way.
    test "a green verdict with no run time cannot be judged stale" do
      assert_equal :green,
                   Ci::LadderRung.resolve_state(raw: :green, run_at: nil, newest_parked_at: 1.hour.ago)
    end

    # --- the measured regression --------------------------------------------

    # 2026-08-19: turf-monster `accepted` tip was c1959ef while BranchGate
    # reported green@abe8c51 — a batch-promote-PR verdict from three merges
    # earlier. Four tasks were parked on accepted at the time.
    test "the measured turf-monster case resolves stale, not green" do
      batch_pr_run = Time.utc(2026, 8, 19, 0, 37, 11)
      last_merge_onto_accepted = Time.utc(2026, 8, 19, 4, 39, 31)

      assert_equal :stale,
                   Ci::LadderRung.resolve_state(raw: :green,
                                                run_at: batch_pr_run,
                                                newest_parked_at: last_merge_onto_accepted)
    end

    # --- ranking / display ---------------------------------------------------

    test "attention states are exactly red conflicted and stale" do
      assert_equal %i[red conflicted stale].sort, Ci::LadderRung::ATTENTION_STATES.sort

      %i[red conflicted stale].each do |s|
        assert rung(state: s).needs_attention?, "#{s} must ask for attention"
      end
      %i[green pending not_built].each do |s|
        refute rung(state: s).needs_attention?, "#{s} must not ask for attention"
      end
    end

    test "worse states sort ahead of better ones" do
      states = %i[green not_built pending stale conflicted red]
      ordered = states.map { |s| rung(state: s) }.sort_by(&:sort_key).map(&:state)

      assert_equal %i[red conflicted stale pending not_built green], ordered
    end

    test "at the same state a rung with parked work sorts ahead of an idle one" do
      busy = rung(state: :green, parked_count: 2)
      idle = rung(state: :green, parked_count: 0)

      assert_equal 0, busy.sort_key.last, "parked work must carry the leading tiebreak"
      assert_equal(-1, busy.sort_key <=> idle.sort_key, "busy must sort ahead of idle")
    end

    test "short_sha truncates and tolerates a blank sha" do
      assert_equal "abc1234", rung(sha: "abc1234def5678").short_sha
      assert_nil rung(sha: nil).short_sha
    end

    test "not_built renders a readable label" do
      assert_equal "not built", rung(state: :not_built).label
      assert_equal "green", rung(state: :green).label
    end

    private

    def rung(state: :green, sha: "abc1234def", parked_count: 0)
      Ci::LadderRung.new(repo: "turf-monster", branch: "accepted", state: state,
                         sha: sha, verdict_at: 1.hour.ago, parked_count: parked_count)
    end
  end
end
