# frozen_string_literal: true

# ZapRevalidation — the pre-merge decision that HOSTS reviewer-applied zaps
# (task teach-pr-review-reviewer-zaps; the Reviewer seam in
# docs/agents/modules/zap-protocol.md).
#
# A reviewer may push a bounded `zap:` fix to the PR branch WHILE reviewing it, so on a
# merge-ready verdict the head the supervisor is about to merge may NOT be the head the
# reviewers approved. bin/pr-review captures the head at review-read time and re-reads it
# here before merging. This decision is PURE — no gh/CI I/O — so every branch is unit-
# tested directly against a synthetic (reviewed_head, current_head, ci_state):
#
#   head UNCHANGED (or unknowable) -> :merge              the ordinary path.
#   head ADVANCED + its CI :green  -> :merge_after_zap    the zapped head's OWN CI vouches
#                                                         for the content the reviewers
#                                                         did not see.
#   head ADVANCED + CI not :green  -> :hold_for_rereview  NEVER merge a head the reviewers
#                                                         did not see on a non-green CI —
#                                                         hold it for the next wave to
#                                                         re-review the zapped head.
#
# Fail CLOSED on the non-green branch: red, pending, none, AND unverified all hold — only
# a positive :green releases the zapped head. A nil reviewed_head (an older run that
# captured none, or a gh read fault) merges: the revalidation only ever ADDS a hold, it
# never removes the pre-existing merge path.
module ZapRevalidation
  module_function

  def decide(reviewed_head, current_head, current_ci_state)
    return :merge if reviewed_head.nil? || current_head.nil? || current_head == reviewed_head
    return :merge_after_zap if current_ci_state == :green

    :hold_for_rereview
  end
end
