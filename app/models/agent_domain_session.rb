require Rails.root.join("bin/lib/agent_warm_session").to_s
require Rails.root.join("bin/lib/agent_proposal_block").to_s

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
# THE LEASE KEY. The holder is not just a worker NAME (the shared agent token
# can say any name, and GET index shows the holder's). An acquire that takes
# the lease mints a random key, answers it once, and keeps only its SHA-256
# (lease_key_digest). Every holder verb, the checkpoint read included, must
# present it, so only the process that took the lease reads or writes the
# session. A process that loses its key (a crash) waits out the lease, as any
# other worker would.
#
# FAULTS. The holder reports a checkpoint or restore that failed (#fault!): the
# row keeps the last one (last_fault, last_fault_at) and ErrorLog records it,
# so a domain gone cold is visible on the board, not only in one machine's log.
#
# The transcript holds owner and team text only: the dispatcher never answers a
# client, a public sender or a released hold from a warm session.
class AgentDomainSession < ApplicationRecord
  LEASE = 5.minutes
  # The largest checkpoint the board keeps, compressed. A transcript past it is
  # consolidated by the holder instead of checkpointed.
  CHECKPOINT_LIMIT = AgentMailbox::WarmSession::CHECKPOINT_LIMIT
  GZIP_MAGIC = "\x1F\x8B".b.freeze
  SUMMARY_LIMIT = 8_000
  SESSION_ID = /\A[0-9A-Za-z-]{8,100}\z/
  FIELD_LIMIT = 200
  # The faults a holder may report (#fault!): fixed words, never free text.
  FAULTS = %w[checkpoint_failed restore_failed].freeze
  FAULT_DETAIL = /\A[A-Za-z0-9:_. -]{0,120}\z/

  # What ErrorLog records for a holder's fault report.
  class Fault < StandardError; end

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
  # live (its meta says whether a handback was requested). lease_key: the key
  # this acquire minted (only when it took the lease; a renewal mints none).
  Acquired = Struct.new(:row, :taken_over_from, :refused, :lease_key, keyword_init: true)

  has_one_attached :checkpoint

  validates :domain, presence: true, uniqueness: true
  validates :generation, :turns, :context_tokens, numericality: { greater_than_or_equal_to: 0 }

  def self.registry = AgentProposal.registry

  # Take the domain's lease, or renew it when `worker` already holds it AND
  # presents its lease key. A lapsed or free lease is taken (a lapsed holder is
  # recorded in taken_over_from) under a freshly minted key. A live lease the
  # caller does not hold with its key refuses (LEASE_HELD), even when the name
  # matches: the caller answers that message per message, never waits. When the
  # refused caller is a primary and the holder a standby, the row is marked
  # handback_requested in the same transaction, which commits; the standby
  # releases after its current turn.
  def self.acquire!(domain:, worker:, lease_key: nil, now: Time.current, registry: self.registry)
    worker = clean(worker)
    domain = domain.to_s.strip
    raise Refused.new("worker is required", code: "WORKER_REQUIRED") if worker.empty?
    unless registry.warm_session?(domain)
      raise Refused.new("domain #{domain.inspect} has no warm session (config/agent_domains.yml warm_session)",
                        code: "NOT_WARM")
    end

    row = find_or_create_row(domain)
    transaction do
      row.lock!
      holds = row.holder == worker && row.key_matches?(lease_key)
      if row.lease_live?(now: now) && !holds
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
      key = holds ? nil : SecureRandom.urlsafe_base64(32)
      attrs[:lease_key_digest] = digest(key) if key
      row.update!(attrs)
      Acquired.new(row: row, taken_over_from: changed ? previous : nil, lease_key: key)
    end
  end

  def self.digest(key) = Digest::SHA256.hexdigest(key.to_s)

  # Does `key` open this row's lease? A row with no key (never taken, released,
  # reset) opens to nobody.
  def key_matches?(key)
    return false if lease_key_digest.blank? || key.to_s.empty?

    ActiveSupport::SecurityUtils.secure_compare(lease_key_digest, self.class.digest(key))
  end

  # The domain's row, made on first use. Two first acquirers racing on the
  # unique index: the loser reads the winner's row.
  def self.find_or_create_row(domain)
    find_by(domain: domain) || create!(domain: domain)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by!(domain: domain)
  end

  # The holder extends its lease (and its heartbeat). A holder whose lease
  # lapsed but was not taken may renew: the session is still its own.
  def renew!(worker:, lease_key:, now: Time.current)
    with_holder(worker, lease_key, verb: "renew", live: false) do
      update!(lease_expires_at: now + LEASE, heartbeat_at: now)
    end
  end

  # After a turn: the transcript of the session's new head, gzipped. Refused to
  # anyone but the holder, to a holder whose lease lapsed (a late checkpoint
  # from a machine that lost the session), and to a transcript that is not
  # gzip or is over CHECKPOINT_LIMIT. Extends the lease, and clears a reported
  # fault (the session checkpoints again).
  #
  # The blob is UPLOADED BEFORE the row says checkpointed (create_and_upload!,
  # inside the holder's lock), not after commit as `attach(io:)` would: an upload
  # that fails raises here, the transaction rolls back, the caller gets the
  # error (ErrorLog through rescue_and_log), and the row keeps the previous,
  # readable checkpoint instead of naming one storage never received.
  def checkpoint!(worker:, lease_key:, session_id:, data:, turns:, context_tokens:, now: Time.current)
    session_id = session_id.to_s.strip
    raise Refused.new("session_id is not a Claude session id", code: "BAD_SESSION") unless session_id.match?(SESSION_ID)

    data = data.to_s.b
    if data.bytesize > CHECKPOINT_LIMIT
      raise Refused.new("checkpoint is #{data.bytesize} bytes; the limit is #{CHECKPOINT_LIMIT} (consolidate instead)",
                        code: "TOO_LARGE")
    end
    raise Refused.new("checkpoint must be a gzipped transcript", code: "BAD_CHECKPOINT") unless data.start_with?(GZIP_MAGIC)

    with_holder(worker, lease_key, verb: "checkpoint", live: true, now: now) do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: "#{domain}-#{session_id}.jsonl.gz",
                                                    content_type: "application/gzip", identify: false)
      begin
        checkpoint.attach(blob)
        update!(claude_session_id: session_id, turns: turns.to_i.clamp(0, 1_000_000),
                context_tokens: context_tokens.to_i.clamp(0, 100_000_000), checkpointed_at: now,
                checkpoint_bytes: data.bytesize, lease_expires_at: now + LEASE, heartbeat_at: now,
                last_fault: nil, last_fault_at: nil)
      rescue StandardError
        # The row rolls back; the uploaded file would be an orphan.
        blob.service.delete(blob.key) rescue nil # rubocop:disable Style/RescueModifier
        raise
      end
    end
  end

  # The holder gives the lease up (after a handback request, a failed turn, or
  # a shutdown). The session and its checkpoint stay for the next holder.
  def release!(worker:, lease_key:)
    with_holder(worker, lease_key, verb: "release", live: false) do
      update!(holder: nil, lease_expires_at: nil, lease_key_digest: nil, handback_requested_at: nil,
              handback_requested_by: nil)
    end
  end

  # The holder reports that a checkpoint or a restore failed: one of FAULTS and
  # a code-shaped detail (an error class and code, never message text). Kept on
  # the row (last_fault, last_fault_at; cleared by the next checkpoint) and
  # recorded in ErrorLog. Holder-only; a lapsed lease may still report.
  def fault!(worker:, lease_key:, fault:, detail: nil, now: Time.current)
    fault = fault.to_s
    raise Refused.new("fault must be one of #{FAULTS.join(', ')}", code: "BAD_FAULT") unless FAULTS.include?(fault)

    detail = detail.to_s.strip
    detail = "" unless detail.match?(FAULT_DETAIL)
    text = detail.empty? ? fault : "#{fault}: #{detail}"
    with_holder(worker, lease_key, verb: "report a fault on", live: false) do
      update!(last_fault: text[0, FIELD_LIMIT], last_fault_at: now)
    end
    ErrorLog.capture!(Fault.new("warm session #{domain} (#{holder}): #{text}"))
    self
  end

  # Past the domain's consolidate_at the holder asks its session for a summary
  # and sends it here: one AgentDomainSummary row for this generation, then the
  # session is cleared and the generation bumped, so the next turn starts a
  # fresh session seeded with the summary. Holder-only, live lease.
  def consolidate!(worker:, lease_key:, text:, source_session_id: nil, turns_covered: nil, context_tokens: nil,
                   now: Time.current)
    text = AgentMailbox::ProposalBlock.reply(text.to_s).to_s.strip
    raise Refused.new("summary text is required", code: "SUMMARY_REQUIRED") if text.empty?

    with_holder(worker, lease_key, verb: "consolidate", live: true, now: now) do
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

  # An operator's act (`bin/rails agent_dispatchers:reset_session`): drop the
  # session's head, its checkpoint and the lease, so the next turn starts a
  # fresh session. Summaries are kept. For a checkpoint that will not restore.
  def reset!
    self.class.transaction do
      lock!
      checkpoint.purge_later if checkpoint.attached?
      update!(holder: nil, lease_expires_at: nil, lease_key_digest: nil, claude_session_id: nil, turns: 0,
              context_tokens: 0, checkpointed_at: nil, checkpoint_bytes: nil, handback_requested_at: nil,
              handback_requested_by: nil)
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

  # The checkpoint's bytes, for the holder restoring it: the worker that holds
  # the lease AND presents its key. nil when there is none.
  def checkpoint_bytes_for(worker:, lease_key:, now: Time.current)
    with_holder(worker, lease_key, verb: "read the checkpoint of", live: true, now: now) do
      checkpoint.attached? ? checkpoint.download : nil
    end
  end

  def lease_live?(now: Time.current) = holder.present? && lease_expires_at.present? && lease_expires_at > now
  def handback_requested? = handback_requested_at.present?

  # What the dispatcher reads. The seed summary is the holder's only (`holder:
  # true` once the caller's lease key was checked): it is owner and team text.
  # The lease key is never in it.
  def as_api_json(for_holder: false)
    data = slice(:domain, :holder, :lease_expires_at, :heartbeat_at, :claude_session_id, :generation, :turns,
                 :context_tokens, :checkpointed_at, :checkpoint_bytes, :handback_requested_at,
                 :handback_requested_by, :last_fault, :last_fault_at).as_json
    data["handback_requested"] = handback_requested?
    data["has_checkpoint"] = checkpoint_bytes.present? && claude_session_id.present?
    data["consolidate_at"] = self.class.registry.consolidate_at(domain)
    data["seed_summary"] = seed_summary if for_holder
    data
  end

  def self.clean(value) = value.to_s.strip[0, FIELD_LIMIT].to_s

  private

  # Locks the row, checks `worker` holds it with its lease key (and, when
  # `live`, that its lease has not lapsed), then yields. Returns the yield's
  # value. A wrong or missing key reads exactly as a wrong worker.
  def with_holder(worker, lease_key, verb:, live:, now: Time.current)
    worker = self.class.clean(worker)
    self.class.transaction do
      lock!
      unless worker.present? && holder == worker && key_matches?(lease_key)
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
