# frozen_string_literal: true

# The production ship's post-ship refresh of the always-on local services
# (bin/release.rb#refresh_local_services): for every entry in the hub primary's
# config/local_services.yml that names a `refresh`, the primary's script with
# that refresh's arguments (`install --if-changed` for the agent dispatcher and
# the client build launcher), warn-only. Its own file because
# release_cli_post_deploy_test.rb is a frozen append hotspot.
#
# Part of the bin/release CLI suite; the shared subprocess harness lives in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_local_services_refresh_test.rb
#
# Every unit case stubs `sh`, so no service script runs. The two [integration]
# cases run this tree's REAL scripts against a throwaway HOME with a recording
# launchctl first on PATH; launchctl itself is never run.

require_relative "release_cli_harness"
require_relative "../../bin/lib/local_services"

class ReleaseCliLocalServicesRefreshTest < ReleaseCliHarness
  ROOT = File.expand_path("../..", __dir__)
  REGISTRY = File.join(ROOT, "config/local_services.yml")

  # A temp "primary" holding REGISTRY_TEXT as its config/local_services.yml and an
  # empty file for each named script, so a case proves WHICH script runs with
  # WHICH arguments.
  def stub_primary(registry_text, scripts:)
    <<~RUBY
      require "tmpdir"; require "fileutils"
      PRIMARY = Dir.mktmpdir("hub-primary")
      FileUtils.mkdir_p(File.join(PRIMARY, "bin"))
      FileUtils.mkdir_p(File.join(PRIMARY, "config"))
      File.write(File.join(PRIMARY, "config", "local_services.yml"), #{registry_text.inspect})
      #{scripts.inspect}.each { |s| File.write(File.join(PRIMARY, s), "") }
      def repo_path(repo) = repo == "mcritchie-studio" ? PRIMARY : "/no/such/" + repo
      $stdout.puts("PRIMARY " + PRIMARY)
    RUBY
  end

  def real_primary(scripts: real_scripts) = stub_primary(File.read(REGISTRY), scripts: scripts)

  def real_scripts = LocalServices::Registry.load.map { |s| Shellwords.split(s.refresh).first }

  RECORD_SH = <<~RUBY
    def sh(*a, **_k)
      $stdout.puts("SH-ARGV " + a.inspect)
      [File.basename(a.first) + ": not installed; nothing to refresh\\n", true]
    end
  RUBY

  def sh_argvs(out) = out.lines.grep(/^SH-ARGV /).map { |l| eval(l.delete_prefix("SH-ARGV ")) } # rubocop:disable Security/Eval

  def test_ship_dry_run_refreshes_the_services_after_the_docs_sync
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)

    sync_at    = out.index("sync installed agent docs")
    refresh_at = out.index("refresh the always-on local services")
    assert sync_at && refresh_at, "both post-ship steps must appear:\n#{out}"
    assert_operator sync_at, :<, refresh_at, "the refresh runs after the primaries are restored and the docs synced"
  end

  def test_the_real_registry_gives_every_service_an_if_changed_refresh
    services = LocalServices::Registry.load

    assert_equal %w[agent-dispatcher client-build-launcher], services.map(&:name)
    services.each do |s|
      assert_equal "#{Shellwords.split(s.install).first} install --if-changed", s.refresh,
                   "#{s.name}: the ship's refresh is its own install, only when the template changed"
    end
  end

  def test_the_refresh_walks_every_registered_service_in_order
    out = run_cli(["--yes"], setup: real_primary + RECORD_SH, call: "refresh_local_services")

    primary = out[/^PRIMARY (.+)$/, 1]
    expected = LocalServices::Registry.load.map do |s|
      argv = Shellwords.split(s.refresh)
      [ File.join(primary, argv.first), *argv.drop(1) ]
    end
    assert_equal expected, sh_argvs(out), "every registered service, the PRIMARY's script, in registry order"
    assert_includes sh_argvs(out), [ File.join(primary, "bin", "dispatcher"), "install", "--if-changed" ],
                    "the dispatcher's refresh is exactly what it was before the registry walk"
    assert_includes out, "client-build-launcher: not installed; nothing to refresh", "each script's own verdict reaches the operator"
    refute_includes out, "⚠"
  end

  def test_an_entry_without_a_refresh_is_named_and_skipped
    registry = <<~YAML
      services:
        - name: quiet
          sop: docs/x.md
          install: bin/quiet install
          status: bin/quiet status
        - name: loud
          sop: docs/x.md
          install: bin/loud install
          status: bin/loud status
          refresh: bin/loud install --if-changed
    YAML
    out = run_cli(["--yes"], setup: stub_primary(registry, scripts: %w[bin/quiet bin/loud]) + RECORD_SH,
                             call: "refresh_local_services")

    assert_includes out, "quiet: no refresh registered; nothing to do"
    assert_equal [ "loud" ], sh_argvs(out).map { |a| File.basename(a.first) }
  end

  def test_a_service_whose_script_is_missing_is_skipped_and_the_next_still_runs
    out = run_cli(["--yes"], setup: real_primary(scripts: real_scripts.drop(1)) + RECORD_SH, call: "refresh_local_services")

    assert_match(%r{agent-dispatcher: no /\S+/bin/dispatcher; nothing to refresh}, out)
    assert_equal [ "client-build-launcher" ], sh_argvs(out).map { |a| File.basename(a.first) }
  end

  def test_no_registry_in_the_primary_refreshes_nothing
    setup = <<~RUBY
      def repo_path(*) = "/no/such/primary"
      def sh(*a, **_k) = ($stdout.puts("SH-REACHED"); ["", true])
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_local_services")

    assert_includes out, "nothing to refresh"
    refute_includes out, "SH-REACHED"
  end

  def test_one_failed_refresh_warns_and_never_stops_the_next_or_the_ship
    setup = real_primary + <<~RUBY
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        a.first.end_with?("/dispatcher") ? ["launchctl bootstrap failed: 5", false] : ["current", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_local_services; puts('SHIP-CONTINUES')")

    assert_match(%r{⚠ agent-dispatcher refresh failed — run `/\S+/bin/dispatcher install` by hand}, out)
    assert_equal 2, sh_argvs(out).size, "the launcher's refresh still runs after the dispatcher's failed"
    assert_includes out, "SHIP-CONTINUES"
  end

  def test_a_raising_refresh_warns_per_service_and_the_ship_continues
    setup = real_primary + <<~RUBY
      def sh(*a, **_k) = a.first.end_with?("/client-build-launcher") ? raise("spawn exploded") : ["current", true]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_local_services; puts('SHIP-CONTINUES')")

    assert_match(%r{⚠ client-build-launcher refresh skipped \(spawn exploded\) — run `/\S+/bin/client-build-launcher install` by hand}, out)
    assert_includes out, "SHIP-CONTINUES"
  end

  def test_an_exception_before_the_walk_never_aborts_the_ship
    setup = <<~RUBY
      def repo_path(*) = raise("registry exploded")
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "refresh_local_services; puts('SHIP-CONTINUES')")

    assert_includes out, "local services refresh skipped (registry exploded) — run each service's install from the hub primary by hand"
    assert_includes out, "SHIP-CONTINUES"
  end

  def test_a_malformed_registry_warns_and_the_ship_continues
    out = run_cli(["--yes"], setup: stub_primary("services: nope\n", scripts: []) + RECORD_SH,
                             call: "refresh_local_services; puts('SHIP-CONTINUES')")

    assert_match(/⚠ local services refresh skipped \(.*no `services:` list\)/, out)
    refute_includes out, "SH-ARGV"
    assert_includes out, "SHIP-CONTINUES"
  end

  # [integration] The REAL bin/dispatcher and bin/client-build-launcher of this
  # tree, against a throwaway HOME and a recording launchctl first on PATH: a Mac
  # without the services gets nothing, and installed plists that match their
  # templates (rendered under a DIFFERENT ruby and PATH than the ship's) are left
  # alone. launchctl is never run.
  def real_refresh(installed_plists: nil)
    setup = <<~RUBY
      require "tmpdir"; require "fileutils"
      HOME_DIR = Dir.mktmpdir("services-home")
      SEAM = Dir.mktmpdir("launchctl-seam")
      File.write(File.join(SEAM, "launchctl"), ["#!/bin/sh", %q{echo "$@" >> } + SEAM + "/calls", "exit 1", ""].join("\\n"))
      File.chmod(0o755, File.join(SEAM, "launchctl"))
      ENV["HOME"] = HOME_DIR
      ENV["PATH"] = SEAM + ":" + ENV["PATH"]
      #{installed_plists || ''}
      def repo_path(*) = #{ROOT.inspect}
      at_exit { $stdout.puts("LAUNCHCTL-CALLS " + (File.exist?(File.join(SEAM, "calls")) ? File.read(File.join(SEAM, "calls")).inspect : "none")) }
    RUBY
    run_cli(["--yes"], setup: setup, call: "refresh_local_services")
  end

  def test_real_refresh_on_a_mac_without_the_services_installs_nothing
    out = real_refresh

    assert_includes out, "studio.mcritchie.agent-dispatcher: not installed; nothing to refresh"
    assert_includes out, "studio.mcritchie.client-build-launcher: not installed; nothing to refresh"
    assert_includes out, "LAUNCHCTL-CALLS none"
    refute_includes out, "⚠"
  end

  def test_real_refresh_leaves_current_plists_alone_across_environments
    plant = <<~RUBY
      require #{File.join(ROOT, 'bin/lib/agent_dispatcher').inspect}
      require #{File.join(ROOT, 'bin/lib/client_build_launcher').inspect}
      [AgentMailbox::LaunchAgent, ClientBuildLauncher::LaunchAgent].each do |klass|
        agent = klass.new(home: HOME_DIR, repo_root: #{ROOT.inspect},
                          ruby: "/installer/ruby/bin/ruby", path: "/installer/only/bin")
        FileUtils.mkdir_p(File.dirname(agent.plist_path))
        File.write(agent.plist_path, agent.render)
      end
    RUBY
    out = real_refresh(installed_plists: plant)

    assert_includes out, "studio.mcritchie.agent-dispatcher: installed plist matches the template; nothing to refresh"
    assert_includes out, "studio.mcritchie.client-build-launcher: installed plist matches the template; nothing to refresh"
    assert_includes out, "LAUNCHCTL-CALLS none", "a current plist is never reloaded"
    refute_includes out, "⚠"
  end
end
