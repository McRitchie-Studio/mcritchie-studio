# Runs a proposal the owner confirmed with `go` (AgentMessages::ProposalConfirm)
# and posts the result as the answer to that `go` message, through the one
# reply path (AgentMessageReplyJob). docs/agents/system/agent-message-loop.md,
# "Proposals and confirm".
#
# THREE STEPS, so no row lock is held across the run (an ask may fetch a
# satellite's health report over HTTP):
#   1. CLAIM under the proposal's row lock: only a `confirmed` proposal with no
#      live claim is taken, and the claim (a token and a time, in `result`)
#      commits at once.
#   2. RUN outside any lock: the executor's query or task.
#   3. SETTLE under the lock again, only while the claim is still this job's:
#      `executed`, or back to `proposed` on a failure.
# ONCE: a retried or duplicate job finds the proposal claimed or `executed` and
# does nothing. A claim older than CLAIM_TTL (a worker that died mid-run) may be
# taken again, so a crash never strands a confirmed proposal.
#
# A FAILED run writes an ErrorLog row (targeted at the go message), puts the
# proposal back to `proposed` (a later `go` retries it), and tells the thread in
# one line with a short reason (an error class, never a message that might
# carry a secret).
class AgentProposalJob < ApplicationJob
  queue_as :default

  CLAIM_TTL = 10.minutes

  def perform(proposal_id, executor: nil)
    proposal = AgentProposal.find_by(id: proposal_id)
    return unless proposal&.status == "confirmed"

    token = claim(proposal)
    return if token.nil?

    message = proposal.confirm_message
    outcome = begin
      [ :ok, (executor || AgentProposals::Executor.new(proposal)).run ]
    rescue StandardError => e
      [ :failed, e ]
    end
    text = settle(proposal, token, message, outcome)
    return if text.nil? || message.nil?

    message.update!(response_text: text, reply_status: "queued")
    AgentMessageReplyJob.perform_later(message.id)
  end

  private

  # The claim token, or nil when the proposal is not ours to run.
  def claim(proposal, now: Time.current)
    AgentProposal.transaction do
      proposal.lock!
      next nil unless proposal.status == "confirmed"

      stamp = proposal.result.to_h["claimed_at"].to_s
      claimed_at = stamp.present? ? Time.zone.parse(stamp) : nil
      next nil if claimed_at && claimed_at > now - CLAIM_TTL

      token = SecureRandom.hex(8)
      proposal.update!(result: { "claim" => token, "claimed_at" => now.iso8601 })
      token
    end
  end

  # The text to post, or nil when the claim was lost (another job settled it).
  def settle(proposal, token, message, outcome)
    AgentProposal.transaction do
      proposal.lock!
      next nil unless proposal.status == "confirmed" && proposal.result.to_h["claim"] == token

      kind, value = outcome
      kind == :ok ? executed(proposal, message, *value) : failed(proposal, message, value)
    end
  end

  def executed(proposal, message, text, result)
    proposal.update!(status: "executed", result: result || {})
    message&.record!("proposal_executed", actor: "board", detail: { "proposal_id" => proposal.id }.merge(result.to_h.slice("task_slug", "query")))
    text
  end

  def failed(proposal, message, error)
    reason = error.is_a?(AgentProposals::Executor::NotEnabled) || error.is_a?(AgentProposals::Queries::Unavailable) ? error.message : error.class.name.demodulize
    log(error, message)
    proposal.update!(status: "proposed", confirm_message: nil, settled_at: nil, settled_by: nil,
                     result: { "error" => reason.to_s[0, 200] })
    message&.record!("proposal_failed", actor: "board", detail: { "proposal_id" => proposal.id, "reason" => reason.to_s[0, 200] })
    "That did not run (#{reason.to_s[0, 200]}). The proposal is still open: reply **go** to try again, or **no** to drop it."
  end

  def log(error, message)
    entry = ErrorLog.capture!(error)
    entry.update(target: message, target_name: "agent proposal for message #{message&.id}") if message
  rescue StandardError => e
    Rails.logger.warn("[agent-proposal] could not write ErrorLog: #{e.class}")
  end
end
