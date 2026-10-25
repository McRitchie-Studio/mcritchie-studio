# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "time"
require "fileutils"
require_relative "local_services"
require_relative "harness_key"
require_relative "op_vaults"

# ConductorHost: the checks and the idempotent steps that make a Mac the
# always-on conductor host (the agent dispatcher and the client build launcher
# under launchd, a harness key, power settings that survive a power cut).
# Runbook: docs/agents/agents/steffon/sops/conductor-host.md. CLI: bin/conductor-host-setup.
#
# NEVER A SECRET. No check reads a secret's value into anything it prints: the
# token checks match a line's NAME and test that a value follows, and every item
# that needs a secret names the 1Password item an operator fetches it from.
#
# Every command goes through a runner seam (argv, chdir) -> [output, ok], and every
# path is derived from the env handed in, so the tests run the whole check
# against a fake home with stub commands on PATH.
module ConductorHost
  # What `pmset -g` must read on the conductor. The runbook's one command sets
  # all five: `sudo pmset -c sleep 0 displaysleep 10 disksleep 0 womp 1 autorestart 1`.
  PMSET = { "sleep" => "0", "displaysleep" => "10", "disksleep" => "0", "womp" => "1", "autorestart" => "1" }.freeze
  PMSET_COMMAND = %w[sudo pmset -c sleep 0 displaysleep 10 disksleep 0 womp 1 autorestart 1].freeze

  HUB_REPO = "mcritchie-studio"
  HUB_URL = "https://github.com/McRitchie-Studio/mcritchie-studio.git"
  BREW_INSTALL = '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  CLAUDE_INSTALL = "curl -fsSL https://claude.ai/install.sh | bash"
  BOARD_TASKS = "https://mcritchie.studio/tasks"
  LAUNCHER_SOUL = "client-build-launcher"
  LIVE_SECONDS = 5 * 60 # AgentDispatcher::SILENT_AFTER
  PRE_CUTOVER = "the current conductor (until bin/conductor-host-setup --take-over)"

  # The 1Password names an operator needs. Named, never read here.
  def self.op_agent_token
    "a service account token with read on the #{OpVaults.vault} vault, one per machine " \
      "(1Password > Developer Tools > Service Accounts; Alex creates it)"
  end

  def self.op_agent_secret = "item `Agent API Secret` (field AGENT_API_SECRET), vault #{OpVaults.vault}"

  # The printed fix for a hub .env without AGENT_API_SECRET: the vault read piped
  # straight into a Ruby writer, so the value is never in a shell variable, an
  # argument or the screen. The writer refuses an EMPTY read, which is what a
  # failed `op read` produces, so a broken session cannot append a blank
  # `AGENT_API_SECRET=` line that then reads as "set"; and it creates or tightens
  # the .env to 600 (secrets-scrub-review-notes; news-pipeline.md's X token recipe).
  # One line, single-quoted Ruby, so the code inside uses double quotes only.
  def self.agent_secret_fix(hub)
    writer = 'v = $stdin.read.chomp; abort "refusing: empty read, nothing written" if v.empty?; ' \
             'File.open(ARGV[0], "a", 0o600) { |f| f.puts "AGENT_API_SECRET=" + v }; File.chmod(0o600, ARGV[0])'
    "op read '#{OpVaults.ref('Agent API Secret', 'AGENT_API_SECRET')}' | ruby -e '#{writer}' #{hub}/.env"
  end

  Item = Struct.new(:key, :label, :state, :detail, :fix, :secret, keyword_init: true) do
    def done? = state == :done
  end

  module_function

  def default_runner
    lambda do |argv, chdir = nil|
      opts = chdir ? { chdir: chdir } : {}
      out, status = Open3.capture2e(*argv, **opts)
      [ out, status.success? ]
    rescue SystemCallError
      [ nil, false ]
    end
  end

  def host_name = Socket.gethostname.split(".").first

  # The host's layout, from the env alone (HOME, PROJECTS_DIR, CLAUDE_PROJECTS_DIR).
  class Layout
    attr_reader :home, :projects

    def initialize(env)
      @home = File.expand_path(env.fetch("HOME"))
      dir = env["PROJECTS_DIR"].to_s.strip
      dir = env["CLAUDE_PROJECTS_DIR"].to_s.strip if dir.empty?
      @projects = dir.empty? ? File.join(@home, "projects") : File.expand_path(dir)
    end

    def hub = File.join(projects, HUB_REPO)
    def zprofile = File.join(home, ".zprofile")
    def zprofile_admin = File.join(home, ".zprofile.admin")

    # The directories the two launchd agents and the harness write into.
    def directories
      [ File.join(home, "Library", "LaunchAgents"), File.join(home, "Library", "Logs"),
        File.join(home, ".client-builds") ]
    end
  end

  # Reads the board's dispatcher rows (GET /api/v1/agent_dispatchers) with the
  # agent token. Returns [rows, nil] or [nil, reason].
  def default_board(env)
    lambda do
      require_relative "agent_api"
      api = AgentApi.new(env: env, open_timeout: 5, read_timeout: 20)
      res = AgentApi.call(api, :get, "/api/v1/agent_dispatchers")
      next [ nil, "no answer from the board (no agent token, or unreachable)" ] unless res
      next [ nil, "the board answered HTTP #{res.code}" ] unless res.code.to_i == 200

      rows = JSON.parse(res.body.to_s)["data"]
      rows.is_a?(Array) ? [ rows, nil ] : [ nil, "the board's answer carried no rows" ]
    rescue StandardError => e
      [ nil, "the board read failed (#{e.class})" ]
    end
  end

  # One conductor: this host's dispatcher and launcher rows are live, and no OTHER
  # host's primary row is. A registered standby on another host is allowed.
  def board_verdict(rows, host:, now: Time.now)
    live = rows.select do |r|
      seen = Time.parse(r["last_seen_at"].to_s) rescue nil
      seen && now - seen <= LIVE_SECONDS && r["state"].to_s != "stopping"
    end
    launcher = ->(r) { Array(r["souls"]) == [ LAUNCHER_SOUL ] }
    mine = live.select { |r| r["host"].to_s == host }
    others = live.reject { |r| r["host"].to_s == host || r["role"].to_s == "standby" }
    missing = []
    missing << "no live dispatcher ping from #{host}" unless mine.any? { |r| !launcher.call(r) }
    missing << "no live launcher ping from #{host}" unless mine.any? { |r| launcher.call(r) }
    if others.any?
      hosts = others.map { |r| r["host"] }.uniq.join(", ")
      missing << "another host is still a live conductor: #{hosts}"
    end
    missing
  end

  class Checker
    def initialize(env: ENV, runner: ConductorHost.default_runner, board: nil, host: ConductorHost.host_name,
                   allow_admin_token: false, services: nil, now: Time.now)
      @env = env
      @layout = Layout.new(env)
      @runner = runner
      @board = board
      @host = host
      @allow_admin_token = allow_admin_token
      @services = services
      @now = now
    end

    attr_reader :layout

    def items
      [ power, filevault, power_cut_recovery, ethernet, directories, homebrew, hub, op_token, admin_token,
        agent_docs, agent_secret, claude, role, *service_items, harness_key, *board_items ]
    end

    private

    def item(key, label, ok, detail, fix = nil, secret = nil)
      Item.new(key: key, label: label, state: ok ? :done : :missing, detail: detail,
               fix: ok ? nil : fix, secret: ok ? nil : secret)
    end

    def run(*argv, chdir: nil) = @runner.call(argv, chdir)

    def power
      out, ok = run("pmset", "-g")
      return item(:power, "Energy settings (pmset)", false, "pmset did not answer", PMSET_COMMAND.join(" ")) unless ok

      have = out.to_s.lines.filter_map { |l| l.strip.split(/\s+/, 3).first(2) if l =~ /\A\s*\w+\s+\d+/ }.to_h
      wrong = PMSET.reject { |k, v| have[k] == v }.map { |k, v| "#{k}=#{have[k] || 'unset'} (want #{v})" }
      item(:power, "Energy settings (pmset)", wrong.empty?,
           wrong.empty? ? PMSET.map { |k, v| "#{k} #{v}" }.join(", ") : wrong.join(", "),
           PMSET_COMMAND.join(" "))
    end

    # Decision 2 in the runbook: A is FileVault on, B is FileVault off with
    # automatic login. Either is a finished host; only off-without-auto-login misses.
    def filevault
      out, = run("fdesetup", "status")
      on = out.to_s.include?("FileVault is On")
      login, auto = run("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser")
      auto &&= !login.to_s.strip.empty?
      item(:filevault, "FileVault", on || auto, on ? "on" : (auto ? "off (decision B: automatic login)" : "off or unreadable"),
           "System Settings > Privacy & Security > FileVault > Turn On (keep the recovery key in 1Password)")
    end

    # With FileVault on, macOS offers no automatic login: after a power cut the box
    # waits at the unlock screen and launchd agents start only once a person types
    # the password. So this item is done when either automatic login is set, or
    # FileVault is on and the person-unlocks path is the accepted one.
    def power_cut_recovery
      out, ok = run("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser")
      auto = ok && !out.to_s.strip.empty?
      fv = run("fdesetup", "status").first.to_s.include?("FileVault is On")
      detail = if auto then "automatic login as #{out.to_s.strip}"
               elsif fv then "FileVault on: after a power cut a person unlocks the box at the login screen"
               else "no automatic login and FileVault off"
               end
      item(:power_cut, "Power-cut recovery", auto || fv, detail,
           "Turn FileVault on (default), or turn it off and set System Settings > Users & Groups > Automatic login")
    end

    def ethernet
      route, = run("route", "-n", "get", "default")
      iface = route.to_s[/interface:\s*(\S+)/, 1]
      ports, = run("networksetup", "-listallhardwareports")
      port = ports.to_s.split(/\n\s*\n/).find { |b| b.include?("Device: #{iface}") } if iface
      name = port.to_s[/Hardware Port:\s*(.+)/, 1].to_s.strip
      wired = name.match?(/ethernet|thunderbolt bridge|usb.*lan/i)
      item(:ethernet, "Wired network", wired,
           iface ? "default route on #{iface} (#{name.empty? ? 'unknown port' : name})" : "no default route",
           "Plug in Ethernet and put it first: System Settings > Network > ... > Set Service Order")
    end

    def directories
      missing = @layout.directories.reject { |d| File.directory?(d) }
      item(:directories, "Directory layout", missing.empty?,
           missing.empty? ? "#{@layout.directories.size} present" : "missing #{missing.join(', ')}",
           "bin/conductor-host-setup   # creates them")
    end

    def homebrew
      ok = %w[/opt/homebrew/bin/brew /usr/local/bin/brew].any? { |p| File.executable?(p) } || which("brew")
      item(:homebrew, "Homebrew", ok, ok ? "installed" : "not installed", BREW_INSTALL)
    end

    def hub
      ok = File.directory?(File.join(@layout.hub, ".git")) || File.file?(File.join(@layout.hub, ".git"))
      item(:hub, "Hub checkout", ok, ok ? @layout.hub : "no checkout at #{@layout.hub}",
           "git clone #{HUB_URL} #{@layout.hub}")
    end

    def op_token
      ok = exported?(@layout.zprofile, "OP_SERVICE_ACCOUNT_TOKEN")
      item(:op_token, "1Password agent token", ok, ok ? "set in ~/.zprofile (value not read)" : "not in ~/.zprofile",
           "copy the token to the clipboard, then: cd #{@layout.hub} && bin/setup-1pass-token",
           ConductorHost.op_agent_token)
    end

    # The admin (deployer) token stays on Alex's laptop unless he says otherwise:
    # production deploys run from there, and this box should not be able to mint a
    # deployer credential.
    def admin_token
      held = exported?(@layout.zprofile_admin, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN")
      ok = !held || @allow_admin_token
      detail = if !held then "absent (it stays on Alex's laptop)"
               else "present#{@allow_admin_token ? ', allowed by --allow-admin-token' : ''}"
               end
      item(:admin_token, "No deployer token here", ok, detail,
           "remove the OP_ADMIN_SERVICE_ACCOUNT_TOKEN line from ~/.zprofile.admin, or pass --allow-admin-token " \
           "if Alex said it belongs here")
    end

    def agent_docs
      ok = File.file?(File.join(@layout.projects, "AGENTS.md")) && File.file?(File.join(@layout.projects, "CLAUDE.md"))
      item(:ecosystem_build, "bin/ecosystem-build finished", ok,
           ok ? "AGENTS.md and CLAUDE.md installed in #{@layout.projects}" : "no installed AGENTS.md/CLAUDE.md",
           "cd #{@layout.hub} && bin/ecosystem-build   # twice on a fresh box: the token step sits between")
    end

    def agent_secret
      ok = LocalServices::Restorer.default_dotenv.call(@layout.hub, "AGENT_API_SECRET")
      item(:agent_secret, "Board secret in the hub .env", ok,
           ok ? "AGENT_API_SECRET set (value not read)" : "AGENT_API_SECRET missing from #{@layout.hub}/.env",
           ConductorHost.agent_secret_fix(@layout.hub),
           ConductorHost.op_agent_secret)
    end

    def claude
      state, method = LocalServices::ClaudeSignIn.check(runner: ->(argv, _) { run(*argv) }, which: ->(c) { which(c) })
      detail = { ok: "signed in with claude.ai", missing: "not installed",
                 wrong: method ? "signed in with #{method}, not claude.ai" : "signed out" }.fetch(state)
      fix = state == :missing ? CLAUDE_INSTALL : "claude auth login   # Alex's claude.ai account, in a browser"
      item(:claude, "Claude Code", state == :ok, detail, fix)
    end

    def role
      to = LocalServices.handed_off_to(@layout.home)
      item(:role, "Conductor role kept here", to.nil?, to ? "handed off to #{to}" : "no hand-off marker",
           "bin/conductor-host-setup --take-over   # only once the other host's agents are uninstalled")
    end

    def service_items
      services.map do |s|
        out, ok = File.directory?(@layout.hub) ? run(*s.status.split, chdir: @layout.hub) : [ "no hub checkout", false ]
        line = out.to_s.lines.last.to_s.strip
        item(:"service_#{s.name}", "launchd: #{s.name}", ok, line.empty? ? (ok ? "running" : "not running") : line,
             "bin/conductor-host-setup --take-over   # after the laptop's copy is uninstalled")
      end
    end

    def services
      @services ||= LocalServices::Registry.load
    end

    # Where bin/harness-key keeps it (HarnessKey.projects_dir), which is not
    # always PROJECTS_DIR: read it from the same place the key is written.
    def harness_key
      dir = HarnessKey.projects_dir(@env)
      held = HarnessKey.token(dir, env: @env)
      pending = !held && HarnessKey.open_request(dir, now: @now, env: @env)
      detail = if held then "held (value not read)"
               elsif pending then "requested (#{pending['request']}); waiting on Alex's Approve tap"
               else "none"
               end
      fix = if pending
              "Alex: Approve `Harness key · #{@host}` on #{BOARD_TASKS}; then: bin/harness-key collect --wait 600"
            else
              "bin/harness-key request --label #{@host}   # then Alex approves; then bin/harness-key collect --wait 600"
            end
      item(:harness_key, "Harness key", !held.nil?, detail, fix)
    end

    def board_items
      return [] if @board.nil?

      rows, reason = @board.call
      if rows.nil?
        return [ item(:board, "The board sees this host", false, reason,
                      "check the hub .env secret and the network, then re-run --check") ]
      end
      missing = ConductorHost.board_verdict(rows, host: @host, now: @now)
      [ item(:board, "The board sees one conductor: #{@host}", missing.empty?,
             missing.empty? ? "dispatcher and launcher pinging from #{@host}; no other live conductor" : missing.join("; "),
             "uninstall the laptop's agents (runbook, Cutover), then wait a minute and re-run --check") ]
    end

    def exported?(path, key)
      return false unless File.file?(path) && File.readable?(path)

      File.foreach(path, encoding: "UTF-8").any? { |l| l.match?(/\A\s*export\s+#{key}=\S/) }
    end

    def which(cmd)
      @env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) }
    end
  end

  # Prints the items; returns the miss count.
  def report(items, out: $stdout)
    items.each do |i|
      out.puts format("  %-8s %-34s %s", i.done? ? "done" : "MISSING", i.label, i.detail)
      next if i.done?

      out.puts "           fix: #{i.fix}" if i.fix
      out.puts "           1Password: #{i.secret}" if i.secret
    end
    misses = items.count { |i| !i.done? }
    out.puts(misses.zero? ? "conductor host: all #{items.size} items done" : "conductor host: #{misses} of #{items.size} missing")
    misses
  end

  # The other half of a cutover, run on the Mac giving the role up (Alex's
  # laptop): uninstall both launchd agents, then leave the marker that keeps
  # bin/ecosystem-build's services phase from installing them again. Returns
  # true when both uninstalls answered 0.
  class HandOff
    UNINSTALLS = [ %w[bin/dispatcher uninstall], %w[bin/client-build-launcher uninstall] ].freeze

    def initialize(to:, env: ENV, runner: ConductorHost.default_runner, out: $stdout)
      @to = to
      @layout = Layout.new(env)
      @runner = runner
      @out = out
    end

    def run
      return false.tap { @out.puts("  no hub checkout at #{@layout.hub}") } unless File.directory?(@layout.hub)

      results = UNINSTALLS.map do |argv|
        out, ok = @runner.call(argv, @layout.hub)
        @out.puts("  #{argv.join(' ')}: #{ok ? 'done' : 'FAILED'}  #{out.to_s.lines.last.to_s.strip}")
        ok
      end
      marker = LocalServices.handoff_path(@layout.home)
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "#{@to}\n")
      @out.puts("  conductor role: handed to #{@to}; this Mac's bin/ecosystem-build will not reinstall the agents " \
                "(marker: ~/.config/mcritchie/#{LocalServices::HANDOFF_FILE})")
      @out.puts("  next, on #{@to}: bin/conductor-host-setup --take-over")
      results.all?
    end
  end

  # The idempotent steps, in order. Each prints one line. Returns false when a
  # step that later steps need could not be done (no Homebrew, no hub checkout).
  class Setup
    def initialize(checker:, env: ENV, runner: ConductorHost.default_runner, take_over: false, out: $stdout)
      @checker = checker
      @layout = checker.layout
      @env = env
      @runner = runner
      @take_over = take_over
      @out = out
    end

    def run
      state = @checker.items.to_h { |i| [ i.key, i ] }
      step_power(state.fetch(:power))
      step_directories
      return stop("Homebrew is not installed. Install it (it asks for this Mac's password), then re-run:\n  #{BREW_INSTALL}") unless state.fetch(:homebrew).done?
      return false unless step_hub(state.fetch(:hub))

      step_claude(state.fetch(:claude))
      step_services
      step_harness_key(state.fetch(:harness_key))
      true
    end

    private

    def say(msg) = @out.puts("  #{msg}")

    def stop(msg)
      @out.puts msg
      false
    end

    def step_power(item)
      return say("pmset: already set") if item.done?

      say("pmset: setting #{PMSET.map { |k, v| "#{k} #{v}" }.join(', ')} (sudo asks for this Mac's login password)")
      _, ok = @runner.call(PMSET_COMMAND, nil)
      say(ok ? "pmset: set" : "pmset: FAILED; run it yourself: #{PMSET_COMMAND.join(' ')}")
    end

    def step_directories
      @layout.directories.each { |d| FileUtils.mkdir_p(d) }
      say("directories: #{@layout.directories.size} present")
    end

    def step_hub(item)
      return true.tap { say("hub: #{@layout.hub}") } if item.done?

      FileUtils.mkdir_p(@layout.projects)
      say("hub: cloning #{HUB_URL}")
      _, ok = @runner.call([ "git", "clone", HUB_URL, @layout.hub ], nil)
      ok ? true : stop("git clone failed; clone it by hand: git clone #{HUB_URL} #{@layout.hub}")
    end

    def step_claude(item)
      return say("Claude Code: #{item.detail}") unless item.detail == "not installed"

      say("Claude Code: installing (#{CLAUDE_INSTALL})")
      _, ok = @runner.call([ "/bin/bash", "-c", CLAUDE_INSTALL ], nil)
      say(ok ? "Claude Code: installed; Alex signs it in: claude auth login" : "Claude Code: install FAILED; run: #{CLAUDE_INSTALL}")
    end

    # The two launchd agents, through the same restorer bin/ecosystem-build's
    # services phase runs, so the prerequisites (claude.ai sign-in, the .env
    # secret) are checked one way. Only with --take-over: two dispatchers split
    # the mailbox and two launchers release each other's runs.
    def step_services
      marker = LocalServices.handoff_path(@layout.home)
      unless @take_over
        # Until the cutover, keep bin/ecosystem-build's services phase from
        # installing a second dispatcher here: the same marker a laptop keeps
        # after it hands the role away. --take-over removes it.
        unless File.file?(marker) || services_running?
          FileUtils.mkdir_p(File.dirname(marker))
          File.write(marker, "#{PRE_CUTOVER}\n")
        end
        return say("launchd agents: not installed. Uninstall them on the laptop first (runbook, Cutover), " \
                   "then re-run with --take-over")
      end

      if File.file?(marker)
        File.delete(marker)
        say("conductor role: taken back (removed the hand-off marker)")
      end
      LocalServices::Restorer.new(services: LocalServices::Registry.load, hub: @layout.hub, out: @out).run
    end

    def services_running?
      LocalServices::Registry.load.any? do |svc|
        _, ok = @runner.call(svc.status.split, @layout.hub)
        ok
      end
    end

    def step_harness_key(item)
      return say("harness key: #{item.detail}") if item.done? || item.detail.start_with?("requested")
      return say("harness key: not requested yet; needs the board secret in the hub .env first") unless
        LocalServices::Restorer.default_dotenv.call(@layout.hub, "AGENT_API_SECRET")

      out, ok = @runner.call([ "bin/harness-key", "request", "--label", ConductorHost.host_name ], @layout.hub)
      say("harness key: #{out.to_s.lines.last.to_s.strip}")
      say("harness key: Alex approves `Harness key · #{ConductorHost.host_name}` on #{BOARD_TASKS}, then run: " \
          "bin/harness-key collect --wait 600") if ok
    end
  end
end
