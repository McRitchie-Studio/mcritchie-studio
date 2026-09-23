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
require_relative "../../bin/lib/toolchain_env"

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

  # stdout and stderr are kept APART on purpose. The `--json` contract is about
  # STDOUT; when this suite runs under `bin/rails test` the child ruby inherits
  # RUBYOPT=-rbundler/setup and prints a dozen "already initialized constant
  # Gem::Platform::JAVA" warnings to STDERR, which a combined capture would fold
  # into the output and read as a broken machine contract.
  def run_cli(root, *flags, env: {})
    out, err, status = Open3.capture3(env, RbConfig.ruby, CLI, "--root=#{root}", *flags)
    assert status.success?, "bin/clean-artifacts failed:\n#{out}\n#{err}"
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

  # The audit boots each app in a RESTORED environment — the one it would have
  # had before any toolchain manager touched it. If the hub's bundler leaked
  # through, every shim here reports the poisoned 100 MB cap and a perfectly
  # healthy app would be named as missing rotation.
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

  # [integration] THE CLOSING REPORT, through the real process. The table rows
  # above are one thing; what a reader and bin/release archive actually act on is
  # the verdict at the bottom, and an app that could not be booted has to reach
  # it as its OWN named category. An assertion that only checked the three capped
  # apps would pass against the version that ended a loose machine in silence.
  def test_the_closing_report_names_the_loose_app_and_the_unprovable_one
    with_apps do |root|
      out, summary = run_cli(root, "--dry-run")

      assert_equal "uncapped", summary[:rotation_verdict],
                   "the verdict must be computed, not inferred from an empty list"
      assert_includes out, "MISSING LOG ROTATION: default-app, unrotated-app"
      assert_includes out, "LOG CAP NOT PROVEN for dormant-app",
                      "the unprovable app must still reach the closing report as its OWN named category"
      # AND IT MUST SAY WHY. The seam used to name the app and stop, which is how
      # a contaminated audit — one that booted every app under the wrong Ruby and
      # called the result UNKNOWN — was indistinguishable from a dormant checkout
      # with uninstalled gems. Naming the app without the reason is the state this
      # assertion exists to red.
      assert_includes out, "could not boot it: simulated boot failure: Could not find rails-4.1.6",
                      "the closing report names the unprovable app but not the REASON it could not boot"
      refute_includes out, "every audited app caps its local logs",
                      "a machine with two loose apps must never claim a clean audit"
    end
  end

  # [integration] THE ABLATION: the audit's verdict must be a fact about the
  # APPS, not about the parent that launched the sweep.
  #
  # This reproduces the production bug in miniature. bin/release execs the
  # release runner as `mise x ruby@<version> -- ruby bin/release.rb`, whose ONLY
  # environment change is prepending mise's Ruby bin dir to PATH. Each audited
  # app's `bin/rails` then resolved `ruby` through that PATH to an interpreter
  # whose gem tree is not the app's, and the boot died at config/boot.rb:3.
  # Measured 2026-09-22 on this machine: moms-app and rolio read LOOSE from a
  # clean shell and UNKNOWN under `mise x`, hiding four genuinely loose apps
  # behind the one that stayed visible — and under a `bundle exec` parent an app
  # measured healthy at a 16 MB cap read UNKNOWN too. A contaminated UNKNOWN says
  # nothing in EITHER direction, which is what makes it worse than a wrong answer.
  #
  # BOTH ARMS RUN HERE, and the first is what makes the second mean anything: a
  # green "the verdicts agree" proves nothing unless the contamination it claims
  # to survive is shown to reach the verdict when it is NOT restored.
  def test_the_audit_verdict_does_not_depend_on_the_parents_path
    with_apps do |root|
      _, clean = run_cli(root, "--dry-run")
      assert_equal "uncapped", clean[:rotation_verdict], "the clean baseline moved; the arms below compare to it"

      Dir.mktmpdir("decoy-bin") do |fake_bin|
        decoy = File.join(fake_bin, "ruby")
        File.write(decoy, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, decoy)
        poisoned = "#{fake_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"

        # BOTH ARMS RUN FROM A PARENT SHAPED LIKE THE RELEASE RUNNER'S: no bundler
        # binding at all, exactly as `mise x ruby@<version> -- ruby bin/release.rb`
        # leaves it (measured: RUBYOPT, GEM_HOME, GEM_PATH and BUNDLE_GEMFILE are
        # all empty there). Two things forced this, and both are worth knowing:
        #
        #   * this suite runs under bundler, so BUNDLER_ORIG_PATH is inherited and
        #     restores the decoy away on its own — arm 1 came back `uncapped`
        #     until the records were cleared, which is the fix working through its
        #     OTHER path and an ablation measuring nothing.
        #   * clearing only the records is not enough. RUBYOPT=-rbundler/setup is
        #     also inherited, so bundler loads inside the spawned CLI and RE-WRITES
        #     BUNDLER_ORIG_* from the already-bundled environment it finds — the
        #     restoration then faithfully restores a binding that came from the
        #     grandparent. Leaving RUBYOPT set while deleting its record builds a
        #     parent that cannot occur in life, and it reads as a leak.
        mise_like = (%w[RUBYOPT RUBYLIB BUNDLER_SETUP BUNDLER_VERSION BUNDLE_GEMFILE BUNDLE_BIN_PATH] +
                     ENV.keys.select { |key| key.start_with?(ToolchainEnv::BUNDLER_PREFIX) })
                    .to_h { |key| [key, nil] }
                    .merge(ToolchainEnv::MISE_ORIG_PATH => nil)

        # ARM 1 — contaminated, with NO record to restore from. Each shim's
        # `#!/usr/bin/env ruby` resolves the decoy, so no app boots. If this arm
        # ever goes green, arm 2 is self-certifying and must not be believed.
        _, unrestored = run_cli(root, "--dry-run", env: mise_like.merge("PATH" => poisoned))
        assert_equal "unproven", unrestored[:rotation_verdict],
                     "the decoy PATH never reached the audit child, so arm 2 proves nothing"
        assert_empty Array(unrestored[:rotation_missing]),
                     "THE HARM: a contaminated parent hides loose apps inside UNKNOWN rather than naming them"

        # ARM 2 — the same contaminated PATH, plus mise's own record of what it
        # replaced. The restoration must put every verdict back exactly where the
        # clean parent had it.
        _, restored = run_cli(root, "--dry-run",
                              env: mise_like.merge("PATH" => poisoned,
                                                    ToolchainEnv::MISE_ORIG_PATH => ENV.fetch("PATH")))

        assert_equal clean[:rotation_verdict], restored[:rotation_verdict],
                     "the restored run reached a different verdict than the clean parent"
        assert_equal clean[:rotation_missing], restored[:rotation_missing],
                     "the restored run did not name the same loose apps as the clean parent"
        assert_equal clean[:rotation_unknown], restored[:rotation_unknown],
                     "the restored run did not name the same unprovable apps as the clean parent"
      end
    end
  end

  # An audit that did not run must not print what a capped machine prints. This
  # is the exact conflation the verdict exists for: --skip-audit emits the same
  # empty rotation_missing a fully capped machine does.
  def test_a_skipped_audit_says_so_rather_than_going_quiet
    with_apps do |root|
      out, summary = run_cli(root, "--dry-run", "--skip-audit")

      assert_equal "unaudited", summary[:rotation_verdict]
      assert_includes out, "LOG CAP NOT PROVEN"
      assert_includes out, "did not run"
      refute_includes out, "every audited app caps its local logs"
    end
  end

  def test_a_machine_where_every_app_is_capped_says_so_affirmatively
    Dir.mktmpdir("clean-artifacts-capped") do |root|
      make_app(root, "capped-app", cap: 16 * MB)
      make_app(root, "also-capped", cap: 8 * MB)

      out, summary = run_cli(root, "--dry-run")

      assert_equal "capped", summary[:rotation_verdict]
      assert_includes out, "every audited app caps its local logs (development)"
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
      %i[reclaimed_bytes reclaimed_human repos worktrees rotation_missing rotation_unknown
         rotation_verdict].each do |key|
        assert summary.key?(key), "the archive summary needs #{key}"
      end
    end
  end

  def test_json_flag_prints_only_the_summary
    with_apps do |root|
      out, = run_cli(root, "--dry-run", "--skip-audit", "--json")

      assert_equal 1, out.lines.count { |l| l.include?(ArtifactSweep::SUMMARY_TAG) }
      assert_equal 1, out.lines.reject { |l| l.strip.empty? }.size,
                   "--json is for machines: stdout is one line and nothing else"
    end
  end
end
