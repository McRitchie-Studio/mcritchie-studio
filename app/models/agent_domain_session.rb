# One domain's warm Claude session, as the board leases it
# (docs/agents/system/agent-message-loop.md, "Warm sessions"; plan: Phase 7 of
# .agents/epics/domain-agents.md).
#
# A domain with `warm_session: true` in config/agent_domains.yml answers its
# owner and team messages by resuming ONE Claude session instead of starting a
# fresh run per message. This row says which dispatcher may resume it now:
#
#   holder + lease_expires_at   THE LEASE, on the row as AgentMessage's is: a
#                               holder that dies loses it when it lapses, with
#                               no sweeper. LEASE is 5 minutes; the holder
#                               renews it on its minute ping and on each turn.
#   claude_session_id           the session's head: the envelope's session_id
#                               after the last checkpointed turn
#   checkpoint                  that session's transcript (gzipped JSONL, at
#                               most CHECKPOINT_LIMIT bytes), so another machine
#                               can resume it; checkpointed_at says when
#   generation                  bumped by each consolidation, which writes an
#                               AgentDomainSummary row and clears the session,
#                               so the next turn starts fresh from that summary
#   handback_requested_*        a primary asked for the lease a standby holds;
#                               the standby releases it after its turn
#
# EVERY WRITE IS HOLDER-CHECKED, and a lease that lapsed refuses the late
# checkpoint and consolidation of its old holder (Refused, NOT_HOLDER or
# LEASE_LAPSED, answered 409), so two machines never write one session.
#
# The transcript holds owner and team text only: the dispatcher never answers a
# client, a public sender or a released hold from a warm session.
class AgentDomainSession < ApplicationRecord
  LEASE = 5.minutes
  # The largest checkpoint the board keeps, compressed. A transcript past it is
  # consolidated by the holder instead of checkpointed.
  CHECKPOINT_LIMIT = 4 * 1024 * 1024
  GZIP_MAGIC = "\x1F\x8B".b.freeze
  SUMMARY_LIMIT = 8_000
  SESSION_ID = /\A[0-9A-Za-z-]{8,100}\z/
  FIELD_LIMIT = 200

  class Refused < StandardError
    attr_reader :code, :meta

    def initialize(message, code:, meta: {})
      super(message)
      @code = code
      @meta = meta
    end
  end

  # row: the session (nil when refused). taken_over_from: the lapsed holder this
  # acquire replaced, or nil. refused: a Refused, when another worker's lease is
  # live (its meta says whether a handback was requested).
  Acquired = Struct.new(:row, :taken_over_from, :refused, keyword_init: true)

  has_one_attached :checkpoint

  validates :domain, presence: true, uniqueness: true
  validates :generation, :turns, :context_tokens, numericality: { greater_than_or_equal_to: 0 }

  def self.registry = AgentProposal.registry

  # Take the domain's lease, or renew it when `worker` already holds it. A
  # lapsed lease is taken over (its holder recorded in taken_over_from). A live
  # lease another worker holds refuses (LEASE_HELD): the caller answers that
  # message per message, never waits. When the refused caller is a primary and
  # the holder a standby, the row is marked handback_requested in the same
  # transaction, which commits; the standby releases after its current turn.
  def self.acquire!(domain:, worker:, now: Time.current, registry: self.registry)
    worker = clean(worker)
    domain = domain.to_s.strip
    raise Refused.new("worker is required", code: "WORKER_REQUIRED") if worker.empty?
    unless registry.warm_session?(domain)
      raise Refused.new("domain #{domain.inspect} has no warm session (config/agent_domains.yml warm_session)",
                        code: "NOT_WARM")
    end

    row = create_or_find_by!(domain: domain)
    transaction do
      row.lock!
      if row.lease_live?(now: now) && row.holder != worker
        handback = row.request_handback!(worker, now: now)
        next Acquired.new(refused: Refused.new(
          "#{domain}'s warm session is held by #{row.holder} until #{row.lease_expires_at.iso8601}; " \
          "answer this message per message",
          code: "LEASE_HELD", meta: { "holder" => row.holder, "handback_requested" => handback }
        ))
      end

      previous = row.holder.presence
      changed = previous != worker
      attrs = { holder: worker, lease_expires_at: now + LEASE, heartbeat_at: now }
      attrs.merge!(handback_requested_at: nil, handback_requested_by: nil) if changed
      row.update!(attrs)
      Acquired.new(row: row, taken_over_from: changed ? previous : nil)
    end
  end

  # The holder extends its lease (and its heartbeat). A holder whose lease
  # lapsed but was not taken may renew: the session is still its own.
  def renew!(worker:, now: Time.current)
    with_holder(worker, verb: "renew", live: false) do
      update!(lease_expires_at: now + LEASE, heartbeat_at: now)
    end
  end

  # After a turn: the transcript of the session's new head, gzipped. Refused to
  # anyone but the holder, to a holder whose lease lapsed (a late checkpoint
  # from a machine that lost the session), and to a transcript that is not
  # gzip or is over CHECKPOINT_LIMIT. Extends the lease.
  def checkpoint!(worker:, session_id:, data:, turns:, context_tokens:, now: Time.current)
    session_id = session_id.to_s.strip
    raise Refused.new("session_id is not a Claude session id", code: "BAD_SESSION") unless session_id.match?(SESSION_ID)

    data = data.to_s.b
    if data.bytesize > CHECKPOINT_LIMIT
      raise Refused.new("checkpoint is #{data.bytesize} bytes; the limit is #{CHECKPOINT_LIMIT} (consolidate instead)",
                        code: "TOO_LARGE")
    end
    raise Refused.new("checkpoint must be a gzipped transcript", code: "BAD_CHECKPOINT") unless data.start_with?(GZIP_MAGIC)

    with_holder(worker, verb: "checkpoint", live: true, now: now) do
      checkpoint.attach(io: StringIO.new(data), filename: "#{domain}-#{session_id}.jsonl.gz",
                        content_type: "application/gzip", identify: false)
      update!(claude_session_id: session_id, turns: turns.to_i.clamp(0, 1_000_000),
              context_tokens: context_tokens.to_i.clamp(0, 100_000_000), checkpointed_at: now,
              checkpoint_bytes: data.bytesize, lease_expires_at: now + LEASE, heartbeat_at: now)
    end
  end

  # The holder gives the lease up (after a handback request, a failed turn, or
  # a shutdown). The session and its checkpoint stay for the next holder.
  def release!(worker:)
    with_holder(worker, verb: "release", live: false) do
      update!(holder: nil, lease_expires_at: nil, handback_requested_at: nil, handback_requested_by: nil)
    end
  end

  # Past the domain's consolidate_at the holder asks its session for a summary
  # and sends it here: one AgentDomainSummary row for this generation, then the
  # session is cleared and the generation bumped, so the next turn starts a
  # fresh session seeded with the summary. Holder-only, live lease.
  def consolidate!(worker:, text:, source_session_id: nil, turns_covered: nil, context_tokens: nil, now: Time.current)
    text = AgentMailbox::ProposalBlock.reply(text.to_s).to_s.strip
    raise Refused.new("summary text is required", code: "SUMMARY_REQUIRED") if text.empty?

    with_holder(worker, verb: "consolidate", live: true, now: now) do
      AgentDomainSummary.create!(domain: domain, generation: generation, text: text[0, SUMMARY_LIMIT],
                                 source_session_id: source_session_id.to_s[SESSION_ID],
                                 turns_covered: (turns_covered || turns).to_i.clamp(0, 1_000_000),
                                 context_tokens: context_tokens&.to_i, written_by: worker[0, FIELD_LIMIT],
                                 created_at: now)
      checkpoint.purge_later if checkpoint.attached?
      update!(generation: generation + 1, claude_session_id: nil, turns: 0, context_tokens: 0, checkpointed_at: nil,
              checkpoint_bytes: nil, lease_expires_at: now + LEASE, heartbeat_at: now)
    end
  end

  # Marks a handback when `worker` is a primary dispatcher and the holder a
  # standby. Returns whether the row now carries a request.
  def request_handback!(worker, now: Time.current)
    return handback_requested_at.present? unless AgentDispatcher.standby?(holder) && !AgentDispatcher.standby?(worker)

    update!(handback_requested_at: now, handback_requested_by: worker[0, FIELD_LIMIT]) if handback_requested_at.nil?
    true
  end

  # The newest summary a fresh session starts from: the one the last
  # consolidation wrote. nil while a session is live, or before any.
  def seed_summary
    return nil if claude_session_id.present?

    AgentDomainSummary.where(domain: domain).where("generation < ?", generation).order(generation: :desc).pick(:text)
  end

  # The checkpoint's bytes, for the holder restoring it. nil when there is none.
  def checkpoint_bytes_for(worker:, now: Time.current)
    with_holder(worker, verb: "read the checkpoint of", live: true, now: now) do
      checkpoint.attached? ? checkpoint.download : nil
    end
  end

  def lease_live?(now: Time.current) = holder.present? && lease_expires_at.present? && lease_expires_at > now
  def handback_requested? = handback_requested_at.present?

  # What the dispatcher reads. The seed summary is the holder's only: it is
  # owner and team text.
  def as_api_json(worker: nil)
    data = slice(:domain, :holder, :lease_expires_at, :heartbeat_at, :claude_session_id, :generation, :turns,
                 :context_tokens, :checkpointed_at, :checkpoint_bytes, :handback_requested_at,
                 :handback_requested_by).as_json
    data["handback_requested"] = handback_requested?
    data["has_checkpoint"] = checkpoint_bytes.present? && claude_session_id.present?
    data["consolidate_at"] = self.class.registry.consolidate_at(domain)
    data["seed_summary"] = seed_summary if worker.present? && worker == holder
    data
  end

  def self.clean(value) = value.to_s.strip[0, FIELD_LIMIT].to_s

  private

  # Locks the row, checks `worker` holds it (and, when `live`, that its lease
  # has not lapsed), then yields. Returns the yield's value.
  def with_holder(worker, verb:, live:, now: Time.current)
    worker = self.class.clean(worker)
    self.class.transaction do
      lock!
      unless worker.present? && holder == worker
        raise Refused.new("#{domain}'s warm session is #{holder.present? ? "held by #{holder}" : 'not held'}; " \
                          "only its holder may #{verb} it", code: "NOT_HOLDER")
      end
      if live && !lease_live?(now: now)
        raise Refused.new("#{domain}'s lease lapsed at #{lease_expires_at&.iso8601}; acquire it again before you " \
                          "#{verb} it", code: "LEASE_LAPSED")
      end

      yield
    end
  end
end
