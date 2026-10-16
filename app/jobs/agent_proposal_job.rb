# Runs a proposal the owner confirmed with `go` (AgentMessages::ProposalConfirm)
# and posts the result as the answer to that `go` message, through the one
# reply path (AgentMessageReplyJob). docs/agents/system/agent-message-loop.md,
# "Proposals and confirm".
#
# ONCE: only a `confirmed` proposal runs, and it is locked while it does, so a
# retried job finds it `executed` and does nothing. A FAILED run writes an
# ErrorLog row (targeted at the go message), puts the proposal back to
# `proposed` (a later `go` retries it), and tells the thread in one line with a
# short reason (an error class, never a message that might carry a secret).
class AgentProposalJob < ApplicationJob
  queue_as :default

  def perform(proposal_id, executor: nil)
    proposal = AgentProposal.find_by(id: proposal_id)
    return unless proposal&.status == "confirmed"

    message = proposal.confirm_message
    text = AgentProposal.transaction do
      proposal.lock!
      next nil unless proposal.status == "confirmed"

      run(proposal, message, executor || AgentProposals::Executor.new(proposal))
    end
    return if text.nil? || message.nil?

    message.update!(response_text: text, reply_status: "queued")
    AgentMessageReplyJob.perform_later(message.id)
  end

  private

  def run(proposal, message, executor)
    text, result = AgentProposal.transaction(requires_new: true) { executor.run }
    proposal.update!(status: "executed", result: result || {})
    message&.record!("proposal_executed", actor: "board", detail: { "proposal_id" => proposal.id }.merge(result.to_h.slice("task_slug", "query")))
    text
  rescue StandardError => e
    reason = e.is_a?(AgentProposals::Executor::NotEnabled) || e.is_a?(AgentProposals::Queries::Unavailable) ? e.message : e.class.name.demodulize
    log(e, message)
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
