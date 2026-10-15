# frozen_string_literal: true

require "digest"
require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "yaml"
require_relative "agent_mailbox"

# bin/dispatcher: the agent mailbox served as a set-and-forget service on Alex's
# Mac (docs/agents/agents/steffon/sops/agent-dispatcher.md). Every mechanic here
# is deterministic and under test (test/integration/agent_dispatcher_loop_test.rb,
# test/lib/agent_usage_limit_test.rb, test/lib/agent_dispatcher_launch_agent_test.rb);
# the agent judges only the anomalies the board's floor alert raises.
module AgentMailbox
  # The souls config/agent_routes.yml routes, read without Rails. The board's
  # AgentMessages::Routes#souls is the same rule (every soul a guild lists, plus
  # each channel override's non-empty default_soul); this copy exists because bin/ runs
  # without the app loaded.
  def self.routed_souls(path = File.join(REPO_ROOT, "config/agent_routes.yml"))
    config = YAML.safe_load_file(path, aliases: false) || {}
    guilds = (config.dig("discord", "guilds") || {}).values.compact
    souls = guilds.flat_map { |g| (g["souls"] || {}).keys.map(&:to_s) }
    defaults = guilds.flat_map { |g| (g["channels"] || {}).values.compact.map { |c| c["default_soul"].to_s } }
    (souls + defaults).map(&:strip).reject(&:empty?).uniq
  end

  # A digest of the code the running dispatcher is made of: the entry script,
  # every file under the repo it has required (bin/lib/agent_dispatcher.rb,
  # agent_mailbox.rb, agent_api.rb, cli_arg_guard.rb and what they pull in), and
  # config/agent_routes.yml, whose souls are read only at startup. The file LIST
  # is fixed when the fingerprint is taken; each #call re-reads those files, so
  # an edit, a checkout or a deletion changes the digest and an unrelated
  # release (one that touches none of them) does not. A missing file digests as
  # missing rather than raising.
  class CodeFingerprint
    attr_reader :files

    # The fingerprint of THIS process: what it has loaded from repo_root so far.
    # Take it after every require has run (bin/dispatcher does, just before run).
    def self.for_process(repo_root: REPO_ROOT, entry: $PROGRAM_NAME, loaded: $LOADED_FEATURES)
      roots = [ File.expand_path(repo_root), (File.realpath(repo_root) rescue nil) ].compact.uniq
                                                                                  .map { |r| File.join(r, "") }
      required = loaded.select { |path| roots.any? { |root| path.start_with?(root) } }
      new([ File.expand_path(entry), *required, File.join(repo_root, "config/agent_routes.yml") ])
    end

    def initialize(files)
      @files = files.map { |f| File.expand_path(f) }.uniq.sort.freeze
    end

    def call
      digest = Digest::SHA256.new
      @files.each do |path|
        digest << path << "\0"
        digest << (File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing") << "\0"
      end
      digest.hexdigest
    end
  end

  # The loop. One process, one worker id; answers run on threads (each a
  # Responder, whose Claude is a child process), and EVERY board call is made
  # from the main loop, so the API client is never shared across threads.
  #
  #   each tick:  reap finished runs (complete, or release; usage limit → refund + pause
  #               until the reset; a failed run → pause FAILURE_PAUSE; signed out → ClaudeAuth::PAUSE)
  #               renew leases older than RENEW_EVERY, never past RUN_DEADLINE
  #               abandon a run past RUN_DEADLINE (release it, free the slot)
  #               ping the board every PING_EVERY, and on the same beat re-read the
  #               code fingerprint: a new digest seen on two checks in a row stops
  #               claiming and drains (see #restart_for_new_code!), and launchd's
  #               KeepAlive starts the new code
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
    # The longest a run can legitimately take: its action and its Claude call,
    # each with TERM then KILL on timeout, plus a margin. Past it the lease is no
    # longer renewed and the run is abandoned (its message given back, its slot
    # freed), so a wedged run cannot hold a message forever.
    RUN_DEADLINE = Responder::ACTION_TIMEOUT + Responder::CLAUDE_TIMEOUT + (2 * KILL_GRACE) + 60
    # The code fingerprint is re-read on the ping beat. A new digest must be seen
    # on two checks in a row before the dispatcher restarts, so a checkout read
    # half-way through a branch move cannot start a restart loop.
    CODE_CHECK_EVERY = PING_EVERY

    Run = Struct.new(:message, :thread, :started_at, :renewed_at, keyword_init: true)

    attr_reader :worker, :runs, :paused_until, :pause_reason

    def initialize(client:, souls:, channel: "discord", worker: nil, cap: CAP, claude_cmd: Responder::DEFAULT_CLAUDE_CMD,
                   runner: nil, out: $stdout, clock: -> { Time.now }, sleeper: ->(s) { sleep(s) },
                   repo_root: REPO_ROOT, idle_wait: IDLE_WAIT, busy_wait: BUSY_WAIT, version: nil, fingerprint: nil)
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
      # The baseline: the digest of the code this process started on (nil: no
      # self-restart, as in the loop tests that pass none).
      @fingerprint = fingerprint
      @code_digest = fingerprint&.call
      @pending_digest = nil
      @last_code_check = @started_at
      @restarting = false
      @term_at = nil
    end

    def self.git_version(root)
      out, status = Open3.capture2("git", "-C", root, "rev-parse", "--short", "HEAD")
      status.success? ? out.strip : "unknown"
    rescue SystemCallError
      "unknown"
    end

    # SIGTERM / INT (and a test's stop). launchd SIGKILLs after the plist's
    # ExitTimeOut, so a signal always caps the drain at GRACE from here, even
    # mid-way through a longer restart drain.
    def stop!
      @stopping = true
      @term_at ||= @clock.call
    end

    # New code on disk: stop claiming and let the runs in flight finish, each up
    # to its own RUN_DEADLINE (nobody will SIGKILL us, so there is no GRACE cap
    # unless a signal arrives too). bin/dispatcher then exits 0 and launchd's
    # KeepAlive (plain true, not SuccessfulExit=false) starts the new code.
    def restart_for_new_code!
      @restarting = true
      @stopping = true
    end

    def stopping? = @stopping
    def restarting? = @restarting

    def paused?(now = @clock.call) = !@paused_until.nil? && now < @paused_until

    # Loop until stopped (SIGTERM / INT), then shut down gracefully. `ticks`
    # bounds the loop for tests.
    def run(ticks: nil)
      code = @code_digest ? ", code #{@code_digest[0, 12]}" : ""
      log "start #{@worker} serving #{@souls.join(', ')} on #{@channel} (cap #{@cap}, version #{@version}#{code})"
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
      check_code(now) if @fingerprint && !@stopping && now - @last_code_check >= CODE_CHECK_EVERY
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

    # Stop claiming; give runs GRACE to finish (a restart for new code: until
    # their RUN_DEADLINE, unless a signal cuts it to GRACE); then stop their
    # Claude and give their messages back. The drain keeps the minute ping going
    # (state stopping): a restart drain can outlast AgentDispatcher::SILENT_AFTER,
    # and a quiet drain would raise a false "dispatcher silent" alert. A final
    # ping says it stopped.
    def shutdown(grace: GRACE)
      started = @clock.call
      window = @restarting ? RUN_DEADLINE : grace
      log "stopping#{' for new code' if @restarting}: #{@runs.size} run(s) in flight, waiting up to #{window}s"
      until @runs.empty? || @clock.call >= drain_deadline(started, window, grace)
        reap
        now = @clock.call
        renew_due(now)
        ping(now, state: "stopping") if @last_ping.nil? || now - @last_ping >= PING_EVERY
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

    def drain_deadline(started, window, grace)
      limit = started + window
      @term_at ? [ limit, [ @term_at, started ].max + grace ].min : limit
    end

    # Re-read the fingerprint. Changed and confirmed (the same new digest on the
    # previous check too) → one log line and a restart. A read that raises keeps
    # the running code.
    def check_code(now)
      @last_code_check = now
      current = @fingerprint.call
      if current == @code_digest
        @pending_digest = nil
      elsif current == @pending_digest
        log "code changed (#{@code_digest.to_s[0, 12]} -> #{current[0, 12]}); restarting on the new code: " \
            "no new claims, #{@runs.size} run(s) drain, then exit 0 for launchd to start it"
        restart_for_new_code!
      else
        @pending_digest = current
      end
    rescue StandardError => e
      log "code check failed (#{e.class}); keeping the running code"
    end

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
      # The memory, fetched here on the main loop (every board call is): the
      # holder's context bundle. Without it the answer would forget the person,
      # so a failed fetch gives the message back instead of answering blind.
      context = begin
        @client.context(message["id"], worker: @worker)["data"]
      rescue ApiError => e
        give_back(message["id"], "could not read the message's context: #{e.message}")
        return
      end
      responder = Responder.new(soul: message["soul_slug"], claude_cmd: @claude_cmd, runner: @runner,
                                repo_root: @repo_root, clock: @clock)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        responder.respond(message, context: context)
      end
      @runs << Run.new(message: message, thread: thread, started_at: now, renewed_at: now)
    end

    def reap
      done, @runs = @runs.partition { |run| !run.thread.alive? }
      done.each { |run| finish(run) }
      abandon_overdue(@clock.call)
    end

    # A run past RUN_DEADLINE is wedged (its timeouts should have ended it). Give
    # its message back, free the slot, and pause FAILURE_PAUSE; the thread's late
    # result is ignored.
    def abandon_overdue(now)
      overdue, @runs = @runs.partition { |run| now - run.started_at > RUN_DEADLINE }
      overdue.each do |run|
        give_back(run.message["id"], "the run passed its #{RUN_DEADLINE}s deadline and was abandoned")
      end
      # A wedged run is a failed run: pause, so the message is not re-claimed
      # into the same wedge at once.
      pause_until(now + FAILURE_PAUSE, "run_overdue") if overdue.any?
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
                                      action_summary: answer.action&.dig(:summary), run: answer.run_record)
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
        next if now - run.started_at > RUN_DEADLINE # never renew a run past its deadline

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
      if @repo_root.include?("/.worktrees/")
        @out.puts "refused: #{@repo_root} is a task desk under .worktrees/. Install from the hub's primary " \
                  "checkout (/Users/alex/projects/mcritchie-studio), which the release moves; nothing was installed."
        return 2
      end

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

    # The ship's step (bin/release.rb#refresh_dispatcher_service): reinstall only
    # when the service is installed AND the template it was rendered from has
    # changed. Not installed → nothing, never a bootstrap. The comparison renders
    # the new template with the INSTALLED plist's own ruby and PATH, because the
    # ship's environment is not the shell that installed it: comparing a plain
    # render would differ on every ship and restart the service for nothing. A
    # reinstall keeps those two values for the same reason. Code changes alone
    # need nothing here: the running dispatcher restarts itself on them.
    # 0 not installed / current / reinstalled · install's code on a failure.
    def install_if_changed
      unless File.exist?(plist_path)
        @out.puts "#{LABEL}: not installed; nothing to refresh"
        return 0
      end

      installed = File.read(plist_path)
      kept = installed_paths(installed)
      agent = kept ? self.class.new(home: @home, repo_root: @repo_root, ruby: kept[:ruby], path: kept[:path],
                                    uid: @uid, launchctl: @launchctl, out: @out) : self
      if agent.render == installed
        @out.puts "#{LABEL}: installed plist matches the template; nothing to refresh"
        return 0
      end

      @out.puts "#{LABEL}: the plist template changed; reinstalling"
      agent.install
    end

    # The ruby and PATH a plist this class rendered carries, or nil when it does
    # not read as one (a hand edit): then the refresh renders with this process's.
    def installed_paths(xml)
      ruby = xml[%r{<key>ProgramArguments</key>\s*<array>\s*<string>([^<]*)</string>}, 1]
      path = xml[%r{<key>PATH</key>\s*<string>([^<]*)</string>}, 1]
      return nil unless ruby && path

      { ruby: xml_unescape(ruby), path: xml_unescape(path) }
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

    def xml_unescape(value)
      value.gsub("&quot;", '"').gsub("&lt;", "<").gsub("&gt;", ">").gsub("&amp;", "&")
    end
  end
end
