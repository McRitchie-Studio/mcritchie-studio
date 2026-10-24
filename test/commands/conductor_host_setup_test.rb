# frozen_string_literal: true

# [unit] bin/conductor-host-setup end to end: the real script, spawned as a real
# process, against a FAKE HOME (HOME, PROJECTS_DIR and CLAUDE_PROJECTS_DIR all in a
# tmp dir) with stub macOS commands first on PATH. Nothing here can reach the
# operator's Mac: pmset, sudo, fdesetup, claude and the hub's bin/ scripts are all
# stubs that answer from fixtures and RECORD their argv, so "it did not install"
# is a receipt (no line in the record), not an absence of output.
#
# What it pins:
#   1. --check reads every item, prints done or MISSING, and exits 1 on a miss.
#   2. No secret is ever printed: the fake token and secret values are sentinels
#      that must never appear in the output, while the 1Password item names must.
#   3. --check writes nothing into the home it checks.
#   4. The apply run sets pmset with the runbook's exact command, makes the
#      directories, requests the harness key, and installs NO launchd agent
#      without --take-over (two dispatchers split the mailbox).
#
#   ruby -Itest test/commands/conductor_host_setup_test.rb

require "minitest/autorun"
require "open3"
require "json"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../../bin/lib/conductor_host"

class ConductorHostSetupTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "conductor-host-setup")
  TOKEN_SENTINEL = "ops_SENTINEL_never_printed_1234"
  SECRET_SENTINEL = "agent_secret_SENTINEL_5678"
  PMSET_DONE = " sleep                0\n displaysleep         10\n disksleep            0\n womp                 1\n autorestart          1\n"

  def setup
    @dir = Dir.mktmpdir("conductor-host")
    @home = File.join(@dir, "home")
    @projects = File.join(@home, "projects")
    @hub = File.join(@projects, "mcritchie-studio")
    @stubs = File.join(@dir, "stubs")
    @record = File.join(@dir, "record.log")
    FileUtils.mkdir_p([ @home, @stubs ])
    File.write(@record, "")
    stub("pmset", %(printf '%s' "$PMSET_OUT"))
    stub("fdesetup", 'echo "FileVault is On."')
    stub("defaults", "exit 1")
    stub("route", 'echo "   interface: en0"')
    stub("networksetup", %(printf 'Hardware Port: Ethernet\\nDevice: en0\\n\\nHardware Port: Wi-Fi\\nDevice: en1\\n'))
    stub("brew", "exit 0")
    stub("launchctl", "exit 0")
    stub("claude", %(echo '{"loggedIn":true,"authMethod":"claude.ai","email":"nobody@example.test"}'))
    stub("sudo", %(echo "sudo $*" >> "#{@record}"))
    stub("git", %(echo "git $*" >> "#{@record}"; exit 1))
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def stub(name, body, dir: @stubs)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  # A host that has had every step done.
  def build_done_host(pending_key: false, admin: false, services_running: true)
    FileUtils.mkdir_p(File.join(@hub, ".git"))
    FileUtils.mkdir_p(File.join(@hub, "bin"))
    ConductorHost::Layout.new("HOME" => @home, "PROJECTS_DIR" => @projects).directories.each { |d| FileUtils.mkdir_p(d) }
    File.write(File.join(@projects, "AGENTS.md"), "# map\n")
    File.write(File.join(@projects, "CLAUDE.md"), "# adapter\n")
    File.write(File.join(@home, ".zprofile"), "export PATH=/x\nexport OP_SERVICE_ACCOUNT_TOKEN=#{TOKEN_SENTINEL}\n")
    File.write(File.join(@home, ".zprofile.admin"), "export OP_ADMIN_SERVICE_ACCOUNT_TOKEN=#{TOKEN_SENTINEL}\n") if admin
    File.write(File.join(@hub, ".env"), "LOCAL_EMAIL_CAPTURE=1\nAGENT_API_SECRET=#{SECRET_SENTINEL}\n")
    # Each service stub answers `status` from a marker file and `install` records
    # itself and creates the marker, so an install is a receipt in the record.
    %w[dispatcher client-build-launcher].each do |svc|
      marker = File.join(@dir, "installed-#{svc}")
      FileUtils.touch(marker) if services_running
      stub(svc, <<~SH.chomp, dir: File.join(@hub, "bin"))
        echo "#{svc} $*" >> "#{@record}"
        if [ "$1" = install ]; then touch "#{marker}"; exit 0; fi
        if [ -f "#{marker}" ]; then echo "studio.mcritchie.#{svc}: running (pid 42)"; exit 0; fi
        echo "studio.mcritchie.#{svc}: not installed"; exit 3
      SH
    end
    stub("harness-key", %(echo "harness-key $*" >> "#{@record}"; echo "harness-key: posted login-abc"), dir: File.join(@hub, "bin"))
    key = if pending_key
            { "request" => "login-abc", "collect_key" => "ck", "ends_at" => (Time.now + 600).iso8601 }
          else
            { "token" => TOKEN_SENTINEL, "slug" => "sess-1" }
          end
    File.write(File.join(@projects, ".agents", "harness-key.json"), JSON.generate(key))
  end

  def run_cli(*args, pmset: PMSET_DONE)
    env = { "HOME" => @home, "PROJECTS_DIR" => @projects, "CLAUDE_PROJECTS_DIR" => @projects,
            "PATH" => "#{@stubs}:/usr/bin:/bin", "PMSET_OUT" => pmset, "TASK_USAGE_SANDBOX" => "1",
            "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }
    Open3.capture3(env, RbConfig.ruby, SCRIPT, *args, chdir: @dir, unsetenv_others: true)
  end

  def tree = Dir.glob("#{@home}/**/*", File::FNM_DOTMATCH).sort

  def recorded = File.read(@record)

  def assert_no_secret(text)
    refute_includes text, TOKEN_SENTINEL, "a token value reached the output"
    refute_includes text, SECRET_SENTINEL, "the board secret's value reached the output"
    refute_includes text, "nobody@example.test", "the Claude account's email reached the output"
  end

  def test_a_finished_host_checks_clean_and_exits_zero
    build_done_host
    out, err, status = run_cli("--check", "--no-board")

    assert_predicate status, :success?, "#{out}\n#{err}"
    refute_includes out, "MISSING"
    assert_match(/all 16 items done/, out)
    assert_match(/launchd: agent-dispatcher\s+studio\.mcritchie\.dispatcher: running/, out)
    assert_no_secret(out + err)
  end

  def test_a_fresh_home_names_every_miss_and_the_1password_items_without_a_value
    before = tree
    out, err, status = run_cli("--check", "--no-board",
                               pmset: " sleep 1 (sleep prevented by powerd)\n displaysleep 180\n disksleep 10\n womp 1\n")

    assert_equal 1, status.exitstatus, out
    %w[Energy Directory Hub 1Password\ agent\ token ecosystem-build Board\ secret Harness].each do |label|
      assert_match(/MISSING\s+.*#{label}/, out, "no MISSING line for #{label}")
    end
    assert_includes out, "sleep=1 (want 0)"
    assert_includes out, "autorestart=unset (want 1)"
    assert_includes out, "fix: sudo pmset -c sleep 0 displaysleep 10 disksleep 0 womp 1 autorestart 1"
    assert_includes out, "1Password: item `Agent API Secret` (field AGENT_API_SECRET)"
    assert_match(/1Password: a service account token with read on the \S+ vault/, out)
    assert_equal before, tree, "--check wrote into the home it checked"
    assert_no_secret(out + err)
  end

  def test_a_pending_harness_key_waits_on_alex
    build_done_host(pending_key: true)
    out, = run_cli("--check", "--no-board")

    assert_match(/MISSING\s+Harness key\s+requested \(login-abc\); waiting on Alex's Approve tap/, out)
    assert_includes out, "bin/harness-key collect --wait 600"
  end

  def test_the_deployer_token_is_a_miss_unless_alex_allowed_it
    build_done_host(admin: true)
    out, = run_cli("--check", "--no-board")
    allowed, = run_cli("--check", "--no-board", "--allow-admin-token")

    assert_match(/MISSING\s+No deployer token here/, out)
    assert_match(/done\s+No deployer token here\s+present, allowed by --allow-admin-token/, allowed)
    assert_no_secret(out + allowed)
  end

  def test_apply_sets_power_makes_directories_requests_the_key_and_installs_no_agent_without_take_over
    build_done_host(services_running: false)
    File.delete(File.join(@projects, ".agents", "harness-key.json"))
    FileUtils.rm_rf(File.join(@home, ".client-builds"))
    out, err, status = run_cli("--no-board", pmset: " sleep 1\n")

    assert_includes recorded, "sudo pmset -c sleep 0 displaysleep 10 disksleep 0 womp 1 autorestart 1"
    assert_path_exists File.join(@home, ".client-builds")
    assert_includes recorded, "harness-key request --label"
    refute_match(/^(dispatcher|client-build-launcher) install/, recorded, "a launchd agent was installed without --take-over")
    assert_includes out, "re-run with --take-over"
    assert_match(/MISSING\s+launchd: agent-dispatcher\s+studio\.mcritchie\.dispatcher: not installed/, out)
    assert_equal 1, status.exitstatus, "the stubbed pmset still reads unset, so the closing check must miss: #{out}#{err}"
    assert_no_secret(out + err)
  end

  # The control for the test above: the same host WITH --take-over installs both
  # agents through the services restorer, so the refute above watches a real seam.
  def test_take_over_installs_both_launchd_agents
    build_done_host(services_running: false)
    out, err, = run_cli("--no-board", "--take-over")

    assert_match(/^dispatcher install$/, recorded, out + err)
    assert_match(/^client-build-launcher install$/, recorded, out + err)
    assert_match(/done\s+launchd: client-build-launcher\s+studio\.mcritchie\.client-build-launcher: running/, out)
  end

  # The laptop half of the cutover: both uninstalls run from the hub, and the
  # marker keeps the services restorer from reinstalling them. The take-over on
  # the new host removes it.
  def test_hand_off_uninstalls_both_agents_and_leaves_the_marker_that_take_over_removes
    build_done_host
    out, err, status = run_cli("--hand-off-to", "conductor-mini")

    assert_predicate status, :success?, out + err
    assert_match(/^dispatcher uninstall$/, recorded)
    assert_match(/^client-build-launcher uninstall$/, recorded)
    marker = File.join(@projects, ".agents", "conductor-elsewhere")
    assert_equal "conductor-mini\n", File.read(marker)

    checked, = run_cli("--check", "--no-board")
    assert_match(/MISSING\s+Conductor role kept here\s+handed off to conductor-mini/, checked)

    run_cli("--no-board", "--take-over")
    refute_path_exists marker, "--take-over must take the role back"
  end

  def test_usage_refuses_and_help_writes_nothing
    before = tree
    _, err, status = run_cli("--check", "--take-over")
    assert_equal 2, status.exitstatus
    assert_includes err, "does not take --take-over"

    _, err, status = run_cli("--hand-off-to", "mini", "--take-over")
    assert_equal 2, status.exitstatus
    assert_includes err, "runs alone"

    _, err, status = run_cli("--bogus")
    assert_equal 2, status.exitstatus
    assert_includes err, "invalid option"

    out, _, status = run_cli("--help", "--take-over")
    assert_predicate status, :success?
    assert_includes out, "usage: bin/conductor-host-setup"
    assert_equal before, tree
    assert_empty recorded, "--help ran a command"
  end

  # --- the board verdict: one conductor -------------------------------------

  def row(host, souls: [ "avi" ], seen: 30, role: "primary", state: "live")
    { "host" => host, "souls" => souls, "last_seen_at" => (NOW - seen).iso8601, "role" => role, "state" => state }
  end

  NOW = Time.parse("2026-10-24T12:00:00Z")

  def verdict(rows) = ConductorHost.board_verdict(rows, host: "conductor-mini", now: NOW)

  def test_board_verdict_wants_both_pings_from_this_host_and_no_other_live_conductor
    mine = [ row("conductor-mini"), row("conductor-mini", souls: [ "client-build-launcher" ]) ]

    assert_empty verdict(mine)
    assert_equal [ "another host is still a live conductor: mac" ], verdict(mine + [ row("mac") ])
    assert_empty verdict(mine + [ row("mac", role: "standby") ]), "a registered standby is not a second conductor"
    assert_empty verdict(mine + [ row("mac", seen: 600) ]), "a silent laptop row is history, not a conductor"
    assert_empty verdict(mine + [ row("mac", state: "stopping") ]), "an uninstall's last ping says stopping"
    assert_equal [ "no live launcher ping from conductor-mini" ], verdict([ row("conductor-mini") ])
    assert_equal [ "no live dispatcher ping from conductor-mini", "no live launcher ping from conductor-mini" ],
                 verdict([ row("conductor-mini", seen: 900) ])
  end
end
