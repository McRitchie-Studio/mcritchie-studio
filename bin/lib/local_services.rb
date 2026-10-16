# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "shellwords"
require "yaml"
require_relative "agent_mailbox"
require_relative "projects_root"

# The always-on local services a rebuilt Mac must be running, restored from one
# registry (config/local_services.yml) by the services phase of
# bin/ecosystem-build, plus the two things those services and the agents need
# from the operator's machine: the Claude Code allow-rules
# (config/claude_allow_rules.json) and a claude.ai sign-in. Whatever only the
# operator can do lands on the build's closing checklist (Checklist), so after a
# fresh-Mac rebuild he has to remember nothing
# (docs/agents/system/house-burn-down.md, "First-run audit").
#
# Every command goes through a runner seam and every path is an argument, so the
# tests drive it with a throwaway HOME, a fake launchctl and a fake claude
# (test/lib/local_services_test.rb, test/integration/ecosystem_build_services_phase_test.rb).
module LocalServices
  REPO_ROOT = File.expand_path("../..", __dir__)
  REGISTRY = File.join(REPO_ROOT, "config/local_services.yml")
  ALLOW_RULES = File.join(REPO_ROOT, "config/claude_allow_rules.json")
  HUB_TOKEN = "{{HUB}}"
  # The command that re-runs only this phase; every checklist item that ends in
  # "then re-run" names it.
  RERUN = "bin/ecosystem-build --phase services"

  class Error < StandardError; end

  Service = Struct.new(:name, :sop, :install, :status, :claude_auth, :commands, keyword_init: true)

  # The registry, read and checked. A malformed entry raises Error naming it:
  # a registry that half-loads would restore half the services and say nothing.
  module Registry
    KEYS = %w[name sop install status requires].freeze
    REQUIRES = %w[claude_auth commands].freeze

    module_function

    def load(path = REGISTRY)
      data = YAML.safe_load_file(path, aliases: false) || {}
      entries = data.is_a?(Hash) ? data["services"] : nil
      raise Error, "#{path}: no `services:` list" unless entries.is_a?(Array)

      services = entries.each_with_index.map { |entry, i| parse(entry, "#{path} services[#{i}]") }
      dupes = services.map(&:name).tally.select { |_, n| n > 1 }.keys
      raise Error, "#{path}: duplicate service name(s) #{dupes.join(', ')}" if dupes.any?

      services
    end

    def parse(entry, where)
      raise Error, "#{where}: not a mapping" unless entry.is_a?(Hash)

      unknown = entry.keys - KEYS
      raise Error, "#{where}: unknown key(s) #{unknown.join(', ')}" if unknown.any?

      %w[name sop install status].each do |key|
        raise Error, "#{where}: `#{key}` is missing or blank" if entry[key].to_s.strip.empty?
      end
      requires = entry["requires"] || {}
      raise Error, "#{where}: `requires` must be a mapping" unless requires.is_a?(Hash)

      unknown = requires.keys - REQUIRES
      raise Error, "#{where}: unknown prerequisite(s) #{unknown.join(', ')}" if unknown.any?

      commands = Array(requires["commands"]).map(&:to_s)
      Service.new(name: entry["name"].to_s, sop: entry["sop"].to_s, install: entry["install"].to_s,
                  status: entry["status"].to_s, claude_auth: requires["claude_auth"]&.to_s, commands: commands)
    end
  end

  # One step only the operator can take. `rank` orders the list (lower first);
  # equal items are listed once.
  Item = Struct.new(:rank, :text, :command, keyword_init: true)

  # The build's closing list is RENDERED by bin/ecosystem-build (render_checklist),
  # so it prints even when the build stops before Homebrew's Ruby exists. Ruby
  # only writes items into the same file, as `rank<TAB>text<TAB>command` lines.
  # RANKS is the order the operator does things in (lower first, gaps leave room);
  # the script's RANK_* constants carry the same numbers, and
  # test/lib/local_services_test.rb fails when the two disagree.
  module Checklist
    RANKS = {
      xcode: 5, homebrew: 10, op_agent: 20, github: 25, claude_install: 30, claude_login: 40,
      allow_rules: 45, service: 50, chrome: 70, op_admin: 80
    }.freeze

    module_function

    def line(item)
      [ item.rank, item.text, item.command ].map { |f| f.to_s.tr("\t\n", "  ") }.join("\t")
    end
  end

  # `claude auth status`, read through AgentMailbox::ClaudeAuth.auth_method.
  # :missing (no claude on PATH), :ok, or :wrong (signed out, or signed in some
  # other way than the method asked for).
  module ClaudeSignIn
    module_function

    def check(runner:, which:, want: "claude.ai")
      return [ :missing, nil ] unless which.call("claude")

      output, = runner.call(%w[claude auth status], nil)
      method = AgentMailbox::ClaudeAuth.auth_method(output)
      [ method == want ? :ok : :wrong, method ]
    end
  end

  # The services phase proper: for each registry entry, check prerequisites;
  # met and not running → install then re-check; unmet → skip and owe a
  # checklist item. Never raises on a failed command; returns the items.
  class Restorer
    attr_reader :items

    def initialize(services:, hub:, runner: Restorer.default_runner, which: Restorer.default_which, out: $stdout)
      @services = services
      @hub = hub
      @runner = runner
      @which = which
      @out = out
      @items = []
    end

    def self.default_runner
      ->(argv, chdir) { chdir ? Open3.capture2e(*argv, chdir: chdir) : Open3.capture2e(*argv) }
    end

    def self.default_which
      ->(cmd) { ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) } }
    end

    def run
      sign_in = claude_sign_in
      @services.each { |service| restore(service, sign_in) }
      @items
    end

    private

    def claude_sign_in
      state, method = ClaudeSignIn.check(runner: @runner, which: @which)
      waiting = @services.select(&:claude_auth).map(&:name)
      also = waiting.empty? ? "" : ", which starts #{waiting.join(', ')}"
      case state
      when :ok
        ok "Claude Code", "signed in with claude.ai"
      when :missing
        fail_line "Claude Code is not installed"
        owe :claude_install, "Install Claude Code (the CLI the agents and the dispatcher run)",
            "curl -fsSL https://claude.ai/install.sh | bash"
        owe :claude_login, "Sign Claude Code in with your claude.ai account, not an API key",
            "claude auth login   # then: #{RERUN}#{also}"
      else
        fail_line "Claude Code is not signed in with claude.ai", (method ? "authMethod: #{method}" : "signed out")
        owe :claude_login, "Sign Claude Code in with your claude.ai account, not an API key",
            "claude auth login   # then: #{RERUN}#{also}"
      end
      [ state, method ]
    end

    def restore(service, sign_in)
      missing = service.commands.reject { |cmd| @which.call(cmd) }
      if missing.any?
        fail_line "#{service.name} skipped", "needs #{missing.join(', ')} on PATH"
        # A missing claude is already on the list (ClaudeSignIn); anything else
        # (launchctl: not macOS) is named here.
        other = missing - %w[claude]
        if other.any?
          owe :service, "#{service.name} needs #{other.join(', ')}, which this machine lacks (#{service.sop})",
              "#{other.map { |c| "command -v #{c}" }.join(' && ')}   # then: #{RERUN}"
        end
        return
      end
      if service.claude_auth && sign_in.last != service.claude_auth
        fail_line "#{service.name} skipped", "waits on Claude Code signed in with #{service.claude_auth}"
        return
      end

      if running?(service)
        ok service.name, "running"
        return
      end

      act "installing #{service.name} (#{service.install})"
      output, status = command(service.install)
      if status&.success? && running?(service)
        ok service.name, "installed and running"
      else
        detail = output.to_s.lines.last.to_s.strip
        fail_line "#{service.name} did not start", detail.empty? ? nil : detail
        owe :service, "Get #{service.name} running: follow the Unblock playbook in #{service.sop}",
            "cd #{@hub} && #{service.status}"
      end
    end

    def running?(service)
      _, status = command(service.status)
      status&.success? || false
    end

    def command(line)
      @runner.call(Shellwords.split(line), @hub)
    rescue SystemCallError => e
      [ "#{e.class}: #{e.message}", nil ]
    end

    def owe(rank, text, command)
      @items << Item.new(rank: Checklist::RANKS.fetch(rank), text: text, command: command)
    end

    def ok(what, detail = nil) = @out.puts("  ✓ #{what}#{detail ? "  #{detail}" : ''}")
    def act(what) = @out.puts("  → #{what}")
    def fail_line(what, detail = nil) = @out.puts("  ✗ #{what}#{detail ? "  #{detail}" : ''}")
  end

  # The allow-rules agents rely on, merged into the operator's USER settings.
  module AllowRules
    module_function

    def rules(hub:, path: ALLOW_RULES)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      Array(data["allow"]).map { |rule| rule.to_s.gsub(HUB_TOKEN, hub) }
    end

    # Adds every rule `permissions.allow` lacks, in order, and changes nothing
    # else: every other key, rule and its order stays as it was. Writes only
    # when a rule is missing, through a temp file in the same directory renamed
    # over the original (atomic on one filesystem), keeping the file's mode. A
    # symlinked settings file is written through to its target. A file that is
    # not a JSON object, or whose permissions/allow have the wrong type, is
    # refused and left untouched.
    #
    # Returns [:added, rules] · [:current, []] · [:refused, reason].
    def merge!(settings_path, wanted)
      target = File.symlink?(settings_path) ? File.realpath(settings_path) : settings_path
      existing = File.exist?(target) ? File.read(target, encoding: "UTF-8") : nil
      data = existing.nil? || existing.strip.empty? ? {} : JSON.parse(existing)
      return [ :refused, "#{settings_path} is not a JSON object" ] unless data.is_a?(Hash)

      perms = data["permissions"] ||= {}
      return [ :refused, "#{settings_path}: permissions is not an object" ] unless perms.is_a?(Hash)

      allow = perms["allow"] ||= []
      return [ :refused, "#{settings_path}: permissions.allow is not a list" ] unless allow.is_a?(Array)

      added = wanted.uniq - allow
      return [ :current, [] ] if added.empty?

      allow.concat(added)
      write_atomically(target, "#{JSON.pretty_generate(data)}\n", existing ? File.stat(target).mode & 0o777 : 0o600)
      [ :added, added ]
    rescue JSON::ParserError => e
      [ :refused, "#{settings_path} is not valid JSON (#{e.message.lines.first.to_s.strip[0, 80]})" ]
    end

    def write_atomically(path, content, mode)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{rand(1 << 32)}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(content) }
      File.chmod(mode, tmp)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end

  module_function

  # The hub's primary checkout the services install from: PROJECTS_DIR's
  # mcritchie-studio when set (bin/ecosystem-build's own seam), else the one
  # ProjectsRoot resolves (a desk climbs out to the primary).
  def default_hub
    dir = ENV["PROJECTS_DIR"].to_s
    dir.empty? ? ProjectsRoot.hub_checkout : File.join(File.expand_path(dir), ProjectsRoot::HUB_REPO)
  end

  def default_settings = File.join(Dir.home, ".claude/settings.json")
end
