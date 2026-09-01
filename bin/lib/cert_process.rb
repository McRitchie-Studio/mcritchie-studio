# frozen_string_literal: true

require_relative "cert_orphan_guard"

# CertProcess — run a cert lane so that it CANNOT outlive the cert.
#
# The lanes used to run through a bare `system(env, cmd, chdir: root)`. That puts
# the suite in the cert's OWN process group and installs no handler, so a signal
# aimed at the cert never reaches the suite: the harness's 120s Bash timeout killed
# `ruby bin/fast-check` and left `ruby bin/rails test` running with PPID 1, holding
# an open PG connection to the worktree test DB. Retries then died on
# PG::ObjectInUse — blamed on "an ENV gap" — for as long as the orphan lived.
#
# So a lane now runs in its OWN process group (`pgroup: true`), and the cert reaps
# that GROUP — not just the leader — on every death it can catch:
#
#   SIGTERM / SIGINT / SIGHUP  → trap: reap the group, clear the lock, exit
#   an exception / early abort → ensure: same
#   SIGKILL                    → no handler can run. THIS is why the runlock exists:
#                                the group we could not reap is named in the lock,
#                                and the NEXT cert reaps it (CertOrphanGuard).
#
# The GROUP is the unit that matters: the suite forks (a `sh -c` wrapper, Rails'
# own children), and killing only the leader strands the rest on the DB.
#
# A lane also cannot run FOREVER. `run` used to block in `waitpid2` with no ceiling, so
# a runner that deadlocked took the cert down with it: measured 2026-08-21, a turf-monster
# mapped-tests lane sat 41 minutes at 0.0% CPU and the cert then reported "lane(s) RED:
# mapped-tests" — a verdict about tests, when no test had run. Every agent that hit it
# burned its whole harness budget and retried into the same wall. So a lane may be given a
# `timeout:`; past it the wait gives up, reads the process table BEFORE the reap, and
# returns `:timeout` with a signature naming what the runner was doing. FAIL LOUD AND
# ACCURATE BEATS FAIL SLOW AND WRONG — and a ceiling is worth having even when today's
# deadlock is environmental, because the next one will not announce itself either.
#
# WHAT THE SIGNATURE IS ALLOWED TO CLAIM. The ceiling was the easy half; saying what the
# runner was DOING is the hard one, and this file got it wrong for a while. It inferred a
# hang from near-zero CPU on the process-group LEADER — but a cert lane's leader is a
# WRAPPER that idles by design while its child works, so on 2026-09-01 it told three
# different agents their healthy lanes were "PARKED, not working". All three were being
# starved by a loaded machine (load 111; load 244; a release sweep colliding), and the
# damage was the REPAIR the word invites: kill the run, hunt a deadlock, raise a shared
# ceiling. So the evidence rules are now explicit — sample the whole GROUP, never its
# leader; prefer OUTPUT LIVENESS over CPU, because a subprocess-bound lane burns no CPU
# either way while only a working one keeps writing; carry the machine's load and swap in
# every verdict; and where the evidence cannot separate waiting from hung, SAY SO rather
# than pick. A confident wrong diagnosis costs more than an honest "I cannot tell".
module CertProcess
  SIGNALS = %w[TERM INT HUP].freeze

  # How often a bounded wait re-checks a running lane. Invisible against a lane measured
  # in minutes, and it keeps the ceiling's resolution well under a second.
  POLL_INTERVAL = 0.25

  # How fresh the lane's own output must be to count as PROOF OF WORK.
  #
  # Generous ON PURPOSE, and the asymmetry is the whole point: reading a live lane as
  # merely slow costs the reader nothing (that IS the honest fallback), while reading a
  # slow lane as parked is the bug this window exists to prevent. Carl's lane was writing
  # dots four seconds before it was sampled; a runner blocked on a lock does not do that.
  OUTPUT_FRESH_WINDOW = 120.0

  # The lane's own output stream, as a FILE we can stat.
  #
  # The runner's stdout is the CERT's stdout — inherited, never captured — so the progress
  # marks an agent watches scroll past are not ours to read. A Rails lane's durable
  # equivalent is log/test.log: every query it runs lands there, which is exactly how all
  # three false PARKED calls were refuted after the fact.
  OUTPUT_PATHS = ["log/test.log"].freeze

  # What the lane's output did WHILE WE WAITED.
  #
  # `grew` is measured against a baseline taken BEFORE the wait, so a log left fresh by a
  # previous run — or touched by a neighbour — cannot masquerade as this lane working.
  # `age` is wall-clock since the last write. Together they are the discriminator that CPU
  # cannot be: a subprocess-bound parent burns no CPU whether it is working or hung, but
  # only a working lane keeps advancing its output.
  Output = Struct.new(:path, :age, :grew, keyword_init: true) do
    def advancing?
      grew && !age.nil? && age <= OUTPUT_FRESH_WINDOW
    end

    def to_fact
      return "#{path}: gone" if age.nil?

      "#{path} last written #{CertProcess.humanize_age(age)} ago" \
        "#{grew ? " and it GREW while we waited" : ' but it did NOT grow while we waited'}"
    end
  end

  # Machine pressure — the number every reader of a hang verdict had to go and find for
  # themselves. All three false positives on 2026-09-01 were SATURATION (15-minute load of
  # 111; load 244.50 with 860 MB of swap left; a release sweep colliding), and in each case
  # the load average was the fact that settled it. It costs one sysctl to carry it here
  # instead of leaving it as homework.
  Pressure = Struct.new(:load1, :load5, :load15, :swap_free_mb, :swap_total_mb, keyword_init: true) do
    def to_sentence
      parts = []
      parts << "load is #{format('%.2f', load1)} (5m #{format('%.2f', load5)}, " \
               "15m #{format('%.2f', load15)})" if load1
      parts << "swap #{format('%.0f', swap_free_mb)} MB free of #{format('%.0f', swap_total_mb)} MB" if swap_total_mb
      parts.empty? ? "machine pressure unreadable" : parts.join(", ")
    end
  end

  # What the lane DID, as distinct from what it returned:
  #   :completed — the runner produced a verdict; `ok` carries it
  #   :timeout   — the runner produced NO verdict inside its ceiling; `detail` says what
  #                the process table showed at the moment we gave up
  #
  # `ok` is FALSE for :timeout, which is the load-bearing property: `run` still returns a
  # plain boolean, so a caller that never learns about outcomes still fails CLOSED. The one
  # thing a hung runner must never do is certify. (This is why `run_bounded` returns a
  # Struct and `run` returns `.ok` — a truthy `:timeout` symbol handed back from `run`
  # would have read as PASS at every existing call site.)
  Result = Struct.new(:ok, :outcome, :detail, keyword_init: true) do
    def timeout?
      outcome == :timeout
    end

    # The lane never STARTED — the command does not exist, or is not executable.
    # A third verdict alongside green/red/hung, because it is a different repair:
    # nothing ran, so the diff was never judged, and the fix is the COMMAND, not
    # the code.
    def unlaunchable?
      outcome == :unlaunchable
    end
  end

  # Run `cmd` in its own process group; return true when it exits 0.
  #
  # This is the boolean face of `run_bounded` and the API every existing caller uses. A
  # timed-out lane returns false here, with the diagnosis discarded — pass `timeout:` and
  # call `run_bounded` when you want to TELL a hang apart from a red suite.
  #
  # root/lane/db: when a root is given the runlock is written for the lifetime of
  # the lane, so a SIGKILLed cert leaves behind a record of the group it stranded.
  #
  # We record the OS's start time for BOTH pids the lock names — this cert, and the
  # group leader we just spawned. A pgid is a recyclable integer, so a later cert
  # reading this lock cannot tell "our stranded suite" from "a stranger who inherited
  # the number" unless we leave it something that identifies the process rather than
  # merely addresses it. The start time is that identity, and CertOrphanGuard refuses
  # to kill anything it cannot match against it.
  # `ps:` is the guard's own injection seam (CERT_GUARD_PS). It threads through every
  # process-table read this file makes — including the two `process_started_at` calls that
  # RECORD the identity. They used to hardcode the default `ps`, which meant the identity
  # half of the lock could not be driven from a fixture, which is precisely why `with_traps`
  # had NO test: you cannot test a reap you cannot make fail.
  def self.run(env, cmd, chdir:, root: nil, lane: nil, db: nil, ps: CertOrphanGuard.ps_bin, timeout: nil,
               on_signal: nil)
    run_bounded(env, cmd, chdir: chdir, root: root, lane: lane, db: db, ps: ps, timeout: timeout,
                on_signal: on_signal).ok
  end

  # The same run, reporting the OUTCOME as well as the verdict. `timeout` is in seconds;
  # nil (or non-positive) means no ceiling and an ordinary blocking wait, exactly as before.
  def self.run_bounded(env, cmd, chdir:, root: nil, lane: nil, db: nil, ps: CertOrphanGuard.ps_bin,
                       timeout: nil, on_signal: nil)
    # A COMMAND THAT DOES NOT EXIST IS A RED LANE, NOT A CRASH. Process.spawn
    # raises Errno::ENOENT, and unrescued it took the whole cert down with a
    # stack trace — mid-run, AFTER the g1_cert attempt had opened, which no
    # `emit_gate --failed` then closed. The board reads that as a STALLED lane
    # and the builder gets a backtrace instead of a verdict.
    #
    # It is reachable for real: a gem repo whose registry row names a
    # `release_check` the checkout does not carry, a lane command renamed in one
    # repo and not another, a bin/ script that lost its +x bit. Reporting it as a
    # lane result keeps the ordinary failure path — evidence withheld, gate
    # closed failed, exit non-zero — and names the actual repair.
    pid = begin
      Process.spawn(env, cmd, chdir: chdir, pgroup: true)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
      return Result.new(ok: false, outcome: :unlaunchable, detail: "#{cmd}: #{e.message}")
    end
    pgid = begin
      Process.getpgid(pid)
    rescue Errno::ESRCH
      pid # it already exited; its own pid is the best group id we have
    end
    started_at = CertOrphanGuard.process_started_at(pid, ps: ps)

    if root
      CertOrphanGuard.write_lock(root, cert_pid: Process.pid, pgid: pgid,
                                 cert_started_at: CertOrphanGuard.process_started_at(Process.pid, ps: ps),
                                 pgid_started_at: started_at, lane: lane, db: db)
    end

    with_traps(pgid, started_at, root, ps: ps, on_signal: on_signal) do
      wait_bounded(pid, pgid, timeout: timeout, ps: ps, root: root)
    end
  ensure
    # Any abnormal exit (exception, `abort`, a trap that re-raises): never leave the
    # group behind. `settle` re-proves ownership before it signals, so this is a no-op
    # when the lane already exited and refuses outright if the number has been handed to
    # somebody else in the meantime.
    settle(pgid, started_at, root, ps: ps) if pgid
    # And CLAIM THE CORPSE. On the normal path `waitpid2` already reaped the lane; on the
    # TIMEOUT path nothing has, so the killed child lingers as a ZOMBIE of this cert for as
    # long as the cert lives. A zombie holds no DB connection, but it still answers
    # `kill(0)` — so every "is the lane gone?" probe, ours and the operator's alike, reads
    # a corpse as a live orphan. Reap it here and the question has an honest answer.
    reap_child(pid) if pid
  end

  def self.reap_child(pid)
    Process.waitpid(pid, Process::WNOHANG)
  rescue Errno::ECHILD, Errno::ESRCH
    nil # already reaped by the normal path, or never ours
  end

  # Wait for the lane, with or without a ceiling.
  #
  # No ceiling → the original blocking `waitpid2`, byte for byte. With one → poll with
  # WNOHANG until the deadline. Polling (rather than a timer thread) keeps the whole wait
  # on the main thread, where `with_traps`' handlers already live: a signal arriving mid-
  # wait must reap the group and `exit!`, and that is far easier to reason about when
  # there is no second thread holding a half-finished waitpid.
  def self.wait_bounded(pid, pgid, timeout: nil, ps: "ps", root: nil)
    unless timeout.is_a?(Numeric) && timeout.positive?
      _, status = Process.waitpid2(pid)
      return Result.new(ok: status.success?, outcome: :completed)
    end

    # BASELINE THE OUTPUT BEFORE THE WAIT. Freshness alone would let a log left behind by
    # the PREVIOUS run vouch for this one; measured against a baseline, only growth on our
    # own watch counts as evidence.
    baseline = output_probe(root)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      reaped = Process.waitpid2(pid, Process::WNOHANG)
      return Result.new(ok: reaped[1].success?, outcome: :completed) if reaped
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep POLL_INTERVAL
    end

    # READ THE TABLE BEFORE THE REAP. `run_bounded`'s ensure kills this group on the way
    # out; after that there is nothing left to diagnose, and the verdict would be reduced
    # to "it took too long" — which is the uninformative half of the bug we are fixing.
    Result.new(ok: false, outcome: :timeout,
               detail: hang_signature(pgid, timeout: timeout, ps: ps, root: root,
                                      baseline: baseline))
  end

  # What the process table says a hung lane was DOING — the sentence that tells a DEADLOCK
  # apart from slow work, written for whoever reads the cert's last screen.
  #
  # The strongest signature we can read is the one measured on 2026-08-21: the runner alive
  # and every one of its children a ZOMBIE. Rails' `parallelize` forks workers and hands
  # them work over a DRb channel; when the workers die AT the fork (locally, the pg
  # fork-safety SIGSEGV in `pg/connection.rb`, `connect_start`, before any test runs) the
  # parent waits for results that can never arrive. Fourteen corpses and a parked parent is
  # not a slow suite, and the cert should say so instead of guessing.
  def self.hang_signature(pgid, timeout:, ps: "ps", root: nil, baseline: nil,
                          pressure: pressure_reading)
    table = CertOrphanGuard.process_table(ps: ps)
    members = table.select { |p| p[:pgid] == pgid.to_i }
    zombies, live = members.partition { |p| CertOrphanGuard.zombie?(p) }
    cpu = group_cpu_seconds(live, ps: ps)
    output = output_progress(root, baseline: baseline)

    facts = ["process group #{pgid}: #{live.size} live, #{zombies.size} zombie"]
    facts << "the group burned #{format('%.1fs', cpu)} of CPU across " \
             "#{format('%.0fs', timeout)} of wall clock" if cpu
    facts << output.to_fact if output
    facts << "machine: #{pressure.to_sentence}" if pressure

    "#{facts.join('; ')}. #{diagnosis(zombies: zombies.size, live: live.size, cpu: cpu,
                                      timeout: timeout, output: output, pressure: pressure)}"
  end

  # CPU burned by the WHOLE process group, not by whichever member happens to lead it.
  #
  # THE BUG THIS REPLACES, in one line: `live.find { |p| p[:pid] == pgid } || live.first`
  # sampled the group LEADER. A cert lane's leader is a WRAPPER — `sh -c`, `bin/rails`, an
  # Open3 parent — that blocks BY DESIGN while its child does the work, so the number this
  # produced was an idle parent's and the diagnosis built on it was "PARKED, not working".
  # Measured three times on 2026-09-01: a leader at 0.1s in front of a runner that had
  # burned 52s; a leader in front of children that had emitted 757 progress marks.
  #
  # nil when we could read NOTHING — `parse_cpu_time`'s fabrication guard, one level up. A
  # PARTIAL read is honest (it is a floor on the group's CPU, and a floor is what the
  # threshold needs); an empty one is not evidence at all, and zero is the input to a hang
  # verdict, so inventing it is precisely how this file would lie with confidence.
  def self.group_cpu_seconds(live, ps: "ps")
    readings = live.filter_map { |p| cpu_seconds(p[:pid], ps: ps) }
    return nil if readings.empty?

    readings.sum
  end

  # The newest lane output file under `root`, as {path:, size:, mtime:} — or nil when there
  # is nothing to read. `path` is kept RELATIVE because it is printed at the reader.
  def self.output_probe(root)
    return nil unless root

    OUTPUT_PATHS.each do |rel|
      stat = File.stat(File.join(root.to_s, rel))
      return { path: rel, size: stat.size, mtime: stat.mtime }
    rescue SystemCallError
      next
    end
    nil
  end

  # Compare the output now against the baseline taken before the wait.
  def self.output_progress(root, baseline: nil, now: Time.now)
    current = output_probe(root)
    return nil unless current || baseline
    return Output.new(path: baseline[:path], age: nil, grew: false) unless current

    grew = baseline.nil? ? current[:size].positive? : current[:size] > baseline[:size]
    Output.new(path: current[:path], age: (now - current[:mtime]).to_f, grew: grew)
  end

  # The named signatures, most specific first. Anything we cannot recognise gets an honest
  # "we do not know" rather than a confident wrong answer — a diagnosis this file invents
  # is the same failure as the "lane(s) RED" it replaces.
  #
  # ADVANCING OUTPUT OUTRANKS A LOW CPU READING, and that ordering is the fix. The middle
  # branch used to fire on near-zero CPU alone and print "the runner is PARKED, not
  # working". CPU cannot carry that claim: a subprocess-bound lane's parent burns none
  # whether it is working or hung, and a machine under load starves a healthy lane into the
  # identical shape. Output can — a lane still writing its log four seconds ago is working,
  # and a lane blocked on a lock is not writing anything. So when the output advanced we
  # fall through to the ceiling branch, which was the CORRECT reading in all three measured
  # false positives.
  def self.diagnosis(zombies:, live:, cpu:, timeout:, output: nil, pressure: nil)
    if zombies.positive? && live <= 1
      "SIGNATURE: the forked test workers are DEAD (#{zombies} zombie(s)) and the runner is still " \
        "waiting on them over its DRb channel — results that can never arrive. Locally this is the pg " \
        "fork-safety SIGSEGV at the fork (pg/connection.rb, connect_start), before any test runs. " \
        "Re-run the lane with PARALLEL_WORKERS=1."
    elsif cpu && cpu < [timeout * 0.02, 5.0].max && !output&.advancing?
      idle_diagnosis(output, pressure)
    else
      slow_diagnosis(output, pressure)
    end
  end

  # WHAT THIS DELIBERATELY NO LONGER SAYS: "the runner is PARKED, not working."
  #
  # That sentence asserted a HANG from evidence that cannot tell a hang from a wait, and on
  # 2026-09-01 it was wrong three times in one day — to three different agents, in two
  # different runners, every one of them actually being starved by a loaded machine. The
  # cost was never the wrong word; it was the wrong REPAIR it invites: kill the run, hunt a
  # deadlock, or raise a shared ceiling. One agent came within a keystroke of raising
  # FAST_CHECK_LANE_TIMEOUT and refused only because he had measured the opposite; a clean
  # re-run later finished comfortably under the UNCHANGED ceiling. Raising it would have
  # hidden every future sweep collision behind a bigger number, permanently.
  #
  # So: say what was SEEN, name the other explanation, and put the numbers that settle it in
  # the same breath. "No CPU, and this may be saturation — load is N, swap is M" would have
  # been TRUE in all three cases; "PARKED" was true in none.
  def self.idle_diagnosis(output, pressure)
    # SAY WHICH IT WAS. "No output advanced" is a MEASUREMENT; when there is no log to read
    # we made no measurement at all, and reporting the two as one sentence is a smaller
    # version of the same over-claim this whole file just stopped making.
    output_clause = if output.nil?
                      "and no lane output we know how to read (#{OUTPUT_PATHS.join(', ')}) exists here, " \
                        "so nothing corroborates either way"
                    else
                      "and #{output.path} did not advance while we waited"
                    end
    "SIGNATURE: no CPU worth the name anywhere in the process group, #{output_clause}. That is " \
      "consistent with a BLOCK (a channel, a lock, a database connection) — and equally consistent " \
      "with SATURATION starving a healthy lane" \
      "#{pressure ? ": #{pressure.to_sentence}" : ''}. CHECK THE LOAD BEFORE YOU HUNT A DEADLOCK. " \
      "Re-run on a quiet machine first; if it passes there, the ceiling was never the problem."
  end

  # The branch that was RIGHT all three times, now able to say why.
  def self.slow_diagnosis(output, pressure)
    seen = if output&.advancing?
             "the lane was still WRITING OUTPUT #{humanize_age(output.age)} before we gave up, so it " \
               "was working rather than blocked, and "
           else
             ""
           end
    "No known deadlock signature: #{seen}the runner may simply be slower than this ceiling allows" \
      "#{pressure ? " (#{pressure.to_sentence})" : ''}. Raise the ceiling deliberately if so, and " \
      "record what you measured — but if the machine was merely BUSY, the remedy is to wait or to " \
      "reduce concurrency, not a bigger ceiling."
  end

  # Read the machine's load and swap. Nil when this platform reports neither, so a verdict
  # never carries a pressure claim we could not actually measure.
  def self.pressure_reading(sysctl: "sysctl")
    load = parse_loadavg(read_file("/proc/loadavg") || run_quietly(sysctl, "-n", "vm.loadavg"))
    swap = parse_meminfo_swap(read_file("/proc/meminfo")) ||
           parse_swapusage(run_quietly(sysctl, "-n", "vm.swapusage"))
    return nil unless load || swap

    Pressure.new(load1: load&.first, load5: load&.at(1), load15: load&.last,
                 swap_free_mb: swap&.first, swap_total_mb: swap&.last)
  end

  # `sysctl -n vm.loadavg` renders "{ 6.00 7.01 12.46 }"; /proc/loadavg renders
  # "6.00 7.01 12.46 1/2 3". One parser reads both: take the first three decimals and
  # REFUSE anything else — a fabricated load average inside a saturation verdict is the
  # same disease as a fabricated CPU reading, and this file already learned that one.
  def self.parse_loadavg(text)
    numbers = text.to_s.scan(/\d+\.\d+/).first(3).map(&:to_f)
    numbers.size == 3 ? numbers : nil
  end

  # `sysctl -n vm.swapusage` → "total = 24576.00M  used = 23001.25M  free = 1574.75M".
  def self.parse_swapusage(text)
    total = text.to_s[/total\s*=\s*([\d.]+)M/, 1]
    free  = text.to_s[/free\s*=\s*([\d.]+)M/, 1]
    return nil unless total && free

    [free.to_f, total.to_f]
  end

  # /proc/meminfo → "SwapTotal:  4194304 kB" / "SwapFree:  2097152 kB".
  def self.parse_meminfo_swap(text)
    total = text.to_s[/^SwapTotal:\s+(\d+) kB/, 1]
    free  = text.to_s[/^SwapFree:\s+(\d+) kB/, 1]
    return nil unless total && free

    [free.to_f / 1024, total.to_f / 1024]
  end

  # A stale log is the load-bearing half of the idle signature, so its age has to READ
  # correctly at a glance. Measured against a log left over from January, the raw seconds
  # rendered as "21040718s ago" — arithmetic homework inside the one message whose entire
  # job is to be understood on the first pass.
  def self.humanize_age(seconds)
    seconds = seconds.to_f
    return format("%.0fs", seconds) if seconds < 90
    return format("%.0fm", seconds / 60) if seconds < 3600
    return format("%.1fh", seconds / 3600) if seconds < 172_800

    format("%.1f days", seconds / 86_400)
  end

  def self.read_file(path)
    File.read(path)
  rescue SystemCallError
    nil
  end

  def self.run_quietly(*cmd)
    out = IO.popen(cmd, err: File::NULL, &:read).to_s
    $?.success? ? out : nil
  rescue Errno::ENOENT, SystemCallError
    nil
  end

  # CPU seconds consumed by one pid, or nil when we cannot read it honestly.
  #
  # `ps -o time=` renders as [[DD-]HH:]MM:SS[.ss]. The format is matched STRICTLY before it
  # is parsed: a fixture `ps` (the CERT_GUARD_PS seam) answers a shape it was not written
  # for with arbitrary text, and `"Jul 8 09".split(":").map(&:to_f)` yields a perfectly
  # confident 0.0. A diagnostic that fabricates its evidence is worse than no diagnostic.
  def self.cpu_seconds(pid, ps: "ps")
    out = IO.popen([ps, "-p", pid.to_s, "-o", "time="], err: File::NULL, &:read).to_s.strip
    return nil unless $?.success?

    parse_cpu_time(out)
  rescue Errno::ENOENT, SystemCallError
    nil
  end

  def self.parse_cpu_time(text)
    match = /\A(?:(\d+)-)?(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)\z/.match(text.to_s.strip)
    return nil unless match

    days, hours, minutes, seconds = match.captures
    (days.to_i * 86_400) + (hours.to_i * 3600) + (minutes.to_i * 60) + seconds.to_f
  end

  # The last screen an agent reads when a lane never returned, as an array of lines.
  #
  # It has exactly ONE job: TO NOT BE MISTAKEN FOR A TEST FAILURE. The bug this whole
  # ceiling exists for was not the deadlock — it was that the deadlock was REPORTED as
  # "lane(s) RED", which every agent reads as "your tests failed", so the next move is
  # always a re-run into the same wall. So: name the RUNNER, say plainly that no verdict
  # was produced, print the ceiling, and hand over the process table's signature.
  #
  # Shared by both certs rather than written twice: two copies of a message drift, and
  # the half that drifts is always the one nobody is currently reading.
  def self.timeout_report(hung, ceiling:, tool:, env_var:)
    lines = ["", "#{tool}: lane(s) TIMED OUT: #{hung.keys.join(', ')} — THE RUNNER HUNG.",
             "  This is NOT a test failure and NOT a verdict on your diff: the runner never produced a",
             "  result at all. It was given #{ceiling}s of wall clock and did not return."]
    hung.each { |label, result| lines << "  #{label}: #{result.detail}" if result.detail }
    lines << "  Nothing certified. Diagnose the RUNNER — re-running will not produce a different suite result."
    lines << "  Raise the ceiling with #{env_var}=<seconds>, but only once you have MEASURED that the lane"
    lines << "  is genuinely that slow; record the measurement where the default is set."
    lines << ""
  end

  # Reap the group, then decide — ON THE OUTCOME — whether the runlock may be cleared.
  #
  # THE LOCK IS THE ONLY RECORD NAMING A PROCESS WE COULD NOT KILL. This code used to
  # DISCARD the reap's return, clear the lock unconditionally, and announce "no orphan left
  # behind" — a reap it may never have performed. `reap_group` does not signal at all when
  # it cannot prove the group is ours (a recycled pgid, or a nil `started_at` because the
  # `ps` at spawn returned nothing). So the cert destroyed the only evidence naming the
  # orphan and declared it gone; the next cert's preflight then graded `:none`, and the
  # entire DETECT half never ran. A detectable orphan became an UNNAMEABLE one — strictly
  # worse than the orphan bug this file exists to fix.
  #
  # The lock now survives exactly when the group does. `reap_cleared?` is the tri-state
  # gate: `:reaped` and `:absent` mean the group is gone and we know it — clear the lock.
  # `:survived` and `:refused` mean something is still out there — KEEP it. (A naive
  # `if reaped` gate would strand a stale lock behind every CLEAN cert, because a clean
  # lane's group is already gone: that is `:absent`, not a refusal. The tri-state exists
  # to keep those two apart.)
  def self.settle(pgid, started_at, root, ps: "ps")
    outcome = CertOrphanGuard.reap_group(pgid, started_at: started_at, ps: ps)
    CertOrphanGuard.clear_lock(root) if root && CertOrphanGuard.reap_cleared?(outcome)
    outcome
  end

  # Install group-reaping handlers for the duration of the block, then restore the
  # previous ones. The handler does its own cleanup and exit!s: an `exit` inside a
  # trap would unwind through ensure blocks while signals are still in flight, and
  # we want the reap to be the last thing that happens, deterministically.
  #
  # THE INTERRUPT CONTRACT, and why `on_signal` exists. `exit!` skips every ensure
  # block and at_exit hook in the cert — which is the point for the REAP (it must
  # be last and deterministic), but it also skipped the cert's own G1 closure. A
  # cert killed by Ctrl-C therefore left its g1_cert attempt open forever, and the
  # board's local-check indicator (Cert::LocalCheck) reads an open attempt with a
  # `running` lane as a cert that is still going: the killed run showed as STALLED
  # on the card for the rest of the task's life, and every re-run opened another
  # attempt beside it.
  #
  # A catchable signal is not an unknowable death. We are still executing; we can
  # still say what happened. So the caller passes a closure that stops its
  # heartbeat and closes the gate, and it runs AFTER the reap (the suite dies
  # first, always) and BEFORE `exit!`. STALLED is thereby reserved for the deaths
  # where no code of ours could run — SIGKILL, a lost machine — which is the only
  # honest reading of it.
  #
  # The closure is best-effort BY CONSTRUCTION: it runs inside a trap handler, so
  # it must not raise and must not take a lock (Mutex#synchronize raises in trap
  # context — see CertEmission::Heartbeat#stop_now). A failure here is reported
  # and then abandoned; nothing may keep the reap from reaching its exit.
  def self.with_traps(pgid, started_at, root, ps: "ps", on_signal: nil)
    previous = SIGNALS.to_h do |sig|
      [sig, Signal.trap(sig) do
        outcome = settle(pgid, started_at, root, ps: ps)
        warn "cert: signal SIG#{sig} — #{reap_report(pgid, outcome, root)}"
        close_on_signal(on_signal, sig)
        exit!(128 + Signal.list.fetch(sig, 15))
      end]
    end
    yield
  ensure
    previous&.each { |sig, handler| Signal.trap(sig, handler || "DEFAULT") }
  end

  # Run the caller's interrupt closure, swallowing anything it throws. A cert
  # dying under an operator has ONE remaining duty — reap the suite and go — and
  # a raise in the bookkeeping must not cost them that.
  def self.close_on_signal(on_signal, sig)
    return unless on_signal

    on_signal.call(sig)
  rescue StandardError, ScriptError => e
    warn "cert: could not close the gate on SIG#{sig} (#{e.class}: #{e.message}) — " \
         "the board may still show this cert running until the next attempt supersedes it."
  end

  # Report what ACTUALLY happened. A cert that announces a kill it did not perform is back
  # to asserting rather than evidencing — the exact disease this guard exists to cure, and
  # the loudest possible place to relapse into it is the line an operator reads while their
  # cert is dying under them.
  def self.reap_report(pgid, outcome, root)
    case outcome
    when :reaped
      "reaped the suite's process group #{pgid} (no orphan left behind)."
    when :absent
      "the suite's process group #{pgid} was already gone — nothing to reap."
    else
      lock = root ? CertOrphanGuard.lock_path(root) : nil
      "could NOT reap the suite's process group #{pgid} (#{outcome}). An orphan MAY still be " \
        "holding the test DB. The runlock is LEFT IN PLACE ON PURPOSE#{lock ? " (#{lock})" : ''} — " \
        "it NAMES the process, and the next cert will find it and say so. " \
        "Inspect: #{CertOrphanGuard.inspect_command(pgid)}"
    end
  end
end
