# frozen_string_literal: true

require "digest"
require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "yaml"
require_relative "agent_mailbox"
require_relative "agent_domain_registry"

# bin/dispatcher: the agent mailbox served as a set-and-forget service on Alex's
# Mac (docs/agents/agents/steffon/sops/agent-dispatcher.md). Every mechanic here
# is deterministic and under test (test/integration/agent_dispatcher_loop_test.rb,
# test/lib/agent_usage_limit_test.rb, test/lib/agent_dispatcher_launch_agent_test.rb);
# the agent judges only the anomalies the board's floor alert raises.
module AgentMailbox
  # The souls config/agent_routes.yml routes, read without Rails. The board's
  # AgentMessages::Routes#souls is the same rule (every soul a guild lists, plus
  # each channel override's non-empty default_soul, plus the web chat's CTOs under
  # `web: souls:`); this copy exists because bin/ runs without the app loaded.
  def self.routed_souls(path = File.join(REPO_ROOT, "config/agent_routes.yml"))
    config = YAML.safe_load_file(path, aliases: false) || {}
    guilds = (config.dig("discord", "guilds") || {}).values.compact
    souls = guilds.flat_map { |g| (g["souls"] || {}).keys.map(&:to_s) }
    defaults = guilds.flat_map { |g| (g["channels"] || {}).values.compact.map { |c| c["default_soul"].to_s } }
    web = Array((config["web"] || {})["souls"]).map(&:to_s)
    (souls + defaults + web).map(&:strip).reject(&:empty?).uniq
  end

  # A digest of the code the running dispatcher is made of: the entry script,
  # every file under the repo it has required (bin/lib/agent_dispatcher.rb,
  # agent_mailbox.rb, agent_api.rb, cli_arg_guard.rb and what they pull in),
  # config/agent_routes.yml, whose souls are read only at startup, and
  # config/agent_domains.yml, whose warm_session flags are too (so turning a
  # domain warm reaches a running dispatcher). The file LIST
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
      new([ File.expand_path(entry), *required, File.join(repo_root, "config/agent_routes.yml"),
            File.join(repo_root, "config/agent_domains.yml") ])
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
  #               until the reset; a failed or raised run → pause FAILURE_PAUSE; signed out → ClaudeAuth::PAUSE)
  #               renew leases older than RENEW_EVERY, never past RUN_DEADLINE
  #               pulse "typing…" for each live Discord run every TYPING_EVERY, up to
  #               TYPING_CAP after its start (the first pulse goes out as the run starts)
  #               abandon a run past RUN_DEADLINE (release it, free the slot)
  #               ping the board every PING_EVERY, and on the same beat re-read the
  #               code fingerprint: a new digest seen on two checks in a row stops
  #               claiming and drains (see #restart_for_new_code!), and launchd's
  #               KeepAlive starts the new code
  #               claim (long-poll) when not stopping, not paused and under the cap
  #
  # WARM SESSIONS (docs/agents/system/agent-message-loop.md, "Warm sessions").
  # Off unless a domain sets `warm_session: true` in config/agent_domains.yml;
  # with every domain off, nothing below runs and each answer is the cold run.
  # For a warm domain's front-door soul and an owner or team sender (never a
  # client, the public, or a released hold) a claim also takes the domain's
  # board lease (presenting the lease key the board answered when this process
  # took it), restores the checkpoint unless the local transcript is the one
  # THIS PROCESS last checkpointed or restored (same session, same checkpoint,
  # same SHA-256), and runs `claude -p --resume <id>` (still no tools, the
  # json envelope read as before). After the complete it uploads the transcript
  # as the checkpoint; past consolidate_at it runs one more no-tools turn for a
  # summary, which the board stores before the next turn starts fresh. One warm
  # turn per domain at a time: a second message meanwhile, a lease another
  # dispatcher holds, or any failure answers that message per message. A
  # checkpoint or restore that fails is reported to the board (fault: ErrorLog
  # and the row), never only logged here. Leases renew on the ping beat; a
  # handback request (a primary asking a standby) is honoured only between
  # turns. Giving a lease up removes the transcripts this process held for it.
  # A STANDBY (the board's role for this host) claims nothing while a primary is
  # live.
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
    # The most of a raised error's message a give-back reason carries.
    RAISE_DETAIL_LIMIT = 200
    # The longest a run can legitimately take: its action and its Claude call,
    # each with TERM then KILL on timeout, plus a margin. Past it the lease is no
    # longer renewed and the run is abandoned (its message given back, its slot
    # freed), so a wedged run cannot hold a message forever.
    RUN_DEADLINE = Responder::ACTION_TIMEOUT + Media::DEADLINE + Responder::CLAUDE_TIMEOUT + (2 * KILL_GRACE) + 60
    # The code fingerprint is re-read on the ping beat. A new digest must be seen
    # on two checks in a row before the dispatcher restarts, so a checkout read
    # half-way through a branch move cannot start a restart loop.
    CODE_CHECK_EVERY = PING_EVERY
    # "typing…" in the message's channel while its run lives (AgentMessageTypingJob
    # on the board). Discord shows a pulse for about ten seconds, so one goes out
    # as the run starts and every TYPING_EVERY after, which leaves the busy loop's
    # few seconds of slack before the indicator would fade. TYPING_CAP is the
    # board's own cap (AgentMessage::TYPING_CAP): past it no pulse is asked for.
    TYPING_EVERY = 7
    TYPING_CAP = 180
    # The channels whose reader shows typing (the board's AgentMessage::TYPING_CHANNELS):
    # Discord through the replying bot, the web chat over its Turbo stream.
    TYPING_CHANNELS = %w[discord web].freeze

    # typed_at: the last pulse asked for (nil: none yet). typing: false once the
    # board said no (or failed): that run is never pulsed again.
    # warm: the WarmSession::Turn the run answers on, or nil (a cold run).
    # phase: a web-chat run's ClaudeStream::Phase (thinking, then typing), fed
    # by the run's own stdout; nil for Discord, whose pulse has one look.
    # pulsed_phase: the phase the last pulse carried, so a change pulses at once.
    Run = Struct.new(:message, :thread, :started_at, :renewed_at, :typed_at, :typing, :warm, :phase, :pulsed_phase,
                     keyword_init: true)
    # A consolidation turn in flight on a warm domain.
    Chore = Struct.new(:domain, :thread, :started_at, :source_session_id, :turns, :context_tokens, keyword_init: true)
    # A domain lease this dispatcher holds. busy: a warm turn or a consolidation
    # is running on the session, so no second turn may resume it. key: the
    # lease key the board answered the acquire that took it (every lease call
    # presents it). cwd: the soul folder its transcripts live under. files: the
    # transcripts this process restored or checkpointed for it, removed when
    # the lease is given up.
    Lease = Struct.new(:domain, :session_id, :turns, :generation, :checkpointed_at, :busy, :handback, :key, :cwd,
                       :files, keyword_init: true)
    # The transcript this process last checkpointed or restored for a domain:
    # the only local file a warm turn resumes without a download.
    OwnCheckpoint = Struct.new(:session_id, :checkpointed_at, :path, :digest, keyword_init: true)

    attr_reader :worker, :runs, :paused_until, :pause_reason, :role, :leases, :chores

    def initialize(client:, souls:, channel: "discord", worker: nil, cap: CAP, claude_cmd: Responder::DEFAULT_CLAUDE_CMD,
                   runner: nil, out: $stdout, clock: -> { Time.now }, sleeper: ->(s) { sleep(s) },
                   repo_root: REPO_ROOT, idle_wait: IDLE_WAIT, busy_wait: BUSY_WAIT, version: nil, fingerprint: nil,
                   registry: nil, mailbox_home: nil, claude_home: File.join(Dir.home, ".claude"), host: nil, media: nil)
      raise ArgumentError, "no souls to serve" if souls.empty?

      # The files a message carries are fetched and converted on the run's
      # thread (Media::Preparer): R2 downloads and ImageMagick, never a board call.
      @media = media
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
      @host = host || Socket.gethostname.split(".").first
      # The baseline: the digest of the code this process started on (nil: no
      # self-restart, as in the loop tests that pass none).
      @fingerprint = fingerprint
      @code_digest = fingerprint&.call
      @pending_digest = nil
      @last_code_check = @started_at
      @restarting = false
      @term_at = nil
      # Warm sessions: the domain registry this checkout ships, the leases held,
      # the consolidations running, and the checkpoint this process last wrote
      # or restored per domain (domain => OwnCheckpoint), the one local
      # transcript trusted without a download.
      @registry = registry || DomainRegistry.load(File.join(repo_root, "config/agent_domains.yml"))
      @mailbox_home = mailbox_home
      @claude_home = claude_home
      @leases = {}
      @chores = []
      @own_checkpoints = {}
      # The board's answer to each ping: this host's role, and whether a
      # primary is live. A standby claims nothing while one is.
      @role = "primary"
      @primary_live = true
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
      log "start #{@worker} serving #{@souls.join(', ')} on #{@channel || 'every channel'} (cap #{@cap}, version #{@version}#{code})"
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
      type_due(now)
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
      if @runs.size + @chores.size >= @cap
        @sleeper.call(1)
        return
      end
      if standing_by?
        @sleeper.call([ @idle_wait, 1 ].max)
        return
      end

      claim_one
    end

    # A standby while a primary pings: it claims nothing (the board refuses it
    # too, AgentDispatcher.claim_scope).
    def standing_by? = @role == "standby" && @primary_live

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
      until (@runs.empty? && @chores.empty?) || @clock.call >= drain_deadline(started, window, grace)
        reap
        now = @clock.call
        renew_due(now)
        type_due(now)
        ping(now, state: "stopping") if @last_ping.nil? || now - @last_ping >= PING_EVERY
        @sleeper.call(1) unless @runs.empty? && @chores.empty?
      end
      unless @runs.empty? && @chores.empty?
        Children.terminate_all
        @runs.each do |run|
          run.thread.join(5)
          give_back(run.message["id"], "dispatcher stopped before the answer finished")
        end
        @runs.clear
        @chores.each { |chore| chore.thread.join(5) }
        @chores.clear
      end
      # Every warm lease goes back, so a restart (a new worker id) or the
      # standby takes the session at once instead of after the lease lapses.
      @leases.each_value { |lease| lease.busy = false }
      @leases.keys.each { |domain| drop_lease(domain, "dispatcher stopping") }
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
      responder = responder_for(message["soul_slug"])
      warm = warm_turn(message, context)
      phase = ClaudeStream::Phase.new if message["channel"] == "web" && responder.streams?
      thread = Thread.new do
        Thread.current.report_on_exception = false
        options = { context: context }
        options[:warm] = warm if warm
        options[:phase] = phase if phase
        responder.respond(message, **options)
      end
      run = Run.new(message: message, thread: thread, started_at: now, renewed_at: now,
                    typing: TYPING_CHANNELS.include?(message["channel"]), warm: warm, phase: phase)
      @runs << run
      pulse_typing(run, now)
    end

    def responder_for(soul)
      Responder.new(soul: soul, claude_cmd: @claude_cmd, runner: @runner, repo_root: @repo_root, clock: @clock,
                    mailbox_home: @mailbox_home, claude_home: @claude_home, media: @media)
    end

    def reap
      done, @runs = @runs.partition { |run| !run.thread.alive? }
      done.each { |run| finish(run) }
      finished, @chores = @chores.partition { |chore| !chore.thread.alive? }
      finished.each { |chore| finish_chore(chore) }
      abandon_overdue(@clock.call)
    end

    # A run past RUN_DEADLINE is wedged (its timeouts should have ended it). Give
    # its message back, free the slot, and pause FAILURE_PAUSE; the thread's late
    # result is ignored.
    def abandon_overdue(now)
      overdue, @runs = @runs.partition { |run| now - run.started_at > RUN_DEADLINE }
      overdue.each do |run|
        give_back(run.message["id"], "the run passed its #{RUN_DEADLINE}s deadline and was abandoned")
        settle_warm(run, nil) if run.warm
      end
      stale, @chores = @chores.partition { |chore| now - chore.started_at > RUN_DEADLINE }
      stale.each { |chore| release_busy(chore.domain, "the consolidation passed its deadline") }
      # A wedged run is a failed run: pause, so the message is not re-claimed
      # into the same wedge at once.
      pause_until(now + FAILURE_PAUSE, "run_overdue") if overdue.any?
    end

    # A warm run settles its lease after the complete, whatever happened
    # (settle_warm): a completed answer is checkpointed, anything else drops
    # the lease, and the message's own outcome is exactly the cold run's.
    def finish(run)
      completed = nil
      finish_answer(run) { |answer| completed = answer }
    ensure
      settle_warm(run, completed) if run.warm
    end

    def finish_answer(run)
      id = run.message["id"]
      answer = begin
        run.thread.value
      rescue StandardError => e
        answer_raised(id, e)
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
        yield answer
      end
    rescue ApiError => e
      log "complete ##{id} failed: #{e.message}"
      give_back(id, e.message)
    end

    # ---- warm sessions -------------------------------------------------------

    # The warm turn for this message, or nil to answer it cold. Every miss is
    # the cold path: a domain not warm, a sender who is not owner or team, a
    # released hold, a turn already running on the session, a lease another
    # dispatcher holds, a handback asked for, or a checkpoint that will not
    # restore.
    def warm_turn(message, context)
      domain = @registry.warm_domain_for(message["soul_slug"])
      return nil unless domain && WarmSession.eligible?(message, context)
      return nil if @leases[domain]&.busy

      held = @leases[domain]
      result = @client.domain_acquire(domain, worker: @worker, lease_key: held&.key)
      state = result["data"] || {}
      lease = (@leases[domain] ||= Lease.new(domain: domain, files: []))
      lease.cwd ||= responder_for(message["soul_slug"]).soul_folder
      minted = result.dig("meta", "lease_key")
      unless minted.to_s.empty?
        # A new lease period: whatever this machine wrote before it, someone
        # else may have advanced the session since.
        lease.key = minted
        @own_checkpoints.delete(domain)
      end
      lease.session_id = state["claude_session_id"]
      lease.turns = state["turns"].to_i
      lease.generation = state["generation"]
      lease.checkpointed_at = state["checkpointed_at"]
      lease.handback = state["handback_requested"] == true
      taken = result.dig("meta", "taken_over_from")
      log "warm #{domain}: took the lapsed lease of #{taken}" if taken
      if lease.handback
        drop_lease(domain, "a handback was requested; between turns")
        return nil
      end
      return nil if lease.session_id && !transcript_ready?(lease, message["soul_slug"])

      lease.busy = true
      WarmSession::Turn.new(domain: domain, resume_id: lease.session_id, seed: state["seed_summary"],
                            turns: lease.turns, generation: lease.generation,
                            consolidate_at: (state["consolidate_at"] || @registry.consolidate_at(domain)).to_i)
    rescue ApiError => e
      forget_lease(domain) if e.code == "LEASE_HELD"
      reason = e.code == "LEASE_HELD" ? "another dispatcher holds the lease" : "acquire failed (#{e.message})"
      log "warm #{domain}: #{reason}; answering ##{message['id']} per message"
      nil
    end

    # Is this machine's transcript of the session's head current? Only when it
    # is the one THIS PROCESS last checkpointed or restored (#own_current?).
    # No clock is compared: a file's mtime is this machine's clock and the
    # checkpoint's is the board's, and a machine that lost the lease mid-turn
    # holds a newer-looking file that is not the session. Else restore the
    # board's checkpoint; a restore that fails is reported (fault) and drops the
    # lease (the caller goes cold).
    def transcript_ready?(lease, _soul)
      return true if own_current?(lease)

      session_id, bytes = @client.domain_checkpoint_read(lease.domain, worker: @worker, lease_key: lease.key)
      raise ArgumentError, "the checkpoint is of #{session_id}, not #{lease.session_id}" unless session_id == lease.session_id

      path = WarmSession.restore!(session_id, bytes, cwd: lease.cwd, claude_home: @claude_home)
      lease.files << path
      @own_checkpoints[lease.domain] = OwnCheckpoint.new(session_id: session_id, checkpointed_at: lease.checkpointed_at,
                                                         path: path, digest: WarmSession.digest(path))
      log "warm #{lease.domain}: restored the checkpoint of #{session_id} (#{bytes.bytesize} bytes)"
      true
    rescue ApiError, ArgumentError, Zlib::Error, SystemCallError, IOError => e
      report_fault(lease, "restore_failed", e)
      drop_lease(lease.domain, "the checkpoint would not restore (#{e.class})")
      false
    end

    # The board's head is the session this process last checkpointed or
    # restored, at that same checkpoint, and the file is still byte for byte
    # what it was then.
    def own_current?(lease)
      own = @own_checkpoints[lease.domain]
      return false unless own && own.session_id == lease.session_id && own.checkpointed_at == lease.checkpointed_at
      return false unless File.file?(own.path)

      WarmSession.digest(own.path) == own.digest
    rescue SystemCallError, IOError
      false
    end

    # After a warm run: checkpoint a completed answer, or drop the lease. Never
    # raises into the loop.
    def settle_warm(run, answer)
      domain = run.warm.domain
      lease = @leases[domain]
      return unless lease

      return release_busy(domain, "the warm turn did not complete") unless answer

      checkpoint_turn(domain, lease, answer, run)
    rescue StandardError => e
      release_busy(domain, "settling the warm turn raised #{e.class}")
    end

    def checkpoint_turn(domain, lease, answer, run)
      session_id = answer.session_id
      path = session_id && WarmSession.transcript_path(session_id, cwd: answer.cwd, claude_home: @claude_home)
      unless path
        report_fault(lease, "checkpoint_failed", "no_transcript")
        return release_busy(domain, "the turn left no transcript")
      end

      lease.files << path
      tokens = WarmSession.context_tokens(answer.meta)
      turns = lease.turns.to_i + 1
      data = WarmSession.pack(path)
      digest = WarmSession.digest(path)
      previous = lease.session_id
      if data.bytesize > WarmSession::CHECKPOINT_LIMIT
        lease.session_id = session_id
        lease.turns = turns
        return start_consolidation(domain, run.message["soul_slug"], lease, tokens, "the transcript passed the checkpoint limit")
      end

      state = @client.domain_checkpoint(domain, worker: @worker, lease_key: lease.key, session_id: session_id, data: data,
                                                turns: turns, context_tokens: tokens)["data"] || {}
      lease.session_id = session_id
      lease.turns = turns
      lease.checkpointed_at = state["checkpointed_at"]
      lease.handback = state["handback_requested"] == true
      @own_checkpoints[domain] = OwnCheckpoint.new(session_id: session_id, checkpointed_at: lease.checkpointed_at,
                                                   path: path, digest: digest)
      prune_superseded(previous, session_id, answer.cwd)
      log "warm #{domain}: turn #{turns} checkpointed (#{data.bytesize} bytes, context #{tokens} tokens)"
      return release_busy(domain, "a handback was requested; between turns") if lease.handback
      if WarmSession.consolidate?(tokens, run.warm.consolidate_at)
        return start_consolidation(domain, run.message["soul_slug"], lease, tokens, "context passed #{run.warm.consolidate_at} tokens")
      end

      lease.busy = false
    rescue ApiError, SystemCallError, IOError, Zlib::Error => e
      log "warm #{domain}: CHECKPOINT FAILED (#{fault_detail(e)}); the turn is answered, the session falls back to " \
          "the board's last checkpoint"
      report_fault(lease, "checkpoint_failed", e)
      release_busy(domain, "the checkpoint failed (#{fault_detail(e)})")
    end

    # Tell the board a checkpoint or restore failed (AgentDomainSession#fault!:
    # ErrorLog and the row), so a domain gone cold shows on the board and not
    # only in this log. `cause` is an error (its class and code are sent, never
    # its message) or a fixed word. Never raises.
    def report_fault(lease, fault, cause)
      return unless lease&.key

      detail = cause.is_a?(Exception) ? fault_detail(cause) : cause.to_s
      @client.domain_fault(lease.domain, worker: @worker, lease_key: lease.key, fault: fault, detail: detail)
      log "warm #{lease.domain}: reported #{fault} (#{detail}) to the board"
    rescue ApiError => e
      log "warm #{lease.domain}: the #{fault} report failed too (#{e.message})"
    end

    def fault_detail(error)
      code = error.respond_to?(:code) && error.code ? " #{error.code}" : ""
      "#{error.class}#{code}"[/\A[A-Za-z0-9:_. -]{0,120}/].to_s
    end

    # A resumed turn may write its transcript under a new session id that holds
    # the whole history; the superseded file is then a duplicate. Removed only
    # inside this soul's own project folder, never anywhere else.
    def prune_superseded(previous, current, cwd)
      return if previous.nil? || previous == current
      return unless previous.match?(WarmSession::SESSION_ID)

      old = File.join(WarmSession.project_dir(cwd, claude_home: @claude_home), "#{previous}.jsonl")
      WarmSession.discard(old)
      @leases.each_value { |lease| lease.files&.delete(old) }
    end

    def start_consolidation(domain, soul, lease, tokens, why)
      responder = responder_for(soul)
      session_id = lease.session_id
      thread = Thread.new do
        Thread.current.report_on_exception = false
        responder.summarize(session_id)
      end
      @chores << Chore.new(domain: domain, thread: thread, started_at: @clock.call, source_session_id: session_id,
                           turns: lease.turns, context_tokens: tokens)
      log "warm #{domain}: consolidating (#{why})"
    end

    def finish_chore(chore)
      domain = chore.domain
      lease = @leases[domain]
      return unless lease

      text, run = chore.thread.value
      # The summary turn's own transcript holds the whole session too.
      summary_id = run.respond_to?(:session_id) ? run.session_id : nil
      if summary_id.to_s.match?(WarmSession::SESSION_ID) && lease.cwd
        lease.files << File.join(WarmSession.project_dir(lease.cwd, claude_home: @claude_home), "#{summary_id}.jsonl")
      end
      return release_busy(domain, "the consolidation answered nothing") if text.nil?

      state = @client.domain_consolidate(domain, worker: @worker, lease_key: lease.key, text: text,
                                                 source_session_id: chore.source_session_id, turns_covered: chore.turns,
                                                 context_tokens: chore.context_tokens)["data"] || {}
      lease.session_id = nil
      lease.turns = 0
      lease.checkpointed_at = nil
      lease.generation = state["generation"]
      lease.handback = state["handback_requested"] == true
      @own_checkpoints.delete(domain)
      # The summary replaces the session: its transcripts go.
      WarmSession.discard(lease.files)
      lease.files = []
      log "warm #{domain}: consolidated #{chore.turns} turn(s); generation #{lease.generation} starts fresh"
      return release_busy(domain, "a handback was requested; between turns") if lease.handback

      lease.busy = false
    rescue StandardError => e
      release_busy(domain, "the consolidation failed (#{e.class})")
    end

    def release_busy(domain, why)
      @leases[domain]&.busy = false
      drop_lease(domain, why)
    end

    # Give a domain's lease back to the board. The session and its checkpoint
    # stay for the next holder; this machine's copies of its transcripts go.
    def drop_lease(domain, why)
      lease = @leases[domain]
      return unless lease

      begin
        @client.domain_release(domain, worker: @worker, lease_key: lease.key)
        log "warm #{domain}: lease released (#{why})"
      rescue ApiError => e
        log "warm #{domain}: release failed (#{e.message}); the lease lapses on its own"
      end
      forget_lease(domain)
    end

    # Forget a lease without a board call (it was lost, or refused): its key,
    # the trust in this process's last checkpoint, and the transcripts this
    # process held for it, which are owner and team text.
    def forget_lease(domain)
      lease = @leases.delete(domain)
      own = @own_checkpoints.delete(domain)
      return unless lease || own

      files = Array(lease&.files) + [ own&.path ]
      if lease&.session_id.to_s.match?(WarmSession::SESSION_ID) && lease.cwd
        files << File.join(WarmSession.project_dir(lease.cwd, claude_home: @claude_home), "#{lease.session_id}.jsonl")
      end
      removed = WarmSession.discard(files)
      log "warm #{domain}: removed #{removed} local transcript(s)" if removed.positive?
    end

    # On the ping beat: renew every lease held, and give back, between turns,
    # one a primary asked for, or any a standby holds while a primary is live.
    def renew_leases
      @leases.values.each do |lease|
        if !lease.busy && (lease.handback || standing_by?)
          drop_lease(lease.domain, lease.handback ? "a handback was requested" : "the primary is back")
          next
        end

        state = @client.domain_renew(lease.domain, worker: @worker, lease_key: lease.key)["data"] || {}
        lease.handback = state["handback_requested"] == true
        drop_lease(lease.domain, "a handback was requested") if lease.handback && !lease.busy
      rescue ApiError => e
        # Lost: lapsed and taken. A turn in flight checkpoints into a refusal
        # and drops it then; an idle lease is simply forgotten.
        log "warm #{lease.domain}: renew refused (#{e.message})"
        forget_lease(lease.domain) unless lease.busy
      end
    end

    # The role and the primary's liveness from the ping's answer.
    def read_role(answer)
      role = answer.is_a?(Hash) ? answer.dig("data", "role") : nil
      if %w[primary standby].include?(role) && role != @role
        log "board role: #{role}"
        @role = role
      end
      live = answer.is_a?(Hash) ? answer.dig("meta", "primary_live") : nil
      @primary_live = live unless live.nil?
    end

    # A run that raised is a failed run: give the message back naming the error
    # (#raise_detail), log where it was raised (the log only, never the board),
    # and pause FAILURE_PAUSE so the next tick does not reclaim it into the same
    # raise and spend all its attempts in seconds (#67 and #68 on 2026-10-15).
    def answer_raised(id, error)
      detail = self.class.raise_detail(error)
      log "##{id} raised #{error.class} at #{error.backtrace&.first || 'unknown'}"
      give_back(id, "the answer run raised #{error.class}#{detail.empty? ? '' : ": #{detail}"}")
      pause_until(@clock.call + FAILURE_PAUSE, "answer_raised")
    end

    # A raised error's message, safe for the log and the board: its first line,
    # scrubbed to valid UTF-8, every quoted span replaced by `…` (a parser or
    # encoding error quotes the input it choked on, which can be message or answer
    # text), an unclosed quote redacted to the end of the line, and capped at
    # RAISE_DETAIL_LIMIT characters.
    def self.raise_detail(error)
      text = error.message.to_s.b.force_encoding(Encoding::UTF_8).scrub
      text = text.lines.first.to_s.gsub(/"(?:[^"\\]|\\.)*"|'[^']*'|`[^`]*`/, "…")
      # A quote left open (the error cut the input off mid-quote) runs to the end.
      text = text.sub(/["'`].*\z/, "…").strip
      text.length > RAISE_DETAIL_LIMIT ? "#{text[0, RAISE_DETAIL_LIMIT - 1]}…" : text
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

    # Every live run whose last pulse is TYPING_EVERY old gets another, until
    # TYPING_CAP after its start; a web run whose phase moved on (thinking to
    # typing) gets one at once, so the page swaps on the loop's next beat. A
    # finished run is reaped before this runs, so typing stops with the run.
    def type_due(now)
      @runs.each do |run|
        next unless run.typing
        next if run.typed_at && now - run.typed_at < TYPING_EVERY && !phase_moved?(run)

        pulse_typing(run, now)
      end
    end

    # Best effort: typing never holds up an answer. The board answering anything
    # but "queued" (capped, not answered, not Discord), refusing, or the call
    # raising anything at all stops this run's pulses; the answer goes on. Ids
    # and error classes only in the log.
    def pulse_typing(run, now)
      return unless run.typing

      if now - run.started_at > TYPING_CAP
        run.typing = false
        return
      end
      run.typed_at = now
      verdict = if run.phase
                  run.pulsed_phase = run.phase.current
                  @client.typing(run.message["id"], worker: @worker, phase: run.pulsed_phase)
                else
                  @client.typing(run.message["id"], worker: @worker)
                end.dig("meta", "typing")
      return if verdict == "queued"

      run.typing = false
      log "typing for ##{run.message['id']} stopped (#{verdict || 'no verdict'})"
    rescue ApiError => e
      run.typing = false
      log "typing for ##{run.message['id']} refused: #{e.message}"
    rescue StandardError => e
      # Anything else (a dropped connection, a client without #typing) must not
      # reach the main loop: typing is the one call here that is never needed.
      run.typing = false
      log "typing for ##{run.message['id']} failed (#{e.class})"
    end

    def phase_moved?(run) = run.phase ? run.phase.current != run.pulsed_phase : false

    def ping(now, state: nil)
      @last_ping = now
      answer = @client.ping({ "worker" => @worker, "host" => @host, "souls" => @souls, "running" => @runs.size,
                              "capacity" => @cap, "paused_until" => paused?(now) ? @paused_until.utc.iso8601 : nil,
                              "pause_reason" => paused?(now) ? @pause_reason : nil,
                              "state" => state || (paused?(now) ? "paused" : "running"),
                              "version" => @version, "started_at" => @started_at.utc.iso8601 })
      read_role(answer)
      renew_leases unless @leases.empty?
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
    # The command a refusal names. A service built on this class (ClientBuildLauncher::LaunchAgent)
    # sets its own LABEL, TEMPLATE, LOG_NAME and COMMAND; every method reads them through self.class.
    COMMAND = "bin/dispatcher"
    # After `bootout`, launchd stops the old job (SIGTERM, then up to the plist's
    # ExitTimeOut of 90s) before the label is free; a `bootstrap` sent sooner fails
    # with "Bootstrap failed: 5: Input/output error". So install waits for the
    # label to leave the domain, polling `launchctl print`, for up to BOOTOUT_WAIT.
    BOOTOUT_WAIT = 100
    BOOTOUT_POLL = 1
    # A bootstrap that still fails is tried this many times in all, BOOTSTRAP_BACKOFF apart.
    BOOTSTRAP_TRIES = 3
    BOOTSTRAP_BACKOFF = 3
    # Appended to the plist when install could not load it: the file then matches
    # no render, so the next ship's install --if-changed tries again.
    FAILED_MARK = "<!-- bootstrap failed"

    def initialize(home: Dir.home, repo_root: REPO_ROOT, ruby: RbConfig.ruby, path: ENV.fetch("PATH", ""),
                   uid: Process.uid, launchctl: nil, out: $stdout, sleeper: ->(s) { sleep(s) })
      @home = home
      @repo_root = repo_root
      @ruby = ruby
      @path = path
      @uid = uid
      @launchctl = launchctl || ->(*args) { Open3.capture2e("launchctl", *args) }
      @out = out
      @sleeper = sleeper
    end

    def label = self.class::LABEL
    def plist_path = File.join(@home, "Library/LaunchAgents/#{label}.plist")
    def log_path = File.join(@home, "Library/Logs/#{self.class::LOG_NAME}")
    def domain = "gui/#{@uid}"

    def render
      values = { "REPO_ROOT" => @repo_root, "HOME" => @home, "RUBY" => @ruby, "PATH" => service_path,
                 "LOG" => log_path, "LABEL" => label }
      File.read(self.class::TEMPLATE, encoding: "UTF-8").gsub(/\{\{([A-Z_]+)\}\}/) do
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
      rendered = render
      File.write(plist_path, rendered)
      @launchctl.call("bootout", target) # a reinstall replaces the running copy
      wait_for_bootout
      output = bootstrap
      if output
        mark_failed(rendered, output)
        return 1
      end
      @out.puts "installed #{plist_path}; logs at #{log_path}"
      status_report
    end

    def target = "#{domain}/#{label}"

    # True once `launchctl print` no longer finds the label (the old job has
    # exited); false when it is still listed after BOOTOUT_WAIT.
    def wait_for_bootout
      polls = (BOOTOUT_WAIT / BOOTOUT_POLL.to_f).ceil
      polls.times do
        _, status = @launchctl.call("print", target)
        return true unless status.success?

        @sleeper.call(BOOTOUT_POLL)
      end
      @out.puts "#{label}: still loaded #{BOOTOUT_WAIT}s after bootout; trying the bootstrap anyway"
      false
    end

    # nil on success, else the last failure's output.
    def bootstrap
      output = nil
      BOOTSTRAP_TRIES.times do |i|
        @sleeper.call(BOOTSTRAP_BACKOFF) if i.positive?
        output, status = @launchctl.call("bootstrap", domain, plist_path)
        return nil if status.success?

        @out.puts "launchctl bootstrap failed (try #{i + 1} of #{BOOTSTRAP_TRIES}): #{output.to_s.strip}"
      end
      output.to_s.strip
    end

    # The bootstrap never took: the job is booted out and KeepAlive cannot revive
    # it. Leave the plist on disk (launchd's bootstrap reads it from this path, so
    # it cannot be written only after a success, and removing it would read as
    # "not installed", which the ship never retries), but mark it, so it matches
    # no render and the next ship's install --if-changed reinstalls.
    def mark_failed(rendered, output)
      File.write(plist_path, "#{rendered}#{FAILED_MARK} #{Time.now.utc.iso8601}: " \
                             "#{output.gsub(/\s+/, ' ').gsub('--', '- -')}; the next ship reinstalls -->\n")
      @out.puts "launchctl bootstrap failed: #{output}. The service is NOT loaded; run `#{self.class::COMMAND} install` " \
                "from the hub checkout (the next production ship also retries)."
    end

    # The ship's step (bin/release.rb#refresh_local_services, each service's
    # `refresh` in config/local_services.yml): reinstall only
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
        @out.puts "#{label}: not installed; nothing to refresh"
        return 0
      end

      installed = File.read(plist_path, encoding: "UTF-8")
      kept = installed_paths(installed)
      agent = kept ? self.class.new(home: @home, repo_root: @repo_root, ruby: kept[:ruby], path: kept[:path],
                                    uid: @uid, launchctl: @launchctl, out: @out, sleeper: @sleeper) : self
      if agent.render == installed
        @out.puts "#{label}: installed plist matches the template; nothing to refresh"
        return 0
      end

      @out.puts "#{label}: the plist template changed; reinstalling"
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
      @launchctl.call("bootout", "#{domain}/#{label}")
      existed = File.exist?(plist_path)
      FileUtils.rm_f(plist_path)
      @out.puts existed ? "uninstalled #{label}; removed #{plist_path}" : "#{label} was not installed"
      0
    end

    # 0 running · 1 installed but not running · 3 not installed.
    def status_report
      unless File.exist?(plist_path)
        @out.puts "#{label}: not installed (no #{plist_path})"
        return 3
      end
      output, status = @launchctl.call("print", "#{domain}/#{label}")
      unless status.success?
        @out.puts "#{label}: installed but not loaded (launchctl print failed)"
        return 1
      end
      state = output[/^\s*state = (.+)$/, 1]&.strip
      pid = output[/^\s*pid = (\d+)/, 1]
      last_exit = output[/last exit code = (.+)$/, 1]
      @out.puts "#{label}: #{state || 'unknown'}#{pid ? " (pid #{pid})" : ''}" \
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
