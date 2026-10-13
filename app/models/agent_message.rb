# One inbound message to an agent: the agent mailbox's row
# (docs/agents/system/agent-message-loop.md).
#
# A poll (AgentMessages::DiscordPoll) writes it, routed to a soul or stored
# `unrouted`. A worker (`bin/heartbeat <soul>`) claims it under a lease, answers,
# and completes it; AgentMessageReplyJob posts the answer back exactly once.
#
#   received ──claim──▶ claimed ──complete──▶ completed
#      ▲                  │  └─lease lapses, attempts < cap──▶ claimable again
#      └────release───────┘  └─lease lapses, attempts = cap──▶ dead
#   unrouted: stored, never claimable (no soul was addressed)
#
# THE LEASE LIVES ON THE ROW (claimed_by, lease_expires_at), as lib/claim_lease.rb's
# leases do: a worker that dies holding a message loses it when the lease lapses,
# with no sweeper. Unlike those leases nothing renews it: one message is one unit of
# work, and LEASE is sized to cover a headless Claude run with room to spare.
#
# THE CONTENT IS UNTRUSTED. It came from whoever can post in an allow-listed
# channel; a worker hands it to a model fenced as data, never as instructions.
class AgentMessage < ApplicationRecord
  CHANNELS = %w[discord].freeze
  STATUSES = %w[received claimed completed dead unrouted].freeze
  # Statuses a thread waits on: an older message in one of these holds the
  # thread's newer messages back, so a conversation is answered in order.
  OPEN_STATUSES = %w[received claimed].freeze
  ROUTED_BY = %w[user role thread default none].freeze
  REPLY_STATUSES = %w[queued posted skipped failed].freeze

  # How long a claim holds before another worker may take the message. A
  # heartbeat run (one read-only action plus one headless Claude call, capped at
  # bin/heartbeat's CLAUDE_TIMEOUT of 5 minutes) fits twice over.
  LEASE = 10.minutes
  # Claims a message may take before it is dead-lettered. Each claim counts, so a
  # message whose worker crashes three times stops being handed out.
  MAX_ATTEMPTS = 3

  ClaimResult = Struct.new(:message, :reason, keyword_init: true)

  class Refused < StandardError
    attr_reader :code

    def initialize(message, code:)
      super(message)
      @code = code
    end
  end

  has_many :events, -> { order(:id) }, class_name: "AgentMessageEvent", dependent: :delete_all

  validates :channel, inclusion: { in: CHANNELS }
  validates :external_id, :channel_ref, :thread_key, presence: true
  validates :external_id, uniqueness: { scope: :channel }
  validates :status, inclusion: { in: STATUSES }
  validates :routed_by, inclusion: { in: ROUTED_BY }, allow_nil: true
  validates :soul_slug, presence: true, unless: :unrouted?
  validates :attempts, numericality: { greater_than_or_equal_to: 0 }
  validates :reply_status, inclusion: { in: REPLY_STATUSES }, allow_nil: true

  scope :newest_first, -> { order(id: :desc) }
  scope :for_soul, ->(soul) { where(soul_slug: soul) }
  scope :with_status, ->(status) { where(status: status) }
  scope :on_channel, ->(channel) { where(channel: channel) }

  # Messages a worker for `soul` may take now: received, or claimed under a lapsed
  # lease with attempts left, AND the oldest open message in its thread.
  #
  # The thread rule is what keeps a conversation ordered, and it is written as
  # "no OLDER open message in this thread" rather than "no LIVE claim in this
  # thread" on purpose. Under FOR UPDATE SKIP LOCKED a racer skips the row its
  # rival has locked but not yet committed, and would then see that row still
  # `received`, find no live claim, and take the NEXT message in the same thread.
  # "No older open message" refuses that, because the locked row is still older
  # and still open. It also yields at most one active claim per thread for free.
  def self.claimable(soul:, now: Time.current, channel: nil)
    scope = where(soul_slug: soul)
            .where("agent_messages.status = 'received' OR " \
                   "(agent_messages.status = 'claimed' AND agent_messages.lease_expires_at < :now " \
                   "AND agent_messages.attempts < :cap)", now: now, cap: MAX_ATTEMPTS)
            .where(<<~SQL.squish)
              NOT EXISTS (SELECT 1 FROM agent_messages older
                          WHERE older.thread_key = agent_messages.thread_key
                            AND older.id < agent_messages.id
                            AND older.status IN ('received', 'claimed'))
            SQL
    scope = scope.where(channel: channel) if channel.present?
    scope.order(:id)
  end

  # THE ATOMIC CLAIM: at most one message per call, never one another worker holds.
  #
  # One transaction: dead-letter the exhausted leases, then select the oldest
  # claimable row FOR UPDATE SKIP LOCKED and stamp the lease. Two workers calling
  # at once never block each other and never get the same row; the loser of a
  # race gets nothing (an empty claim is a normal answer, the caller idles).
  def self.claim!(soul:, worker:, now: Time.current, channel: nil, actor: nil)
    worker = worker.to_s.strip
    soul = soul.to_s.strip
    raise Refused.new("worker is required", code: "WORKER_REQUIRED") if worker.empty?
    raise Refused.new("soul is required", code: "SOUL_REQUIRED") if soul.empty?

    transaction do
      dead_letter_exhausted!(now: now)
      message = claimable(soul: soul, now: now, channel: channel).lock("FOR UPDATE SKIP LOCKED").first
      next ClaimResult.new(message: nil, reason: "nothing_waiting") unless message

      reclaim = message.status == "claimed"
      prior = message.claimed_by
      message.update!(status: "claimed", claimed_by: worker, claimed_at: now,
                      lease_expires_at: now + LEASE, attempts: message.attempts + 1)
      if reclaim
        message.record!("lease_expired", actor: prior, detail: { "reclaimed_by" => worker })
      end
      message.record!("claimed", actor: actor || soul,
                                 detail: { "worker" => worker, "attempt" => message.attempts,
                                           "lease_expires_at" => message.lease_expires_at.iso8601 })
      ClaimResult.new(message: message, reason: "claimed")
    end
  end

  # Claimed rows whose lease lapsed on their last attempt are done being retried.
  # Called inside claim!'s transaction: the rows are locked SKIP LOCKED before the
  # UPDATE, so two concurrent sweeps dead-letter (and record) each row once.
  def self.dead_letter_exhausted!(now: Time.current)
    ids = where(status: "claimed").where("lease_expires_at < ?", now).where("attempts >= ?", MAX_ATTEMPTS)
          .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
    return ids if ids.empty?

    where(id: ids).update_all(status: "dead", updated_at: now)
    ids.each do |id|
      AgentMessageEvent.create!(agent_message_id: id, kind: "dead_lettered", actor: "system",
                                detail: { "reason" => "lease lapsed on attempt #{MAX_ATTEMPTS} of #{MAX_ATTEMPTS}" },
                                created_at: now)
    end
    ids
  end

  # Record the worker's answer and queue the reply. Guarded by state: only the
  # worker holding the claim completes it, and a second complete by that worker
  # is a no-op that queues nothing, so the reply is posted once however often a
  # worker retries the call. Returns :completed or :already_completed.
  def complete!(worker:, response_text:, action_summary: nil, actor: nil, now: Time.current)
    worker = worker.to_s.strip
    raise Refused.new("response_text is required", code: "RESPONSE_REQUIRED") if response_text.to_s.strip.empty?

    outcome = self.class.transaction do
      lock!
      if status == "completed" && claimed_by == worker
        next :already_completed
      end
      unless status == "claimed" && claimed_by == worker && worker.present?
        raise Refused.new(holder_refusal("complete"), code: "NOT_HOLDER")
      end

      update!(status: "completed", completed_at: now, lease_expires_at: nil,
              response_text: response_text.to_s, action_summary: action_summary.presence,
              reply_nonce: reply_nonce.presence || "agentmsg-#{id}", reply_status: "queued")
      record!("completed", actor: actor || soul_slug,
                           detail: { "worker" => worker, "action_summary" => action_summary.presence }.compact)
      :completed
    end
    AgentMessageReplyJob.perform_later(id) if outcome == :completed
    outcome
  end

  # A worker gives the message back: it returns to `received` for the next claim.
  # The attempt it used still counts toward MAX_ATTEMPTS: a give-back on the last
  # attempt dead-letters, since `received` rows are claimable at any attempt count.
  def release!(worker:, reason: nil, actor: nil, now: Time.current)
    worker = worker.to_s.strip
    self.class.transaction do
      lock!
      unless status == "claimed" && claimed_by == worker && worker.present?
        raise Refused.new(holder_refusal("release"), code: "NOT_HOLDER")
      end

      exhausted = attempts >= MAX_ATTEMPTS
      update!(status: exhausted ? "dead" : "received", claimed_by: nil, claimed_at: nil, lease_expires_at: nil)
      record!("released", actor: actor || soul_slug, detail: { "worker" => worker, "reason" => reason.presence }.compact)
      if exhausted
        record!("dead_lettered", actor: "system",
                                 detail: { "reason" => "given back on attempt #{attempts} of #{MAX_ATTEMPTS}" })
      end
    end
    self
  end

  def record!(kind, actor: nil, detail: {})
    events.create!(kind: kind, actor: actor, detail: detail, created_at: Time.current)
  end

  def unrouted? = status == "unrouted"
  def claimed? = status == "claimed"

  def lease_live?(now: Time.current)
    claimed? && lease_expires_at.present? && lease_expires_at > now
  end

  # The Discord link to a message this row names (its own, or the reply).
  def discord_url(message_id = external_id)
    return nil unless channel == "discord" && guild_id.present? && message_id.present?

    "https://discord.com/channels/#{guild_id}/#{channel_ref}/#{message_id}"
  end

  def reply_url = reply_external_id.present? ? discord_url(reply_external_id) : nil

  # The JSON the API and bin/agent-inbox read.
  def as_api_json(events: false)
    data = slice(:id, :channel, :external_id, :guild_id, :channel_ref, :thread_key, :author_ref, :author_name,
                 :content, :mentions, :soul_slug, :routed_by, :status, :claimed_by, :claimed_at,
                 :lease_expires_at, :attempts, :response_text, :action_summary, :reply_external_id, :reply_status,
                 :reply_posted_at, :completed_at, :sent_at, :created_at, :updated_at).as_json
    data["url"] = discord_url
    data["reply_url"] = reply_url
    data["events"] = self.events.map(&:as_api_json) if events
    data
  end

  private

  def holder_refusal(verb)
    holder = claimed_by.present? ? "held by #{claimed_by}" : "not claimed"
    "message #{id} is #{status} (#{holder}); only the worker holding the claim may #{verb} it"
  end
end
