# frozen_string_literal: true

# [unit] `bin/task review-claim status` OBSERVES the lease.
#
# THE MEASUREMENT THIS FILE ENCODES (2026-09-01/02). Two independent sessions were
# told to "sample the lease twice" before deciding whether a holder was alive. Both
# sampled twice, both reported the question unanswerable, and both were looking at a
# claim that had ALREADY EXPIRED. Sampling twice makes a reader look for AGREEMENT,
# and two reads of one lease agree about the STATE every time — the fact that
# settles it is that they disagree about the NUMBER.
#
# So the differencing lives in the COMMAND. Each test below drives the real `status`
# path with a scripted sequence of board reads and an injected clock, and asserts
# which of the states it OBSERVED — never that it printed a timestamp for somebody
# else to work out.
#
#   ruby -Itest test/lib/review_claim_status_observation_test.rb

require "minitest/autorun"
require "json"
require "time"
require "stringio"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__)

class ReviewClaimStatusObservationTest < Minitest::Test
  SLUG = "ship-waiter-misreports-ci"
  REVIEWER_SESSION = "7c21d0aa-15be-4f0d-9a33-0b6e12c4d9c1"
  START = Time.parse("2026-09-02T04:14:28Z")

  Resp = Struct.new(:code, :body)

  # A board whose answers CHANGE between reads — the one thing the existing
  # FakeApi (one canned payload for every call) cannot express, and the only thing
  # a differencing observer can be tested against. Each entry is the `holder` for
  # one read; the last entry repeats once the script runs out.
  class ScriptedApi
    attr_reader :reads

    def initialize(holders)
      @holders = holders
      @reads = 0
    end

    def token = "tok"
    def projects_dir = "/nonexistent"
    def env = {}
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(_method, _path, _body = nil, **)
      holder = @holders[[@reads, @holders.length - 1].min]
      @reads += 1
      return Resp.new(500, "boom") if holder == :unreadable

      Resp.new(200, JSON.generate({ data: { holder: holder } }))
    end
  end

  # ── THE THREE STATES A DIFFERENCED PAIR RESOLVES TO ─────────────────────────

  def test_an_expiry_that_moves_is_reported_as_renewing
    out, = run_status([holder(60), holder(90)])

    assert_includes out, "RENEWING", "the expiry MOVED — something is alive and holding this"
    assert_includes out, "ASK THE HOLDER TO RELEASE IT",
                     "a live review is released by its own session; the caller must be sent to " \
                     "ask rather than left to reach for a takeover"
    assert_includes out, "Do NOT take this task over",
                     "and told why — a steal mid-review strands the verdict"
  end

  def test_an_expiry_that_never_moves_past_its_deadline_is_reported_as_lapsed
    out, = run_status([holder(10), holder(10)])

    assert_includes out, "LAPSED", "we outlasted the lease and it never moved"
    assert_includes out, "review-claim acquire #{SLUG}", "a dead lease means the task is free"
  end

  def test_an_expiry_that_never_moves_across_a_renewal_cycle_is_reported_as_not_renewing
    out, = run_status([holder(300)] * 20)

    assert_includes out, "NOT RENEWING",
                     "nothing heartbeat this in longer than the cadence that would have"
    assert_includes out, "lapses on its own",
                     "the caller's move is to wait it out or ask — the command must say which"
  end

  # ── THE FIRST READ ANSWERS THE COMMON CASE, FOR FREE ────────────────────────
  #
  # An absent or already-lapsed claim is the state the near-miss was actually in.
  # Making the caller wait to learn that would be the same bug, slower.

  def test_an_already_expired_claim_answers_from_the_first_read_with_no_waiting
    out, cli = run_status([holder(-122)])

    assert_includes out, "FREE"
    assert_equal 1, cli.api.reads, "an already-lapsed lease is answerable from ONE read"
    assert_empty cli.naps, "and must cost the caller no wall time at all"
  end

  def test_no_claim_at_all_answers_from_the_first_read
    out, cli = run_status([nil])

    assert_includes out, "FREE"
    assert_empty cli.naps
  end

  # ── HONEST IGNORANCE ────────────────────────────────────────────────────────

  def test_a_window_too_short_to_conclude_reports_inconclusive
    out, = run_status([holder(300)] * 20, flags: ["--observe-for", "10"])

    assert_includes out, "INCONCLUSIVE",
                     "ten seconds of a thirty-second cadence proves nothing either way; " \
                     "reporting it as 'not renewing' would be the confident-wrong answer " \
                     "this command replaces"
    assert_includes out, "--observe-for", "and it must hand over the way to get an answer"
  end

  def test_no_observe_reports_a_single_read_as_unobserved
    out, cli = run_status([holder(60)], flags: ["--no-observe"])

    assert_includes out, "UNOBSERVED"
    assert_equal 1, cli.api.reads
    assert_empty cli.naps, "--no-observe must not wait for anything"
  end

  # `free` is a fact ONE read establishes, so --no-observe must still report it as
  # one rather than hedging about something it knows.
  def test_no_observe_still_reports_an_already_dead_lease_as_free
    out, = run_status([holder(-122)], flags: ["--no-observe", "--json"])
    payload = JSON.parse(out)

    assert_equal "free", payload["observed"]
    assert_equal true, payload["free"],
                 "a lapsed lease is free whether or not the caller asked us to watch; " \
                 "reporting it as unobserved would be the command hedging about a fact it has"
  end

  # ── A BLIP IS NOT EVIDENCE ──────────────────────────────────────────────────
  #
  # The failure direction this whole change exists to avoid: reporting a LIVE
  # reviewer as gone. A read that failed tells us nothing, and must not end the
  # observation with a verdict built on the last good sample.

  def test_an_unreadable_poll_keeps_watching_instead_of_declaring_the_holder_dead
    out, = run_status([holder(60), :unreadable, holder(95)])

    assert_includes out, "RENEWING",
                     "the middle read failed and the third showed the expiry had moved — a blip " \
                     "must never be allowed to resolve as 'not renewing'"
  end

  def test_a_board_that_cannot_be_read_at_all_refuses_rather_than_answering
    out, cli = run_status([:unreadable])

    assert_empty out.strip, "no verdict may be printed on a board we could not read"
    assert_equal ReviewClaimCli::CANT_RUN, cli.code
  end

  # ── THE MACHINE FACE ────────────────────────────────────────────────────────

  def test_json_carries_the_observed_state_and_the_holder
    out, = run_status([holder(60, agent: "carl")], flags: ["--json", "--no-observe"])
    payload = JSON.parse(out)

    assert_equal "unobserved", payload["observed"]
    assert_equal false, payload["free"]
    assert_equal "carl", payload.dig("holder", "agent"),
                 "bin/ship's refusal reads this to say WHO to ask; a holder with no name " \
                 "turns 'ask them to release' into advice nobody can act on"
    assert_equal REVIEWER_SESSION, payload.dig("holder", "session")
  end

  # ── THE ARGUMENT GRAMMAR STILL HOLDS ────────────────────────────────────────
  #
  # This CLI refuses any argument it cannot account for — the scar from
  # `claim-next-review --help` popping a real task. New flags must be admitted to
  # the dictionary, and everything else must still be refused.

  def test_the_new_status_flags_are_accepted_and_an_unknown_one_is_still_refused
    _out, cli = run_status([holder(60)], flags: ["--observe-for", "1", "--json"])
    assert_equal ReviewClaimCli::OK, cli.code

    _out, bad = run_status([holder(60)], flags: ["--observe-fro", "1"])
    assert_equal ReviewClaimCli::CANT_RUN, bad.code,
                 "a typo'd flag must refuse, not fall through into a default window"
  end

  # An unbounded --observe-for turns a diagnostic into a hang.
  def test_an_absurd_observation_window_is_clamped
    _out, cli = run_status([holder(9999)] * 200, flags: ["--observe-for", "100000"])

    assert_operator cli.naps.sum, :<=, ReviewClaimCli::MAX_OBSERVE_SECONDS,
                    "the budget must be clamped; a caller cannot be left waiting indefinitely " \
                    "on a lease that outlives the window"
  end

  private

  def holder(expires_in, agent: nil)
    { "task_slug" => SLUG, "session" => REVIEWER_SESSION, "label" => "Gastly", "agent" => agent,
      "acquired_at" => START.utc.iso8601, "expires_at" => (START + expires_in).utc.iso8601,
      "heartbeat_age" => 30, "live" => expires_in.positive? }
  end

  # Drive the REAL `status` path with a scripted board, a virtual clock, and a
  # sleeper that records instead of sleeping — so the observation is exercised as
  # arithmetic and the suite never waits on wall time.
  def run_status(holders, flags: [])
    out = StringIO.new
    cli = ReviewClaimCli.new(env: {}, out: out, err: StringIO.new)
    api = ScriptedApi.new(holders)
    naps = []
    now = START
    cli.instance_variable_set(:@api, api)
    cli.instance_variable_set(:@sleeper, ->(seconds) { naps << seconds; now += seconds })
    cli.instance_variable_set(:@clock, -> { now })
    code = cli.run(["status", SLUG, *flags])
    [out.string, Probe.new(api, naps, code)]
  end

  Probe = Struct.new(:api, :naps, :code)
end
