# frozen_string_literal: true

# Runs one ARMED MERGE through Review::PendingActionExecutor. Two callers:
#
#   * the CI WEBHOOK (GithubWorkflowRunIngestJob → ReviewPendingAction
#     .trigger_for_head) — the fast path, firing the moment a run settles on the
#     pinned tree. `recheck: false`: this is a one-shot, and it must not start a
#     retry chain of its own or every delivery would fork another.
#
#   * the ARM itself (`recheck: true`) — starts the ONE self-rescheduling chain
#     that carries the action to its conclusion. It exists because the webhook
#     alone is not enough: CI can settle green BEFORE the reviewer arms (no
#     further delivery is ever coming), a delivery can be dropped, and the
#     live-reviewer guard can hold an action back until a lease lapses — a moment
#     no webhook announces. The chain re-checks the BOARD's own rows, never
#     GitHub, so a waiting action costs a couple of indexed reads.
#
# The chain is self-limiting: it stops the moment the action leaves `pending`,
# and an action that never goes green is settled `expired` by the executor's own
# expiry guard, which ends the chain by definition. Nothing here decides
# anything — every guard lives in the executor.
class ReviewPendingActionExecutionJob < ApplicationJob
  # Backstop cadence. The webhook is the fast path (the failure this exists for
  # settled in eighty seconds); this only has to be faster than a human noticing.
  RECHECK_INTERVAL = 2.minutes

  def perform(action_id, recheck: false)
    action = ReviewPendingAction.find_by(id: action_id)
    return if action.nil?

    result = Review::PendingActionExecutor.call(action)
    return unless recheck

    # Keep the chain alive only while the action could still succeed. `:error` is
    # included deliberately — a GitHub blip must not strand an authorised merge.
    return unless result.waiting? || result.status == :error

    action.reload
    return unless action.pending?
    return if action.expired?

    self.class.set(wait: RECHECK_INTERVAL).perform_later(action_id, recheck: true)
  end
end
