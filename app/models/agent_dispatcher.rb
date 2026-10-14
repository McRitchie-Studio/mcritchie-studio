# One bin/dispatcher process, as its minute ping last described it
# (docs/agents/agents/steffon/sops/agent-dispatcher.md). The dispatcher serves the
# agent mailbox from Alex's Mac: it long-polls claims, runs headless Claude, and
# pings POST /api/v1/agent_dispatchers/ping every minute. A restart is a new
# worker id and so a new row; the floor alert (AgentDispatcherAlertJob) reads the
# newest ping across all rows, and prunes rows nobody has heard from in a week.
class AgentDispatcher < ApplicationRecord
  # No ping for this long and the floor alert calls the dispatcher silent.
  SILENT_AFTER = 5.minutes
  # Rows older than this are pruned, always keeping the newest one.
  RETAIN = 7.days
  STATES = %w[running paused stopping].freeze
  # Strings a ping may carry are clipped to this, so a broken client cannot
  # write an essay into the table.
  FIELD_LIMIT = 200

  validates :worker_id, presence: true, uniqueness: true
  validates :last_seen_at, presence: true
  validates :running, numericality: { greater_than_or_equal_to: 0 }
  validates :state, inclusion: { in: STATES }, allow_nil: true

  scope :newest_first, -> { order(last_seen_at: :desc) }

  # Upsert this worker's row from a ping. Unknown keys are ignored; a missing
  # worker raises ArgumentError (the API answers 422). Returns the row.
  def self.ping!(params, now: Time.current)
    worker = params["worker"].to_s.strip[0, FIELD_LIMIT]
    raise ArgumentError, "worker is required" if worker.empty?

    row = find_or_initialize_by(worker_id: worker)
    row.assign_attributes(
      host: clip(params["host"]),
      souls: Array(params["souls"]).map { |s| clip(s) }.compact.first(50),
      running: params["running"].to_i.clamp(0, 1000),
      capacity: params["capacity"].presence&.to_i,
      paused_until: parse_time(params["paused_until"]),
      pause_reason: clip(params["pause_reason"]),
      state: STATES.include?(params["state"].to_s) ? params["state"].to_s : nil,
      version: clip(params["version"]),
      started_at: parse_time(params["started_at"]) || row.started_at || now,
      last_seen_at: now
    )
    row.save!
    row
  end

  def self.last_ping_at = maximum(:last_seen_at)

  def self.silent?(now: Time.current)
    last = last_ping_at
    last.nil? || last < now - SILENT_AFTER
  end

  # Delete rows unheard-from for RETAIN, never the newest (it carries the
  # last-ping time the silent alert reads).
  def self.prune!(now: Time.current)
    newest = newest_first.pick(:id)
    where("last_seen_at < ?", now - RETAIN).where.not(id: newest).delete_all
  end

  def paused?(now: Time.current) = paused_until.present? && paused_until > now
  def live?(now: Time.current) = last_seen_at >= now - SILENT_AFTER

  def as_api_json
    slice(:id, :worker_id, :host, :souls, :running, :capacity, :paused_until, :pause_reason, :state, :version,
          :started_at, :last_seen_at).as_json
  end

  def self.clip(value)
    value.to_s.strip[0, FIELD_LIMIT].presence
  end

  def self.parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
  private_class_method :clip, :parse_time
end
