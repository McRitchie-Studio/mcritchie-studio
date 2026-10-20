# frozen_string_literal: true

# [integration] `bin/ecosystem-build --phase services` on a simulated fresh Mac:
# a throwaway HOME with no ~/.claude and no LaunchAgents, a throwaway projects
# root holding a copy of the hub (bin/dispatcher refuses to install from a task
# desk under .worktrees/, so the hub is copied, not linked), and fake
# `launchctl` and `claude` first on PATH. The real script runs the real
# bin/local-services, which runs the real `bin/dispatcher install` and
# `bin/client-build-launcher install`; only the two binaries are stubs. The hub
# copy's .env holds a stand-in AGENT_API_SECRET unless a case removes it. Nothing
# here can reach the live services or the real
# ~/.claude/settings.json: HOME is the temp dir and every launchctl call lands
# in the fake's log (the precondition below refuses to run otherwise).
require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class EcosystemBuildServicesPhaseTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/ecosystem-build")
  LABEL = "studio.mcritchie.agent-dispatcher"
  LAUNCHER_LABEL = "studio.mcritchie.client-build-launcher"
  # The directories bin/ecosystem-build puts AHEAD of the caller's PATH (its
  # `export PATH=` line). A real launchctl or claude in one of them would win
  # over the fakes, so the test refuses to run rather than risk the live service.
  PREPENDED = %w[/opt/homebrew/opt/ruby@3.3/bin /opt/homebrew/lib/ruby/gems/3.3.0/bin /opt/homebrew/bin].freeze

  FAKE_LAUNCHCTL = <<~'SH'
    #!/bin/bash
    # Records every call; bootstrap loads the label, bootout unloads it, print
    # answers only while that label is loaded (as launchctl does).
    state="${FAKE_LAUNCHCTL_STATE:?}"
    echo "$*" >> "$state.log"
    case "$1" in
      bootstrap) touch "$state.$(basename "$3" .plist).loaded" ;;
      bootout) rm -f "$state.${2##*/}.loaded" ;;
      print)
        if [ -f "$state.${2##*/}.loaded" ]; then printf 'state = running\n\tpid = 4242\n'; else echo "Could not find service" >&2; exit 113; fi ;;
    esac
    exit 0
  SH

  FAKE_CLAUDE = <<~'SH'
    #!/bin/bash
    echo "$*" >> "${FAKE_CLAUDE_LOG:?}"
    if [ "$1 $2" = "auth status" ]; then
      if [ "${FAKE_CLAUDE_SIGNED_IN:-}" = 1 ]; then
        echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com"}'
      else
        echo '{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}'
        exit 1
      fi
      exit 0
    fi
    echo "fake claude: refusing $*" >&2
    exit 64
  SH

  def setup
    PREPENDED.each do |dir|
      %w[launchctl claude].each do |bin|
        # A hard refusal, not a skip: a skip would hide the lost coverage.
        flunk "#{dir}/#{bin} would shadow the fake; refusing to run" if File.exist?(File.join(dir, bin))
      end
    end

    # realpath: macOS hands out /var/folders, which bin/dispatcher sees as /private/var.
    @tmp = File.realpath(Dir.mktmpdir("ecosystem-services"))
    @home = File.join(@tmp, "home")
    @projects = File.join(@tmp, "projects")
    @hub = File.join(@projects, "mcritchie-studio")
    @fakebin = File.join(@tmp, "fakebin")
    @state = File.join(@tmp, "launchctl")
    [ @home, @hub, @fakebin ].each { |d| FileUtils.mkdir_p(d) }
    %w[bin config lib].each { |d| FileUtils.cp_r(File.join(ROOT, d), @hub) }
    write_exe("launchctl", FAKE_LAUNCHCTL)
    write_exe("claude", FAKE_CLAUDE)
    File.write(File.join(@hub, ".env"), "AGENT_API_SECRET=stand-in-not-a-secret\n")
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def test_a_fresh_mac_gets_the_dispatcher_plist_rendered_loaded_and_the_allow_rules
    out = build(signed_in: true)

    plist = File.join(@home, "Library/LaunchAgents/#{LABEL}.plist")
    assert File.exist?(plist), "the dispatcher plist is rendered into the fresh HOME\n#{out}"
    xml = File.read(plist)
    assert_includes xml, "<string>#{@hub}/bin/dispatcher</string>", "rendered from the hub's primary checkout"
    assert_includes xml, "<string>#{@home}</string>"
    refute_match(/\{\{[A-Z_]+\}\}/, xml, "every placeholder filled")

    calls = launchctl_calls
    assert_includes calls, "bootstrap gui/#{Process.uid} #{plist}", "loaded through launchctl"
    assert_includes out, "agent-dispatcher  installed and running"

    launcher = File.join(@home, "Library/LaunchAgents/#{LAUNCHER_LABEL}.plist")
    assert File.exist?(launcher), "the client build launcher is restored beside the dispatcher\n#{out}"
    assert_includes File.read(launcher), "<string>#{@hub}/bin/client-build-launcher</string>"
    assert_includes calls, "bootstrap gui/#{Process.uid} #{launcher}"
    assert_includes out, "client-build-launcher  installed and running"

    settings = JSON.parse(File.read(File.join(@home, ".claude/settings.json")))
    allow = settings.dig("permissions", "allow")
    assert_includes allow, "Bash(bin/dispatcher status)"
    assert_includes allow, "Bash(#{@hub}/bin/dispatcher install)", "the absolute rules name THIS projects root"

    refute_includes out, "someone@example.com", "the sign-in check prints no account detail"
    assert_equal "═══ What only you can do ═══", checklist(out).first, "the checklist is the last output"
    refute(checklist(out).any? { |l| l.include?("claude auth login") }, "signed in: no sign-in step owed")
  end

  def test_re_running_is_safe_and_restarts_nothing
    build(signed_in: true)
    File.write("#{@state}.log", "")
    settings_path = File.join(@home, ".claude/settings.json")
    before = File.read(settings_path)
    out = build(signed_in: true)

    assert_equal [ "print gui/#{Process.uid}/#{LABEL}", "print gui/#{Process.uid}/#{LAUNCHER_LABEL}" ], launchctl_calls,
                 "status only: no bootout, no bootstrap"
    assert_includes out, "agent-dispatcher  running"
    assert_includes out, "client-build-launcher  running"
    assert_equal before, File.read(settings_path), "no duplicate rules, no rewrite"
  end

  def test_signed_out_claude_skips_the_dispatcher_and_puts_the_sign_in_on_the_checklist
    out = build(signed_in: false)

    refute File.exist?(File.join(@home, "Library/LaunchAgents/#{LABEL}.plist")), "a skipped service is not installed"
    assert_empty launchctl_calls
    assert_equal [ "auth status" ], File.readlines(File.join(@tmp, "claude.log"), chomp: true),
                 "the build only asks; it never logs in"

    items = checklist(out)
    login = items.index { |l| l.include?("claude auth login") }
    refute_nil login, "the checklist owes the claude.ai sign-in\n#{out}"
    assert_includes items[login], "bin/ecosystem-build --phase services"
    assert_match(/\A  1\. Sign Claude Code in with your claude\.ai account/, items[login - 1],
                 "the sign-in is numbered first: nothing ranks ahead of it here")
  end

  def test_no_board_secret_in_the_hub_env_skips_both_services_and_owes_it_once
    File.delete(File.join(@hub, ".env"))
    out = build(signed_in: true)

    assert_empty launchctl_calls, "no service is installed that could not reach the board"
    assert_includes out, "agent-dispatcher skipped  needs AGENT_API_SECRET"
    assert_includes out, "client-build-launcher skipped  needs AGENT_API_SECRET"
    owed = checklist(out).select { |l| l.include?("Put AGENT_API_SECRET in #{@hub}/.env") }
    assert_equal 1, owed.size, "one step for both services\n#{out}"
  end

  def test_help_installs_no_service_and_writes_no_settings
    out, status = Open3.capture2e(env(signed_in: true), "bash", SCRIPT, "--phase", "services", "--help",
                                  chdir: @tmp, unsetenv_others: true)

    assert status.success?
    assert_includes out, "--phase services"
    assert_empty launchctl_calls
    refute File.exist?(File.join(@home, ".claude")), "--help writes no settings"
  end

  private

  def write_exe(name, body)
    path = File.join(@fakebin, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def build(signed_in:)
    out, status = Open3.capture2e(env(signed_in: signed_in), "bash", SCRIPT, "--phase", "services",
                                  chdir: @tmp, unsetenv_others: true)
    assert status.success?, "the services phase never fails the build\n#{out}"
    out
  end

  def env(signed_in:)
    {
      "HOME" => @home, "PROJECTS_DIR" => @projects, "TMPDIR" => @tmp,
      "PATH" => [ @fakebin, RbConfig::CONFIG["bindir"], "/usr/bin", "/bin" ].join(":"),
      "FAKE_LAUNCHCTL_STATE" => @state, "FAKE_CLAUDE_LOG" => File.join(@tmp, "claude.log"),
      "FAKE_CLAUDE_SIGNED_IN" => signed_in ? "1" : "0"
    }
  end

  def launchctl_calls
    path = "#{@state}.log"
    File.exist?(path) ? File.readlines(path, chomp: true).reject(&:empty?) : []
  end

  # The lines from the checklist heading to the end: it must be the last block.
  def checklist(out)
    lines = out.lines.map(&:rstrip)
    head = lines.rindex("═══ What only you can do ═══")
    assert head, "no checklist in:\n#{out}"
    lines[head..].reject(&:empty?)
  end
end
