# frozen_string_literal: true

require "minitest/autorun"

# THE REVIEWER HALF'S WIRING (/tasks/review-guards-stacked-prs).
#
# merge_feature_pr used to read baseRefName, retarget ANY non-`accepted` base, and merge one
# line later. Measured 2026-09-13: turf #701 was stacked on turf #624 while #624 was HELD for
# a credential rotation, so popping #701 would have put the held signing-key change on
# `accepted`. `--match-head-commit` cannot catch it, because retargeting moves what the PR
# MERGES while the head stays exactly where the reviewer validated it.
#
# WHAT THIS FILE CAN AND CANNOT PROVE, stated because it decided the design. bin/pr-review has
# no execution harness — every test of it reads its SOURCE — and a source test CANNOT see a
# disabled branch: a mutant that replaced the refusal's condition with `if false` left the
# refusal text sitting in dead code and every assertion here green. So the decision does not
# live in the script any more. It lives in StackedPr.guard_base, where test/lib/
# stacked_pr_test.rb drives it with a SPY writer and asserts that a stack retargets NOTHING.
# This file pins only the wiring: that the script asks that function and honours its answer.
class PrReviewStackedBaseTest < Minitest::Test
  SRC = File.read(File.expand_path("../../bin/pr-review", __dir__))

  def merge_body
    body = SRC[/def merge_feature_pr\b.*?\nend\n/m]
    refute_nil body, "merge_feature_pr body not found in bin/pr-review"
    body
  end

  def test_the_base_decision_goes_through_the_shared_guard
    assert_includes merge_body, "StackedPr.guard_base",
                    "merge_feature_pr must ask the SAME guard bin/ship asks — the reviewer half of this " \
                    "bug existed because the two answered the base question separately"
  end

  # The answer has to be HONOURED, not merely asked for: anything but a clean proceed or a
  # completed retarget leaves the task submitted.
  def test_only_a_proceed_or_a_retarget_continues_to_the_merge
    body = merge_body
    assert_match(/return false unless %i\[proceed retargeted\]\.include\?\(outcome\)/, body,
                 "a refusal (or a failed retarget) must stop merge_feature_pr before it merges")
    guard = body.index("StackedPr.guard_base")
    merge = body.index("MergeCommand.args(pr_url, merge_head)")
    refute_nil merge, "merge_feature_pr must still build its pinned merge argv"
    assert guard < merge, "the base guard must run BEFORE the merge argv is built"
  end

  # The retarget still exists for the mis-based case — the fix must not become "never retarget".
  # THE FAILED BASE READ IS HANDED DOWN, not acted on here. It used to gate the whole block,
  # so a failed read skipped the base check entirely and merged — and no test could see it,
  # because a source test cannot watch a branch that never runs (/tasks/review-refuses-unread-base).
  def test_the_base_read_result_is_handed_to_the_guard_rather_than_gating_it
    body = merge_body
    assert_match(/base_read_ok: base_ok/, body,
                 "the read result must be JUDGED in the lib, where a spy can drive it")
    refute_match(/if base_ok\n/, body,
                 "gating the block on base_ok is what let a failed read merge unchecked")
    assert_match(/repo_scope: repo_slug/, body,
                 "the probe's repo scope is the caller's fact too, and a blank one must refuse")
  end

  def test_the_repair_arm_is_still_wired
    assert_match(/gh_write\("pr", "edit", pr_url, "--base", ACCEPTED_BRANCH\)/, merge_body,
                 "a merged parent, a closed one, a deleted branch, release and main still self-heal")
  end

  def test_the_probe_is_repo_scoped
    # pr-review reviews PRs in OTHER repos by URL; `gh pr list` has no URL to key on, so the
    # probe must carry --repo or it would ask the hub about a turf branch and answer "no open
    # PR has that head" — silently converting every satellite stack into a retarget.
    assert_match(/--repo/, merge_body, "the parent probe must be scoped to the PR's own repo")
    assert_match(/repo_slug = pr_url/, merge_body,
                 "…derived from the PR url this function already holds, not from the cwd")
  end
end
