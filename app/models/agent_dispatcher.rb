# One bin/dispatcher process, as its minute ping last described it
# (docs/agents/agents/steffon/sops/agent-dispatcher.md). The dispatcher serves the
# agent mailbox from Alex McRitchie's Mac: it long-polls claims, runs headless Claude, and
# pings POST /api/v1/agent_dispatchers/ping every minute. A restart is a new
# worker id and so a new row; the floor alert (AgentDispatcherAlertJob) reads the
# newest PRIMARY ping, and prunes rows nobody has heard from in a week.
#
# ROLE (docs/agents/system/agent-message-loop.md, "Warm sessions"). Every
# dispatcher is a `primary` unless an admin registered its host as a `standby`
# for a list of warm domains (set_role!, `bin/rails agent_dispatchers:role`). A
# standby claims nothing while a primary is live, and then only messages for
# the souls of its standby domains (claim_scope). The role belongs to the host:
# a restart is a new row, which inherits the newest same-host row's role.
class AgentDispatcher < ApplicationRecord
  # No ping for this long and the floor alert calls the dispatcher silent.
  SILENT_AFTER = 5.minutes
  # Rows older than this are pruned, always keeping the newest one.
  RETAIN = 7.days
  STATES = %w[running paused stopping].freeze
  # The role vocabulary; the CHECK agent_dispatchers_role_known holds the same
  # list (20261016230000).
  ROLES = %w[primary standby].freeze
  # Consecutive measured beats with op or gh failing before the floor opens
  # harness_degraded (AgentMessages::FloorAlert#harness_check).
  HARNESS_BEATS = 5
  POWER_SOURCES = %w[ac battery].freeze
  # Strings a ping may carry are clipped to this, so a broken client cannot
  # write an essay into the table.
  FIELD_LIMIT = 200

  validates :worker_id, presence: true, uniqueness: true
  validates :last_seen_at, presence: true
  validates :running, numericality: { greater_than_or_equal_to: 0 }
  validates :state, inclusion: { in: STATES }, allow_nil: true
  validates :role, inclusion: { in: ROLES }

  scope :newest_first, -> { order(last_seen_at: :desc) }
  # bin/client-build-launcher pings this table too (its row lists the one soul
  # LAUNCHER_SOUL), so the status card can tell a live launcher from none
  # (docs/agents/system/client-build-launcher.md). It answers no mailbox, so it is
  # never a primary or a standby: the floor alert and the standby rule read only
  # the mailbox rows, and a live launcher can never hide a silent dispatcher.
  LAUNCHER_SOUL = "client-build-launcher".freeze
  scope :mailbox, -> { where.not("agent_dispatchers.souls @> ?", [ LAUNCHER_SOUL ].to_json) }
  scope :launchers, -> { where("agent_dispatchers.souls @> ?", [ LAUNCHER_SOUL ].to_json) }
  scope :primaries, -> { mailbox.where(role: "primary") }
  scope :standbys, -> { mailbox.where(role: "standby") }

  # Upsert this worker's row from a ping. Unknown keys are ignored; a missing
  # worker raises ArgumentError (the API answers 422). Returns the row.
  def self.ping!(params, now: Time.current)
    worker = params["worker"].to_s.strip[0, FIELD_LIMIT]
    raise ArgumentError, "worker is required" if worker.empty?

    row = find_or_initialize_by(worker_id: worker)
    host = clip(params["host"])
    if row.new_record? && host && (kept = mailbox.where(host: host).newest_first.first)
      row.role = kept.role
      row.standby_domains = kept.standby_domains
    end
    row.assign_attributes(
      host: host,
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
    record_harness(row, params)
    row.save!
    row
  end

  # HARNESS HEALTH, measured on the Mac by bin/dispatcher on each beat with
  # 20-second bounds (AgentMailbox::HarnessProbe) and carried on the ping:
  # op_ok (a bounded `op whoami`), gh_ok (a bounded GitHub check), power
  # ("ac"/"battery"), and harness_measured_at. A ping that carries no
  # measurement, or the same one again (the probe had not finished a new one),
  # leaves the counter alone: harness_failing_beats counts MEASUREMENTS, so five
  # failing beats are five separate checks that failed.
  def self.record_harness(row, params)
    row.power_source = params["power"].to_s if POWER_SOURCES.include?(params["power"].to_s)
    measured = parse_time(params["harness_measured_at"])
    return if measured.nil? || (row.harness_checked_at && measured <= row.harness_checked_at)

    op = boolean(params["op_ok"])
    gh = boolean(params["gh_ok"])
    return if op.nil? && gh.nil?

    row.op_ok = op
    row.gh_ok = gh
    row.harness_checked_at = measured
    row.harness_failing_beats = op == false || gh == false ? row.harness_failing_beats.to_i + 1 : 0
  end
  private_class_method :record_harness

  def self.boolean(value)
    case value
    when true, "true", "1", 1 then true
    when false, "false", "0", 0 then false
    end
  end
  private_class_method :boolean

  def harness_degraded? = harness_failing_beats.to_i >= HARNESS_BEATS

  # The newest PRIMARY ping: a standby's pings never stand in for the primary's,
  # so the floor alert still says the primary is silent while a standby covers.
  def self.last_ping_at = primaries.maximum(:last_seen_at)

  def self.silent?(now: Time.current)
    last = last_ping_at
    last.nil? || last < now - SILENT_AFTER
  end

  # Is a primary answering now: pinged within SILENT_AFTER and not stopping
  # (a graceful stop's last ping says `stopping`, so a standby may start at once).
  def self.primary_live?(now: Time.current)
    primaries.where("last_seen_at >= ?", now - SILENT_AFTER)
             .where("state IS NULL OR state <> 'stopping'").exists?
  end

  def self.standby?(worker) = worker.present? && standbys.exists?(worker_id: worker.to_s)

  # The live standby rows (for the floor alert's "a standby is covering").
  def self.live_standbys(now: Time.current) = standbys.where("last_seen_at >= ?", now - SILENT_AFTER)

  # What a claim by `worker` for `souls` may take: [souls, nil], or [[], reason].
  # A primary (or a worker with no row, such as bin/heartbeat) is unchanged. A
  # standby takes nothing while a primary is live, and otherwise only the souls
  # its standby domains map to (registry.soul_domains plus each front door).
  def self.claim_scope(worker, souls, now: Time.current, registry: AgentProposal.registry)
    row = find_by(worker_id: worker.to_s.strip)
    return [ souls, nil ] unless row&.role == "standby"
    return [ [], "standby_primary_live" ] if primary_live?(now: now)

    domains = Array(row.standby_domains).map(&:to_s)
    served = registry.soul_domains.select { |_, d| domains.include?(d.to_s) }.keys.map(&:to_s)
    served += domains.filter_map { |d| registry.domains.dig(d, "soul") if registry.domains[d].is_a?(Hash) }.map(&:to_s)
    allowed = Array(souls) & served
    allowed.empty? ? [ [], "standby_no_domain" ] : [ allowed, nil ]
  end

  # Register (or clear) a host's role: every row of that host, so the running
  # dispatcher reads it on its next ping and a restart inherits it. A standby
  # names at least one warm domain. Refused for a host that has never pinged:
  # set the machine up first (the agent-dispatcher SOP, "Standby on a second
  # machine").
  def self.set_role!(host:, role:, domains: [], registry: AgentProposal.registry)
    host = clip(host)
    raise ArgumentError, "host is required" if host.nil?
    raise ArgumentError, "role must be one of #{ROLES.join(', ')}" unless ROLES.include?(role.to_s)

    domains = Array(domains).map { |d| d.to_s.strip }.reject(&:empty?).uniq
    if role.to_s == "standby"
      raise ArgumentError, "a standby needs at least one domain" if domains.empty?

      cold = domains.reject { |d| registry.warm_session?(d) }
      raise ArgumentError, "not warm domains (config/agent_domains.yml warm_session): #{cold.join(', ')}" if cold.any?
    else
      domains = []
    end
    rows = where(host: host)
    raise ArgumentError, "no dispatcher on #{host} has ever pinged; install it there first" unless rows.exists?

    rows.update_all(role: role.to_s, standby_domains: domains, updated_at: Time.current)
  end

  # Delete rows unheard-from for RETAIN, never the newest (it carries the
  # last-ping time the silent alert reads) and never a host's newest standby
  # row (it carries that host's registration across a long stop).
  def self.prune!(now: Time.current)
    keep = [ newest_first.pick(:id), primaries.newest_first.pick(:id) ] +
           standbys.select("DISTINCT ON (host) id").order(:host, last_seen_at: :desc).map(&:id)
    where("last_seen_at < ?", now - RETAIN).where.not(id: keep.compact).delete_all
  end

  def paused?(now: Time.current) = paused_until.present? && paused_until > now
  def live?(now: Time.current) = last_seen_at >= now - SILENT_AFTER

  def as_api_json
    slice(:id, :worker_id, :host, :souls, :running, :capacity, :paused_until, :pause_reason, :state, :version,
          :started_at, :last_seen_at, :role, :standby_domains, :op_ok, :gh_ok, :power_source, :harness_checked_at,
          :harness_failing_beats).as_json
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
