# A Microsoft Teams conversation reference: a place the bot may post on its own
# (docs/agents/system/agent-message-loop.md, "Teams"). A proactive post needs
# the conversation's serviceUrl and id, which only an activity from that place
# carries, so AgentMessages::TeamsIngest records one from the install
# (conversationUpdate with the bot in membersAdded, installationUpdate add), a
# channelCreated event, and every message the bot reads, refreshing serviceUrl.
#
#   conversation_id   the channel's conversation id (19:…@thread.tacv2, never
#                     with ;messageid=), a group chat's, or a personal chat's (a:…)
#   conversation_type channel | groupChat | personal
#   service_url       the base URI the Bot Connector calls go to
#   status            installed | removed (the bot was removed: never posted to)
class TeamsConversation < ApplicationRecord
  STATUSES = %w[installed removed].freeze

  validates :conversation_id, presence: true, uniqueness: true
  validates :service_url, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :installed, -> { where(status: "installed") }

  # Upserts the reference for `conversation_id` from what an activity carried,
  # keeping known fields an activity left out. Answers the row.
  def self.remember!(conversation_id:, service_url:, status: nil, **attrs)
    row = find_or_initialize_by(conversation_id: conversation_id.to_s)
    row.assign_attributes(attrs.compact_blank.merge(service_url: service_url.to_s, last_activity_at: Time.current))
    row.status = status if status
    row.save!
    row
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def installed? = status == "installed"
end
