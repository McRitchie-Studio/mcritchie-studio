# frozen_string_literal: true

require "json"
require "set"
require "time"
require_relative "cert_orphan_guard"

# AgentPresence — the surface an agent reads BEFORE it starts something expensive.
#
# Slice 1 of docs/agents/system/agent-presence.md (jasper, 2026-09-01): THE READER
# ALONE. It writes nothing, signals nothing, and unlinks nothing. That is not
# timidity, it is the design's central safety argument: zero new markers means zero
# new ways to wedge a peer, so the worst case of this slice is *no change*.
#
# WHAT IT READS, AND WHY THAT IS ENOUGH TODAY. `CertProcess.run_bounded` writes the
# cert runlock at the instant a lane is SPAWNED (bin/lib/cert_process.rb:183) and
# `settle` clears it once that lane's process group is provably gone. So the
# runlock's lifetime ALREADY equals the window in which a suite is consuming this
# machine — the phase fact exists, carries full identity, and was designed from the
# start to survive a SIGKILL. It is simply unreadable across desks, because it lives
# inside each desk's git dir where `git status` cannot see it. This module is that
# read: one glob, one `ps`, and the grader below.
#
# ------------------------------------------------------------------------------
# THE GOVERNING RULE, INHERITED FROM bin/lib/cert_orphan_guard.rb
# ------------------------------------------------------------------------------
# NO CLAIM ASSERTS ITS OWN LIVENESS. Every claim carries the OS's `(pid, lstart)`
# identity proof and THE READER DECIDES. A killed writer leaves its file behind —
# by design — but that file's only claim to being live is a pid and a start time
# the OS contradicts on the very next read. There is no timeout to elapse and no
# renewal to miss, so THE WEDGE WINDOW IS ZERO, not one TTL. That is the property
# a heartbeat cannot offer: a stale heartbeat is indistinguishable from a slow one
# until its TTL expires, and this house has already paid for that twice (a shift
# lease renewed by a UI paint reported a lane FREE while its holder worked; a
# renewer that outlived its work spent the account-wide 1Password cap).
#
# REUSED AS-IS from CertOrphanGuard — not reimplemented, not forked:
#   process_table / parse_ps_line  one `ps`, so every claim is graded against a
#                                  CONSISTENT world (two calls could straddle an exit)
#   identity_of                    the (pid, lstart) proof, compared as an opaque
#                                  string — no clock, no parse, no timezone, no DST
#   live_process / group_members   liveness with zombies excluded
#   coerce_pid                     a pid out of JSON is whatever was on disk
#
# DELIBERATELY NOT REUSED: `signalable?`, `reap_group`, and everything downstream of
# them. Those answer "may I KILL this?", and this module never signals anything. A
# pgid that is unsafe to signal is still perfectly safe to READ, so inheriting that
# refusal here would blind the reader to real load for a reason that does not apply.
#
# ------------------------------------------------------------------------------
# WHY THIS READER UNLINKS NOTHING, THOUGH THE DESIGN PERMITS IT
# ------------------------------------------------------------------------------
# §6 of the design lists "unlink a proven corpse" among the reader's verbs. This
# slice declines it, and the reason is concrete rather than cautious: CertOrphanGuard
# KEEPS a lock on purpose when a reap is REFUSED, because at that moment the lock is
# the only record naming the survivor. A reader that unlinked corpses on its own
# schedule would race that decision and could destroy the one artefact identifying a
# live orphan — turning a read-only surface into a way to lose evidence. Unlinking is
# a permitted verb, not a required one; reaping stays exactly where it is.
module AgentPresence
  SCHEMA_VERSION = 1

  # The two globs, relative to the projects root. Direct, and deliberately NOT via
  # `bin/agent-worktree snapshot` (a 112-desk sweep with a `git status` each and a
  # board POST, whose output is a manually refreshed 255 KB file) and NOT via any
  # `git` invocation. A "who is working?" read must never sit behind either. In a
  # git worktree the git dir is `<primary>/.git/worktrees/<name>/`, so the second
  # glob is what makes this per-desk.
  CLAIM_GLOBS = [
    "*/.git/cert-run.json",
    "*/.git/worktrees/*/cert-run.json"
  ].freeze

  # SUITE_CAPACITY — how many concurrent suites this machine can carry.
  #
  # MEASURED, NOT ASSUMED, and the measurement is the whole point. On this box
  # (14 cores / 48 GB) three concurrent certs produced load 355, swap 98%, and
  # 530 MB free of 22 GB, and starved an agent for over an hour. So 3 is the
  # CEILING observed to hurt, which makes it the capacity above which nobody
  # should launch.
  #
  # It is an open question in the design, so this module does not pretend the
  # number is settled: every report emits a `calibration` block (observed load
  # beside the live-claim count) so the constant can be refitted from logged
  # observation. The READER does not log it — it emits it, and whoever wants a
  # record keeps one. A reader that wrote a calibration log would be a writer.
  DEFAULT_SUITE_CAPACITY = 3.0

  # Weight classes. `suite | light | idle` is the design's first cut and it is
  # explicitly a first cut. Only "suite" is reachable in this slice — a cert
  # runlock is by definition a suite — but the map is the seam later slices write
  # against, and an unknown class costs a full unit rather than zero, because
  # under-reporting cost is the expensive direction.
  WEIGHTS = { "suite" => 1.0, "light" => 0.25, "idle" => 0.0 }.freeze
  UNKNOWN_WEIGHT = 1.0

  # A claim whose phase says it is WAITING consumes nothing — that is cost #4 in
  # the design: two idle `bin/ship` processes parked in a CI wait read as competing
  # certs and nearly held off a launch. No writer publishes `phase` yet (slice 3),
  # so today every runlock is `working`; honoring the field now means the reader is
  # already correct when one does.
  DEFAULT_PHASE = "working"

  # Corpses older than this are counted and summarized but not listed row by row.
  #
  # The session store never garbage-collects — 747 records reaching back to June, of
  # which 4 were touched in a representative day. A lister that prints 743 dead rows
  # beside 4 live ones is one an agent stops reading, and an unread surface answers
  # nothing. LIVE claims are never suppressed, at any age: a suite that has run for
  # two days is the single most important row on the page.
  STALE_AFTER_SECONDS = 24 * 60 * 60

  # The backstop: what "heavy" looks like when it carries no claim.
  #
  # This is the design's explicit fallback, not the primary answer. `ps aux | grep -E
  # "fast-check|rails test"` is correct BY COINCIDENCE of naming — nothing in it
  # encodes the cert/CI-wait distinction, so it degrades silently the first time a
  # lane is renamed. Here the graded claims are the answer and this scan only speaks
  # for load they FAIL to attribute, which is why a rename degrades it to "I see
  # something heavy I cannot name" instead of to silence.
  HEAVY_PATTERNS = [
    [:suite,   /\b(bin\/)?rails\s+test\b/],
    [:cert,    /\bbin\/(fast-check|full-suite-check|dor-check)\b/],
    [:ship,    /\bbin\/ship\b/],
    [:sweep,   /\bbin\/release(\.rb)?\b/],
    [:suite,   /\brspec\b/],
    [:e2e,     /\bplaywright\b/]
  ].freeze

  # Exit codes. `--json` is for agents; these are for scripts.
  EXIT_CLEAR   = 0 # headroom, and nothing heavy left unattributed
  EXIT_BUSY    = 1 # no headroom, OR heavy load this reader could not attribute
  EXIT_USAGE   = 2 # CliArgGuard
  EXIT_UNKNOWN = 3 # the process table is unavailable — we graded nothing

  module_function

  def suite_capacity(env = ENV)
    raw = env["AGENT_PRESENCE_SUITE_CAPACITY"]
    value = raw && Float(raw, exception: false)
    value&.positive? ? value : DEFAULT_SUITE_CAPACITY
  end

  def stale_after(env = ENV)
    raw = env["AGENT_PRESENCE_STALE_AFTER"]
    value = raw && Float(raw, exception: false)
    value&.positive? ? value : STALE_AFTER_SECONDS
  end

  # --- reading the claims ----------------------------------------------------------

  def claim_paths(root)
    base = root.to_s
    return [] if base.empty?

    CLAIM_GLOBS.flat_map { |pattern| Dir.glob(File.join(base, pattern)) }.sort
  end

  # nil  — the file vanished between the glob and the read. A race, not a defect;
  #        it is simply not a claim any more and nothing should be reported for it.
  # [:malformed, nil] — it is there and it is not a claim record.
  # [:ok, hash]       — a claim record. Whether it is LIVE is not this method's call.
  def read_claim(path)
    parsed = JSON.parse(File.read(path))
    return [:malformed, nil] unless parsed.is_a?(Hash) && !parsed.empty?

    [:ok, parsed]
  rescue JSON::ParserError
    [:malformed, nil]
  rescue Errno::ENOENT
    nil
  rescue SystemCallError
    [:malformed, nil]
  end

  # --- the grader ------------------------------------------------------------------

  # Grade one claim against a SNAPSHOT of the process table. Reads no clock, no
  # process table and no disk, so every vector below is testable without spawning
  # anything — and the integration tier then proves it against real kills.
  #
  #   :live         — a subject is alive AND its start time matches EXACTLY. Count it.
  #   :unverifiable — a subject is alive and we CANNOT prove whose it is. COUNT IT
  #                   CONSERVATIVELY AND NAME IT. Never silently trust, never
  #                   silently discard.
  #   :recycled     — something is alive at that number and it is PROVABLY NOT ours.
  #                   The pid was reused. Ignore it for capacity — and never, ever
  #                   touch it. (A nine-day-old lock whose pgid had been recycled is
  #                   what once made the reaper kill an unrelated bystander.)
  #   :dead         — nothing is alive at any subject. A corpse, graded on the very
  #                   next read with no timeout to wait out.
  #   :malformed    — names no pid at all, so it proves nothing and identifies
  #                   nobody. Discard it LOUDLY; the backstop speaks for any real load.
  #
  # A RUNLOCK NAMES TWO SUBJECTS and both matter, for a reason that is the guard's
  # entire reason to exist: the cert supervisor can be killed while the suite it
  # spawned SURVIVES, reparented to launchd, still holding the test DB. That orphan
  # is precisely the thing that saturates the machine and starves the next agent, so
  # a reader that graded only `cert_pid` would report the worst real case as DEAD.
  # Any subject proving `:ours` makes the claim live.
  #
  # Precedence is live > unverifiable > recycled > dead, and it is ordered that way
  # on purpose: proof of life wins over inability to prove, which wins over proof of
  # innocence. Every tie is broken toward over-reporting cost, because over-reporting
  # buys delay and under-reporting buys a saturated machine and a lost 45-minute run.
  def grade(lock:, table:)
    cert_pid = CertOrphanGuard.coerce_pid(lock["cert_pid"])
    pgid     = CertOrphanGuard.coerce_pid(lock["pgid"])

    detail = {
      cert_pid: cert_pid, pgid: pgid, lane: lock["lane"], db: lock["db"],
      started_at: lock["started_at"], cert_started_at: lock["cert_started_at"],
      pgid_started_at: lock["pgid_started_at"]
    }
    return [:malformed, detail] if cert_pid.nil? && pgid.nil?

    members = pgid ? CertOrphanGuard.group_members(table, pgid) : []
    subjects = []
    subjects << [:cert, cert_pid, lock["cert_started_at"], false] if cert_pid
    subjects << [:lane, pgid, lock["pgid_started_at"], members.any?] if pgid

    graded = subjects.map do |name, pid, recorded, group_alive|
      process = CertOrphanGuard.live_process(table, pid)
      {
        subject: name, pid: pid, process: process,
        # The lane leader can exit while its children live on; the group is still
        # burning the machine, so the subject is still ALIVE for capacity purposes.
        alive: !process.nil? || group_alive,
        identity: CertOrphanGuard.identity_of(process, recorded)
      }
    end
    detail[:members] = members.size

    if (ours = graded.find { |g| g[:identity] == :ours })
      return [:live, detail.merge(subject: ours[:subject], found: ours[:process])]
    end
    if (unprovable = graded.find { |g| g[:alive] && g[:identity] == :unprovable })
      return [:unverifiable, detail.merge(subject: unprovable[:subject], found: unprovable[:process])]
    end
    if (stranger = graded.find { |g| g[:identity] == :not_ours })
      return [:recycled, detail.merge(subject: stranger[:subject], found: stranger[:process])]
    end

    [:dead, detail]
  end

  # Grades that consume capacity. `:unverifiable` is here deliberately — see `grade`.
  COUNTED_GRADES = %i[live unverifiable].freeze

  def phase_of(lock)
    value = lock["phase"].to_s
    value.empty? ? DEFAULT_PHASE : value
  end

  def weight_of(lock)
    return 0.0 if phase_of(lock) == "waiting"

    key = lock["weight"].to_s
    return WEIGHTS.fetch("suite") if key.empty?

    WEIGHTS.fetch(key, UNKNOWN_WEIGHT)
  end

  # Repo + desk, derived from the lock's own path. No `git`, no registry lookup.
  #   <root>/turf-monster/.git/cert-run.json                  → turf-monster, primary
  #   <root>/mcritchie-studio/.git/worktrees/foo/cert-run.json → mcritchie-studio, foo
  def locate(path, root)
    rel = path.to_s.sub(/\A#{Regexp.escape(root.to_s)}\/?/, "")
    parts = rel.split("/")
    repo = parts.first
    desk = parts[1] == ".git" && parts[2] == "worktrees" ? parts[3] : "primary"
    { repo: repo, desk: desk }
  end

  def age_seconds(started_at, now)
    return nil if started_at.to_s.empty?

    now - Time.parse(started_at.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Every claim on the machine, graded against ONE process-table snapshot.
  def claims(root:, table:, now: Time.now)
    claim_paths(root).filter_map do |path|
      result = read_claim(path)
      next nil if result.nil? # vanished mid-read: not a claim any more

      status, lock = result
      lock ||= {}
      verdict, detail = status == :malformed ? [:malformed, {}] : grade(lock: lock, table: table)

      {
        path: path, kind: "cert", grade: verdict,
        phase: status == :malformed ? nil : phase_of(lock),
        weight: status == :malformed ? 0.0 : weight_of(lock),
        age_seconds: age_seconds(lock["started_at"], now)
      }.merge(locate(path, root)).merge(detail)
    end
  end

  def consumed(claims)
    claims.select { |c| COUNTED_GRADES.include?(c[:grade]) }.sum { |c| c[:weight].to_f }
  end

  # --- the backstop -----------------------------------------------------------------
  #
  # Heavy processes carrying no claim. This exists so the reader can NEVER print "idle"
  # as a conclusion drawn from an empty directory — the failure mode §7 names. If every
  # claim is missing, this degrades to today's grep PLUS honesty about what it could not
  # attribute, which is strictly more than today's grep offers.
  #
  # Attribution is by PGID first: a cert's lane children all carry the lane's pgid, so
  # matching the group attributes the whole tree in one comparison rather than matching
  # command strings that a rename would break.
  def backstop(table:, claims:, self_pid: Process.pid, self_pgid: Process.getpgrp)
    counted = claims.select { |c| COUNTED_GRADES.include?(c[:grade]) }
    known_pgids = counted.filter_map { |c| c[:pgid] }.to_set
    known_pids  = counted.filter_map { |c| c[:cert_pid] }.to_set

    # AND THE CERT'S OWN GROUP, which is NOT the lane's. A cert spawns each lane into a
    # NEW process group (`pgroup: true`), so the runlock's `pgid` names the LANE and says
    # nothing about the group the cert supervisor itself runs in. Observed live: the
    # runlock named cert_pid 37252 / pgid 37411, while 37252 was actually running in
    # pgid 37248 — the group of the `/bin/zsh -c …` wrapper that launched it. That
    # wrapper carries the whole command in its argv, so it matches the heavy patterns,
    # and without this it was reported as UNATTRIBUTED beside the very claim that names
    # its child. Resolving each claimed cert to its live row and taking THAT pgid folds
    # the wrapper — and the `bin/ship` in the same group — back onto the claim covering it.
    counted.filter_map { |c| CertOrphanGuard.live_process(table, c[:cert_pid]) }
           .each { |process| known_pgids << process[:pgid] }

    table.filter_map do |process|
      next nil if process[:pid] == self_pid || process[:pgid] == self_pgid.to_i
      next nil if known_pgids.include?(process[:pgid]) || known_pids.include?(process[:pid])

      kind = HEAVY_PATTERNS.find { |(_, pattern)| pattern.match?(process[:command]) }
      next nil unless kind

      {
        kind: kind.first, pid: process[:pid], pgid: process[:pgid],
        started_at: process[:started_at], command: process[:command]
      }
    end.then { |heavy| group_unattributed(heavy) }
  end

  # A shell wrapper carries the WHOLE command it is about to run in its own argv, so
  # it matches every pattern its child does. Reporting both is double-counting one
  # workload, and it is the wrapper — the least informative of the two — that sorts
  # first. Collapse each process GROUP to one row and let a real command represent it.
  SHELL_WRAPPER = %r{\A(/[\w/.-]*)?(z|ba|da|k)?sh\s+-[a-z]*c\b}

  def group_unattributed(processes)
    processes.group_by { |p| p[:pgid] }.map do |pgid, members|
      # Prefer a member that is not a shell wrapper: `npm exec playwright test` says
      # what is running, `/bin/zsh -c source /Users/.../snapshot-zsh-178...` does not —
      # and its distinguishing tail is exactly what a truncated row drops.
      lead = members.find { |p| !SHELL_WRAPPER.match?(p[:command]) } || members.first
      lead.merge(pgid: pgid, processes: members.size)
    end
  end

  # --- corroboration, NEVER the gate -------------------------------------------------
  #
  # A load average is an exponentially weighted mean over 1/5/15 minutes, so it
  # necessarily LAGS: it reports where the machine has BEEN, and "may I start?" is a
  # question about where it is GOING. (Measured: a load of "31, falling" was 190 when
  # acted on.) It stays in the output because high load with NO live claims is a
  # diagnosis — unattributed load — and never a green light.
  def load_average(reader: nil)
    reader ||= method(:read_load_average)
    reader.call
  rescue StandardError
    nil
  end

  def read_load_average
    if File.readable?("/proc/loadavg")
      one, five, fifteen = File.read("/proc/loadavg").split(/\s+/).first(3).map(&:to_f)
      return { "1m" => one, "5m" => five, "15m" => fifteen }
    end

    out = IO.popen(["sysctl", "-n", "vm.loadavg"], err: File::NULL, &:read).to_s
    nums = out.scan(/[\d.]+/).first(3).map(&:to_f)
    return nil unless nums.size == 3

    { "1m" => nums[0], "5m" => nums[1], "15m" => nums[2] }
  rescue Errno::ENOENT, SystemCallError
    nil
  end

  # --- the whole report --------------------------------------------------------------

  def snapshot(root:, table: nil, env: ENV, now: Time.now, load: :read, ps: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    table ||= CertOrphanGuard.process_table(ps: ps || CertOrphanGuard.ps_bin(env))
    degraded = table.empty?

    found = claims(root: root, table: table, now: now)
    capacity = suite_capacity(env)
    used = consumed(found)
    unattributed = degraded ? [] : backstop(table: table, claims: found)
    averages = load == :read ? load_average : load

    counts = Hash.new(0)
    found.each { |c| counts[c[:grade].to_s] += 1 }

    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0

    {
      schema_version: SCHEMA_VERSION,
      generated_at: now.utc.iso8601,
      root: root.to_s,
      degraded: degraded,
      capacity: capacity,
      consumed: used,
      headroom: capacity - used,
      claims: found,
      counts: counts,
      unattributed: unattributed,
      load: averages,
      # Emitted so SUITE_CAPACITY can be refitted from logged observation rather than
      # assumed. The reader publishes the datum; it does not keep the log.
      calibration: {
        live_claims: found.count { |c| COUNTED_GRADES.include?(c[:grade]) },
        load_1m: averages && averages["1m"],
        capacity: capacity
      },
      elapsed_ms: elapsed.round(1),
      verdict: verdict_for(degraded: degraded, headroom: capacity - used, unattributed: unattributed)
    }
  end

  # `unknown` is today's state, and it is what a reader that graded nothing must say.
  # Unattributed heavy load lands on `busy`, not `clear`: something is consuming the
  # machine that this reader cannot name, and "I cannot see it" is not permission.
  def verdict_for(degraded:, headroom:, unattributed:)
    return "unknown" if degraded
    return "busy" if headroom <= 0 || unattributed.any?

    "clear"
  end

  def exit_code(snapshot)
    case snapshot[:verdict]
    when "unknown" then EXIT_UNKNOWN
    when "busy"    then EXIT_BUSY
    else                EXIT_CLEAR
    end
  end

  # --- rendering ---------------------------------------------------------------------

  def format_age(seconds)
    return "?" if seconds.nil?

    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600

    "#{seconds / 3600}h#{(seconds % 3600) / 60}m"
  end

  GRADE_MARK = {
    live: "LIVE", unverifiable: "UNVERIFIED", recycled: "recycled",
    dead: "dead", malformed: "MALFORMED"
  }.freeze

  def render(snapshot, env: ENV)
    lines = []
    cutoff = stale_after(env)

    if snapshot[:degraded]
      lines << "presence: UNKNOWN — no process table (ps unavailable). Nothing was graded."
      lines << "  This is today's state, said out loud: absence of evidence, not evidence of absence."
      return lines.join("\n")
    end

    shown, hidden = partition_for_display(snapshot[:claims], cutoff)

    lines << "cert claims (#{snapshot[:claims].size} on disk, #{snapshot[:counts]['live'] || 0} live)"
    if shown.empty?
      # NEVER "idle". An empty directory is an absence of claims, not a fact about load.
      lines << "  none live — no cert runlock on this machine grades live or unverifiable."
    else
      shown.each { |c| lines << "  #{claim_row(c)}" }
    end
    lines << "  (#{hidden} stale corpse#{'s' unless hidden == 1} older than #{format_age(cutoff)} not listed)" if hidden.positive?

    lines << ""
    lines << headroom_line(snapshot)

    lines << ""
    if snapshot[:unattributed].empty?
      lines << "backstop: no heavy process is running without a claim."
    else
      lines << "backstop: #{snapshot[:unattributed].size} heavy workload(s) carry NO claim — UNATTRIBUTED, not idle:"
      snapshot[:unattributed].each do |p|
        span = p[:processes].to_i > 1 ? " (#{p[:processes]} procs)" : ""
        lines << "  #{p[:kind]} pgid #{p[:pgid]}#{span}  #{truncate(p[:command], 84)}"
      end
    end

    if (load = snapshot[:load])
      lines << ""
      lines << "load: #{load['1m']} / #{load['5m']} / #{load['15m']} (1m/5m/15m) — corroboration, never the gate"
    end

    lines << ""
    lines << "verdict: #{snapshot[:verdict].upcase}  (#{snapshot[:elapsed_ms]} ms)"
    lines.join("\n")
  end

  # Live and unverifiable claims are NEVER suppressed by age — a suite that has been
  # running for two days is the most important row on the page. The cutoff only hides
  # corpses, so the reader shows a roster rather than a cemetery.
  def partition_for_display(claims, cutoff)
    shown = []
    hidden = 0
    claims.each do |c|
      if COUNTED_GRADES.include?(c[:grade])
        shown << c
      elsif c[:age_seconds] && c[:age_seconds] > cutoff
        hidden += 1
      else
        shown << c
      end
    end
    [shown, hidden]
  end

  def claim_row(claim)
    parts = [
      GRADE_MARK.fetch(claim[:grade], claim[:grade].to_s).ljust(10),
      "#{claim[:repo]}/#{claim[:desk]}".ljust(38),
      (claim[:lane] || "-").to_s.ljust(16),
      "pid #{claim[:cert_pid] || '-'} pgid #{claim[:pgid] || '-'}".ljust(22),
      format_age(claim[:age_seconds])
    ]
    row = parts.join(" ")
    return "#{row}  [#{claim[:subject]} alive, identity UNPROVABLE — counted]" if claim[:grade] == :unverifiable
    return "#{row}  [pid reused by a stranger — not ours, never signalled]" if claim[:grade] == :recycled

    row
  end

  def headroom_line(snapshot)
    head = format("headroom: %.2f of %.2f suite(s)  (consumed %.2f)",
                  snapshot[:headroom], snapshot[:capacity], snapshot[:consumed])
    return "#{head} — no room; a suite launched now competes." if snapshot[:headroom] <= 0

    head
  end

  def truncate(text, width)
    text = text.to_s
    text.length <= width ? text : "#{text[0, width - 1]}…"
  end
end
