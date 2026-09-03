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

  # TaskReviewClaim.release NULLS the fields but KEEPS the row, and holder_info
  # always returns its full 8-key Hash — so "any Hash means somebody" graded the
  # terminal step of EVERY review (the primary releases in step 7) as a 45-second
  # INCONCLUSIVE. A row with no named session is nobody; nobody is FREE, from one
  # read, at no cost. Measured live against three released production claims
  # before this test existed (2026-09-03 review).
  def test_a_released_claim_row_grades_free_from_one_read
    out, cli = run_status([released_row])

    assert_includes out, "FREE"
    assert_equal 1, cli.api.reads, "a released row is answerable from ONE read"
    assert_empty cli.naps, "and must cost the caller no wall time"
  end

  # The class of the regression, as its own case: a claim released BETWEEN the
  # two reads must grade FREE — the second read's empty row is the release
  # happening, not a holder going unreadable. (Two mutants survived precisely
  # because nothing asserted this.)
  def test_a_claim_released_between_the_two_reads_grades_free
    out, = run_status([holder(300), released_row])

    assert_includes out, "FREE",
                    "the holder we watched let go mid-observation; reporting anything but " \
                    "free tells the next reviewer a vacated claim is still contested"
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

  # A SUSTAINED outage is not a blip, and it is not evidence either. If the board
  # answers once and then fails for the WHOLE window, there is no second reading to
  # difference — `latest` stays pinned to `first`, and differencing a value against
  # ITSELF says "it did not move" about something that was never looked at twice.
  #
  # MEASURED pre-fix: a live holder with 300s of lease left plus a board that 500s
  # for the entire window printed CHARACTER-FOR-CHARACTER the same line as a
  # genuinely dying holder. The grade is the smaller half of the defect; the line
  # asserting an observation that never happened is the honesty failure.
  def test_a_board_unreadable_for_the_whole_window_reports_ignorance_not_a_dead_holder
    # ScriptedApi repeats its last entry, so this is: one good read, then 500s forever.
    out, = run_status([holder(300), :unreadable])

    refute_includes out, "NOT RENEWING",
                    "no poll after the first ever succeeded — calling a live holder " \
                    "'not renewing' is the one direction this command must never fail in"
    assert_includes out, "INCONCLUSIVE",
                    "an unobservable window is ignorance, and ignorance has a grade already"
    refute_includes out, "the expiry did not move",
                     "the expiry was never READ a second time, so nothing may be asserted " \
                     "about whether it moved — that is the evidence this command never had"
  end

  # The other half of the same contract: the fix must not buy honesty under outage
  # by making a REAL not-renewing holder unreportable. A board that answers every
  # time and shows a frozen expiry is still a definite finding.
  def test_a_readable_board_with_a_frozen_expiry_still_reports_not_renewing
    out, = run_status([holder(300)] * 20)

    assert_includes out, "NOT RENEWING",
                    "every poll succeeded and the expiry never moved — that is observed, " \
                    "and the outage fix must not blunt it"
  end

  def test_a_board_that_cannot_be_read_at_all_refuses_rather_than_answering
    out, cli = run_status([:unreadable])

    assert_empty out.strip, "no verdict may be printed on a board we could not read"
    assert_equal ReviewClaimCli::CANT_RUN, cli.code
  end

  # ── THE STEAL ROUTE AN OUTAGE CAN STILL REACH ───────────────────────────────
  #
  # LAPSED is inside OBSERVED_FREE (claim_holder.rb:126), so it is not merely a
  # diagnostic — it is the grade that tells a caller the task is FREE TO TAKE.
  #
  # `observe` decides it with `now >= second`, where `now` is the LOOP-EXIT time
  # and `second` is the expiry from the last SUCCESSFUL read. Nothing in that
  # comparison knows the observation ended. So: one good poll, then the board goes
  # dark for the rest of a window longer than the remaining lease, and the command
  # concludes it "outlasted" a lease it stopped watching.
  #
  # The previous fix (observation-lies-under-outage) guarded the case where NO poll
  # after the first succeeded. This has exactly ONE, so `differenced` is true and
  # that guard does not fire. The guard was keyed on "did we ever difference a
  # pair" when the question is "was the observation still LIVE when the deadline
  # passed".
  def test_a_window_that_goes_dark_before_the_deadline_cannot_report_the_lease_free
    # first read + one good poll at the same expiry, then 500s forever.
    out, = run_status([holder(10), holder(10), :unreadable])

    refute_includes out, "LAPSED",
                    "the observation died at the second read; a lease cannot be declared " \
                    "dead on a deadline nobody was watching when it passed"
    refute_includes out, "free to claim",
                    "this is the steal route — LAPSED sits inside OBSERVED_FREE, so a wrong " \
                    "LAPSED does not merely misinform, it authorises taking a live review"
  end

  # Same shape, asserted on the MACHINE face, because that is what a caller
  # branches on rather than the prose.
  def test_a_dark_window_does_not_report_free_true_in_json
    out, = run_status([holder(10), holder(10), :unreadable], flags: ["--json"])
    payload = JSON.parse(out)

    assert_equal false, payload["free"],
                 "free=true here is the whole defect: bin/ship and any claim gate reading " \
                 "this field would treat a live holder's task as available"
    refute_equal "lapsed", payload["observed"]
  end

  # The other direction, so the fix cannot buy safety by refusing to conclude:
  # a board readable for the WHOLE window that genuinely outlasts the lease must
  # still report LAPSED and still offer the acquire.
  def test_a_readable_window_that_outlasts_the_lease_still_reports_lapsed
    out, = run_status([holder(10), holder(10)])

    assert_includes out, "LAPSED",
                    "every poll succeeded and we watched the expiry pass — that is observed"
    assert_includes out, "review-claim acquire",
                    "a genuinely dead lease must still hand over the acquire"
  end

  # LAPSED is the STEAL route and the tests above pin it. NOT_RENEWING is the same
  # lie in the other grade — "nothing is heartbeating this" is a claim about
  # WATCHING, and an outage can manufacture it the same way, by letting the window
  # accrue time nobody spent reading.
  #
  # This case cannot reach LAPSED (the lease outlives the window by minutes), so it
  # isolates the `watched` half of the fix: wall time is longer than the renewal
  # cycle, OBSERVED time is not. Without it, reverting `watched` to `now -
  # first_read_at` passes every other test in this file — measured.
  def test_a_dark_window_cannot_manufacture_not_renewing_from_time_it_did_not_watch
    # Lease with 300s left, so no deadline is reached. One good poll, then dark for
    # a window LONGER than the 30s renewal cycle.
    out, = run_status([holder(300), holder(300), :unreadable])

    refute_includes out, "NOT RENEWING",
                    "the window outlasted the renewal cycle but the OBSERVATION did not — " \
                    "a heartbeat cannot be reported absent over a stretch nobody was reading"
    assert_includes out, "INCONCLUSIVE",
                    "one good poll then darkness is ignorance, whatever the wall clock says"
  end

  # ── THE THIRD ROUTE: A 200-OK BOARD WE CANNOT READ ──────────────────────────
  #
  # `parse_time` returns nil for an EMPTY string and for an UNPARSEABLE one, and
  # `observe` reads that nil as "nothing held it" — so a holder whose expiry cannot
  # be read grades FREE, which is inside OBSERVED_FREE and hands over the acquire.
  # The payload says `live: true` at the same time.
  #
  # Same shape as the two routes already closed: the command concludes from
  # evidence it does not have. A failed poll is not evidence (fixed); a field it
  # cannot parse is not evidence either. Ignorance is INCONCLUSIVE, never FREE.
  # claim_holder.rb:141 already states the rule — "an unknown must never inherit
  # the steal route" — it was simply not enforced for this input class.
  #
  # Asserted on the JSON `free` flag rather than prose: prose can match both the
  # honest and the dishonest wording, and `free` is what a caller branches on.
  MALFORMED_HOLDERS = {
    "expires_at missing"     => { "session" => REVIEWER_SESSION, "live" => true },
    "expires_at empty"       => { "session" => REVIEWER_SESSION, "expires_at" => "", "live" => true },
    "expires_at unparseable" => { "session" => REVIEWER_SESSION, "expires_at" => "soon-ish", "live" => true },
    "holder is empty hash"   => {}
  }.freeze

  MALFORMED_HOLDERS.each do |label, holder|
    define_method(:"test_a_malformed_holder_#{label.tr(' ', '_')}_never_grades_free") do
      out, = run_status([holder], flags: ["--json"])
      payload = JSON.parse(out)

      assert_equal false, payload["free"],
                   "#{label}: an unreadable holder is IGNORANCE, not an absent claim — " \
                   "free=true here tells the reader to steal a claim the same payload " \
                   "may be calling live"
      refute_equal "free", payload["observed"], "#{label}: must not grade FREE"
    end
  end

  # holder_present?'s full input taxonomy in ONE place, so nobody again reasons
  # about two of the classes and ships a predicate wrong on the third (which is
  # exactly how the released-row regression happened):
  #   ABSENT     (nil — no claim row)            → FREE, one read
  #   RELEASED   (row kept, session nulled)      → FREE, one read
  #   UNREADABLE but NAMED (expiry unparseable)  → never free; ignorance
  def test_the_three_holder_input_classes_grade_distinctly
    absent_out, = run_status([nil], flags: ["--json"])
    assert_equal true, JSON.parse(absent_out)["free"], "ABSENT: no row is nobody"

    released_out, = run_status([released_row], flags: ["--json"])
    assert_equal true, JSON.parse(released_out)["free"], "RELEASED: a nulled row is nobody"

    named = holder(60).merge("expires_at" => "soon-ish")
    named_out, = run_status([named], flags: ["--json"])
    assert_equal false, JSON.parse(named_out)["free"],
                 "NAMED-UNREADABLE: a named session with an expiry we cannot read is " \
                 "ignorance, never an invitation to steal"
  end

  # THE SECOND READ CAN DEGRADE TOO. The first read is clean — a live lease with
  # ample time — and the board then answers 200 OK with a holder whose expiry
  # cannot be parsed. `observe` reads that nil as "released outright between the
  # two reads" and grades FREE, which is the steal route again, one read later.
  #
  # This path is NOT reachable through the four first-read shapes above: those all
  # settle before the second read is ever graded. It needed its own case, and
  # without it the second guard is inert — measured, by removing the guard and
  # watching all 26 tests stay green.
  def test_a_second_read_we_cannot_parse_is_ignorance_not_a_release
    good = { "task_slug" => SLUG, "session" => REVIEWER_SESSION, "label" => "Gastly",
             "acquired_at" => START.utc.iso8601, "expires_at" => (START + 300).utc.iso8601,
             "heartbeat_age" => 30, "live" => true }
    degraded = good.merge("expires_at" => "not-a-timestamp")

    out, = run_status([good, degraded], flags: ["--json"])
    payload = JSON.parse(out)

    assert_equal false, payload["free"],
                 "a second read we cannot parse says NOTHING about the lease — treating it " \
                 "as a release hands over the acquire on a holder still reporting live=true"
    refute_equal "free", payload["observed"]
  end

  def test_a_malformed_holder_offers_watching_not_acquiring
    out, = run_status([MALFORMED_HOLDERS.fetch("expires_at unparseable")])

    refute_includes out, "review-claim acquire",
                    "the acquire is the steal route; an unreadable board must never offer it"
  end

  # The other direction, so the fix cannot buy safety by refusing to answer: a
  # genuinely ABSENT claim (nil holder, not a malformed one) is still FREE from one
  # read, and must still cost the caller no wall time.
  def test_an_absent_claim_is_still_free_from_the_first_read
    out, cli = run_status([nil], flags: ["--json"])
    payload = JSON.parse(out)

    assert_equal true, payload["free"],
                 "nil holder means NO CLAIM — that is a fact one read establishes, and " \
                 "hedging about it would be the command refusing to answer what it knows"
    assert_equal 1, cli.api.reads
    assert_empty cli.naps
  end

  # The DISPLAYED span, pinned. `watched_seconds` is what the caller sees beside a
  # sentence about what the expiry did, so it must be the window OBSERVED, not the
  # window waited out. Under an outage those diverge, and reporting the wait as the
  # watch puts a number next to a claim nobody was in a position to make.
  #
  # This was left unpinned by the PR that introduced observed_span — named there,
  # not tested, and two mutations survived on it.
  def test_the_displayed_span_is_the_window_observed_not_the_window_waited
    # One good poll ~5s in, then dark for the rest of a ~45s window.
    out, = run_status([holder(300), holder(300), :unreadable], flags: ["--json"])
    payload = JSON.parse(out)

    assert_operator payload["watched_seconds"], :<, 30,
                    "the observation ended at the second read; a span that keeps growing " \
                    "through the dark stretch is reporting the WAIT as the WATCH"
    assert_operator payload["watched_seconds"], :>=, 0
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

  # Exactly what holder_info returns after TaskReviewClaim.release: the row
  # kept, every identifying field nulled, live false.
  def released_row
    { "task_slug" => SLUG, "session" => nil, "label" => nil, "agent" => nil,
      "acquired_at" => nil, "expires_at" => nil, "heartbeat_age" => nil, "live" => false }
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
