# frozen_string_literal: true

# ProcessTable — the OS's own answer to "what is running, and since when?"
#
# One `ps` snapshot, parsed into rows a reader can grade a presence claim against.
# The two halves of a process IDENTITY live here: a pid ADDRESSES a process, and
# the OS's start-time record is what tells "our process" from a stranger who
# inherited a recycled number. Readers (bin/lib/agent_presence.rb,
# bin/lib/desk_context.rb, bin/lib/presence_claim.rb, bin/agent-worktree) only
# ever OBSERVE through this module; nothing here signals anything.
#
# Until DevOps v3 phase 2b these helpers lived in bin/lib/cert_orphan_guard.rb,
# whose reaping half retired with the local cert evidence system.
module ProcessTable
  # `ps -o lstart=` prints "Mon Jul 13 05:00:00 2026" — five whitespace tokens.
  LSTART_TOKENS = 5

  def self.ps_bin(env = ENV)
    env.fetch("CERT_GUARD_PS", "ps")
  end

  # One snapshot of every process on the box: [{pid:, pgid:, state:, started_at:,
  # command:}, ...]. ONE `ps` call, so a leader check and a group-membership check
  # see a consistent world (two calls could straddle an exit). Empty on any
  # failure, and an empty table proves nothing is ours, so every downstream
  # decision fails SAFE.
  def self.process_table(ps: "ps")
    out = IO.popen([ps, "-Ao", "pid=,pgid=,state=,lstart=,command="], err: File::NULL, &:read).to_s
    return [] unless $?.success?

    out.lines.filter_map { |line| parse_ps_line(line) }
  rescue Errno::ENOENT, SystemCallError
    []
  end

  def self.parse_ps_line(line)
    fields = line.strip.split(/\s+/)
    return nil if fields.size < 3 + LSTART_TOKENS + 1

    pid   = Integer(fields.shift, exception: false)
    pgid  = Integer(fields.shift, exception: false)
    state = fields.shift
    return nil if pid.nil? || pgid.nil?

    started = normalize_start(fields.shift(LSTART_TOKENS).join(" "))
    { pid: pid, pgid: pgid, state: state.to_s, started_at: started, command: fields.join(" ") }
  end

  # A start time is only ever compared to another start time read the same way, so
  # we compare the OS's own rendering — no clock, no parsing, no timezone. Only the
  # space padding is squeezed ("Jul  8" / "Jul 8").
  def self.normalize_start(value)
    text = value.to_s.strip.squeeze(" ")
    text.empty? ? nil : text
  end

  # The OS's start-time record for one pid, or nil when the pid names nothing.
  # A claim records this at spawn so a LATER reader can prove identity.
  def self.process_started_at(pid, ps: "ps")
    pid = pid.to_i
    return nil unless pid.positive?

    out = IO.popen([ps, "-p", pid.to_s, "-o", "lstart="], err: File::NULL, &:read).to_s
    return nil unless $?.success?

    normalize_start(out)
  rescue Errno::ENOENT, SystemCallError
    nil
  end

  # A zombie is not alive in any sense that matters: it holds no DB connection and
  # cannot be signalled (it is already dead, just unreaped).
  def self.zombie?(process)
    process[:state].to_s.start_with?("Z")
  end

  def self.live_process(table, pid)
    pid = pid.to_i
    return nil unless pid.positive?

    table.find { |p| p[:pid] == pid && !zombie?(p) }
  end

  def self.group_members(table, pgid)
    pgid = pgid.to_i
    return [] unless pgid.positive?

    table.select { |p| p[:pgid] == pgid && !zombie?(p) }
  end

  # Is this live process the one a claim recorded? Three answers:
  #   :ours       — the OS says it started in the exact second the claim recorded.
  #   :not_ours   — it started at some other time. The number was recycled.
  #   :unprovable — no recorded start time, or `ps` told us nothing.
  # BOTH sides are normalized here: a comparator that trusts its caller to have
  # normalized is one refactor away from comparing "Jul  9" to "Jul 9".
  def self.identity_of(process, recorded_start)
    recorded = normalize_start(recorded_start)
    observed = normalize_start(process && process[:started_at])
    return :unprovable if process.nil? || recorded.nil? || observed.nil?

    observed == recorded ? :ours : :not_ours
  end

  # A pid out of a JSON claim is whatever was on disk — `{"pgid": {}}` is a Hash,
  # and `Hash#to_i` is a NoMethodError. Anything that is not plainly an integer is
  # not a pid, and nil means "this claim names nobody".
  def self.coerce_pid(value)
    case value
    when Integer then value
    when String then Integer(value.strip, exception: false)
    end
  end
end
