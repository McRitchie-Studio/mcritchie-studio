# frozen_string_literal: true

# [unit] THE RUBY SUITE'S RATCHET. Standalone (no Rails):
#   ruby -Itest test/lib/test_health_ratchet_test.rb
#
# The static counterpart to config/e2e_lane.yml, for the half of the suite nothing was
# counting: 445 Ruby test files carrying 6,582 cases, 26 skip call sites, and — as of
# 2026-08-14 — zero assertion-free tests.
#
# WHY A ZERO NEEDS ITS OWN PROOF. "assertion_free: 0" is a claim produced by a
# detector, and a detector that silently matches nothing produces the same zero as a
# clean suite. So the vectors below drive TestHealth.assertion_free_in directly and
# prove it FLAGS the shapes it is supposed to flag before the count is trusted at all.
# A negative result from an unproven instrument is not evidence.
#
# WHAT THIS DOES NOT CLAIM. It reads SOURCE. It can see that a test declares no
# assertion; it cannot see whether an assertion it declares actually executes, or
# whether the test ran. That gap is mutation testing's, and it belongs to the grooming
# act — this half is the cheap one that fails in milliseconds and keeps the number
# honest in between.
require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/test_health"

class TestHealthRatchetTest < Minitest::Test
  # TEST_HEALTH_ROOT is the test seam. It exists so the INTEGRATION test can drive this
  # whole guard as a subprocess against a throwaway tree carrying a planted regression,
  # and watch it exit non-zero — which is the only way to prove the guard fails a BUILD
  # rather than merely that an assertion is false. Pointed at a temp dir it touches
  # nothing shared, so it stays safe under CI's parallel workers.
  ROOT     = ENV.fetch("TEST_HEALTH_ROOT", File.expand_path("../..", __dir__))
  TEST_DIR = File.join(ROOT, "test")
  RATCHET  = YAML.safe_load_file(File.join(ROOT, "config", "test_health.yml")).freeze

  # ── the instrument, proven before its readings are believed ────────────────

  def test_the_detector_flags_a_test_that_asserts_nothing
    %w[declarative def_style].zip([
      %(  test "x" do\n    Thing.new.call\n  end\n),
      %(  def test_x\n    Thing.new.call\n  end\n)
    ]).each do |dialect, source|
      refute_empty TestHealth.assertion_free_in(source),
                   "#{dialect}: a test with no assertion must be flagged"
    end
  end

  def test_the_detector_leaves_a_real_test_alone
    {
      "assert"        => %(  test "x" do\n    assert_equal 1, 1\n  end\n),
      "refute"        => %(  test "x" do\n    refute_nil 1\n  end\n),
      "spec must_"    => %(  test "x" do\n    1.must_equal 1\n  end\n),
      "explicit skip" => %(  test "x" do\n    skip "later"\n    Thing.new.call\n  end\n)
    }.each do |label, source|
      assert_empty TestHealth.assertion_free_in(source), "#{label} must not be flagged"
    end
  end

  # THE TRUNCATION TRAP. Body extraction is indent-matched, so a nested block or a
  # heredoc containing the word `end` must not cut the body short and hide the
  # assertions below it — which would report a perfectly good test as assertion-free
  # and make this gate cry wolf on its first real diff.
  def test_a_nested_end_does_not_truncate_the_body
    nested  = %(  test "x" do\n    [1].each do |i|\n      i\n    end\n    assert true\n  end\n)
    heredoc = %(  test "x" do\n    s = <<~T\n      the end\n    T\n    assert s\n  end\n)

    assert_empty TestHealth.assertion_free_in(nested),  "a nested end must not truncate the body"
    assert_empty TestHealth.assertion_free_in(heredoc), "a heredoc containing 'end' must not truncate it"
  end

  # A skip written INSIDE a heredoc is documentation, not a switched-off test. This
  # guard's own integration test builds fixture suites out of heredocs containing
  # `skip "later"` — counting those made the ratchet fail on the very commit that
  # introduced it, and discovering it also corrected the real count from 26 to 25,
  # because one existing skip lives inside a heredoc too.
  def test_a_skip_inside_a_heredoc_is_not_a_skip
    real   = %(  def test_x\n    skip "real"\n    assert true\n  end\n)
    inside = %(  FIX = <<~RB\n    skip "not real"\n  RB\n)

    assert_equal 1, TestHealth.skips_in(real),          "a real skip must be counted"
    assert_equal 0, TestHealth.skips_in(inside),        "a skip inside a heredoc is not a call site"
    assert_equal 1, TestHealth.skips_in(inside + real), "the heredoc must close, not swallow what follows"
  end

  # The SAME exclusion, for the other detector. Both were bitten by this guard's own
  # integration fixtures: a heredoc there declares a deliberately assertion-free test,
  # and scanning heredoc bodies counted it as a real finding.
  def test_a_test_declared_inside_a_heredoc_is_a_fixture_not_a_test
    real   = %(  def test_x\n    Thing.call\n  end\n)
    inside = %(  FIX = <<~RB\n    def test_hollow\n      Thing.call\n    end\n  RB\n)

    assert_equal 1, TestHealth.assertion_free_in(real).size,          "a real one must be flagged"
    assert_equal 0, TestHealth.assertion_free_in(inside).size,        "one inside a heredoc is a fixture"
    assert_equal 1, TestHealth.assertion_free_in(inside + real).size, "the heredoc must close"
  end

  # ── the ratchet itself ─────────────────────────────────────────────────────

  def test_no_test_asserts_nothing
    offenders = TestHealth.assertion_free(TEST_DIR)
    named = offenders.first(5).map { |o| "#{o[:file]}:#{o[:line]} #{o[:name]}" }

    assert_equal RATCHET["assertion_free"], offenders.size,
                 "config/test_health.yml declares #{RATCHET["assertion_free"]} assertion-free test(s), " \
                 "found #{offenders.size}: #{named.join(" | ")}. A test that asserts nothing goes green " \
                 "whatever the code does — it reports coverage it does not have. Give it an assertion, " \
                 "or delete it."
  end

  def test_the_skip_count_matches_the_ratchet
    actual = TestHealth.skips(TEST_DIR)

    assert_equal RATCHET["skips"], actual,
                 "config/test_health.yml declares #{RATCHET["skips"]} skip call site(s), found #{actual}. " \
                 "A skip is a test switched off without being deleted: the suite keeps its name and loses " \
                 "its coverage. Going UP needs a deliberate edit to that file so the reason sits in the " \
                 "diff; going DOWN is the good kind of edit — lower the number and ship it."
  end

  # ── frozen hotspots: a file may shrink freely, never grow ──────────────────

  def test_no_frozen_hotspot_has_grown
    over = TestHealth.oversized(ROOT, RATCHET["frozen_size"])
    named = over.map { |o| "#{o[:file]} is #{o[:lines]} lines, ceiling #{o[:ceiling]}" }

    assert_empty over,
                 "#{named.join("; ")}. These files are the suite's APPEND hotspots — " \
                 "test/lib/release_cli_test.rb alone was touched by 26 of the last 200 PRs, all " \
                 "colliding at the bottom of one file. Put the new test in a NEW file named for its " \
                 "concern (that is what every test added in this session did), or, if you genuinely " \
                 "grew an existing test, raise the ceiling in config/test_health.yml so the reason " \
                 "sits in the diff."
  end

  def test_shrinking_a_frozen_file_is_always_allowed
    frozen = { "test/lib/test_health_ratchet_test.rb" => 10_000 }

    assert_empty TestHealth.oversized(ROOT, frozen),
                 "a file well under its ceiling must never be an offender — shrinking needs no edit here"
  end

  # A ceiling naming a file that no longer exists must not fail the build. Deleting or
  # renaming a frozen file is progress; the stale entry is a reviewer's tidy-up.
  def test_a_ceiling_for_a_missing_file_is_not_a_failure
    assert_empty TestHealth.oversized(ROOT, { "test/lib/nope_does_not_exist_test.rb" => 1 })
  end

  def test_the_ratchet_declares_every_key_the_guard_reads
    assert_equal %w[assertion_free frozen_size skips].sort, RATCHET.keys.sort,
                 "the contract and the guard must not drift: a key here with no assertion is a number " \
                 "nobody enforces, and an assertion with no key fails on arrival"
  end
end
