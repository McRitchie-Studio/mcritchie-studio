# frozen_string_literal: true

require "time"
require_relative "bounded_command"

module AgentMailbox
  # HarnessProbe — is the agent harness on this Mac healthy? bin/dispatcher runs
  # one on each minute beat, off its main loop, and carries the answer on its
  # ping (POST /api/v1/agent_dispatchers/ping). The board stores it on the
  # dispatcher row, and the floor alert opens harness_degraded after five
  # consecutive failing beats (docs/agents/agents/steffon/sops/agent-dispatcher.md).
  #
  # WHY. From 2026-10-21 to 2026-10-24 the 1Password cache daemon never became
  # ready after a reboot: every `op read` hung, so `gh` said Bad credentials and
  # `git fetch` hung, for three days, and no alarm fired, because nothing watched
  # op or gh. The dispatcher never went silent, so its silent check stayed quiet.
  #
  # WHAT, each bounded at DEADLINE seconds (BoundedCommand: SIGKILL to the whole
  # process group at the deadline):
  #
  #   op_ok   `op whoami` in a login shell, so it carries the service-account
  #           token an agent shell gets from ~/.zprofile. Not metered and not
  #           retried: it measures the cached path the daemon serves, and it costs
  #           no quota (measured 2026-10-24: three `op whoami` moved neither the
  #           token's read counter nor the account's read_write counter, while one
  #           `op read` moved each by one).
  #   gh_ok   `gh api /rate_limit` with the token bin/gh-token hands every agent
  #           (its cache, minted through 1Password when stale). /rate_limit
  #           spends no GitHub rate limit.
  #   power   "ac" or "battery", from `pmset -g batt`; nil where pmset is absent.
  #
  # No secret enters this process: the token lives only inside the child shell.
  class HarnessProbe
    DEADLINE = BoundedCommand::DEFAULT_DEADLINE
    OP_SCRIPT = "op whoami >/dev/null 2>&1"
    GH_SCRIPT = 'GH_TOKEN="$(bin/gh-token 2>/dev/null)" && [ -n "$GH_TOKEN" ] && ' \
                'GH_TOKEN="$GH_TOKEN" gh api /rate_limit --silent >/dev/null 2>&1'
    PMSET = "/usr/bin/pmset"

    Measurement = Struct.new(:op_ok, :gh_ok, :power, :measured_at, keyword_init: true) do
      # The ping's keys (Api::V1::AgentDispatchersController#ping).
      def to_ping
        { "op_ok" => op_ok, "gh_ok" => gh_ok, "power" => power, "harness_measured_at" => measured_at&.utc&.iso8601 }
      end
    end

    # The power source in `pmset -g batt`'s first line ("Now drawing from 'AC Power'").
    def self.parse_power(text)
      case text.to_s.lines.first.to_s
      when /'AC Power'/ then "ac"
      when /'Battery Power'/ then "battery"
      end
    end

    # The shell a login session on this machine uses, so ~/.zprofile is read.
    def self.login_shell
      [ ENV.fetch("SHELL", ""), "/bin/zsh", "/bin/bash" ].find { |sh| !sh.empty? && File.executable?(sh) }
    end

    # +runner+ answers whether a script exited 0 inside its deadline.
    def initialize(repo_root:, runner: nil, power: nil, clock: -> { Time.now }, deadline: DEADLINE)
      @repo_root = repo_root
      @deadline = deadline
      @runner = runner || method(:run_script)
      @power = power || method(:read_power)
      @clock = clock
    end

    def call
      Measurement.new(op_ok: @runner.call(OP_SCRIPT, @deadline), gh_ok: @runner.call(GH_SCRIPT, @deadline),
                      power: @power.call, measured_at: @clock.call)
    end

    private

    def run_script(script, deadline)
      shell = self.class.login_shell
      return false if shell.nil?

      BoundedCommand.run({}, [ shell, "-lc", script ], deadline: deadline, pgroup: true,
                                                        in: File::NULL, err: File::NULL, chdir: @repo_root).success?
    rescue SystemCallError
      false
    end

    def read_power
      return nil unless File.executable?(PMSET)

      result = BoundedCommand.run({}, [ PMSET, "-g", "batt" ], deadline: 5, err: File::NULL)
      result.success? ? self.class.parse_power(result.out) : nil
    rescue SystemCallError
      nil
    end
  end
end
