# frozen_string_literal: true

# Structural guards on bin/pr-review's reviewer-zap SHA-safety — the invariants the review of
# teach-pr-review-reviewer-zaps required. Each is an ORDERING or an instruction-string property
# that regresses silently and that no pure-value test can pin (start_review launches real
# reviewer subprocesses; the zap-push line is prose handed to a reviewer agent). We assert them
# against the script SOURCE, so moving the capture back or dropping the pinned lease goes RED.
#
# Run directly:  ruby -Itest test/lib/pr_review_zap_safety_test.rb

require "minitest/autorun"

class PrReviewZapSafetyTest < Minitest::Test
  SRC = File.read(File.expand_path("../../bin/pr-review", __dir__))

  def start_review_body
    # From `def start_review` to its column-0 closing `end` (block ends inside are indented, so
    # the first `\nend\n` is the method's own end) — scopes the ordering check to this method.
    body = SRC[/def start_review\b.*?\nend\n/m]
    refute_nil body, "start_review body not found in bin/pr-review"
    body
  end

  # Fix 1: reviewed_head must be captured BEFORE any reviewer is launched, so it is a provable
  # lower bound on what each reviewer reads. Capturing it AFTER launch (the original bug) lets a
  # zap that lands DURING launch slip an unrevalidated head past finish_review's revalidation.
  def test_reviewed_head_is_captured_before_reviewers_launch
    body = start_review_body
    capture = body.index("reviewed_head = pr_head_oid")
    launch  = body.index("launch_reviewer(")
    refute_nil capture, "start_review must capture reviewed_head via pr_head_oid"
    refute_nil launch,  "start_review must launch reviewers via launch_reviewer"
    assert capture < launch,
           "reviewed_head must be captured BEFORE launch_reviewer (a lower bound on the reviewed head)"
  end

  # Fix 2: the merge must be pinned to the validated head. bin/pr-review builds the merge argv
  # through MergeCommand (unit-tested separately) — assert the wiring is present, not a bare
  # unpinned `gh_write("pr", "merge", ...)`.
  def test_merge_is_built_through_the_pinned_merge_command
    assert_includes SRC, "MergeCommand.args(pr_url, merge_head)",
                    "merge_feature_pr must build its argv through MergeCommand (the --match-head-commit pin)"
  end

  # Fix 3: the reviewer-zap push must use an EXPLICIT pinned lease (=ref:sha), never a bare
  # --force-with-lease that trusts a stale tracking ref and could clobber a sibling zap.
  def test_reviewer_zap_uses_an_explicit_pinned_lease
    assert_includes SRC, "--force-with-lease=refs/heads/",
                    "the zap push must pin the lease to an explicit =ref:sha"
    refute_match(/--force-with-lease\s+origin/, SRC,
                 "a BARE --force-with-lease (no =ref:sha) can clobber a sibling zap that landed first")
  end
end
