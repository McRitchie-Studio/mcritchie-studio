# One step in an AgentMessage's life, for the timeline on /admin/agent_messages
# and `bin/agent-inbox show`: received, routed/unrouted, claimed, lease_expired,
# released, dead_lettered, completed, reply_posted, reply_failed.
class AgentMessageEvent < ApplicationRecord
  KINDS = %w[received routed unrouted claimed lease_expired released dead_lettered
             completed reply_posted reply_skipped reply_failed].freeze

  belongs_to :agent_message

  validates :kind, inclusion: { in: KINDS }

  def as_api_json
    slice(:id, :kind, :actor, :detail, :created_at).as_json
  end
end
