# One post the hub made, or declined to make, on Slack: the outbound ledger the
# noise caps count from (Media::Slack::Limits, config/agent_media.yml `limits:`).
# Media::Slack writes every row: #post for a standalone post, #deliver_reply for
# an agent's answer. Nothing else writes here.
#
#   kind     post     a standalone post (a home's channel: notes, alerts)
#            reply    an agent's answer to a message (AgentMessageReplyJob)
#            release  a release post: the #general summary, an app
#                     channel's post, or its smoke verdict
#                     (ReleaseNotes::SlackAnnouncement). Exempt from the hourly
#                     cap, still counted by it.
#   status   sending     written BEFORE chat.postMessage; a row left here was a
#                        crashed attempt and is never re-posted
#            posted      Slack took it (ts set)
#            suppressed  over a cap; `reason` says which; never retried
#            failed      Slack refused it, or it may have posted (`reason`
#                        starts "ambiguous:"); an ambiguous one is never retried
#
# idempotency_key (unique) makes a keyed post exactly once across re-runs: a
# release post is keyed release:<slug>:<channel>:<what>.
class SlackPost < ApplicationRecord
  KINDS = %w[post reply release].freeze
  STATUSES = %w[sending posted suppressed failed].freeze
  AMBIGUOUS = "ambiguous:".freeze

  validates :channel_id, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  scope :posted, -> { where(status: "posted") }
  scope :by_agent, -> { where.not(soul_slug: [ nil, "" ]) }

  # A row that must never be posted again: posted, suppressed, still sending
  # (a crashed attempt may have posted), or failed ambiguously.
  def final?
    %w[posted suppressed sending].include?(status) || ambiguous?
  end

  def ambiguous? = status == "failed" && reason.to_s.start_with?(AMBIGUOUS)
end
