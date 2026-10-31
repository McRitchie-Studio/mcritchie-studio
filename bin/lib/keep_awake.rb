# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "rbconfig"
require "digest"
require_relative "projects_root"
require_relative "../../lib/task_usage_sandbox"

# KeepAwake — ONE shared "keep the Mac awake" hold that any agent can start,
# join, renew and release (bin/keep-awake; SOP:
# docs/agents/agents/steffon/sops/keep-awake.md).
#
# THE SHAPE. A hold is a set of HOLDERS, each with a lease (30 minutes by
# default) that its holder renews. One SUPERVISOR process owns the single
# `caffeinate -dims` and exits the moment every lease has lapsed or been
# released, so an agent that dies lets the Mac sleep again on its own. A
# second `start` while a hold is live JOINS it (adds a holder) instead of
# spawning a second caffeinate: that is the back-off variable, and `status`
# exits 0 only while a hold is live.
#
# ONE FIXED STATE DIR, outside every repo and desk, so every desk and session
# sees the same hold: <projects>/.agents/keep-awake (MCR_KEEP_AWAKE_DIR pins it,
# for tests). It holds state.json (the holders + the supervisor), state.lock
# (the flock every read-modify-write takes), history.log (one TSV row per
# start/join/renew/release/lapse/end, to line hold windows up against
# op-reads.log), supervisor.log, and the compiled menu-bar indicator.
#
# The dir is a state store under the operator's real .agents, so it answers to
# TaskUsageSandbox: `location` is the private builder, `dir` the one laundered
# seam every read and write goes through.
module KeepAwake
  STORE = "keep-awake"
  DEFAULT_LEASE = 30 * 60
  MAX_LEASE = 12 * 3600
  DEFAULT_TICK = 15
  CAFFEINATE = "/usr/bin/caffeinate"
  CAFFEINATE_FLAGS = "-dims"
  OSASCRIPT = "/usr/bin/osascript"
  INDICATOR_SOURCE = File.expand_path("keep_awake_indicator.swift", __dir__)
  TITLE = "Keep Awake"

  DURATION = /\A(\d+)\s*([smh]?)\z/.freeze
  UNITS = { "s" => 1, "m" => 60, "h" => 3600, "" => 60 }.freeze

  class Error < StandardError; end

  module_function

  # "30m", "2h", "90s", "45" (minutes). Raises Error on anything else, and on a
  # lease longer than MAX_LEASE: a hold is meant to be renewed, not parked.
  def parse_duration(value)
    return DEFAULT_LEASE if value.nil? || value.to_s.strip.empty?

    m = DURATION.match(value.to_s.strip.downcase)
    raise Error, "cannot read duration #{value.inspect}: use 30m, 2h or 90s" unless m

    seconds = m[1].to_i * UNITS.fetch(m[2])
    raise Error, "a lease must be at least 1 second" if seconds < 1
    raise Error, "a lease is at most #{MAX_LEASE / 3600}h; renew it instead" if seconds > MAX_LEASE

    seconds
  end

  # THE ONE SEAM to the state dir: every path below hangs off it.
  def dir(env = ENV)
    path = TaskUsageSandbox.enforce!(location(env), store: STORE, env: TaskUsageSandbox.guard_env(env))
    FileUtils.mkdir_p(path)
    path
  end

  def location(env)
    override = env["MCR_KEEP_AWAKE_DIR"].to_s.strip
    return File.expand_path(override) unless override.empty?

    projects = env["CLAUDE_PROJECTS_DIR"].to_s.strip
    projects = ProjectsRoot.default_projects_dir if projects.empty?
    File.join(File.expand_path(projects), ".agents", "keep-awake")
  end
  # PRIVATE, so no caller can take the raw path (state_store_containment_test.rb
  # LAYER 2a); `dir` is the exported, laundered seam.
  private_class_method :location

  # Is +pid+ a live process? EPERM means it exists but is not ours: alive.
  def alive?(pid)
    return false unless pid.to_i.positive?

    Process.kill(0, pid.to_i)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # A live supervisor is a live pid that is still OUR supervisor: a pid the OS
  # has reused for some other program is a stale pid, not a hold.
  def supervisor_alive?(pid)
    return false unless alive?(pid)

    command = IO.popen(["/bin/ps", "-o", "command=", "-p", pid.to_i.to_s], err: File::NULL, &:read).to_s
    command.include?("keep-awake")
  rescue SystemCallError
    false
  end

  # The state file: holders and the supervisor, under one flock.
  class Store
    attr_reader :env

    def initialize(env: ENV, clock: -> { Time.now.utc }, pid_alive: KeepAwake.method(:supervisor_alive?))
      @env = env
      @clock = clock
      @pid_alive = pid_alive
    end

    def now
      @clock.call
    end

    def state_path
      File.join(KeepAwake.dir(env), "state.json")
    end

    def history_path
      File.join(KeepAwake.dir(env), "history.log")
    end

    # Read-modify-write under an exclusive flock; the write is a temp file and
    # a rename, so a reader never sees half a file. The block mutates +state+
    # in place and its value is returned.
    def transaction
      lock = File.join(KeepAwake.dir(env), "state.lock")
      File.open(lock, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        state = read_state
        result = yield state
        write_state(state)
        result
      end
    end

    # A lock-free read: rename makes every write atomic, so this is consistent.
    def read_state
      raw = File.exist?(state_path) ? File.read(state_path) : ""
      state = raw.strip.empty? ? {} : JSON.parse(raw)
      state["holders"] = Array(state["holders"])
      state
    rescue JSON::ParserError
      { "holders" => [] }
    end

    # Start a hold, join a live one, or (same --by) renew it. Prunes lapsed
    # holders first and logs each. When no live supervisor holds the Mac, calls
    # +spawn+ (inside the lock, so two concurrent starts spawn one) and records
    # the pid it returns. Returns { event:, holder:, spawned:, lapsed: }.
    def start(by:, reason:, seconds:, spawn:)
      by = clean_by(by)
      raise Error, "--reason is required" if reason.to_s.strip.empty?

      transaction do |state|
        lapsed = prune(state)
        existing = state["holders"].find { |h| h["by"] == by }
        event = if existing then "renew"
                elsif state["holders"].empty? then "start"
                else "join"
                end
        holder = existing || { "by" => by, "started" => stamp(now) }
        holder["reason"] = reason.to_s.strip
        holder["renewed"] = stamp(now)
        holder["expires"] = stamp(now + seconds)
        state["holders"] << holder unless existing

        spawned = false
        unless supervising?(state)
          pid = spawn.call
          state["supervisor"] = { "pid" => pid, "started" => stamp(now) }
          spawned = true
          event = "start" if event == "join" || event == "renew"
        end
        log(event, holder)
        { event: event, holder: holder.dup, spawned: spawned, lapsed: lapsed }
      end
    end

    # Extend +by+'s live lease. Raises Error when +by+ holds no live lease: a
    # lapsed lease is gone, and coming back is a `start`.
    def renew(by:, seconds:)
      by = clean_by(by)
      transaction do |state|
        lapsed = prune(state)
        holder = state["holders"].find { |h| h["by"] == by }
        raise Error, "#{by} holds no live lease; run `keep-awake start` again" unless holder

        holder["renewed"] = stamp(now)
        holder["expires"] = stamp(now + seconds)
        log("renew", holder)
        { event: "renew", holder: holder.dup, lapsed: lapsed, supervising: supervising?(state) }
      end
    end

    # Release +by+'s lease. Returns { released:, remaining:, supervisor: }; the
    # caller wakes the supervisor when nothing remains.
    def release(by:)
      by = clean_by(by)
      transaction do |state|
        lapsed = prune(state)
        holder = state["holders"].find { |h| h["by"] == by }
        state["holders"].delete(holder) if holder
        log("release", holder) if holder
        { released: !holder.nil?, holder: holder, remaining: state["holders"].size,
          supervisor: state.dig("supervisor", "pid"), lapsed: lapsed }
      end
    end

    # The supervisor's tick: prune, then decide whether it still holds the Mac.
    # It exits (and clears itself, in the same lock, so the next start spawns
    # afresh) when no holder is left or the state names another supervisor.
    def tick(pid:)
      transaction do |state|
        lapsed = prune(state)
        mine = state.dig("supervisor", "pid").to_i == pid.to_i
        done = !mine || state["holders"].empty?
        if done && mine
          state.delete("supervisor")
          log("end", nil)
        end
        { lapsed: lapsed, done: done, ended: done && mine, holders: state["holders"].map(&:dup) }
      end
    end

    # What `status` reports. Lock-free; lapsed leases are filtered, not pruned.
    def status
      state = read_state
      live = state["holders"].select { |h| live?(h) }
      pid = state.dig("supervisor", "pid")
      supervisor_up = pid && @pid_alive.call(pid)
      {
        "held" => !live.empty? && supervisor_up ? true : false,
        "stale" => !live.empty? && !supervisor_up,
        "holders" => live,
        "supervisor" => state["supervisor"],
        "supervisor_alive" => supervisor_up ? true : false,
        "dir" => KeepAwake.dir(env),
        "checked" => stamp(now)
      }
    end

    def history(limit: 20)
      return [] unless File.exist?(history_path)

      File.readlines(history_path).last(limit).map(&:chomp)
    end

    def live?(holder)
      Time.parse(holder["expires"].to_s) > now
    rescue ArgumentError
      false
    end

    private

    def supervising?(state)
      pid = state.dig("supervisor", "pid")
      pid && @pid_alive.call(pid)
    end

    def prune(state)
      lapsed, live = state["holders"].partition { |h| !live?(h) }
      state["holders"] = live
      lapsed.each { |h| log("lapse", h) }
      lapsed
    end

    def write_state(state)
      tmp = "#{state_path}.#{Process.pid}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(state)}\n")
      File.rename(tmp, state_path)
    end

    # history.log: ts, event, by, expires, reason, pid. TAB-separated like
    # op-reads.log, so the two line up by timestamp.
    def log(event, holder)
      row = [stamp(now), event, holder&.dig("by"), holder&.dig("expires"), holder&.dig("reason"), Process.pid]
      line = row.map { |v| v.to_s.tr("\t\r\n", "   ").strip }.map { |v| v.empty? ? "-" : v }.join("\t")
      File.open(history_path, "a") { |f| f.write("#{line}\n") }
    end

    def clean_by(by)
      value = by.to_s.strip
      raise Error, "--by is required (your agent or session name)" if value.empty?

      value
    end

    def stamp(time)
      time.utc.iso8601
    end
  end

  # macOS notification, best effort. MCR_KEEP_AWAKE_NOTIFIER names a stand-in
  # executable (called as `<it> <title> <message>`), or "0" to stay silent.
  def notify(message, env: ENV)
    notifier = env["MCR_KEEP_AWAKE_NOTIFIER"].to_s.strip
    return if notifier == "0"

    argv = if notifier.empty?
             script = "display notification #{applescript(message)} with title #{applescript(TITLE)}"
             [OSASCRIPT, "-e", script]
           else
             [notifier, TITLE, message]
           end
    pid = Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    nil
  rescue SystemCallError
    nil
  end

  def applescript(text)
    "\"#{text.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')}\""
  end

  def caffeinate_bin(env = ENV)
    override = env["MCR_KEEP_AWAKE_CAFFEINATE"].to_s.strip
    override.empty? ? CAFFEINATE : override
  end

  def tick_seconds(env = ENV)
    value = env["MCR_KEEP_AWAKE_TICK"].to_s.strip
    value.empty? ? DEFAULT_TICK : [value.to_f, 0.1].max
  end

  def indicator_enabled?(env = ENV)
    env["MCR_KEEP_AWAKE_INDICATOR"].to_s.strip != "0"
  end

  # Spawn the supervisor, detached into its own session, so it outlives the
  # shell that ran `start`. Returns its pid.
  def spawn_supervisor(script, env: ENV)
    log = File.join(dir(env), "supervisor.log")
    pid = Process.spawn(RbConfig.ruby, script, "__supervise", pgroup: true, in: File::NULL,
                                                               out: [log, "a"], err: [log, "a"])
    Process.detach(pid)
    pid
  end

  # The compiled menu-bar indicator, cached by the source's digest, or nil when
  # it cannot be built (no swiftc). Compiled once per source version.
  def indicator_binary(env = ENV)
    return nil unless File.exist?(INDICATOR_SOURCE)

    digest = Digest::SHA256.file(INDICATOR_SOURCE).hexdigest[0, 12]
    out_dir = File.join(dir(env), "indicator", digest)
    binary = File.join(out_dir, "KeepAwakeIndicator")
    return binary if File.executable?(binary)

    swiftc = env["MCR_KEEP_AWAKE_SWIFTC"].to_s.strip
    swiftc = "/usr/bin/swiftc" if swiftc.empty?
    return nil unless File.executable?(swiftc)

    FileUtils.mkdir_p(out_dir)
    tmp = "#{binary}.#{Process.pid}.tmp"
    ok = system(swiftc, "-O", "-o", tmp, INDICATOR_SOURCE, out: File::NULL, err: File::NULL)
    return nil unless ok && File.exist?(tmp)

    File.rename(tmp, binary)
    binary
  end

  # The supervisor: holds caffeinate, shows the indicator, and exits when every
  # lease is gone. SIGTERM / SIGUSR1 only WAKE it to re-check: a `stop` that
  # raced a `join` must not end the joiner's hold, so the decision to exit is
  # always the one tick() makes under the lock.
  class Supervisor
    def initialize(env: ENV, store: Store.new(env: env), pid: Process.pid)
      @env = env
      @store = store
      @pid = pid
      @wake = false
      @children = {}
    end

    def run
      %w[TERM USR1 INT HUP].each { |sig| Signal.trap(sig) { @wake = true } }
      ensure_caffeinate
      result = nil
      loop do
        result = @store.tick(pid: @pid)
        result[:lapsed].each do |h|
          KeepAwake.notify("#{h["by"]}'s hold lapsed (no renew). #{remaining(result[:holders])}", env: @env)
        end
        break if result[:done]

        ensure_caffeinate
        ensure_indicator unless @children.key?(:indicator)
        nap
      end
      KeepAwake.notify("The Mac may sleep again: no agent is holding it awake.", env: @env) if result[:ended]
    ensure
      @children.each_value { |pid| stop_child(pid) if pid }
    end

    private

    def remaining(holders)
      return "No holder left; the Mac may sleep." if holders.empty?

      "Still held by #{holders.map { |h| h["by"] }.join(", ")}."
    end

    def nap
      deadline = Time.now + KeepAwake.tick_seconds(@env)
      while Time.now < deadline && !@wake
        sleep(0.1)
      end
      @wake = false
    end

    def ensure_caffeinate
      pid = @children[:caffeinate]
      return if pid && child_alive?(pid)

      @children[:caffeinate] = Process.spawn(KeepAwake.caffeinate_bin(@env), KeepAwake::CAFFEINATE_FLAGS,
                                             "-w", @pid.to_s, in: File::NULL)
    end

    def ensure_indicator
      @children[:indicator] = nil
      return unless KeepAwake.indicator_enabled?(@env)

      binary = KeepAwake.indicator_binary(@env)
      return warn("keep-awake: no indicator (swiftc unavailable or compile failed)") unless binary

      @children[:indicator] = Process.spawn(binary, @store.state_path, in: File::NULL)
    rescue SystemCallError => e
      warn("keep-awake: indicator did not start: #{e.message}")
    end

    def child_alive?(pid)
      Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end

    def stop_child(pid)
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue SystemCallError
      nil
    end
  end
end
