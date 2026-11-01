# frozen_string_literal: true

require "json"
require "rbconfig"
require "yaml"
require_relative "agent_audience"
require_relative "agent_warm_session"

module AgentMailbox
  # DOMINION OF SCOPE (docs/agents/system/agent-message-loop.md, "Scoped runs: the
  # owner's terminal in Slack"; epic .agents/epics/slack-terminal-scope.md).
  #
  # When the verified owner messages a soul on Slack, the soul answers with
  # READ-ONLY tools inside its scope (config/agent_scopes.yml), so it can look
  # things up the way a terminal session would. This file is the one gate that
  # decides it (Scopes#grant), the catalog of board lookups both halves read
  # (LOOKUPS: the dispatcher validates against it, the board's
  # AgentScopes::Lookups runs it), and the Claude command a granted run uses
  # (Grant#claude_cmd).
  #
  # The board requires this file too (AgentScopes::Lookups), as it does
  # agent_audience.rb, so the catalog and the gate live once.
  module Scopes
    PATH = "config/agent_scopes.yml"
    ROUTES_PATH = "config/agent_routes.yml"
    # The MCP server's name in the Claude command: its tools are
    # mcp__<SERVER>__<tool>.
    SERVER = "scope"
    TOOLS = %w[lookup run_command read_file list_files].freeze
    # Built-in tools named again in --disallowedTools, on top of --tools "",
    # so a CLI that ever ignored the empty list would still refuse them.
    DENIED_BUILTINS = %w[Bash Write Edit MultiEdit NotebookEdit WebFetch WebSearch Task Agent].freeze
    SOUL = /\A[a-z0-9_-]{1,40}\z/
    COMMAND_NAME = /\A[a-z][a-z0-9_]{0,40}\z/
    DEFAULTS = { "channels" => %w[slack], "max_turns" => 12, "tool_timeout" => 45, "output_limit" => 12_000,
                 "read_limit" => 40_000 }.freeze
    MAX_TURNS_CAP = 30
    TOOL_TIMEOUT_CAP = 90

    # THE LOOKUP CATALOG: every board read a scope may name, with its params and
    # their bounds. A param the model sends that is not listed is refused; an
    # integer outside its bounds is refused, not clamped (the model is told the
    # bounds). `pattern` params must match whole. The board runs each one
    # (AgentScopes::Lookups); nothing here reaches a database.
    DAYS = ->(default, max) { { "type" => "integer", "min" => 1, "max" => max, "default" => default } }
    ENTITY = { "type" => "string", "pattern" => '\A[a-z][a-z0-9_]{0,30}\z', "required" => true }.freeze
    LOOKUPS = {
      "error_groups" => {
        "what" => "errors across every app's health report (the hub and each satellite), grouped by app, " \
                  "error class and redacted message, most frequent first",
        "params" => { "days" => DAYS.call(1, 3),
                      "app" => { "type" => "string", "pattern" => '\A[a-z0-9][a-z0-9_-]{0,40}\z' } }
      },
      "gate_failures" => {
        "what" => "gate runs (DoR, review, candidate, ship) in the window: attempts and failures per gate, " \
                  "the failing test SOPs most often named, and the subjects that failed most",
        "params" => { "days" => DAYS.call(7, 30) }
      },
      "review_findings" => {
        "what" => "open triage findings (title, repo, source) and the tasks blocked now with their reasons",
        "params" => { "limit" => { "type" => "integer", "min" => 1, "max" => 40, "default" => 20 } }
      },
      "grades" => {
        "what" => "task grades in the window: verdicts, the rules most often tripped, and recent learnings; " \
                  "action grades by disposition",
        "params" => { "days" => DAYS.call(14, 60) }
      },
      "board_status" => { "what" => "task counts per stage, and how many are blocked", "params" => {} },
      "recently_shipped" => { "what" => "tasks shipped in the window", "params" => { "days" => DAYS.call(7, 30) } },
      "release_status" => { "what" => "the open release, the accepted to main ladder, and the last ship", "params" => {} },
      "books_status" => {
        "what" => "one entity's books (config/books.yml): statements per account, lines waiting for an " \
                  "answer, and each close with its cash and net income",
        "params" => { "entity" => ENTITY }
      },
      "books_unclassified" => {
        "what" => "the lines in one entity's books still waiting for a category",
        "params" => { "entity" => ENTITY, "limit" => { "type" => "integer", "min" => 1, "max" => 50, "default" => 25 } }
      },
      "books_month" => {
        "what" => "one month of one entity's books: totals per category and per kind (income, expense, " \
                  "equity, transfer, asset), the line count and what is unclassified",
        "params" => { "entity" => ENTITY,
                      "month" => { "type" => "string", "pattern" => '\A20\d\d-(?:0[1-9]|1[0-2])\z', "required" => true } }
      },
      "usage" => {
        "what" => "an app's agent usage this month and today against its allowance",
        "params" => { "app" => { "type" => "string", "pattern" => '\A[a-z0-9][a-z0-9_-]{0,40}\z', "required" => true } }
      }
    }.freeze

    class ConfigError < StandardError; end
    class Refused < StandardError; end

    # One read-only command: an exact argv prefix and the extra arguments allowed.
    Command = Struct.new(:name, :argv, :args, :max_args, :what, keyword_init: true) do
      # The argv to run, or Refused. Every extra argument must match `args` and
      # none may start a new option the pattern does not name.
      def argv_for(extra)
        extra = Array(extra).map(&:to_s)
        raise Refused, "#{name} takes at most #{max_args} argument#{'s' unless max_args == 1}" if extra.size > max_args

        extra.each do |arg|
          raise Refused, "argument #{arg[0, 40].inspect} is not allowed for #{name}" unless args.match?(arg)
        end
        argv + extra
      end
    end

    # A soul's scope, as loaded and checked.
    Scope = Struct.new(:soul, :lookups, :commands, :paths, keyword_init: true) do
      def command(name) = commands.find { |c| c.name == name.to_s }
      def tools? = lookups.any? || commands.any? || paths.any?
    end

    # A granted run: the scope, and what the MCP server needs to reach the board
    # as this run's holder. `reason` is code-shaped, for the run record.
    Grant = Struct.new(:scope, :message_id, :worker, :repo_root, :max_turns, keyword_init: true) do
      def soul = scope.soul

      # The tool names Claude may call: only this server's, only the tools this
      # scope has something behind.
      def allowed_tools
        tools = []
        tools << "lookup" if scope.lookups.any?
        tools << "run_command" if scope.commands.any?
        tools += %w[read_file list_files] if scope.paths.any?
        tools.map { |t| "mcp__#{SERVER}__#{t}" }
      end

      # The MCP config, inline (no file): one stdio server, bin/agent-scope-mcp,
      # told the soul, the message and the worker. No secret is in it: the
      # server reads the board credential from the environment it inherits.
      def mcp_config
        server = File.join(repo_root, "bin/agent-scope-mcp")
        args = [ "--soul", soul, "--message", message_id.to_s, "--worker", worker.to_s, "--repo", repo_root ]
        JSON.generate("mcpServers" => { SERVER => { "type" => "stdio", "command" => RbConfig.ruby,
                                                    "args" => [ server, *args ] } })
      end

      # The cold command plus the scope. Measured against claude 2.1.316
      # (2026-10-31): --safe-mode turns MCP servers off, --mcp-config included, so
      # a scoped run swaps it for --restricted, which ignores the user, project
      # and local settings files (their hooks, permission rules and plugins with
      # them) and confines any file tool to the working directories, and adds
      # --disable-slash-commands. Built-in tools stay off (--tools "", put in if
      # missing), only this server is loaded (--strict-mcp-config), only its
      # tools are allowed, the built-ins are denied by name as well, anything
      # else is refused without a prompt (dontAsk), and the run is held to
      # max_turns.
      def claude_cmd(base)
        argv = base.map { |a| a == "--safe-mode" ? "--restricted" : a }
        argv += [ "--restricted" ] unless argv.include?("--restricted")
        if (i = argv.index("--tools"))
          argv[i + 1] = ""
        else
          argv += [ "--tools", "" ]
        end
        argv + [ "--disable-slash-commands",
                 "--mcp-config", mcp_config, "--strict-mcp-config",
                 "--allowedTools", allowed_tools.join(","),
                 "--disallowedTools", DENIED_BUILTINS.join(","),
                 "--permission-mode", "dontAsk",
                 "--max-turns", max_turns.to_s ]
      end
    end

    # The decision, with its reason (code-shaped: it goes to the run record and
    # the log, never text a person wrote).
    Decision = Struct.new(:grant, :reason, keyword_init: true) do
      def granted? = !grant.nil?
    end

    class Config
      attr_reader :defaults, :deny_paths, :souls

      def self.load(repo_root)
        path = File.join(repo_root, PATH)
        return new({}) unless File.file?(path)

        new(YAML.safe_load_file(path, aliases: false) || {})
      rescue Psych::Exception => e
        raise ConfigError, "#{PATH} does not parse: #{e.message}"
      end

      def initialize(data)
        raise ConfigError, "#{PATH} must be a mapping" unless data.is_a?(Hash)

        @defaults = DEFAULTS.merge(data["defaults"].is_a?(Hash) ? data["defaults"] : {})
        @deny_paths = Array(data["deny_paths"]).map(&:to_s).freeze
        @souls = (data["souls"] || {}).to_h { |soul, spec| [ soul.to_s, build_scope(soul.to_s, spec || {}) ] }.freeze
        check_defaults!
      end

      def scope_for(soul) = @souls[soul.to_s]
      def max_turns = @defaults["max_turns"].to_i
      def tool_timeout = @defaults["tool_timeout"].to_i
      def output_limit = @defaults["output_limit"].to_i
      def read_limit = @defaults["read_limit"].to_i
      def channels = Array(@defaults["channels"]).map(&:to_s)

      private

      def check_defaults!
        raise ConfigError, "max_turns must be 1..#{MAX_TURNS_CAP}" unless max_turns.between?(1, MAX_TURNS_CAP)
        raise ConfigError, "tool_timeout must be 1..#{TOOL_TIMEOUT_CAP}" unless tool_timeout.between?(1, TOOL_TIMEOUT_CAP)
        raise ConfigError, "output_limit must be positive" unless output_limit.positive?
        raise ConfigError, "read_limit must be positive" unless read_limit.positive?
      end

      def build_scope(soul, spec)
        raise ConfigError, "unsafe soul #{soul.inspect}" unless soul.match?(SOUL)

        lookups = Array(spec["lookups"]).map(&:to_s)
        unknown = lookups - LOOKUPS.keys
        raise ConfigError, "#{soul}: unknown lookup#{'s' if unknown.size > 1} #{unknown.join(', ')}" if unknown.any?

        commands = Array(spec["commands"]).map { |c| build_command(soul, c) }
        paths = Array(spec["paths"]).map(&:to_s)
        paths.each do |p|
          raise ConfigError, "#{soul}: path #{p.inspect} must be relative and stay inside the checkout" if
            p.start_with?("/") || p.split("/").include?("..") || p.empty?
        end
        Scope.new(soul: soul, lookups: lookups.uniq.freeze, commands: commands.freeze, paths: paths.freeze)
      end

      def build_command(soul, spec)
        raise ConfigError, "#{soul}: a command must be a mapping" unless spec.is_a?(Hash)

        name = spec["name"].to_s
        raise ConfigError, "#{soul}: bad command name #{name.inspect}" unless name.match?(COMMAND_NAME)

        argv = Array(spec["argv"]).map(&:to_s)
        raise ConfigError, "#{soul}: #{name} needs an argv" if argv.empty? || argv.any?(&:empty?)
        raise ConfigError, "#{soul}: #{name} must run a checkout script (bin/...)" unless argv.first.start_with?("bin/") &&
                                                                                          !argv.first.include?("..")

        pattern = spec["args"].to_s
        max = spec["max_args"].to_i
        raise ConfigError, "#{soul}: #{name} max_args must be 0..8" unless max.between?(0, 8)
        raise ConfigError, "#{soul}: #{name} args must be anchored (\\A...\\z)" if max.positive? &&
                                                                                 !(pattern.start_with?('\A') && pattern.end_with?('\z'))

        Command.new(name: name, argv: argv.freeze, args: Regexp.new(pattern.empty? ? '\A\z' : pattern),
                    max_args: max, what: spec["what"].to_s)
      rescue RegexpError => e
        raise ConfigError, "#{soul}: #{name} args do not compile: #{e.message}"
      end
    end

    module_function

    # THE GATE. A scoped run only when EVERY one holds; anything else is the
    # no-tools path, and the reason says which check failed:
    #
    #   no_scope          the soul has no scope (or one with nothing in it)
    #   channel           the message is not on a scoped channel (Slack)
    #   not_owner         the board's audience is not the owner (the board
    #                     resolves it from the verified sender's person; a name
    #                     in the text cannot set it)
    #   not_owner_user    the message's author_ref is not slack.owner_user_id:
    #                     the platform id Slack's signed event carried, checked
    #                     again here, so a mislinked identity cannot grant tools
    #   released_hold     an admin released a held row: answered, never scoped
    #   not_cleared       the soul may not answer in this channel (clearance)
    #   quoted            the message or an earlier thread turn carries quoted or
    #                     forwarded material, or a turn that is not the sender's
    #
    # `routes` is config/agent_routes.yml's data, `config` a Scopes::Config.
    def grant(soul:, message:, context:, worker:, repo_root:, config: nil, routes: nil)
      config ||= Config.load(repo_root)
      routes ||= load_routes(repo_root)
      message = message.is_a?(Hash) ? message : {}
      scope = config.scope_for(soul)
      return deny("no_scope") unless scope&.tools?
      return deny("channel") unless config.channels.include?(message["channel"].to_s)
      return deny("not_owner") unless Audience.from_context(context).owner?

      owner = owner_user_id(routes, message["channel"])
      return deny("not_owner_user") if owner.empty? || message["author_ref"].to_s != owner
      return deny("released_hold") unless message["hold_released_at"].to_s.empty?
      return deny("not_cleared") unless cleared?(routes, message["channel"], message["channel_ref"], soul)
      return deny("quoted") unless own_words?(message, context)

      Decision.new(grant: Grant.new(scope: scope, message_id: Integer(message["id"]), worker: worker.to_s,
                                    repo_root: repo_root, max_turns: config.max_turns), reason: "granted")
    rescue ArgumentError, TypeError
      deny("bad_message")
    end

    def deny(reason) = Decision.new(grant: nil, reason: reason)

    def load_routes(repo_root)
      path = File.join(repo_root, ROUTES_PATH)
      File.file?(path) ? (YAML.safe_load_file(path, aliases: false) || {}) : {}
    end

    def owner_user_id(routes, channel)
      block = routes[channel.to_s]
      block.is_a?(Hash) ? block["owner_user_id"].to_s.strip : ""
    end

    # The board's clearance rule (AgentMessages::SlackRoutes#cleared?), read
    # again here without Rails: a muted channel clears nobody; `open: true` every
    # soul the block serves; `souls:` the core souls plus those listed; neither,
    # every served soul. A soul the block does not serve (recognized only, or
    # unknown) is never cleared.
    def cleared?(routes, channel, channel_ref, soul)
      block = routes[channel.to_s]
      return false unless block.is_a?(Hash)
      return false unless (block["souls"] || {}).key?(soul.to_s)

      override = (block["channels"] || {})[channel_ref.to_s]
      return true unless override.is_a?(Hash)
      return false if override["ignore"] == true
      return true if override["open"] == true
      return true unless override.key?("souls")

      (Array(block["core_souls"]) + Array(override["souls"])).map(&:to_s).include?(soul.to_s)
    end

    # The same own-words rule a warm turn uses (WarmSession.quotes?, `own`): a
    # tool run's prompt carries only the owner's own text.
    def own_words?(message, context)
      return false if WarmSession.quotes?(message["content"])

      thread = context.is_a?(Hash) ? context["thread"] : nil
      turns = Array(thread.is_a?(Hash) ? thread["turns"] : nil)
      turns.all? { |turn| turn.is_a?(Hash) && turn["own"] == true && !WarmSession.quotes?(turn["content"]) }
    end

    # The params a lookup was called with, checked against its catalog entry:
    # [name, params with defaults filled] or Refused. Shared by the MCP server
    # (before it calls the board) and the board (before it runs the query).
    def check_lookup(name, params, allowed:)
      name = name.to_s
      spec = LOOKUPS[name]
      raise Refused, "no lookup named #{name[0, 40].inspect}" unless spec
      raise Refused, "#{name} is not in this scope" unless Array(allowed).include?(name)

      given = params.is_a?(Hash) ? params.to_h { |k, v| [ k.to_s, v ] } : {}
      extra = given.keys - spec["params"].keys
      raise Refused, "#{name} takes no #{extra.join(', ')}" if extra.any?

      checked = spec["params"].each_with_object({}) do |(key, rule), out|
        value = given[key]
        if value.nil? || value.to_s.empty?
          raise Refused, "#{name} needs #{key}" if rule["required"]

          out[key] = rule["default"] unless rule["default"].nil?
          next
        end
        out[key] = check_param(name, key, value, rule)
      end
      [ name, checked ]
    end

    def check_param(name, key, value, rule)
      case rule["type"]
      when "integer"
        int = Integer(value.to_s, 10)
        raise Refused, "#{name} #{key} must be #{rule['min']}..#{rule['max']}" unless int.between?(rule["min"], rule["max"])

        int
      else
        text = value.to_s
        raise Refused, "#{name} #{key} #{text[0, 40].inspect} is not allowed" unless Regexp.new(rule["pattern"]).match?(text)

        text
      end
    rescue ArgumentError
      raise Refused, "#{name} #{key} must be a whole number"
    end

    # The lookups a scoped soul is told it has, one line each, for its prompt.
    def describe(scope)
      lines = scope.lookups.map do |name|
        params = LOOKUPS[name]["params"].map do |key, rule|
          bound = rule["type"] == "integer" ? "#{rule['min']}-#{rule['max']}" : "text"
          "#{key} #{bound}#{' required' if rule['required']}"
        end
        "  - lookup `#{name}`#{params.empty? ? '' : " (#{params.join(', ')})"}: #{LOOKUPS[name]['what']}"
      end
      lines += scope.commands.map { |c| "  - run_command `#{c.name}`: #{c.what}" }
      lines << "  - read_file / list_files: #{scope.paths.join(', ')}" if scope.paths.any?
      lines.join("\n")
    end
  end

  # Scrubs what a tool hands back before the model sees it: a value shaped like
  # a credential (a provider token prefix, a bearer header, a key=value whose key
  # names a secret, a long hex or base64 run, a private key block) becomes
  # [redacted]. A false hit costs a word; a miss could post a secret, so the
  # patterns lean wide. Every tool result passes through it, on top of the
  # scope's path deny-list.
  module Redact
    PATTERNS = [
      /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/m,
      /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/,
      /\bgithub_pat_[A-Za-z0-9_]{20,}/,
      /\bsk-[A-Za-z0-9_-]{16,}/,
      /\bxox[abposr]-[A-Za-z0-9-]{10,}/,
      /\bxapp-[A-Za-z0-9-]{10,}/,
      /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
      /\bBearer\s+[A-Za-z0-9._~+\/=-]{12,}/i,
      /\b(?:postgres(?:ql)?|redis|rediss|mysql|amqp):\/\/[^\s"'<>]+/i,
      /\b[a-f0-9]{40,}\b/i,
      /\b[A-Za-z0-9+\/]{48,}={0,2}/
    ].freeze
    # A secret after a name that says it is one: the name is kept, the value goes.
    NAMED = [
      /([?&](?:token|key|secret|signature|sig|password)=)[^&\s"'<>]+/i,
      /(\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*["']?\s?[=:]\s?)["']?[^\s"',]{6,}/i
    ].freeze
    MARK = "[redacted]"

    module_function

    def call(text)
      out = NAMED.reduce(text.to_s.dup) { |acc, re| acc.gsub(re) { "#{Regexp.last_match(1)}#{MARK}" } }
      PATTERNS.reduce(out) { |acc, re| acc.gsub(re, MARK) }
    end
  end
end
