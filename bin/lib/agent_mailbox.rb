# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "socket"
require "time"
require "timeout"
require "tmpdir"
require "uri"
require_relative "agent_api"
require_relative "agent_context_builder"
require_relative "agent_proposal_block"

# The worker and observer side of the agent mailbox
# (docs/agents/system/agent-message-loop.md): `bin/heartbeat` and `bin/dispatcher`
# claim a message, answer it (Responder) and complete it; `bin/agent-inbox` reads
# the queue. Both speak to
# /api/v1/agent_messages through AgentApi, so they authenticate exactly as the
# rest of the agent CLI stack does (a held login first, else the shared token)
# and target the same board (ATOMIC_CAPTURE_URL, default https://mcritchie.studio).
module AgentMailbox
  REPO_ROOT = File.expand_path("../..", __dir__)

  class ApiError < StandardError; end

  # The mailbox endpoints, over AgentApi. Every call returns the parsed body or
  # raises ApiError naming the status and the board's reason; a mailbox command
  # that cannot reach the board must say so, not idle as if nothing were waiting.
  class Client
    def initialize(api: AgentApi.new(open_timeout: 5, read_timeout: 30), soul: nil)
      @api = api
      @session = soul ? api.held_session(soul: soul) : nil
    end

    def base_url = @api.base_url

    def list(params = {})
      call(:get, path("/api/v1/agent_messages", params))
    end

    def show(id) = call(:get, "/api/v1/agent_messages/#{Integer(id)}")
    def peek(soul:, channel:) = call(:get, path("/api/v1/agent_messages/next", soul: soul, channel: channel))

    # One soul (`soul:`) or several (`souls:`, bin/dispatcher). `wait:` long-polls:
    # the board holds the request up to that many seconds (it caps the wait) and
    # answers the moment a message is claimable, else data null.
    def claim(worker:, channel:, soul: nil, souls: nil, wait: nil)
      body = { "worker" => worker, "channel" => channel }
      body["soul"] = soul if soul
      body["souls"] = souls if souls
      body["wait"] = wait if wait
      call(:post, "/api/v1/agent_messages/claim", body)
    end

    def renew(id, worker:)
      call(:post, "/api/v1/agent_messages/#{Integer(id)}/renew", { "worker" => worker })
    end

    # One "typing…" pulse for a held message (AgentMessageTypingJob on the
    # board). meta.typing says "queued" or why not.
    def typing(id, worker:)
      call(:post, "/api/v1/agent_messages/#{Integer(id)}/typing", { "worker" => worker })
    end

    # bin/dispatcher's minute ping (AgentDispatcher on the board).
    def ping(payload)
      call(:post, "/api/v1/agent_dispatchers/ping", payload)
    end

    # The holder's context bundle: the sender's exchanges with this soul on every channel,
    # the thread, the summary and the notes (AgentMessages::MemoryBundle on the board).
    def context(id, worker:)
      call(:get, path("/api/v1/agent_messages/#{Integer(id)}/context", worker: worker))
    end

    # `run`: what the Claude run reported (Responder::Answer#run_record), optional.
    def complete(id, worker:, response_text:, action_summary:, run: {})
      body = { "worker" => worker, "response_text" => response_text, "action_summary" => action_summary }
      call(:post, "/api/v1/agent_messages/#{Integer(id)}/complete", body.merge(run.compact))
    end

    # `code: "usage_limit"` hands the attempt back (AgentMessage::REFUND_CODES).
    def release(id, worker:, reason:, code: nil)
      body = { "worker" => worker, "reason" => reason }
      body["code"] = code if code
      call(:post, "/api/v1/agent_messages/#{Integer(id)}/release", body)
    end

    private

    def path(base, params)
      query = params.reject { |_, v| v.nil? || v.to_s.empty? }
      query.empty? ? base : "#{base}?#{URI.encode_www_form(query)}"
    end

    def call(method, path, body = nil)
      res = AgentApi.call(@api, method, path, body, session: @session)
      raise ApiError, "no answer from #{base_url} (unreachable, or no agent token)" if res.nil?

      parsed = JSON.parse(res.body.to_s) rescue {}
      return parsed if res.code.to_i.between?(200, 299)

      raise ApiError, "#{method.upcase} #{path} -> HTTP #{res.code}: #{parsed['error'] || res.body.to_s[0, 200]}"
    end
  end

  # The environment every child command runs under: an ALLOW-LIST, applied with
  # unsetenv_others, so nothing outside it reaches a child. Headless Claude then
  # bills Alex's claude.ai login (keychain, under HOME and USER) and never an
  # exported API key, auth token, base URL or Bedrock/Vertex switch, including
  # names Anthropic adds later, which a deny-list would miss. The agent-board
  # names are the read-only actions' own (bin/task reads the board through the
  # agent API); none of them routes Claude. No action reads Heroku, so no Heroku
  # credential is passed: bin/release status needed a Heroku login launchd does
  # not have (HEROKU_NONINTERACTIVE_LOGIN, measured 2026-10-15).
  CHILD_ENV_ALLOW = %w[
    PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM TZ __CF_USER_TEXT_ENCODING
    GEM_HOME GEM_PATH
    ATOMIC_CAPTURE_URL AGENT_API_SECRET AGENT_LEGACY_TOKEN PROJECTS_DIR CLAUDE_PROJECTS_DIR TASK_API_BASE
  ].freeze

  def self.child_env(env = ENV)
    CHILD_ENV_ALLOW.each_with_object({}) { |name, kept| kept[name] = env[name] if env.key?(name) }
  end

  # The child processes running right now (pids, each its own process group),
  # so bin/dispatcher can stop them on shutdown. Thread-safe: dispatcher runs
  # answer on threads.
  module Children
    @pids = []
    @lock = Mutex.new

    def self.add(pid) = @lock.synchronize { @pids << pid }
    def self.remove(pid) = @lock.synchronize { @pids.delete(pid) }
    def self.pids = @lock.synchronize { @pids.dup }

    # Signals each child's whole group, so a grandchild holding the output pipe
    # dies with it.
    def self.terminate_all(signal = "TERM")
      pids.each { |pid| AgentMailbox.signal_group(pid, signal) }
    end
  end

  # A child that outlives its timeout gets TERM, then KILL after this many
  # seconds: a run that ignores TERM cannot hold its slot.
  KILL_GRACE = 10
  # How long the output readers may take to drain once the child is gone.
  DRAIN_WAIT = 5

  def self.signal_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    Process.kill(signal, pid) rescue nil
  end

  # [output, exit status or nil on timeout, stderr]. stderr is folded into the
  # output for an action (an operator reads it) but kept apart for Claude.
  # The child runs in its own process group under child_env. On timeout the
  # group gets TERM, then KILL after kill_grace.
  def self.run_command(argv, stdin:, timeout:, chdir:, kill_grace: KILL_GRACE)
    Open3.popen3(child_env, *argv, chdir: chdir, unsetenv_others: true, pgroup: true) do |i, o, e, wait|
      Children.add(wait.pid)
      begin
        begin
          i.write(stdin) if stdin
        rescue Errno::EPIPE
          nil
        end
        i.close
        reader = Thread.new { o.read }
        err = Thread.new { e.read }
        unless wait.join(timeout)
          signal_group(wait.pid, "TERM")
          signal_group(wait.pid, "KILL") unless wait.join(kill_grace)
          wait.join
          return [ drained(reader), nil, drained(err) ]
        end
        output = drained(reader)
        error = drained(err)
        output += error if stdin.nil?
        [ output, wait.value.exitstatus, error ]
      ensure
        Children.remove(wait.pid)
      end
    end
  rescue SystemCallError, IOError => e
    [ "could not run #{argv.first}: #{e.message}", 127, "" ]
  end

  # A child's output, read as UTF-8 whatever the process locale says (launchd
  # gives the dispatcher no LANG), with any invalid byte scrubbed, so it can be
  # joined into a UTF-8 prompt.
  def self.drained(thread) = (thread.join(DRAIN_WAIT)&.value).to_s.b.force_encoding(Encoding::UTF_8).scrub

  # What one headless `claude -p --output-format json` run said, read ONLY from
  # what the model cannot author: the exit status, stderr, and the JSON
  # envelope's own fields (`type`, `subtype`, `is_error`, `api_error_status`).
  #
  #   reply       the envelope's `result` when the run succeeded (exit 0, not
  #               is_error), else nil. The answer text is never scanned for a run
  #               STATUS; the Responder only splits a notes section off it
  #               (NoteBlock), a format the prompt asks for, not a signal it acts on.
  #   error_text  on a failed run only: the envelope's result/error when is_error,
  #               and stderr. This is CLI-authored text, the only text the
  #               usage-limit and signed-out matchers ever read.
  #   api_status  the envelope's api_error_status (429 on a rate or usage limit).
  #   session_id  the envelope's session_id, so an operator can `claude --resume` it.
  #   meta        a few envelope numbers: usage.output_tokens_details.thinking_tokens,
  #               usage.output_tokens, num_turns, duration_ms, the modelUsage model.
  #
  # The envelope carries NO reasoning text: `claude -p --output-format json`
  # reports thinking only as a token count. The text, when the model's thinking
  # is not redacted, is in the session transcript (Transcript.reasoning).
  #
  # Stdout that is not an envelope (a stub, or a CLI crash before it could write
  # one) is a reply on exit 0 and error text otherwise: in json mode the model's
  # words only ever arrive inside the envelope.
  module ClaudeRun
    Parsed = Struct.new(:reply, :error_text, :api_status, :session_id, :meta, keyword_init: true)

    def self.parse(stdout, status, stderr)
      env = envelope(stdout)
      ok = status&.zero? ? true : false
      if env
        failed = !ok || env["is_error"] == true || env["subtype"].to_s.start_with?("error")
        reply = failed ? nil : env["result"].to_s.strip
        error = failed ? [ (env["result"] if env["is_error"] == true), env["error"], stderr ] : nil
        return Parsed.new(reply: reply.to_s.empty? ? nil : reply, error_text: join(error),
                          api_status: env["api_error_status"], session_id: session_id(env), meta: meta(env))
      end

      text = stdout.to_s.strip
      return Parsed.new(reply: text.empty? ? nil : text, error_text: nil, api_status: nil) if ok

      Parsed.new(reply: nil, error_text: join([ stdout, stderr ]), api_status: nil)
    end

    def self.session_id(env)
      id = env["session_id"].to_s
      id.match?(/\A[0-9A-Za-z-]{8,100}\z/) ? id : nil
    end

    def self.meta(env)
      usage = env["usage"].is_a?(Hash) ? env["usage"] : {}
      models = env["modelUsage"].is_a?(Hash) ? env["modelUsage"].keys : []
      { "thinking_tokens" => usage.dig("output_tokens_details", "thinking_tokens"),
        "output_tokens" => usage["output_tokens"], "num_turns" => env["num_turns"],
        "duration_ms" => env["duration_ms"], "model" => models.first }
        .select { |_, v| v.is_a?(Numeric) || v.is_a?(String) }
    end

    def self.envelope(stdout)
      data = JSON.parse(stdout.to_s.strip)
      data.is_a?(Hash) && data["type"] == "result" ? data : nil
    rescue JSON::ParserError
      nil
    end

    def self.join(parts)
      return nil if parts.nil?

      parts.compact.map { |p| p.is_a?(String) ? p : JSON.generate(p) }.join("\n")
    end
    private_class_method :envelope, :join, :session_id, :meta
  end

  # A headless run's session transcript, read for its REASONING: the text of
  # the assistant's `thinking` blocks. Claude Code writes the transcript to
  # <claude home>/projects/<the run's cwd, slugged>/<session_id>.jsonl. Thinking
  # is often redacted (a block with a signature and empty text), so a run can
  # have thinking tokens and no reasoning to show; `source` says which.
  # Display only: nothing acts on what the model thought.
  module Transcript
    LIMIT = 20_000

    # [text or nil, source]: source is "transcript", "redacted" (thinking blocks
    # with no text), "none" (no thinking blocks), or "no_transcript".
    def self.reasoning(session_id, claude_home: File.join(Dir.home, ".claude"))
      return [ nil, "no_transcript" ] unless session_id.to_s.match?(/\A[0-9A-Za-z-]{8,100}\z/)

      path = Dir.glob(File.join(claude_home, "projects", "*", "#{session_id}.jsonl")).first
      return [ nil, "no_transcript" ] unless path

      blocks = []
      File.foreach(path, encoding: "UTF-8") do |line|
        next unless line.include?("thinking")

        entry = JSON.parse(line) rescue next
        content = entry.is_a?(Hash) && entry["type"] == "assistant" ? entry.dig("message", "content") : nil
        Array(content).each { |b| blocks << b["thinking"].to_s if b.is_a?(Hash) && b["type"] == "thinking" }
      end
      return [ nil, "none" ] if blocks.empty?

      text = blocks.map(&:strip).reject(&:empty?).join("\n\n")
      text.empty? ? [ nil, "redacted" ] : [ text[0, LIMIT], "transcript" ]
    rescue SystemCallError, IOError
      [ nil, "no_transcript" ]
    end
  end

  # Claude's "you are out of usage" notice, read deterministically from a FAILED
  # run's CLI-authored text (ClaudeRun#error_text: the error envelope and stderr)
  # and the envelope's api_error_status. Never from a successful answer: that is
  # the model replying to untrusted chat text, which can say anything. A hit hands
  # the message back WITHOUT spending an attempt (release code usage_limit; the
  # board caps those refunds) and pauses bin/dispatcher until the reset the notice
  # names, else for BACKOFF.
  #
  # The PATTERN is the one place these strings live; test/lib/agent_usage_limit_test.rb
  # pins real-looking error envelopes as hits and planted answers as misses.
  module UsageLimit
    PATTERN = /
      claude\ ai\ usage\ limit\ reached
      | usage\ limit\ reached
      | (?:5-hour|five-hour|session|weekly|opus|sonnet)\ limit\ reached
      | you(?:'|’)ve\ (?:hit|reached)\ your\ (?:usage\ |session\ |weekly\ )?limit
      | out\ of\ extra\ usage
      | rate_limit_error
    /ix
    BACKOFF = 15 * 60
    # A parsed reset further out than this is distrusted (BACKOFF instead).
    MAX_PAUSE = 8 * 24 * 3600
    # Resume a minute after the named reset, not on its edge.
    MARGIN = 60

    Hit = Struct.new(:reset_at, :parsed, :notice, keyword_init: true)

    # nil, or a Hit whose reset_at is when to resume. `run` is a ClaudeRun::Parsed;
    # a run with no error_text (it succeeded) is never a hit.
    def self.detect(run, now: Time.now)
      text = run.error_text.to_s
      return nil if run.error_text.nil?
      return nil unless text.match?(PATTERN) || run.api_status.to_i == 429

      reset = parse_reset(text, now: now)
      reset = nil if reset && (reset <= now || reset > now + MAX_PAUSE)
      notice = (text.lines.map(&:strip).find { |l| l.match?(PATTERN) } || "API error #{run.api_status}").to_s[0, 200]
      Hit.new(reset_at: reset ? reset + MARGIN : now + BACKOFF, parsed: !reset.nil?, notice: notice)
    end

    MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze

    # The reset time a notice names, or nil:
    #   "Claude AI usage limit reached|1760461200"            epoch seconds
    #   "... resets 3pm (America/Denver)" / "reset at 3:30 pm" the next such clock time
    #   "... resets Oct 20, 9am (America/Denver)"              that date and time
    # A named zone is honoured when TZInfo is loadable, else local time is used.
    def self.parse_reset(text, now: Time.now)
      if (epoch = text[/usage limit reached\|(\d{9,11})/i, 1])
        return Time.at(epoch.to_i)
      end

      m = text.match(/resets?\s+(?:at\s+|on\s+)?(?:(?<mon>[A-Za-z]{3})[a-z]*\.?\s+(?<day>\d{1,2}),?\s+(?:at\s+)?)?
                      (?<h>\d{1,2})(?::(?<min>\d{2}))?\s*(?<ampm>am|pm)\b(?:\s*\((?<zone>[^)]+)\))?/ix)
      return nil unless m

      hour = m[:h].to_i % 12 + (m[:ampm].downcase == "pm" ? 12 : 0)
      minute = m[:min].to_i
      zone = zone_for(m[:zone])
      local_now = zone ? zone.to_local(now) : now
      month = m[:mon] && MONTHS.index(m[:mon].downcase[0, 3])
      if month
        year = local_now.year
        candidate = build_time(zone, year, month + 1, m[:day].to_i, hour, minute)
        candidate = build_time(zone, year + 1, month + 1, m[:day].to_i, hour, minute) if candidate && candidate < now - 86_400
        return candidate
      end

      candidate = build_time(zone, local_now.year, local_now.month, local_now.day, hour, minute)
      candidate += 86_400 if candidate && candidate <= now
      candidate
    rescue ArgumentError
      nil
    end

    def self.zone_for(name)
      return nil if name.nil? || name.strip.empty?

      require "tzinfo"
      TZInfo::Timezone.get(name.strip)
    rescue LoadError, StandardError
      nil
    end

    def self.build_time(zone, year, month, day, hour, minute)
      return Time.local(year, month, day, hour, minute) unless zone

      zone.local_to_utc(Time.utc(year, month, day, hour, minute)).then { |t| Time.at(t.to_i) }
    rescue ArgumentError, StandardError
      nil
    end
    private_class_method :zone_for, :build_time
  end

  # Claude saying it is not signed in, read the same way: only from a failed
  # run's CLI-authored error text. Unlike a
  # usage limit this spends the attempt (only usage_limit refunds), but
  # bin/dispatcher pauses PAUSE seconds on it, so a signed-out Mac burns at most
  # one attempt per pause while the floor alert reports the waiting message.
  module ClaudeAuth
    PATTERN = %r{not\ logged\ in|please\ run\ /login|invalid\ api\ key|authentication_error|oauth\ token\ (?:has\ )?expired}ix
    PAUSE = 30 * 60

    def self.signed_out?(run)
      !run.error_text.nil? && run.error_text.match?(PATTERN)
    end

    # The sign-in method `claude auth status` reports ("claude.ai" for the
    # subscription the dispatcher bills), or nil when it reports none: logged
    # out, or output that is not the CLI's JSON (a PATTERN-style "not logged in"
    # line included). Unreadable is nil because a sign-in check must fail closed.
    # Reads only these two keys, so the account's email and org never leave
    # this method.
    # (bin/lib/local_services.rb, the services phase of bin/ecosystem-build.)
    def self.auth_method(status_output)
      data = JSON.parse(status_output.to_s)
      return nil unless data.is_a?(Hash) && data["loggedIn"] == true

      method = data["authMethod"].to_s.strip
      method.empty? ? nil : method
    rescue JSON::ParserError
      nil
    end
  end

  # The answer path one message takes, shared by bin/heartbeat and bin/dispatcher:
  # the soul's ONE read-only action, then a headless Claude run on the prompt
  # ContextBuilder lays out (role, domain, notes about the sender, the sender's
  # ledger, the message), every person-written byte fenced as untrusted data. It
  # talks to no API; the caller claims, fetches the context bundle, completes and
  # releases.
  #
  # Each soul's Claude runs from its OWN folder, mailbox_home/<soul> (created on
  # demand), so its transcripts sit together and `claude --resume <id>` from that
  # folder reopens a run. Memory never comes from a resumed session: every answer
  # is rebuilt from the board's rows.
  class Responder
    # The ONE read-only action each soul may take, run from the hub checkout.
    # A soul with none still answers, from its role alone. It runs only when the
    # message's audience may use it (Audience#may?(:read_action): owner and team);
    # for a client or the public it is never run. Every action reads the board
    # through the agent API (bin/task), never Heroku: the dispatcher runs under
    # launchd with no Heroku login. Avi's release numbers come from his
    # release_status ask (AgentProposals::Queries), read in process on the board.
    ACTIONS = {
      "avi" => { argv: %w[bin/task list], what: "the task board" },
      "xan" => { argv: %w[bin/task list], what: "the task board" }
    }.freeze
    ACTION_TIMEOUT = 90
    ACTION_OUTPUT_LIMIT = 6000
    ROLE_LIMIT = ContextBuilder::BUDGETS[:general]
    # Headless Claude, with NO tools: the message is untrusted, so the model
    # answering it can read nothing and run nothing beyond the prompt it is given.
    # --safe-mode skips CLAUDE.md, hooks, skills and plugins for the same reason.
    # json, so the reply and any error arrive in an envelope whose status fields
    # the model cannot write (ClaudeRun).
    DEFAULT_CLAUDE_CMD = [ "claude", "-p", "--safe-mode", "--tools", "", "--output-format", "json" ].freeze
    CLAUDE_TIMEOUT = 300
    # reply: the text to post, or nil when the run failed. usage_limit: a
    # UsageLimit::Hit when Claude answered that the account is out of usage.
    # signed_out: Claude answered that it is not logged in. session_id, cwd,
    # reasoning, meta: what the run reported, for the board's run record. notes:
    # the facts the run returned about the sender (NoteBlock), already cut from
    # the reply. proposal: the parsed PROPOSAL block (ProposalBlock), also cut
    # from the reply; the board alone decides whether it stands.
    Answer = Struct.new(:reply, :action, :status, :usage_limit, :signed_out, :session_id, :cwd, :reasoning, :meta,
                        :notes, :proposal, keyword_init: true) do
      # The complete call's run fields (AgentMessage.run_record on the board),
      # plus `notes`, which the board files under the message's author, and
      # `proposal`, which the board validates (AgentProposal.record_from!).
      def run_record
        { "claude_session_id" => session_id, "claude_cwd" => cwd, "reasoning" => reasoning,
          "run_meta" => meta && !meta.empty? ? meta : nil,
          "notes" => notes && !notes.empty? ? notes : nil,
          "proposal" => proposal.is_a?(Hash) ? proposal : nil }
      end
    end

    def initialize(soul:, claude_cmd: DEFAULT_CLAUDE_CMD, runner: nil, repo_root: REPO_ROOT, clock: -> { Time.now },
                   mailbox_home: nil, claude_home: File.join(Dir.home, ".claude"))
      @soul = soul.to_s
      @claude_cmd = claude_cmd
      @runner = runner || AgentMailbox.method(:run_command)
      @repo_root = repo_root
      @clock = clock
      @mailbox_home = mailbox_home
      @claude_home = claude_home
    end

    # `context`: the board's bundle for this message (Client#context), or nil.
    def respond(message, context: nil)
      audience = Audience.from_context(context)
      action = run_action(audience)
      cwd = soul_folder
      output, status, error = @runner.call(@claude_cmd, stdin: prompt_for(message, action, context: context, audience: audience),
                                                         timeout: CLAUDE_TIMEOUT, chdir: cwd)
      run = ClaudeRun.parse(output, status, error)
      limit = UsageLimit.detect(run, now: @clock.call)
      reasoning, source = run.session_id ? Transcript.reasoning(run.session_id, claude_home: @claude_home) : [ nil, nil ]
      meta = (run.meta || {}).merge(source ? { "reasoning_source" => source } : {})
      reply, notes, proposal = run.reply && !limit ? ProposalBlock.split(run.reply) : [ nil, [], nil ]
      Answer.new(reply: reply.to_s.empty? ? nil : reply, notes: notes, proposal: proposal, action: action, status: status, usage_limit: limit,
                 signed_out: limit.nil? && ClaudeAuth.signed_out?(run), session_id: run.session_id, cwd: cwd,
                 reasoning: reasoning, meta: meta)
    end

    def prompt_for(message, action, context: nil, audience: nil)
      ContextBuilder.new(soul: @soul, message: message, context: context, action: action,
                         action_what: ACTIONS.dig(@soul, :what), repo_root: @repo_root, audience: audience).prompt
    end

    # The soul's folder, <mailbox root>/<soul>, made on demand: the ONE seam that
    # hands the folder out, laundered through TaskUsageSandbox.enforce! (the root
    # is ~/.agents/mailbox, not the <projects>/.agents state store, but the guard
    # keeps a sandboxed run out of that store whatever HOME says). A soul slug is
    # the board's; anything outside [a-z0-9_-] is refused, not joined into a path.
    def soul_folder
      raise ArgumentError, "unsafe soul slug #{@soul.inspect}" unless @soul.match?(/\A[a-z0-9_-]+\z/)

      TaskUsageSandbox.enforce!(File.join(mailbox_root, @soul), store: "agent-mailbox")
                      .tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # nil, running nothing, unless the audience may read the soul's action.
    def run_action(audience)
      spec = ACTIONS[@soul]
      return nil unless spec && audience.may?(:read_action)

      output, status = @runner.call(spec[:argv], stdin: nil, timeout: ACTION_TIMEOUT, chdir: @repo_root)
      exit_text = status.nil? ? "timed out" : "exit #{status}"
      { summary: "ran `#{spec[:argv].join(' ')}` (#{exit_text})", output: output.to_s[0, ACTION_OUTPUT_LIMIT] }
    end

    private

    # Where the soul folders live: the mailbox_home given, else AGENT_MAILBOX_HOME
    # (the tests point it at a temporary folder), else ~/.agents/mailbox. Private:
    # only soul_folder hands a path out, and it launders it.
    def mailbox_root
      given = (@mailbox_home || ENV["AGENT_MAILBOX_HOME"]).to_s
      given.empty? ? File.join(Dir.home, ".agents", "mailbox") : given
    end
  end

  # One soul's heartbeat over the mailbox: claim → the Responder (one read-only
  # action, a headless Claude answer) → complete. Drains what is waiting (or one
  # message with --once) and exits; with nothing waiting it says so and exits 0.
  # bin/dispatcher is the service form of the same path; this stays the manual one.
  class Heartbeat
    ACTIONS = Responder::ACTIONS
    DEFAULT_CLAUDE_CMD = Responder::DEFAULT_CLAUDE_CMD
    CLAUDE_TIMEOUT = Responder::CLAUDE_TIMEOUT
    # A drain stops after this many messages, so one run cannot loop forever on
    # a flooded queue.
    MAX_PER_RUN = 10

    attr_reader :worker

    def initialize(soul:, client:, channel: "discord", once: false, worker: nil, dry_run: false,
                   claude_cmd: DEFAULT_CLAUDE_CMD, runner: nil, out: $stdout, repo_root: REPO_ROOT,
                   mailbox_home: nil, claude_home: File.join(Dir.home, ".claude"))
      @soul = soul
      @client = client
      @channel = channel
      @once = once
      @worker = worker || self.class.default_worker
      @dry_run = dry_run
      @out = out
      @responder = Responder.new(soul: soul, claude_cmd: claude_cmd, runner: runner, repo_root: repo_root,
                                 mailbox_home: mailbox_home, claude_home: claude_home)
    end

    # "host-pid-rand": two runs on one machine, even started the same second,
    # never share a worker id.
    def self.default_worker
      "#{Socket.gethostname.split('.').first}-#{Process.pid}-#{SecureRandom.hex(3)}"
    end

    # Returns [answered, failed]: how many messages were answered (or, dry-run,
    # would have been), and whether a message had to be given back. A failure
    # ENDS the run: re-claiming at once would spend the message's remaining
    # attempts on the same broken Claude call and dead-letter it in seconds.
    def run
      answered = 0
      loop do
        message = next_message
        unless message
          @out.puts "nothing for #{@soul}"
          break
        end
        return [ answered, true ] unless handle(message)

        answered += 1
        break if @once || @dry_run || answered >= MAX_PER_RUN
      end
      [ answered, false ]
    end

    def prompt_for(message, action) = @responder.prompt_for(message, action)

    private

    def next_message
      if @dry_run
        @client.peek(soul: @soul, channel: @channel)["data"]
      else
        @client.claim(soul: @soul, worker: @worker, channel: @channel)["data"]
      end
    end

    def handle(message)
      id = message["id"]
      verb = @dry_run ? "would claim" : "claimed"
      @out.puts "#{verb} ##{id} for #{@soul} (attempt #{message['attempts']}) as #{@worker}: #{message['content'].to_s[0, 120]}"

      # The memory is the board's: a dry run peeks, holds no claim, and so answers
      # without the ledger (the context endpoint is holder-only).
      context = @dry_run ? nil : @client.context(id, worker: @worker)["data"]
      answer = @responder.respond(message, context: context)
      action = answer.action
      @out.puts "action: #{action ? action[:summary] : 'none enabled'}"
      if answer.usage_limit
        give_back(id, "Claude usage limit: #{answer.usage_limit.notice}", code: "usage_limit")
        return false
      end
      reply = answer.reply

      if reply.nil?
        give_back(id, "the Claude run failed or answered nothing")
        return false
      end

      @out.puts "answer: #{reply[0, 300]}"
      if @dry_run
        @out.puts "dry run: nothing claimed, completed or posted"
        return true
      end

      result = @client.complete(id, worker: @worker, response_text: reply, action_summary: action&.dig(:summary),
                                    run: answer.run_record)
      @out.puts "session: #{answer.session_id}" if answer.session_id
      @out.puts "completed ##{id} (#{result.dig('meta', 'outcome')}); the reply posts to #{message['channel']}"
      true
    rescue ApiError => e
      @out.puts "error on ##{id}: #{e.message}"
      give_back(id, e.message) unless @dry_run
      raise
    end

    def give_back(id, reason, code: nil)
      @out.puts "releasing ##{id}: #{reason}"
      return if @dry_run

      @client.release(id, worker: @worker, reason: reason, code: code)
    rescue ApiError => e
      @out.puts "release failed (#{e.message}); the lease lapses on its own"
    end
  end

  # bin/agent-inbox: list | show <id> | tail, read through the API.
  class InboxCli
    USAGE = <<~TEXT
      Usage:
        bin/agent-inbox list [--soul S] [--status S] [--channel C] [--limit N]
        bin/agent-inbox show <id>
        bin/agent-inbox tail [--soul S] [--interval SECONDS]
    TEXT

    def initialize(argv, client: nil, out: $stdout, sleeper: ->(s) { sleep(s) }, iterations: nil)
      @argv = argv.dup
      @client = client
      @out = out
      @sleeper = sleeper
      @iterations = iterations
    end

    def run
      command = @argv.shift
      opts = parse(@argv)
      case command
      when "list" then list(opts)
      when "show" then show(opts[:id])
      when "tail" then tail(opts)
      else
        @out.puts USAGE
        return command.nil? || %w[-h --help help].include?(command) ? 0 : 2
      end
      0
    rescue ApiError, ArgumentError => e
      @out.puts "agent-inbox: #{e.message}"
      1
    end

    private

    def client = (@client ||= Client.new)

    def parse(args)
      opts = {}
      until args.empty?
        arg = args.shift
        case arg
        when "--soul", "--status", "--channel", "--limit", "--interval"
          value = args.shift or raise ArgumentError, "#{arg} needs a value"
          opts[arg.delete_prefix("--").to_sym] = value
        else
          raise ArgumentError, "unknown argument #{arg}" if arg.start_with?("-") || opts[:id]

          opts[:id] = arg
        end
      end
      opts
    end

    def list(opts)
      rows = client.list(opts.slice(:soul, :status, :channel, :limit))["data"]
      @out.puts "no messages" if rows.empty?
      rows.each { |m| @out.puts line(m) }
    end

    def show(id)
      raise ArgumentError, "show needs a message id" if id.nil?

      m = client.show(id)["data"]
      @out.puts line(m)
      @out.puts "  thread:  #{m['thread_key']}"
      @out.puts "  from:    #{m['author_name']} (#{m['author_ref']})"
      @out.puts "  message: #{m['content']}"
      @out.puts "  answer:  #{m['response_text']}" if m["response_text"]
      show_person(m["person"])
      @out.puts "  action:  #{m['action_summary']}" if m["action_summary"]
      @out.puts "  reply:   #{m['reply_url']}" if m["reply_url"]
      show_run(m)
      @out.puts "  timeline:"
      Array(m["events"]).each do |e|
        detail = (e["detail"] || {}).map { |k, v| "#{k}=#{v}" }.join(" ")
        @out.puts "    #{e['created_at']}  #{e['kind'].ljust(14)} #{e['actor']}  #{detail}".rstrip
      end
    end

    # Who wrote it across platforms, and the notes the souls keep about them
    # (model-written from what that person said: data, shown as such).
    def show_person(person)
      return unless person.is_a?(Hash)

      @out.puts "  person:  #{person['display_name']} (##{person['id']}) #{Array(person['identities']).join(' ')}".rstrip
      notes = Array(person["notes"])
      @out.puts "  notes:   #{notes.empty? ? '(none)' : ''}".rstrip
      notes.each { |n| @out.puts "    - #{n['body']}  (#{n['noted_at'].to_s[0, 10]}, from ##{n['source_message_id'] || '-'})" }
    end

    # The answering Claude run: its session, the ready resume line, its numbers
    # and its reasoning when the transcript carried any.
    def show_run(m)
      return if m["claude_session_id"].to_s.empty?

      @out.puts "  session: #{m['claude_session_id']}"
      @out.puts "  resume:  #{m['resume_command']}" if m["resume_command"]
      meta = (m["run_meta"] || {}).map { |k, v| "#{k}=#{v}" }.join(" ")
      @out.puts "  run:     #{meta}" unless meta.empty?
      return if m["reasoning"].to_s.strip.empty?

      @out.puts "  reasoning:"
      m["reasoning"].to_s.each_line { |l| @out.puts "    #{l.rstrip}" }
    end

    # The newest messages, then every change as it lands. Ctrl-C ends it.
    def tail(opts)
      interval = Float(opts[:interval] || 5)
      rows = client.list(opts.slice(:soul).merge(limit: 10))["data"]
      rows.reverse_each { |m| @out.puts line(m) }
      since = rows.map { |m| m["updated_at"] }.max || Time.now.utc.iso8601(6)
      seen = rows.to_h { |m| [ m["id"], m["updated_at"] ] }
      count = 0
      loop do
        break if @iterations && count >= @iterations

        count += 1
        @sleeper.call(interval)
        fresh = client.list(opts.slice(:soul).merge(since: since, limit: 50))["data"]
        fresh.reverse_each do |m|
          next if seen[m["id"]] == m["updated_at"]

          seen[m["id"]] = m["updated_at"]
          @out.puts line(m)
        end
        since = ([ since ] + fresh.map { |m| m["updated_at"] }).max
      end
    rescue Interrupt
      nil
    end

    def line(m)
      holder = if m["claimed_by"].nil? then ""
               elsif m["status"] == "claimed" then " held by #{m['claimed_by']} until #{m['lease_expires_at']}"
               else " by #{m['claimed_by']}"
               end
      reply = m["reply_url"] ? " reply #{m['reply_url']}" : ""
      "##{m['id']} #{m['status'].ljust(9)} #{(m['soul_slug'] || '-').ljust(6)} try #{m['attempts']}#{holder} " \
        "#{m['author_name']}: #{m['content'].to_s.gsub(/\s+/, ' ')[0, 80]}#{reply}"
    end
  end
end
