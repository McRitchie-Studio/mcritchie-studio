# One inbound message to an agent: the agent mailbox's row
# (docs/agents/system/agent-message-loop.md).
#
# DiscordIngest writes it, from the Gateway listener (AgentMessages::DiscordGateway)
# or the backstop poll (AgentMessages::DiscordPoll), only when it is addressed:
# routed to a soul, or kept `unrouted` as a reply to a held message that named none.
# A worker (`bin/dispatcher`, or `bin/heartbeat <soul>` by hand) claims it under a
# lease, answers, and completes it; AgentMessageReplyJob posts the answer back exactly once.
#
#   received ──claim──▶ claimed ──complete──▶ completed
#      ▲                  │  └─lease lapses, attempts < cap──▶ claimable again
#      └────release───────┘  └─lease lapses, attempts = cap──▶ dead
#   unrouted: stored, never claimable (a reply to a held message that named no soul)
#
# THE LEASE LIVES ON THE ROW (claimed_by, lease_expires_at), as lib/claim_lease.rb's
# leases do: a worker that dies holding a message loses it when the lease lapses,
# with no sweeper. The holder may RENEW it (renew!): bin/dispatcher renews every
# few minutes while its run lives, so a long run keeps its claim and a dead one
# still loses it within LEASE.
#
# THE CONTENT IS UNTRUSTED. It came from whoever can post in a listed guild; a worker hands it to a model fenced as data, never as instructions.
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
  # the Responder's CLAUDE_TIMEOUT of 5 minutes) fits twice over, and bin/dispatcher
  # renews it every 3 minutes while a run lives.
  LEASE = 10.minutes
  # Claims a message may take before it is dead-lettered. Each claim counts, so a
  # message whose worker crashes three times stops being handed out.
  MAX_ATTEMPTS = 3
  # Release reasons that hand the attempt BACK (attempts - 1) and never
  # dead-letter: the run never reached the message's own fault. Only
  # usage_limit, which bin/dispatcher sends when its deterministic matcher
  # (AgentMailbox::UsageLimit) reads Claude's usage-limit answer. The account
  # being out of quota says nothing about the message, so it must not burn it.
  REFUND_CODES = %w[usage_limit].freeze
  # Refunds a message may take before a refund-code release spends the attempt
  # like any other. The cap is the board's, not the worker's: a worker that
  # misreads Claude (or a reply crafted to look like a limit) cannot keep a
  # message alive forever.
  MAX_REFUNDS = 3

  # Caps on what a worker reports about its Claude run (complete!'s `run`).
  RUN_LIMITS = { claude_session_id: 100, claude_cwd: 500, reasoning: 20_000 }.freeze
  RUN_META_KEYS = %w[thinking_tokens output_tokens num_turns duration_ms model reasoning_source].freeze

  ClaimResult = Struct.new(:message, :reason, keyword_init: true)

  class Refused < StandardError
    attr_reader :code

    def initialize(message, code:)
      super(message)
      @code = code
    end
  end

  has_many :events, -> { order(:id) }, class_name: "AgentMessageEvent", dependent: :delete_all
  # Who wrote it, across platforms (AgentPerson): stamped at create from
  # (channel, author_ref), so every stored message with an author resolves to a
  # person. A row with no author_ref has none.
  belongs_to :person, class_name: "AgentPerson", optional: true, inverse_of: :messages

  before_create :resolve_person

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
  #
  # The same rule holds per PERSON per soul (AgentMessages::MemoryBundle): a
  # person's second message to a soul waits for their first to be answered, on
  # any channel and even when the two are not a reply chain, so the second
  # answer's context always carries the first exchange. A row with no person (no
  # author_ref) is not held back by this rule.
  #
  # `soul` is one slug or a list (bin/dispatcher serves every routed soul in one
  # claim); across souls the oldest message still goes first.
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
            .where(<<~SQL.squish)
              (agent_messages.person_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM agent_messages earlier
                WHERE earlier.soul_slug = agent_messages.soul_slug
                  AND earlier.person_id = agent_messages.person_id
                  AND earlier.id < agent_messages.id
                  AND earlier.status IN ('received', 'claimed')))
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
    soul = Array(soul).map { |s| s.to_s.strip }.reject(&:empty?).uniq
    raise Refused.new("worker is required", code: "WORKER_REQUIRED") if worker.empty?
    raise Refused.new("soul is required", code: "SOUL_REQUIRED") if soul.empty?

    soul = soul.first if soul.one?

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
      message.record!("claimed", actor: actor || message.soul_slug,
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
  #
  # `run` carries what the answering Claude run reported (claude_session_id,
  # claude_cwd, reasoning, run_meta), stored for /admin/agent_messages/:id and
  # bin/agent-inbox show; RUN_LIMITS caps each field, so a worker cannot flood the row.
  #
  # `notes` are the facts the run returned about the sender (the worker split them
  # off the reply). They are filed under THIS message's person and nobody else's
  # (AgentPersonNote.record_from! validates, dedupes and caps them), and only on
  # the completing call, never on a repeat.
  #
  # The posted reply never carries a notes section: response_text is cut at the
  # NOTES_DELIMITER line here too, so a worker that failed to split it still
  # cannot post the facts to the channel.
  def complete!(worker:, response_text:, action_summary: nil, actor: nil, now: Time.current, run: {}, notes: nil)
    worker = worker.to_s.strip
    response_text = self.class.without_notes(response_text)
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
              reply_nonce: reply_nonce.presence || "agentmsg-#{id}", reply_status: "queued",
              **self.class.run_record(run))
      stored = Array(notes).any? ? AgentPersonNote.record_from!(self, notes, now: now) : []
      record!("completed", actor: actor || soul_slug,
                           detail: { "worker" => worker, "action_summary" => action_summary.presence,
                                     "notes" => (stored.size if stored.any?) }.compact)
      :completed
    end
    AgentMessageReplyJob.perform_later(id) if outcome == :completed
    outcome
  end

  # A worker gives the message back: it returns to `received` for the next claim.
  # The attempt it used still counts toward MAX_ATTEMPTS: a give-back on the last
  # attempt dead-letters, since `received` rows are claimable at any attempt count.
  # A `code` in REFUND_CODES (usage_limit) is the exception: the attempt is handed
  # back and the message does not dead-letter on that release, up to MAX_REFUNDS
  # refunds per message. Past the cap the release spends the attempt as usual.
  def release!(worker:, reason: nil, code: nil, actor: nil, now: Time.current)
    worker = worker.to_s.strip
    code = code.to_s.strip.presence
    if code && !REFUND_CODES.include?(code)
      raise Refused.new("unknown release code #{code.inspect} (known: #{REFUND_CODES.join(', ')})", code: "UNKNOWN_CODE")
    end

    self.class.transaction do
      lock!
      unless status == "claimed" && claimed_by == worker && worker.present?
        raise Refused.new(holder_refusal("release"), code: "NOT_HOLDER")
      end

      capped = code.present? && usage_refunds >= MAX_REFUNDS
      refund = code.present? && !capped
      exhausted = !refund && attempts >= MAX_ATTEMPTS
      update!(status: exhausted ? "dead" : "received", claimed_by: nil, claimed_at: nil, lease_expires_at: nil,
              attempts: refund ? [ attempts - 1, 0 ].max : attempts,
              usage_refunds: refund ? usage_refunds + 1 : usage_refunds)
      detail = { "worker" => worker, "reason" => reason.presence, "code" => code,
                 "attempt_refunded" => (refund || nil),
                 "refund_cap_reached" => (capped || nil) }.compact
      record!("released", actor: actor || soul_slug, detail: detail)
      if exhausted
        record!("dead_lettered", actor: "system",
                                 detail: { "reason" => "given back on attempt #{attempts} of #{MAX_ATTEMPTS}" })
      end
    end
    self
  end

  # The holder extends its lease by LEASE from now. Refused (NOT_HOLDER, 409) to
  # anyone else, and to a holder whose lapsed lease another worker has since
  # taken (claimed_by is then the new worker). A holder whose lease lapsed but
  # was not taken may renew: the message is still its own.
  #
  # One `lease_renewed` event per claim, updated in place on each later renewal
  # (renewals, last lease_expires_at), so a long run does not flood the timeline.
  def renew!(worker:, actor: nil, now: Time.current)
    worker = worker.to_s.strip
    self.class.transaction do
      lock!
      unless status == "claimed" && claimed_by == worker && worker.present?
        raise Refused.new(holder_refusal("renew"), code: "NOT_HOLDER")
      end

      update!(lease_expires_at: now + LEASE)
      last = events.reorder(id: :desc).first
      if last&.kind == "lease_renewed" && last.detail["worker"] == worker
        last.update!(detail: last.detail.merge("renewals" => last.detail["renewals"].to_i + 1,
                                               "lease_expires_at" => lease_expires_at.iso8601))
      else
        record!("lease_renewed", actor: actor || soul_slug,
                                 detail: { "worker" => worker, "renewals" => 1, "lease_expires_at" => lease_expires_at.iso8601 })
      end
    end
    self
  end

  # The line a run's notes section starts with (the worker's AgentMailbox::NoteBlock
  # writes the same constant; the prompt asks for it).
  NOTES_DELIMITER = "===NOTES==="

  # `text` up to (not including) a NOTES_DELIMITER line, stripped.
  def self.without_notes(text)
    text = text.to_s
    cut = text.index(/^[ \t]*#{Regexp.escape(NOTES_DELIMITER)}[ \t]*$/)
    cut ? text[0, cut].strip : text
  end

  # complete!'s run report, cut to RUN_LIMITS and RUN_META_KEYS (scalars only).
  def self.run_record(run)
    run = (run || {}).to_h.transform_keys(&:to_sym)
    record = RUN_LIMITS.to_h { |key, cap| [ key, run[key].to_s.strip.presence&.slice(0, cap) ] }
    meta = (run[:run_meta] || {}).to_h.transform_keys(&:to_s).slice(*RUN_META_KEYS)
    record[:run_meta] = meta.select { |_, v| v.is_a?(String) || v.is_a?(Numeric) }
                            .transform_values { |v| v.is_a?(String) ? v[0, 200] : v }
    record
  end

  # The ready line that reopens this answer's Claude session, or nil.
  def resume_command
    return nil if claude_session_id.blank? || !claude_session_id.match?(/\A[\w-]+\z/)

    cwd = claude_cwd.presence || "~/.agents/mailbox/#{soul_slug}"
    "cd #{Shellwords.escape(cwd).sub(/\A\\~/, '~')} && claude --resume #{claude_session_id}"
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
                 :lease_expires_at, :attempts, :usage_refunds, :response_text, :action_summary, :reply_external_id, :reply_status,
                 :reply_posted_at, :completed_at, :sent_at, :created_at, :updated_at,
                 :claude_session_id, :claude_cwd, :reasoning, :run_meta).as_json
    data["resume_command"] = resume_command
    data["url"] = discord_url
    data["reply_url"] = reply_url
    data["person_id"] = person_id
    if events
      data["events"] = self.events.map(&:as_api_json)
      data["person"] = person&.as_api_json
    end
    data
  end

  # The platform a person speaks on here (an AgentPersonIdentity's): the channel.
  def platform = channel

  private

  def resolve_person
    return if person_id.present? || author_ref.blank?

    self.person = AgentPerson.resolve!(platform: platform, external_id: author_ref, display_name: author_name)
  end

  def holder_refusal(verb)
    holder = claimed_by.present? ? "held by #{claimed_by}" : "not claimed"
    "message #{id} is #{status} (#{holder}); only the worker holding the claim may #{verb} it"
  end
end
