# frozen_string_literal: true

# [unit] Pure-logic tests for bin/lib/fast_lane.rb — the skip/resume decisions
# behind the fast-lane wrappers (`bin/task begin`, `bin/ship`). The wrappers'
# orchestration is exercised end-to-end in test/lib/task_begin_test.rb and
# test/lib/ship_test.rb; THIS file pins the decisions those runs depend on.
# Run directly:
#   ruby -Itest test/lib/fast_lane_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require_relative "../../bin/lib/fast_lane"
require_relative "../../bin/lib/full_suite_gate"

class FastLaneTest < Minitest::Test
  # --- derive_slug: the client-side mirror of Task#generate_slug ---------------

  def test_derive_slug_parameterizes_a_title
    assert_equal "fast-lane-begin-ship", FastLane.derive_slug("Fast Lane Begin Ship")
  end

  def test_derive_slug_collapses_punctuation_and_trims_hyphens
    assert_equal "fix-nav-bug", FastLane.derive_slug("  Fix: Nav / Bug!  ")
  end

  def test_derive_slug_of_blank_is_empty
    assert_equal "", FastLane.derive_slug(nil)
    assert_equal "", FastLane.derive_slug("   ")
  end

  # --- open_pr: the idempotent-PR probe ----------------------------------------

  def test_open_pr_returns_the_first_listed_pr
    json = JSON.generate([{ "number" => 7, "url" => "https://github.com/x/y/pull/7",
                            "isDraft" => true, "baseRefName" => "main" }])
    pr = FastLane.open_pr(json)
    assert_equal 7, pr["number"]
    assert_equal "main", pr["baseRefName"]
    assert pr["isDraft"]
  end

  def test_open_pr_is_nil_for_no_prs_or_garbage
    assert_nil FastLane.open_pr("[]")
    assert_nil FastLane.open_pr("")
    assert_nil FastLane.open_pr("not json")
    assert_nil FastLane.open_pr(JSON.generate("unexpected" => "shape"))
  end

  # --- pr_body: the task URL must LEAD the body --------------------------------

  def test_pr_body_leads_with_the_task_url
    body = FastLane.pr_body("https://mcritchie.studio/tasks/demo", ["does the thing", "  ", nil])
    lines = body.lines.map(&:chomp)
    assert_equal "https://mcritchie.studio/tasks/demo", lines.first,
                 "the review supervisor and qa-release sweep key on the task URL being line 1"
    assert_includes lines, "- does the thing"
    refute_includes lines, "- "
  end

  def test_pr_body_without_acceptance_is_just_the_url
    assert_equal "https://mcritchie.studio/tasks/demo\n",
                 FastLane.pr_body("https://mcritchie.studio/tasks/demo", [])
  end

  # --- cert_fresh?: ship's only skippable gate, fingerprint-bound --------------

  def test_cert_fresh_with_a_fresh_fast_cert
    assert FastLane.cert_fresh?(["[fast-cert@abc1234] green"], "abc1234")
  end

  def test_cert_fresh_with_a_fresh_full_pair
    checks = ["[full-suite@abc1234] tests green", "[rubocop@abc1234] lint clean"]
    assert FastLane.cert_fresh?(checks, "abc1234")
  end

  def test_cert_not_fresh_when_the_tree_moved_on
    refute FastLane.cert_fresh?(["[fast-cert@aaa1111] green"], "bbb2222"),
           "any edit changes the tree hash — a stale cert must re-arm the fast-check step"
  end

  def test_cert_not_fresh_on_a_half_full_pair
    refute FastLane.cert_fresh?(["[full-suite@abc1234] tests green"], "abc1234"),
           "the full route needs BOTH full lanes; one alone must not skip the cert"
  end

  def test_cert_not_fresh_without_evidence_or_fingerprint
    refute FastLane.cert_fresh?([], "abc1234")
    refute FastLane.cert_fresh?(["[unit] bin/rails test test/foo_test.rb"], "abc1234")
    refute FastLane.cert_fresh?(["[fast-cert@abc1234] green"], nil),
           "no fingerprint (unfingerprintable root) must never skip the cert"
  end
end
