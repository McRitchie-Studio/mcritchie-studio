# One step in an AgentMessage's life, for the timeline on /admin/agent_messages
# and `bin/agent-inbox show`: received, routed/unrouted, claimed, lease_expired,
# released, dead_lettered, completed, reply_posted, reply_failed,
# reply_bot_refused (a soul's own Discord bot refused; the shared bot answered),
# typing_bot_refused (the same for the "typing…" pulse, AgentMessageTypingJob), held and
# hold_released (the owner-only guard, AgentMessages::Answerers), and
# lease_renewed (one per claim, its count updated in place), and the proposal
# loop (AgentProposal): proposed, proposal_refused, confirmed, confirm_refused,
# proposal_rejected, proposal_expired, proposal_closed (a word on a proposal no longer open),
# proposal_executed, proposal_failed, the usage meter (AgentUsage): usage_warned
# (the claim was past the warn share) and usage_capped (answered in code at the cap),
# and rate_limited (an email thread past AgentMessages::EmailIngest::RATE_LIMIT; the row is held).
class AgentMessageEvent < ApplicationRecord
  KINDS = %w[received routed unrouted claimed lease_renewed lease_expired released dead_lettered
             completed reply_posted reply_skipped reply_failed reply_bot_refused typing_bot_refused held hold_released
             proposed proposal_refused confirmed confirm_refused proposal_rejected proposal_expired proposal_closed
             proposal_executed proposal_failed usage_warned usage_capped rate_limited].freeze

  belongs_to :agent_message

  validates :kind, inclusion: { in: KINDS }

  def as_api_json
    slice(:id, :kind, :actor, :detail, :created_at).as_json
  end
end
