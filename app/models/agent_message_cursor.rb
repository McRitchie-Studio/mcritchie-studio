# Where the poll last read one source (a Discord channel id): the newest message
# id it has durably stored. Advanced in the same transaction as the rows it
# covers, so a poll that dies mid-page re-reads that page rather than skipping it
# (and the unique index makes the re-read harmless).
class AgentMessageCursor < ApplicationRecord
  validates :channel, inclusion: { in: AgentMessage::CHANNELS }
  validates :source_ref, presence: true, uniqueness: { scope: :channel }

  def self.for(channel, source_ref)
    find_or_create_by!(channel: channel, source_ref: source_ref.to_s)
  rescue ActiveRecord::RecordNotUnique
    find_by!(channel: channel, source_ref: source_ref.to_s)
  end
end
