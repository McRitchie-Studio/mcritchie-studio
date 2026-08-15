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
  ROOT     = File.expand_path("../..", __dir__)
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

  def test_the_ratchet_declares_every_key_the_guard_reads
    assert_equal %w[assertion_free skips].sort, RATCHET.keys.sort,
                 "the contract and the guard must not drift: a key here with no assertion is a number " \
                 "nobody enforces, and an assertion with no key fails on arrival"
  end
end
