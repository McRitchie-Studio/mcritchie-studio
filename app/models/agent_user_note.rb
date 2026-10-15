# Notes an agent keeps about one person it talks to, keyed by where that person
# speaks: (channel, author_ref), author_ref being the provider's author id (a
# Discord user snowflake). docs/agents/system/agent-message-loop.md, "Memory".
#
# The answer path only READS a note: AgentMessages::ThreadLedger puts it in the
# context bundle and the worker's ContextBuilder renders it as the USER layer,
# inside the untrusted fence (a note is written from what that person said, so it
# is data, never instructions). Writing notes is a later task (agent-respond-sop).
class AgentUserNote < ApplicationRecord
  validates :channel, inclusion: { in: AgentMessage::CHANNELS }
  validates :author_ref, presence: true, uniqueness: { scope: :channel }

  def self.for_author(channel:, author_ref:)
    return nil if author_ref.blank?

    find_by(channel: channel, author_ref: author_ref)
  end

  def as_api_json
    { "display_name" => display_name, "notes" => notes.to_s, "updated_at" => updated_at&.iso8601 }
  end
end
