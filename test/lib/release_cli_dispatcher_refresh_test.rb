# frozen_string_literal: true

# The production ship's post-ship dispatcher refresh
# (bin/release.rb#refresh_dispatcher_service): the hub primary's
# `bin/dispatcher install --if-changed`, warn-only. Its own file because
# release_cli_post_deploy_test.rb is a frozen append hotspot.
#
# Part of the bin/release CLI suite; the shared subprocess harness lives in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_dispatcher_refresh_test.rb

require_relative "release_cli_harness"

class ReleaseCliDispatcherRefreshTest < ReleaseCliHarness
  # --- post-ship dispatcher refresh (bin/dispatcher install --if-changed) ----
  # After the primaries are restored and the docs synced, the ship re-renders the
  # agent dispatcher's launchd plist from the HUB PRIMARY, only when the service is
  # installed and its template changed. Warn-only: it never fails the ship.

  # A temp "primary" whose bin/dispatcher is an argv-echoing stub, so the case
  # proves WHICH script runs with WHICH arguments.
  STUB_PRIMARY = <<~RUBY
    require "tmpdir"; require "fileutils"
    PRIMARY = Dir.mktmpdir("hub-primary")
    FileUtils.mkdir_p(File.join(PRIMARY, "bin"))
    File.write(File.join(PRIMARY, "bin", "dispatcher"), "")
    def repo_path(repo) = repo == "mcritchie-studio" ? PRIMARY : "/no/such/" + repo
    $stdout.puts("PRIMARY " + PRIMARY)
  RUBY

  def test_ship_dry_run_refreshes_the_dispatcher_after_the_docs_sync
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)

    sync_at    = out.index("sync installed agent docs")
    refresh_at = out.index("refresh the agent dispatcher service")
    assert sync_at && refresh_at, "both post-ship steps must appear:\n#{out}"
    assert_operator sync_at, :<, refresh_at, "the refresh runs after the primaries are restored and the docs synced"
  end

  def test_refresh_dispatcher_runs_the_primary_dispatcher_install_if_changed
    setup = STUB_PRIMARY + <<~RUBY
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["studio.mcritchie.agent-dispatcher: not installed; nothing to refresh\n", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_dispatcher_service")

    primary = out[/^PRIMARY (.+)$/, 1]
    assert_includes out, %(SH-ARGV [#{File.join(primary, 'bin', 'dispatcher').inspect}, "install", "--if-changed"]),
                    "the PRIMARY's script, with --if-changed (never the ship workspace's or the tooling copy's)"
    assert_includes out, "not installed; nothing to refresh", "the script's own verdict reaches the operator"
    refute_includes out, "⚠"
  end

  def test_refresh_dispatcher_does_nothing_without_a_dispatcher_in_the_primary
    setup = <<~RUBY
      def repo_path(*) = "/no/such/primary"
      def sh(*a, **_k) = ($stdout.puts("SH-REACHED"); ["", true])
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_dispatcher_service")

    assert_includes out, "nothing to refresh"
    refute_includes out, "SH-REACHED"
  end

  def test_refresh_dispatcher_failure_never_aborts_the_ship
    setup = STUB_PRIMARY + <<~RUBY
      def sh(*_a, **_k) = ["launchctl bootstrap failed: 5", false]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_dispatcher_service; puts('SHIP-CONTINUES')")

    assert_match(%r{⚠ dispatcher refresh failed — run `/\S+/bin/dispatcher install` by hand}, out)
    assert_includes out, "SHIP-CONTINUES"
  end

  def test_refresh_dispatcher_exception_never_aborts_the_ship
    setup = <<~RUBY
      def repo_path(*) = raise("registry exploded")
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_dispatcher_service; puts('SHIP-CONTINUES')")

    assert_includes out, "dispatcher refresh skipped (registry exploded) — run `the hub primary's bin/dispatcher install`"
    assert_includes out, "SHIP-CONTINUES"
  end

  # [integration] The REAL bin/dispatcher of this tree, against a throwaway HOME
  # and a recording launchctl first on PATH: a Mac without the service gets
  # nothing, and an installed plist that matches the template (rendered under a
  # DIFFERENT ruby and PATH than the ship's) is left alone. launchctl is never run.
  def real_refresh(installed_plist: nil)
    root = File.expand_path("../..", __dir__)
    setup = <<~RUBY
      require "tmpdir"; require "fileutils"
      HOME_DIR = Dir.mktmpdir("dispatcher-home")
      SEAM = Dir.mktmpdir("launchctl-seam")
      File.write(File.join(SEAM, "launchctl"), ["#!/bin/sh", %q{echo "$@" >> } + SEAM + "/calls", "exit 1", ""].join("\n"))
      File.chmod(0o755, File.join(SEAM, "launchctl"))
      ENV["HOME"] = HOME_DIR
      ENV["PATH"] = SEAM + ":" + ENV["PATH"]
      #{installed_plist ? installed_plist : ''}
      def repo_path(*) = #{root.inspect}
      at_exit { $stdout.puts("LAUNCHCTL-CALLS " + (File.exist?(File.join(SEAM, "calls")) ? File.read(File.join(SEAM, "calls")).inspect : "none")) }
    RUBY
    run_cli(["--yes"], setup: setup, call: "refresh_dispatcher_service")
  end

  def test_real_refresh_on_a_mac_without_the_service_installs_nothing
    out = real_refresh

    assert_includes out, "studio.mcritchie.agent-dispatcher: not installed; nothing to refresh"
    assert_includes out, "LAUNCHCTL-CALLS none"
    refute_includes out, "⚠"
  end

  def test_real_refresh_leaves_a_current_plist_alone_across_environments
    root = File.expand_path("../..", __dir__)
    plant = <<~RUBY
      require #{File.join(root, 'bin/lib/agent_dispatcher').inspect}
      AGENT = AgentMailbox::LaunchAgent.new(home: HOME_DIR, repo_root: #{root.inspect},
                                            ruby: "/installer/ruby/bin/ruby", path: "/installer/only/bin")
      FileUtils.mkdir_p(File.dirname(AGENT.plist_path))
      File.write(AGENT.plist_path, AGENT.render)
    RUBY
    out = real_refresh(installed_plist: plant)

    assert_includes out, "installed plist matches the template; nothing to refresh"
    assert_includes out, "LAUNCHCTL-CALLS none", "a current plist is never reloaded"
    refute_includes out, "⚠"
  end
end
