# frozen_string_literal: true

# bin/lib/gem_served_wait.rb: the wait between `gem push` and the first consumer lock push. A
# conductor's single fresh read can pass while a runner edge still answers "can no longer be
# found in that source". These drive the loop on a fake clock, so no case touches the network or
# sleeps.
# History: release rel-20261029-00560a.
require "minitest/autorun"
require_relative "../../bin/lib/gem_served_wait"

class GemServedWaitTest < Minitest::Test
  # A fake wall clock: each probe costs `per_poll` seconds, each sleep `interval`.
  class Clock
    attr_reader :now, :sleeps

    def initialize = (@now = 0.0; @sleeps = [])
    def read = @now
    def advance(seconds) = @now += seconds
    def sleep(seconds) = (@sleeps << seconds; @now += seconds)
  end

  def run_wait(answers, timeout: 300, interval: 5, settle: 60, per_poll: 0)
    clock = Clock.new
    queue = answers.dup
    calls = 0
    probe = lambda do
      calls += 1
      clock.advance(per_poll)
      queue.empty? ? answers.last : queue.shift
    end
    result = GemServedWait.await(probe: probe, timeout: timeout, interval: interval, settle: settle,
                                 clock: -> { clock.read }, sleeper: ->(s) { clock.sleep(s) })
    [result, calls, clock]
  end

  # ── [unit] listed immediately ─────────────────────────────────────────────

  def test_listed_immediately_with_no_settle_returns_on_the_first_poll
    result, calls, clock = run_wait([true], settle: 0)

    assert_predicate result, :served?
    assert_equal 1, calls
    assert_empty clock.sleeps, "a served answer with no hold must not sleep at all"
  end

  # Served on the first read is NOT enough: it must keep answering for the window.
  def test_listed_immediately_still_holds_for_the_settle_window
    result, calls, = run_wait([true], interval: 5, settle: 60)

    assert_predicate result, :served?
    assert_equal 13, calls, "first served read at t=0, then every 5s until t=60"
    assert_operator result.elapsed, :>=, 60
  end

  # ── [unit] listed after N polls ───────────────────────────────────────────

  def test_listed_after_n_polls_returns_served_on_that_poll
    result, calls, = run_wait([false, false, false, true], settle: 0)

    assert_predicate result, :served?
    assert_equal 4, calls, "three misses, then the read that lists it"
    assert_equal 4, result.polls
  end

  # A miss INSIDE the window starts the hold over: one fresh edge is not proof.
  def test_a_miss_inside_the_settle_window_resets_it
    # served t=0,5 · miss t=10 · served from t=15 on → done at t=15+20=35
    result, calls, = run_wait([true, true, false, true], interval: 5, settle: 20)

    assert_predicate result, :served?
    assert_equal 8, calls, "polls at t=0,5,10 then t=15..35: the hold restarted at the miss"
    assert_in_delta 35, result.elapsed
  end

  # ── [unit] never listed → timeout ─────────────────────────────────────────

  def test_never_listed_times_out
    result, calls, = run_wait([false], timeout: 30, interval: 5, settle: 0)

    refute_predicate result, :served?
    assert_equal :timeout, result.outcome
    assert_equal 7, calls, "t=0..30 every 5s, ending on the read that reaches the bound"
  end

  # A hold that cannot finish inside the budget is a timeout, never a served.
  def test_a_hold_that_outlives_the_budget_times_out
    result, = run_wait([false, false, true], timeout: 30, interval: 5, settle: 60)

    assert_equal :timeout, result.outcome
  end

  # Probe time counts: a hung read must eat the budget, or the deadline never fires.
  def test_the_deadline_counts_probe_time
    result, calls, = run_wait([false], timeout: 100, interval: 0, settle: 0, per_poll: 40)

    assert_equal :timeout, result.outcome
    assert_equal 3, calls, "40, 80, 120: the third read crosses 100s of wall time"
  end

  # ── [unit] the compact-index parsers, against the real payload shapes ──────

  def test_info_matches_a_whole_version_never_a_prefix
    body = "0.47.2 aws-sdk-s3:~> 1.218|checksum:abc\n0.48.0 aws-sdk-s3:~> 1.218|checksum:def\n"

    assert GemServedWait.info_lists?(body, "0.48.0")
    refute GemServedWait.info_lists?(body, "0.49.0")
    refute GemServedWait.info_lists?(body, "0.4")
  end

  # Verified live against https://index.rubygems.org/versions on 2026-10-29: a gem
  # appears on one appended line per publish, "studio-engine 0.119.0 5ecbb13c...".
  def test_versions_reads_every_appended_line_for_the_gem
    tail = "rantly 3.0.0 aaa\nstudio-engine 0.117.0 771c\nstudio-engine-x 0.119.0 zzz\nstudio-engine 0.118.0 dec9\n"

    refute GemServedWait.versions_lists?(tail, "studio-engine", "0.119.0"),
           "a sibling gem whose name starts the same must not count"
    assert GemServedWait.versions_lists?(tail + "studio-engine 0.119.0 5ecb\n", "studio-engine", "0.119.0")
    assert GemServedWait.versions_lists?("studio-engine 0.118.0,0.119.0 md5\n", "studio-engine", "0.119.0")
    refute GemServedWait.versions_lists?("studio-engine 0.119.0 a\nstudio-engine -0.119.0 b\n",
                                         "studio-engine", "0.119.0"), "a later yank line takes it back"
    refute GemServedWait.versions_lists?("", "studio-engine", "0.119.0")
  end

  # ── [unit] Carl's bounce: the monthly rebuild puts old versions in the BASE line ──
  #
  # Real lines from https://index.rubygems.org/versions, 2026-10-29: the header
  # (created_at 2026-10-01), studio-engine's rebuilt base line (ending 0.82.0) with
  # its alphabetical neighbours, an appended block holding 0.82.1, and the file's
  # last 40 lines. A Range tail holds only the appends.
  REBUILT = File.read(File.expand_path("../fixtures/files/rubygems_versions_rebuilt.txt", __dir__))
  TAIL = REBUILT[-2000..]

  def test_the_fixture_has_the_version_in_the_base_line_and_not_the_tail
    assert_includes REBUILT, ",0.82.0 6b7aab37"
    refute_includes TAIL, "0.82.0", "the case only bites when the tail lacks the version"
  end

  def test_an_already_live_version_in_the_base_line_is_served_via_the_full_file
    full_reads = 0
    full = -> { full_reads += 1; REBUILT }

    assert GemServedWait.versions_served?("studio-engine", "0.82.0", TAIL, full: full),
           "a version from before the rebuild is installable; the probe must say so"
    assert_equal 1, full_reads
    refute GemServedWait.versions_served?("studio-engine", "0.82.0", TAIL),
           "the tail alone cannot see it (the bounce's repro)"
  end

  def test_a_version_on_the_tail_never_reads_the_full_file
    tail = REBUILT[REBUILT.index("studio-engine 0.82.1") - 10..]
    full = -> { flunk "a tail hit must not download 25 MB" }

    assert GemServedWait.versions_served?("studio-engine", "0.82.1", tail, full: full)
  end

  def test_a_version_on_neither_is_not_served
    refute GemServedWait.versions_served?("studio-engine", "9.9.9", TAIL, full: -> { REBUILT })
    refute GemServedWait.versions_served?("studio-engine", "9.9.9", TAIL, full: -> { nil })
  end

  # A Range body starts mid-line: "foo-studio-engine 0.119.0 …" cut after "foo-".
  def test_the_cut_first_line_of_a_range_body_is_dropped
    tail = "studio-engine 0.119.0 5ecb\nrantly 3.0.0 aaa\n"

    refute GemServedWait.versions_served?("studio-engine", "0.119.0", tail),
           "a fragment of another gem's line must not read as studio-engine"
    assert GemServedWait.versions_served?("studio-engine", "0.119.0", "ngine 0.1 x\n" + tail)
    assert_equal "", GemServedWait.drop_cut_line("no newline at all")
  end

  # ── [unit] the refusal names the surface that failed ──────────────────────
  #
  # task release-gem-doc-followups: GEM_NOT_SERVED said "not served" and told the
  # operator to wait for /info, even when /info already listed the version and the
  # stale object was /versions or the .gem.

  def test_a_timeout_carries_the_last_missed_surface
    result, = run_wait([GemServedWait::SURFACE_INFO, GemServedWait::SURFACE_GEM], timeout: 10, interval: 5)

    refute_predicate result, :served?
    assert_equal GemServedWait::SURFACE_GEM, result.miss, "the LAST poll's miss is the one the refusal names"
  end

  def test_a_served_result_carries_no_miss_and_a_bare_false_names_none
    served, = run_wait([GemServedWait::SURFACE_INFO, true], settle: 0)
    unnamed, = run_wait([false], timeout: 0)

    assert_predicate served, :served?
    assert_nil served.miss
    assert_nil unnamed.miss, "a probe that answers a bare false names no surface"
  end

  def test_first_miss_stops_at_the_first_failing_surface
    asked = []
    checks = [["/info", -> { asked << :info; true }], [".gem", -> { asked << :gem; false }],
              ["never", -> { flunk "the probe must stop at the first miss" }]]

    assert_equal ".gem", GemServedWait.first_miss(checks)
    assert_equal %i[info gem], asked
    assert_nil GemServedWait.first_miss([["/info", -> { true }]])
  end

  def test_versions_miss_names_tail_full_read_and_failed_read_apart
    assert_nil GemServedWait.versions_miss("studio-engine", "0.82.0", TAIL, full: -> { REBUILT })
    assert_equal GemServedWait::SURFACE_VERSIONS_TAIL,
                 GemServedWait.versions_miss("studio-engine", "0.82.0", TAIL, full: -> { nil })
    assert_equal GemServedWait::SURFACE_VERSIONS_FULL,
                 GemServedWait.versions_miss("studio-engine", "9.9.9", TAIL, full: -> { REBUILT })
    assert_equal GemServedWait::SURFACE_VERSIONS_FULL_FAILED,
                 GemServedWait.versions_miss("studio-engine", "9.9.9", TAIL, full: -> { :failed })
  end

  URLS = { info: "https://index.rubygems.org/info/%s", versions: "https://index.rubygems.org/versions",
           file: "https://rubygems.org/gems/%s-%s.gem" }.freeze

  def test_the_remedy_checks_the_surface_that_missed
    remedy = ->(miss) { GemServedWait.remedy(miss, gem_name: "studio-engine", version: "0.9.0", urls: URLS) }

    assert_includes remedy.call(GemServedWait::SURFACE_INFO), "info/studio-engine | tail -3` lists 0.9.0"
    assert_includes remedy.call(GemServedWait::SURFACE_VERSIONS_TAIL), "versions | grep '^studio-engine '"
    assert_includes remedy.call(GemServedWait::SURFACE_VERSIONS_FULL), "versions | grep '^studio-engine '"
    assert_includes remedy.call(GemServedWait::SURFACE_VERSIONS_FULL_FAILED), "RELEASE_GEM_VERSIONS_FULL_MAX_TIME"
    assert_includes remedy.call(GemServedWait::SURFACE_GEM), "gems/studio-engine-0.9.0.gem` exits 0"
    refute_includes remedy.call(GemServedWait::SURFACE_GEM), "/info/", "a .gem miss must not send the operator to /info"
  end
end
