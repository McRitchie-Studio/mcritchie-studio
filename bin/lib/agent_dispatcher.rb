# frozen_string_literal: true

require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "yaml"
require_relative "agent_mailbox"

# bin/dispatcher: the agent mailbox served as a set-and-forget service on Alex's
# Mac (docs/agents/agents/steffon/sops/agent-dispatcher.md). Every mechanic here
# is deterministic and under test (test/integration/agent_dispatcher_test.rb,
# test/lib/agent_dispatcher_unit_test.rb); the agent judges only the anomalies the
# board's floor alert raises.
module AgentMailbox
  # The souls config/agent_routes.yml routes, read without Rails. The board's
  # AgentMessages::Routes#souls is the same rule (every soul a guild lists, plus
  # each channel's non-empty default_soul); this copy exists because bin/ runs
  # without the app loaded.
  def self.routed_souls(path = File.join(REPO_ROOT, "config/agent_routes.yml"))
    config = YAML.safe_load_file(path, aliases: false) || {}
    guilds = (config.dig("discord", "guilds") || {}).values.compact
    souls = guilds.flat_map { |g| (g["souls"] || {}).keys.map(&:to_s) }
    defaults = guilds.flat_map { |g| (g["channels"] || {}).values.compact.map { |c| c["default_soul"].to_s } }
    (souls + defaults).map(&:strip).reject(&:empty?).uniq
  end

  # The loop. One process, one worker id; answers run on threads (each a
  # Responder, whose Claude is a child process), and EVERY board call is made
  # from the main loop, so the API client is never shared across threads.
  #
  #   each tick:  reap finished runs (complete, or release; usage limit → refund + pause
  #               until the reset; a failed run → pause FAILURE_PAUSE; signed out → ClaudeAuth::PAUSE)
  #               renew leases older than RENEW_EVERY
  #               ping the board every PING_EVERY
  #               claim (long-poll) when not stopping, not paused and under the cap
  class Dispatcher
    CAP = 5
    RENEW_EVERY = 180
    PING_EVERY = 60
    # Long-poll waits: the full wait when idle; short while runs are in flight so
    # a finished run is completed within seconds, not after a 20-second poll.
    IDLE_WAIT = 20
    BUSY_WAIT = 2
    # A board error (unreachable, 5xx, auth) backs the claim loop off this long.
    ERROR_BACKOFF = 15
    # On SIGTERM, runs get this long to finish before their Claude is stopped and
    # the message released. Under the plist's ExitTimeOut.
    GRACE = 60
    # After a failed Claude run, claiming pauses this long, so a broken Claude
    # does not spend every waiting message's attempts in a minute.
    FAILURE_PAUSE = 5 * 60

    Run = Struct.new(:message, :thread, :started_at, :renewed_at, keyword_init: true)

    attr_reader :worker, :runs, :paused_until, :pause_reason

    def initialize(client:, souls:, channel: "discord", worker: nil, cap: CAP, claude_cmd: Responder::DEFAULT_CLAUDE_CMD,
                   runner: nil, out: $stdout, clock: -> { Time.now }, sleeper: ->(s) { sleep(s) },
                   repo_root: REPO_ROOT, idle_wait: IDLE_WAIT, busy_wait: BUSY_WAIT, version: nil)
      raise ArgumentError, "no souls to serve" if souls.empty?

      @client = client
      @souls = souls
      @channel = channel
      @worker = worker || "dispatcher-#{Heartbeat.default_worker}"
      @cap = cap
      @claude_cmd = claude_cmd
      @runner = runner
      @out = out
      @clock = clock
      @sleeper = sleeper
      @repo_root = repo_root
      @idle_wait = idle_wait
      @busy_wait = busy_wait
      @version = version || self.class.git_version(repo_root)
      @runs = []
      @stopping = false
      @paused_until = nil
      @pause_reason = nil
      @last_ping = nil
      @started_at = clock.call
      @host = Socket.gethostname.split(".").first
    end

    def self.git_version(root)
      out, status = Open3.capture2("git", "-C", root, "rev-parse", "--short", "HEAD")
      status.success? ? out.strip : "unknown"
    rescue SystemCallError
      "unknown"
    end

    def stop! = (@stopping = true)
    def stopping? = @stopping

    def paused?(now = @clock.call) = !@paused_until.nil? && now < @paused_until

    # Loop until stopped (SIGTERM / INT), then shut down gracefully. `ticks`
    # bounds the loop for tests.
    def run(ticks: nil)
      log "start #{@worker} serving #{@souls.join(', ')} on #{@channel} (cap #{@cap}, version #{@version})"
      count = 0
      until @stopping
        tick
        count += 1
        break if ticks && count >= ticks
      end
      shutdown if @stopping
    end

    def tick
      now = @clock.call
      reap
      renew_due(now)
      ping(now) if @last_ping.nil? || now - @last_ping >= PING_EVERY
      return if @stopping

      if paused?(now)
        @sleeper.call([ @paused_until - now, 5 ].min)
        return
      end
      if @paused_until
        log "usage pause over; claiming again"
        @paused_until = nil
        @pause_reason = nil
      end
      if @runs.size >= @cap
        @sleeper.call(1)
        return
      end

      claim_one
    end

    # Stop claiming; give runs GRACE to finish; then stop their Claude and give
    # their messages back. A final ping says it stopped.
    def shutdown(grace: GRACE)
      log "stopping: #{@runs.size} run(s) in flight, waiting up to #{grace}s"
      deadline = @clock.call + grace
      until @runs.empty? || @clock.call >= deadline
        reap
        renew_due(@clock.call)
        @sleeper.call(1) unless @runs.empty?
      end
      unless @runs.empty?
        Children.terminate_all
        @runs.each do |run|
          run.thread.join(5)
          give_back(run.message["id"], "dispatcher stopped before the answer finished")
        end
        @runs.clear
      end
      ping(@clock.call, state: "stopping")
      log "stopped"
    end

    private

    def claim_one
      wait = @runs.empty? ? @idle_wait : @busy_wait
      message = @client.claim(souls: @souls, worker: @worker, channel: @channel, wait: wait)["data"]
      return unless message

      if @stopping
        give_back(message["id"], "dispatcher stopping")
        return
      end
      start(message)
    rescue ApiError => e
      log "claim failed: #{e.message}; backing off #{ERROR_BACKOFF}s"
      @sleeper.call(ERROR_BACKOFF)
    end

    def start(message)
      now = @clock.call
      log "claimed ##{message['id']} for #{message['soul_slug']} (attempt #{message['attempts']})"
      responder = Responder.new(soul: message["soul_slug"], claude_cmd: @claude_cmd, runner: @runner,
                                repo_root: @repo_root, clock: @clock)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        responder.respond(message)
      end
      @runs << Run.new(message: message, thread: thread, started_at: now, renewed_at: now)
    end

    def reap
      done, @runs = @runs.partition { |run| !run.thread.alive? }
      done.each { |run| finish(run) }
    end

    def finish(run)
      id = run.message["id"]
      answer = begin
        run.thread.value
      rescue StandardError => e
        give_back(id, "the answer run raised #{e.class}")
        return
      end

      if answer.usage_limit
        hit = answer.usage_limit
        give_back(id, "Claude usage limit: #{hit.notice}", code: "usage_limit")
        pause_until(hit.reset_at, hit.parsed ? "usage_limit" : "usage_limit (reset not named; backing off)")
      elsif answer.signed_out
        give_back(id, "Claude is not signed in (exit #{answer.status.inspect})")
        pause_until(@clock.call + ClaudeAuth::PAUSE, "claude_signed_out")
      elsif answer.reply.nil?
        give_back(id, "the Claude run failed or answered nothing (exit #{answer.status.inspect})")
        pause_until(@clock.call + FAILURE_PAUSE, "claude_failed")
      else
        result = @client.complete(id, worker: @worker, response_text: answer.reply,
                                      action_summary: answer.action&.dig(:summary))
        log "completed ##{id} (#{result.dig('meta', 'outcome')})"
      end
    rescue ApiError => e
      log "complete ##{id} failed: #{e.message}"
      give_back(id, e.message)
    end

    def pause_until(time, reason)
      @paused_until = [ @paused_until, time ].compact.max
      @pause_reason = reason
      log "paused until #{@paused_until.utc.iso8601} (#{reason})"
      ping(@clock.call)
    end

    def renew_due(now)
      @runs.each do |run|
        next if now - run.renewed_at < RENEW_EVERY

        @client.renew(run.message["id"], worker: @worker)
        run.renewed_at = now
      rescue ApiError => e
        # The claim is gone (lapsed and taken, or completed elsewhere). The run's
        # late complete will be refused; nothing else to do.
        log "renew ##{run.message['id']} refused: #{e.message}"
        run.renewed_at = now
      end
    end

    def ping(now, state: nil)
      @last_ping = now
      @client.ping({ "worker" => @worker, "host" => @host, "souls" => @souls, "running" => @runs.size,
                     "capacity" => @cap, "paused_until" => paused?(now) ? @paused_until.utc.iso8601 : nil,
                     "pause_reason" => paused?(now) ? @pause_reason : nil,
                     "state" => state || (paused?(now) ? "paused" : "running"),
                     "version" => @version, "started_at" => @started_at.utc.iso8601 })
    rescue ApiError => e
      log "ping failed: #{e.message}"
    end

    def give_back(id, reason, code: nil)
      log "releasing ##{id}#{code ? " (#{code})" : ''}: #{reason}"
      @client.release(id, worker: @worker, reason: reason, code: code)
    rescue ApiError => e
      log "release ##{id} failed (#{e.message}); the lease lapses on its own"
    end

    # Ids and states only: message content and answers never reach the log file.
    def log(line)
      @out.puts "#{@clock.call.utc.iso8601} #{line}"
      @out.flush if @out.respond_to?(:flush)
    end
  end

  # The launchd service (config/launchd/studio.mcritchie.agent-dispatcher.plist):
  # `bin/dispatcher install|uninstall|status`. The plist in the repo is a
  # TEMPLATE; install renders it with this machine's paths into
  # ~/Library/LaunchAgents and bootstraps it. `launchctl` is a seam tests replace.
  class LaunchAgent
    LABEL = "studio.mcritchie.agent-dispatcher"
    TEMPLATE = File.join(REPO_ROOT, "config/launchd/#{LABEL}.plist")
    LOG_NAME = "agent-dispatcher.log"

    def initialize(home: Dir.home, repo_root: REPO_ROOT, ruby: RbConfig.ruby, path: ENV.fetch("PATH", ""),
                   uid: Process.uid, launchctl: nil, out: $stdout)
      @home = home
      @repo_root = repo_root
      @ruby = ruby
      @path = path
      @uid = uid
      @launchctl = launchctl || ->(*args) { Open3.capture2e("launchctl", *args) }
      @out = out
    end

    def plist_path = File.join(@home, "Library/LaunchAgents/#{LABEL}.plist")
    def log_path = File.join(@home, "Library/Logs/#{LOG_NAME}")
    def domain = "gui/#{@uid}"

    def render
      values = { "REPO_ROOT" => @repo_root, "HOME" => @home, "RUBY" => @ruby, "PATH" => service_path,
                 "LOG" => log_path, "LABEL" => LABEL }
      File.read(TEMPLATE).gsub(/\{\{([A-Z_]+)\}\}/) do
        key = Regexp.last_match(1)
        raise ArgumentError, "template names unknown {{#{key}}}" unless values.key?(key)

        xml_escape(values[key])
      end
    end

    # launchd starts with a bare PATH; the service needs ruby, git and claude.
    def service_path
      dirs = [ File.dirname(@ruby), File.join(@home, ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
               "/usr/bin", "/bin", "/usr/sbin", "/sbin" ]
      (dirs + @path.split(":")).reject(&:empty?).uniq.join(":")
    end

    def install
      FileUtils.mkdir_p(File.dirname(plist_path))
      FileUtils.mkdir_p(File.dirname(log_path))
      File.write(plist_path, render)
      @launchctl.call("bootout", "#{domain}/#{LABEL}") # a reinstall replaces the running copy
      output, status = @launchctl.call("bootstrap", domain, plist_path)
      unless status.success?
        @out.puts "launchctl bootstrap failed: #{output.strip}"
        return 1
      end
      @out.puts "installed #{plist_path}; logs at #{log_path}"
      status_report
    end

    def uninstall
      @launchctl.call("bootout", "#{domain}/#{LABEL}")
      existed = File.exist?(plist_path)
      FileUtils.rm_f(plist_path)
      @out.puts existed ? "uninstalled #{LABEL}; removed #{plist_path}" : "#{LABEL} was not installed"
      0
    end

    # 0 running · 1 installed but not running · 3 not installed.
    def status_report
      unless File.exist?(plist_path)
        @out.puts "#{LABEL}: not installed (no #{plist_path})"
        return 3
      end
      output, status = @launchctl.call("print", "#{domain}/#{LABEL}")
      unless status.success?
        @out.puts "#{LABEL}: installed but not loaded (launchctl print failed)"
        return 1
      end
      state = output[/^\s*state = (.+)$/, 1]&.strip
      pid = output[/^\s*pid = (\d+)/, 1]
      last_exit = output[/last exit code = (.+)$/, 1]
      @out.puts "#{LABEL}: #{state || 'unknown'}#{pid ? " (pid #{pid})" : ''}" \
                "#{last_exit ? ", last exit #{last_exit.strip}" : ''}; logs at #{log_path}"
      state == "running" ? 0 : 1
    end

    private

    def xml_escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end
  end
end
