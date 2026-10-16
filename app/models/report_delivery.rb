# One ReportDestinations.deliver call's receipt, keyed by the caller's
# idempotency_key (unique). A `posted` row is final: the same key never posts
# again. Any other status (not_configured, disabled, failed) is retried in place
# by the next deliver with that key (docs/agents/system/report-destinations.md).
class ReportDelivery < ApplicationRecord
  STATUSES = %w[pending posted not_configured disabled failed].freeze
  # Which bot posted it (AgentMessages::BotSelector): a CTO soul's own bot or
  # the shared agents' bot. nil before it posts, and on rows from before it was recorded.
  POSTED_VIA = [ AgentMessages::BotSelector::SOUL, AgentMessages::BotSelector::SHARED ].freeze

  belongs_to :discord_channel, optional: true

  validates :report_key, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :posted_via, inclusion: { in: POSTED_VIA }, allow_nil: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def posted? = status == "posted"

  def url
    return nil if message_external_id.blank? || guild_external_id.blank? || channel_external_id.blank?

    "https://discord.com/channels/#{guild_external_id}/#{channel_external_id}/#{message_external_id}"
  end
end
