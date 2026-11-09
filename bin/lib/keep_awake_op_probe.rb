# frozen_string_literal: true

require "English"
require "time"
require_relative "bounded_command"
require_relative "op_meter"

# KeepAwake::OpProbe — the keep-awake supervisor's 1Password watch.
#
# WHY (2026-11-09). From 03:41 to 07:29 MST every `op` call hung, even
# `OP_CACHE=false op whoami` with the service-account token. The Mac was awake
# (keep-awake held caffeinate -dims, the display on), but nobody had touched it
# since 03:30. The cause is not proven. This probe collects the evidence: while a
# hold is live, the supervisor runs one bounded `op whoami` about every 25
# minutes and logs the time, the outcome and how long the user has been idle.
# A hang window then lines up against user-idle time, and against
# op-reads.log, without anyone awake to watch it.
#
# ONE PROBE PER SUPERVISOR, NOT PER RENEW. Every holder renews about every 25
# minutes. If `renew` probed, N holders would spend N reads and each renew would
# block for up to 20 seconds. So the one supervisor probes at the renewal
# cadence (EVERY), and at HUNG_EVERY while a hang is open, so the window's edges
# are tight.
#
# THE COST. `op whoami` was measured on 2026-10-24 to move neither the
# token's read counter nor the account's read_write counter
# (bin/lib/agent_harness_probe.rb). Budget it as one read anyway, about 58 a day
# of holding, in case that changes. Every probe is recorded through OpMeter
# (action `whoami`, via `keep-awake`; a hang is `timeout`), so `bin/op-reads`
# counts it like any other call.
#
# THE TOKEN. The probe runs with the supervisor's environment, which it
# inherited from the agent shell that ran `keep-awake start`, so it carries the
# service-account token that shell had. A supervisor started with no token logs
# fail:<exit> (op answered, not signed in), never hung.
#
# THE BOUND. The probe goes through OpMeter.popen, the one metered way into `op`
# (test/lib/op_reads_are_bounded_test.rb), with deadline: DEADLINE (20 seconds)
# and retry_uncached: false. popen runs it in its own process group (its pgid is
# its own pid), and at the deadline BoundedCommand SIGKILLs that group: the
# probe's own process and nothing else. There is no retry: the
# probe exists to observe a hang, not to work around it. OP_CACHE=false keeps the
# 1Password cache daemon out of the path, so a hang here is the CLI, the app or
# the network.
#
# THE LOG. <keep-awake dir>/op-probe.log, one TAB-separated row per probe:
#   ts  outcome  seconds  idle_seconds  pid
# outcome is ok, hung, or fail:<exit>. idle_seconds is "-" when ioreg gives no
# HIDIdleTime. op-probe.noted holds the start of the last hang window that
# posted its one note.
module KeepAwake
  module OpProbe
    LOG = "op-probe.log"
    DEADLINE = 20
    EVERY = 25 * 60
    HUNG_EVERY = 5 * 60
    NOTE_AFTER = 10 * 60
    IDLE_DEADLINE = 5
    OP = "/opt/homebrew/bin/op"
    IOREG = "/usr/sbin/ioreg"
    VIA = "keep-awake"
    OK = "ok"
    HUNG = "hung"
    BLANK = "-"
    TAIL_BYTES = 262_144
    IDLE = /"HIDIdleTime"\s*=\s*(\d+)/.freeze

    module_function

    # Seconds from an env var: a positive number, "0" (= off, nil), or the default.
    def seconds(env, key, default)
      raw = env[key].to_s.strip
      return default if raw.empty?

      value = Float(raw, exception: false)
      return default if value.nil?

      value.positive? ? value : nil
    end

    def deadline(env = ENV)
      seconds(env, "MCR_KEEP_AWAKE_PROBE_DEADLINE", DEADLINE) || DEADLINE
    end

    # nil when MCR_KEEP_AWAKE_PROBE_EVERY is "0": the probe is off.
    def every(env = ENV)
      seconds(env, "MCR_KEEP_AWAKE_PROBE_EVERY", EVERY)
    end

    def hung_every(env = ENV)
      seconds(env, "MCR_KEEP_AWAKE_PROBE_HUNG_EVERY", HUNG_EVERY) || HUNG_EVERY
    end

    def note_after(env = ENV)
      seconds(env, "MCR_KEEP_AWAKE_PROBE_NOTE_AFTER", NOTE_AFTER) || NOTE_AFTER
    end

    def op_bin(env = ENV)
      override = env["MCR_KEEP_AWAKE_OP"].to_s.strip
      override.empty? ? OP : override
    end

    def ioreg_bin(env = ENV)
      override = env["MCR_KEEP_AWAKE_IOREG"].to_s.strip
      override.empty? ? IOREG : override
    end

    def log_path(env = ENV)
      File.join(KeepAwake.dir(env), LOG)
    end

    # Run one probe, log it, meter it. Returns the row as a hash. Never raises
    # a SystemCallError: an absent `op` is a fail:127 row, which is evidence too.
    def run(env: ENV, now: Time.now.utc, idle: nil)
      started = monotonic
      outcome = attempt(env)
      elapsed = (monotonic - started).round(1)
      idle_s = idle ? idle.call : idle_seconds(env)
      row = { "ts" => now.utc.iso8601, "outcome" => outcome, "seconds" => elapsed,
              "idle_seconds" => idle_s, "pid" => Process.pid }
      append(row, env)
      row
    end

    # One metered attempt through OpMeter.popen, which records the row in
    # op-reads.log itself. retry_uncached: false, because the probe observes the
    # hang rather than working around it; announce: false, because the
    # supervisor log is not a terminal. `$?` after popen is the attempt's status.
    def attempt(env)
      OpMeter.popen({ "OP_CACHE" => "false" }, [ op_bin(env), "whoami" ], via: VIA, env: env, announce: false,
                                                                            deadline: deadline(env), retry_uncached: false, err: File::NULL)
      return HUNG if OpMeter.last_hung?

      status = $CHILD_STATUS
      status&.success? ? OK : "fail:#{status&.exitstatus || '?'}"
    rescue SystemCallError => e
      e.is_a?(Errno::EACCES) ? "fail:126" : "fail:127"
    end

    # Seconds since the last keyboard or mouse event (IOHIDSystem's
    # HIDIdleTime, in nanoseconds), or nil when ioreg cannot say.
    def idle_seconds(env = ENV)
      result = BoundedCommand.run({}, [ ioreg_bin(env), "-c", "IOHIDSystem" ],
                                  deadline: IDLE_DEADLINE, pgroup: true, in: File::NULL, err: File::NULL)
      return nil if result.timed_out?

      parse_idle(result.out)
    rescue SystemCallError
      nil
    end

    def parse_idle(text)
      m = IDLE.match(text.to_s)
      m ? m[1].to_i / 1_000_000_000 : nil
    end

    # Every row in the log's tail, oldest first, as hashes.
    def rows(env = ENV)
      path = log_path(env)
      return [] unless File.file?(path)

      tail = File.open(path) do |f|
        f.seek([ f.size - TAIL_BYTES, 0 ].max)
        f.read.to_s
      end
      tail.lines.filter_map do |line|
        ts, outcome, secs, idle, pid = line.chomp.split("\t")
        next if pid.nil? || ts !~ /\A\d{4}-/

        { "ts" => ts, "outcome" => outcome, "seconds" => secs.to_f,
          "idle_seconds" => idle == BLANK ? nil : idle.to_i, "pid" => pid.to_i }
      end
    rescue SystemCallError
      []
    end

    # Hang windows from rows: a run of hung probes. "start" is the first hung
    # probe, "last_hung" the last, "answered" the next probe that op answered
    # (nil while the hang is open). "minutes" is start to last_hung: the time a
    # hang is PROVEN, not guessed. Any answer, ok or fail, closes a window, and so
    # does a gap longer than one cadence plus a deadline (the hold ended): the next
    # hold's hang is a new window, with its own note.
    def windows(rows, env = ENV)
      gap = (every(env) || EVERY) + deadline(env)
      out = []
      open = nil
      rows.each do |row|
        if open && Time.parse(row["ts"]) - Time.parse(open["last_hung"]) > gap
          out << finish(open.merge("answered" => nil))
          open = nil
        end
        if row["outcome"] == HUNG
          open ||= { "start" => row["ts"], "probes" => 0, "idle_at_start" => row["idle_seconds"] }
          open["last_hung"] = row["ts"]
          open["probes"] += 1
        elsif open
          open["answered"] = row["ts"]
          out << finish(open)
          open = nil
        end
      end
      out << finish(open.merge("answered" => nil)) if open
      out
    end

    def finish(window)
      span = Time.parse(window["last_hung"]) - Time.parse(window["start"])
      window.merge("minutes" => (span / 60.0).round)
    end

    # What `keep-awake status` shows: the last probe and the latest hang window.
    def summary(env = ENV)
      all = rows(env)
      { "last" => all.last, "hang" => windows(all, env).last, "every_seconds" => every(env) }
    rescue StandardError
      { "last" => nil, "hang" => nil, "every_seconds" => nil }
    end

    # The note a hang over NOTE_AFTER earns, once per window; nil otherwise.
    def note_for(window, env = ENV)
      return nil unless window && window["answered"].nil?
      return nil if window["minutes"] * 60 < note_after(env)

      idle = window["idle_at_start"]
      idle_text = idle ? ", user idle #{idle / 60}m at the first" : ""
      "1Password `op` has not answered since #{clock(window["start"])} " \
        "(hung #{clock(window["start"])}-#{clock(window["last_hung"])}, #{window["minutes"]}m, " \
        "#{window["probes"]} probes#{idle_text}). See keep-awake status."
    end

    def clock(iso)
      Time.parse(iso.to_s).localtime.strftime("%H:%M")
    rescue ArgumentError
      iso.to_s
    end

    NOTED = "op-probe.noted"

    # The start of the last hang window that already posted its note.
    def noted_start(env = ENV)
      path = File.join(KeepAwake.dir(env), NOTED)
      File.file?(path) ? File.read(path).strip : nil
    rescue SystemCallError
      nil
    end

    def mark_noted(start, env = ENV)
      File.write(File.join(KeepAwake.dir(env), NOTED), "#{start}\n")
    rescue SystemCallError
      nil
    end

    def append(row, env)
      line = [ utc(row["ts"]), row["outcome"], row["seconds"], row["idle_seconds"] || BLANK, row["pid"] ]
             .map { |v| v.to_s.tr("\t\r\n", "   ") }.join("\t")
      File.open(log_path(env), "a") { |f| f.write("#{line}\n") }
    end

    # Every row is UTC, like op-reads.log and history.log, so they line up.
    def utc(iso)
      Time.parse(iso.to_s).utc.iso8601
    rescue ArgumentError
      iso.to_s
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The supervisor's side: probe when due, and post one note per long hang.
    class Watch
      def initialize(env: ENV, clock: -> { Time.now.utc }, probe: nil, notify: nil)
        @env = env
        @clock = clock
        @probe = probe || -> { OpProbe.run(env: env, now: @clock.call) }
        @notify = notify || ->(message) { KeepAwake.notify(message, env: env) }
        @next_at = nil
      end

      # Called on every supervisor tick. Returns the row when it probed.
      def tick
        interval = OpProbe.every(@env)
        return nil if interval.nil?

        now = @clock.call
        return nil if @next_at && now < @next_at

        row = @probe.call
        @next_at = now + (row["outcome"] == HUNG ? OpProbe.hung_every(@env) : interval)
        note_long_hang
        row
      end

      private

      # The marker lives in a file, not in memory, so a supervisor that
      # restarts in the middle of a hang does not post the same note again.
      def note_long_hang
        window = OpProbe.windows(OpProbe.rows(@env), @env).last
        message = OpProbe.note_for(window, @env)
        return unless message && OpProbe.noted_start(@env) != window["start"]

        OpProbe.mark_noted(window["start"], @env)
        @notify.call(message)
      end
    end
  end
end
