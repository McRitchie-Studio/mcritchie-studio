# frozen_string_literal: true

# [integration] tests for bin/clean-artifacts — the real CLI, spawned as a real
# process, against a fake projects root on real disk.
#
# This crosses the boundaries the unit tests deliberately do not: process spawn,
# the child environment handed to each app, and the tagged JSON summary that
# `bin/release archive` parses. The apps here are shims rather than Rails apps
# (a Rails boot per case would make this suite unrunnable), so the "a real Rails
# app gets the cap" half lives in studio-engine's own
# test/integration/log_rotation_test.rb, which boots real apps.
# Run directly:
#   ruby -Itest test/lib/clean_artifacts_cli_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require_relative "../../bin/lib/artifact_sweep"

class CleanArtifactsCliTest < Minitest::Test
  MB = 1024 * 1024
  CLI = File.expand_path("../../bin/clean-artifacts", __dir__)

  # A fake managed Rails app: config/environments makes it discoverable, and
  # bin/rails is a shim that reports whatever logger we want it to have.
  #
  # The shim reports a POISONED 100 MB cap if the parent's bundler environment
  # leaked into it. That is not decoration: bin/clean-artifacts runs under the
  # hub's bundler, and leaking BUNDLE_GEMFILE/RUBYOPT into another app's boot
  # loads the wrong gems — which would surface as a bogus "missing rotation"
  # verdict against a perfectly healthy app.
  def make_app(root, name, cap:, shift_age: 1, boots: true)
    repo = File.join(root, name)
    FileUtils.mkdir_p(File.join(repo, "config", "environments"))
    FileUtils.mkdir_p(File.join(repo, "bin"))

    rails = File.join(repo, "bin", "rails")
    File.write(rails, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      abort("simulated boot failure: Could not find rails-4.1.6 in locally installed gems") unless #{boots}
      leaked = ENV["BUNDLE_GEMFILE"] || ENV["RUBYOPT"] || ENV["RUBYLIB"]
      payload = leaked ? { cap: #{ArtifactSweep::RAILS_DEFAULT_CAP}, shift_age: 1, leaked: true }
                       : { cap: #{cap.inspect}, shift_age: #{shift_age} }
      puts "some boot chatter"
      puts "STUDIO_LOG_AUDIT " + payload.to_json
    RUBY
    FileUtils.chmod(0o755, rails)
    repo
  end

  def write(path, bytes)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x" * bytes)
    path
  end

  def run_cli(root, *flags, env: {})
    out, status = Open3.capture2e(env, RbConfig.ruby, CLI, "--root=#{root}", *flags)
    assert status.success?, "bin/clean-artifacts failed:\n#{out}"
    [out, ArtifactSweep.parse_summary(out)]
  end

  def with_apps
    Dir.mktmpdir("clean-artifacts-root") do |root|
      make_app(root, "capped-app", cap: 16 * MB)
      make_app(root, "default-app", cap: ArtifactSweep::RAILS_DEFAULT_CAP)
      make_app(root, "unrotated-app", cap: nil, shift_age: 0)
      make_app(root, "dormant-app", cap: nil, boots: false)
      yield root
    end
  end

  # --- the sweep -----------------------------------------------------------

  def test_dry_run_reports_the_bytes_and_changes_nothing
    with_apps do |root|
      live = write(File.join(root, "capped-app", "log", "development.log"), 2 * MB)
      worktree_log = write(File.join(root, "capped-app", ".worktrees", "desk", "log", "test.log"), 3 * MB)

      _out, summary = run_cli(root, "--dry-run", "--skip-audit")

      assert_equal 5 * MB, summary[:reclaimed_bytes]
      assert_equal 2 * MB, File.size(live), "a dry run must not touch a byte"
      assert_equal 3 * MB, File.size(worktree_log)
      assert summary[:dry_run]
    end
  end

  def test_the_real_sweep_reclaims_primaries_and_worktrees_alike
    with_apps do |root|
      live = write(File.join(root, "capped-app", "log", "development.log"), 2 * MB)
      rotated = write(File.join(root, "capped-app", "log", "development.log.0"), 4 * MB)
      worktree_log = write(File.join(root, "capped-app", ".worktrees", "desk", "log", "test.log"), 3 * MB)
      keep = write(File.join(root, "capped-app", "tmp", "pids", "server.pid"), 12)

      _out, summary = run_cli(root, "--skip-audit")

      assert_equal 9 * MB, summary[:reclaimed_bytes]
      assert_equal 0, File.size(live)
      assert_equal 0, File.size(worktree_log), "the worktree's log is the volume this sweep exists for"
      refute File.exist?(rotated)
      assert File.exist?(keep), "tmp/pids is never a sweep target"
      assert_equal 1, summary[:worktrees]
      refute summary[:dry_run]
    end
  end

  def test_a_new_app_needs_no_edit_to_be_swept
    with_apps do |root|
      make_app(root, "zzz-brand-new", cap: 16 * MB)
      write(File.join(root, "zzz-brand-new", "log", "development.log"), 1 * MB)

      _out, summary = run_cli(root, "--dry-run", "--skip-audit")

      assert_equal 1 * MB, summary[:reclaimed_bytes]
      assert_equal 5, summary[:repos]
    end
  end

  # --- the self-healing audit ----------------------------------------------

  def test_the_audit_names_every_app_without_a_real_cap
    with_apps do |root|
      out, summary = run_cli(root, "--dry-run")

      assert_equal %w[default-app unrotated-app], summary[:rotation_missing]
      assert_equal %w[dormant-app], summary[:rotation_unknown]
      refute_includes summary[:rotation_missing], "capped-app", "an app on the engine cap is healthy"
      assert_includes out, "Rails' own default"
      assert_includes out, "no rotation at all"
    end
  end

  def test_an_app_that_cannot_boot_is_inconclusive_never_a_pass_or_a_failure
    with_apps do |root|
      out, summary = run_cli(root, "--dry-run")

      refute_includes summary[:rotation_missing], "dormant-app",
                      "a repo that will not boot must NOT be reported as missing rotation"
      assert_includes summary[:rotation_unknown], "dormant-app"
      assert_includes out, "Could not find rails-4.1.6", "say WHY it was inconclusive"
    end
  end

  # The audit boots each app in a scrubbed environment. If the hub's bundler
  # leaked through, every shim here reports the poisoned 100 MB cap and a
  # perfectly healthy app would be named as missing rotation.
  def test_the_audit_does_not_leak_this_process_bundler_into_the_apps
    with_apps do |root|
      # A realistic parent environment: bin/release runs under the hub's bundler,
      # so BUNDLE_GEMFILE points at a REAL Gemfile and RUBYOPT is set. (A bogus
      # Gemfile would just kill this CLI, proving nothing about the children.)
      out, summary = run_cli(root, "--dry-run", env: {
        "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
        "RUBYOPT" => "-W0"
      })

      refute_includes out, "leaked", "the child app saw this process's bundler environment"
      refute_includes summary[:rotation_missing], "capped-app",
                      "a healthy app was mis-reported because the bundler env leaked into its boot"
    end
  end

  def test_skip_audit_boots_nothing
    with_apps do |root|
      _out, summary = run_cli(root, "--dry-run", "--skip-audit")

      assert_empty summary[:audited_envs]
      assert_empty summary[:rotation_missing]
    end
  end

  def test_audit_envs_flag_widens_the_audit
    with_apps do |root|
      _out, summary = run_cli(root, "--dry-run", "--audit-envs=development,test")

      assert_equal %w[development test], summary[:audited_envs]
    end
  end

  # --- the contract bin/release archive depends on -------------------------

  def test_the_summary_line_is_machine_readable_for_the_archive_step
    with_apps do |root|
      write(File.join(root, "capped-app", "log", "development.log"), 1 * MB)
      out, = run_cli(root, "--dry-run", "--skip-audit")

      summary = ArtifactSweep.parse_summary(out)
      refute_nil summary, "bin/release archive parses this line for its Exit Seam report"
      %i[reclaimed_bytes reclaimed_human repos worktrees rotation_missing rotation_unknown].each do |key|
        assert summary.key?(key), "the archive summary needs #{key}"
      end
    end
  end

  def test_json_flag_prints_only_the_summary
    with_apps do |root|
      out, = run_cli(root, "--dry-run", "--skip-audit", "--json")

      assert_equal 1, out.lines.count { |l| l.include?(ArtifactSweep::SUMMARY_TAG) }
      assert_equal 1, out.lines.reject { |l| l.strip.empty? }.size, "--json is for machines: one line"
    end
  end
end
