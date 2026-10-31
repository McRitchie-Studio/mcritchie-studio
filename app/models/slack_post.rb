# One post the hub made, or declined to make, on a chat medium: the outbound
# ledger the noise caps count from (Media::Limits, config/agent_media.yml
# `limits:`). Slack's and Microsoft Teams' rows share it, told apart by
# `medium` (the table keeps its Slack name). Media::Slack and Media::Teams write
# every row, through Media::OnceDelivery: #post for a standalone post,
# #deliver_reply for an agent's answer. Nothing else writes here.
#
#   medium   slack | teams (default slack: every row before Teams)
#   channel_id, thread_ts, ts   the medium's channel, thread root and message
#            ids (Slack: C…, a thread ts, a ts; Teams: the channel's
#            conversation id, the root message id, the activity id)
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
  MEDIA = %w[slack teams].freeze
  KINDS = %w[post reply release].freeze
  STATUSES = %w[sending posted suppressed failed].freeze
  AMBIGUOUS = "ambiguous:".freeze

  validates :medium, inclusion: { in: MEDIA }
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
