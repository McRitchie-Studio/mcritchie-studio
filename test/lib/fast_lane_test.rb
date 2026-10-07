# frozen_string_literal: true

# [unit] Pure-logic tests for bin/lib/fast_lane.rb — the skip/resume decisions
# behind the fast-lane wrappers (`bin/task begin`, `bin/submit`). The wrappers'
# orchestration is exercised end-to-end in test/lib/task_begin_test.rb and
# test/lib/submit_test.rb; THIS file pins the decisions those runs depend on.
# Run directly:
#   ruby -Itest test/lib/fast_lane_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/fast_lane"

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

  # [unit] The push-retry decision for ship-handles-rebased-branch: a
  # non-fast-forward rejection (a rebased branch) earns a --force-with-lease
  # retry; every OTHER failure must NOT (never force over auth/network/foreign).
  def test_push_rejected_non_fast_forward_classifies_git_output
    assert FastLane.push_rejected_non_fast_forward?(
      "! [rejected]        feat/x -> feat/x (non-fast-forward)\nerror: failed to push some refs"
    ), "a real rebase rejection must be recognized"
    assert FastLane.push_rejected_non_fast_forward?("hint: Updates were rejected (fetch first)"),
           "the (fetch first) shape counts too"
    refute FastLane.push_rejected_non_fast_forward?("fatal: Authentication failed for 'origin'"),
           "an auth failure is NOT a rebase — must not be force-pushed"
    refute FastLane.push_rejected_non_fast_forward?("fatal: unable to access ... Could not resolve host"),
           "a network failure is NOT a rebase"
    refute FastLane.push_rejected_non_fast_forward?("")
    refute FastLane.push_rejected_non_fast_forward?(nil)
  end
end
