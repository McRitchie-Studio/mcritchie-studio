# frozen_string_literal: true

# [unit] ShipAuthority — how `bin/release ship --mode ask|timed|auto` takes
# production authority (bin/lib/ship_authority.rb): the mode precedence, the two
# events every mode records, and each firing condition of the timed window —
# grant, lapse-and-proceed, lapse-and-refuse, unreadable-at-lapse, dry-run —
# against an injected clock.
#
#   ruby -Itest test/lib/ship_authority_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/ship_authority"

class ShipAuthorityTest < Minitest::Test
  NOW = Time.utc(2026, 9, 24, 20, 0, 0)

  class Harness
    attr_reader :events, :said, :reads, :now, :sleeps

    def initialize(now: NOW, states: [], confirm: true)
      @now = now
      @states = states
      @confirm = confirm
      @events = []
      @said = []
      @reads = []
      @sleeps = []
    end

    def recorder = ->(status, metadata) { @events << [status, metadata] }
    def reader = ->(blockers:) { @reads << blockers; @states.size > 1 ? @states.shift : @states.first }
    def confirmer = ->(_prompt) { @confirm }
    def say = ->(line) { @said << line }
    def clock = -> { @now }
    def sleeper = ->(seconds) { @sleeps << seconds; @now += seconds }

    def take!(mode:, dry: false, minutes: 30, interval: 45)
      ShipAuthority.take!(mode: mode, release_slug: "rel-demo", minutes: minutes, recorder: recorder, reader: reader,
                          confirmer: confirmer, say: say, clock: clock, sleeper: sleeper, dry: dry, interval: interval)
    end
  end

  # --- mode precedence ---------------------------------------------------------

  def test_explicit_mode_wins_over_yes_and_config
    assert_equal "ask", ShipAuthority.resolve_mode(explicit: "ask", assume_yes: true, config_mode: "timed")
    assert_equal "timed", ShipAuthority.resolve_mode(explicit: "TIMED", assume_yes: true, config_mode: "auto")
  end

  def test_yes_alone_is_auto_and_the_config_default_is_read_only_when_it_decides
    assert_equal "auto", ShipAuthority.resolve_mode(explicit: nil, assume_yes: true, config_mode: -> { raise "not read" })
    assert_equal "timed", ShipAuthority.resolve_mode(explicit: "", assume_yes: false, config_mode: -> { "timed" })
    assert_equal "timed", ShipAuthority.resolve_mode(explicit: nil, assume_yes: false, config_mode: -> { Devops::Windows.production_ship_mode })
  end

  def test_an_unknown_mode_is_refused_wherever_it_comes_from
    assert_raises(ArgumentError) { ShipAuthority.resolve_mode(explicit: "sometimes", assume_yes: false, config_mode: "timed") }
    assert_raises(ArgumentError) { ShipAuthority.resolve_mode(explicit: nil, assume_yes: false, config_mode: "yes") }
    assert_raises(ShipAuthority::Refused) { Harness.new.take!(mode: "sometimes") }
  end

  # --- ask / auto ----------------------------------------------------------------

  def test_ask_records_the_request_then_the_confirmed_grant
    h = Harness.new(confirm: true)
    assert_equal :confirmed, h.take!(mode: "ask")
    assert_equal [["started", { "mode" => "ask" }], ["completed", { "mode" => "ask", "granted_via" => "confirm" }]], h.events
    assert_empty h.reads
  end

  def test_a_declined_ask_refuses_after_the_request_and_records_no_grant
    h = Harness.new(confirm: false)
    error = assert_raises(ShipAuthority::Refused) { h.take!(mode: "ask") }
    assert_equal "aborted — production deploy not confirmed", error.message
    assert_equal [["started", { "mode" => "ask" }]], h.events
  end

  def test_auto_records_both_events_and_asks_nobody
    h = Harness.new(confirm: false)
    assert_equal :auto, h.take!(mode: "auto")
    assert_equal %w[started completed], h.events.map(&:first)
    assert_equal "auto", h.events.last.last["granted_via"]
  end

  # --- timed -------------------------------------------------------------------

  def test_timed_posts_the_request_with_the_window_end_and_returns_on_the_grant
    h = Harness.new(states: [{ "granted" => false }, { "granted" => true, "granted_by" => "alex@example.com", "granted_via" => "web" }])
    assert_equal :granted, h.take!(mode: "timed")

    started = h.events.first
    assert_equal "started", started.first
    assert_equal "timed", started.last["mode"]
    assert_equal 30, started.last["window_minutes"]
    assert_equal "2026-09-24T20:30:00Z", started.last["window_ends_at"]
    assert_equal ["completed", { "mode" => "timed", "granted_via" => "web", "window_ends_at" => "2026-09-24T20:30:00Z" }], h.events.last
    assert_equal [45], h.sleeps, "one poll interval between the two reads"
    assert_equal [false, false], h.reads, "blockers are not computed before the lapse"
    assert h.said.any? { |l| l.include?("granted by alex@example.com (web)") }
    assert h.said.any? { |l| l.include?("30:00 left") }, h.said.inspect
  end

  def test_timed_lapse_proceeds_only_on_green_with_no_escalation
    h = Harness.new(states: [{ "granted" => false, "blockers" => [] }])
    assert_equal :lapsed_proceed, h.take!(mode: "timed", minutes: 2, interval: 45)
    assert_equal NOW + 120, h.now, "the loop reads the lapse exactly at the window end"
    assert_equal [45, 45, 30], h.sleeps, "the last sleep is trimmed to the window end"
    assert_equal [false, false, false, true], h.reads, "blockers are read on the lapse read only"
    assert_equal ["completed", { "mode" => "timed", "lapsed" => true, "granted_via" => "window-lapse",
                                 "window_ends_at" => "2026-09-24T20:02:00Z" }], h.events.last
  end

  # --- idempotency keys: each timed run owns its rows -----------------------------

  def test_the_timed_request_grant_and_lapse_each_key_on_the_window_they_belong_to
    ends = "2026-09-24T20:30:00Z"
    assert_equal "rel-demo:ship_authorized:started:#{ends}",
                 ShipAuthority.idempotency_key("rel-demo", "started", { "mode" => "timed", "window_ends_at" => ends })
    assert_equal "rel-demo:ship_authorized:completed:#{ends}",
                 ShipAuthority.idempotency_key("rel-demo", "completed", { "mode" => "timed", "granted_via" => "web", "window_ends_at" => ends })
    assert_equal "rel-demo:ship_authorized:completed:lapsed:#{ends}",
                 ShipAuthority.idempotency_key("rel-demo", "completed", { "mode" => "timed", "lapsed" => true, "window_ends_at" => ends })
  end

  def test_a_re_run_after_a_lapse_gets_a_fresh_grant_key_not_the_lapse_row
    first = ShipAuthority.idempotency_key("rel-demo", "completed", { "lapsed" => true, "window_ends_at" => "2026-09-24T20:30:00Z" })
    rerun = ShipAuthority.idempotency_key("rel-demo", "completed", { "granted_via" => "web", "window_ends_at" => "2026-09-24T21:30:00Z" })
    refute_equal first, rerun
  end

  def test_ask_and_auto_carry_no_window_and_keep_the_default_key
    assert_nil ShipAuthority.idempotency_key("rel-demo", "started", { "mode" => "ask" })
    assert_nil ShipAuthority.idempotency_key("rel-demo", "completed", { "mode" => "auto", "granted_via" => "auto" })
  end

  def test_timed_lapse_refuses_and_names_the_blockers
    h = Harness.new(states: [{ "granted" => false, "blockers" => ["G3 Candidate is red on rel-demo", "t-1 carries an open escalation (Escalated: x)"] }])
    error = assert_raises(ShipAuthority::Refused) { h.take!(mode: "timed", minutes: 1, interval: 60) }
    assert_match(/lapsed at 2026-09-24T20:01:00Z but the ship may not proceed on its own: G3 Candidate is red on rel-demo; t-1 carries an open escalation/, error.message)
    assert_match(/Nothing deployed/, error.message)
    assert_equal %w[started], h.events.map(&:first), "no completion is recorded on a refusal"
  end

  def test_timed_lapse_with_an_unreadable_release_refuses_rather_than_proceeds
    h = Harness.new(states: [nil])
    error = assert_raises(ShipAuthority::Refused) { h.take!(mode: "timed", minutes: 1, interval: 60) }
    assert_match(/could not be read at the window end/, error.message)
    assert_equal %w[started], h.events.map(&:first)
    assert h.said.any? { |l| l.include?("last read failed; retrying") }
  end

  def test_timed_dry_run_posts_the_plan_and_reads_nothing
    h = Harness.new(states: [{ "granted" => true }])
    assert_equal :dry, h.take!(mode: "timed", dry: true)
    assert_equal %w[started], h.events.map(&:first)
    assert_empty h.reads
    assert h.said.any? { |l| l.include?("[dry-run] would wait up to 30 min") }
  end
end
