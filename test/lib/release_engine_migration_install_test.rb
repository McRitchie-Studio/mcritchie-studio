require "minitest/autorun"
require "open3"
require "tmpdir"

# The engine-migration install, driven for real: the SHELL half of the step after a gem
# publish. Never read ANY non-zero exit from `bin/rails -T <task>` as "not an engine": on a
# live sweep `bundle lock` resolves without INSTALLING, rails dies with Bundler::GemNotFound,
# and the step skips silently while the pre-QA gate reddens after the irreversible publish. A
# FILE OF ITS OWN: release CLI files are frozen at their size by `config/test_health.yml`. Flow
# tests stub this function wholesale; here `sh` is stubbed, so the REAL function runs.
# History: task install-engine-migrations-in-sweep.
class ReleaseEngineMigrationInstallTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # Records every command `sh` is asked to run, and answers the two the install
  # cares about. Each test sets RAILS_PROBE_OK / RAILS_TASK_LISTED /
  # MIGRATE_DIR_CHANGED before this is evaluated.
  SH_RECORDING_STUB = <<~'RUBY'
    RAILS_PROBE_OK = true unless defined?(RAILS_PROBE_OK)
    RAILS_TASK_LISTED = true unless defined?(RAILS_TASK_LISTED)
    MIGRATE_DIR_CHANGED = false unless defined?(MIGRATE_DIR_CHANGED)

    def gate_env(_repo, role: "gate") = {}
    def gate_database_url(_repo, role: "gate") = nil
    def suite_bundle_argv(_path) = ["bin/bundle"]

    def sh(*a, **k)
      cmd = a.reject { |x| x.is_a?(Hash) }.join(" ")
      $stdout.puts("RAN: #{cmd}")
      return ["", true] if cmd.start_with?("bin/bundle")
      if cmd.include?("-T ")
        task = cmd.split.last
        return [RAILS_TASK_LISTED ? "bin/rails #{task}  # Copy migrations" : "", RAILS_PROBE_OK]
      end
      ["", true]
    end

    # The db/migrate listing is read twice — before the install and after — and
    # the step only refreshes the schema when the second differs from the first.
    def git_capture(*a)
      j = a.join(" ")
      if j.include?("status --porcelain") && j.include?("db/migrate")
        was = $migrate_probed
        $migrate_probed = true
        return [(was && MIGRATE_DIR_CHANGED ? "?? db/migrate/20260101_x.studio_engine.rb" : ""), true]
      end
      ["", true]
    end
  RUBY

  # Drive the REAL script with those seams set, then evaluate `call`.
  def run_release(setup, call)
    script = %(ARGV.replace(["--yes"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  # THE MISSING LINE, asserted as an ORDER. Without the bundle the app cannot boot
  # and every probe below is meaningless — which is exactly how this skipped on
  # every live sweep.
  def test_it_installs_the_bundle_before_it_probes
    Dir.mktmpdir do |ws|
      # ensure_suite_bundle! self-gates on a Gemfile, so a bare tmpdir would skip
      # the very step this test is about.
      File.write(File.join(ws, "Gemfile"), %(gem "studio-engine"\n))

      out = run_release(SH_RECORDING_STUB + %(RAILS_TASK_LISTED = false\n),
                        %{install_engine_migrations!(#{ws.inspect}, "mcritchie-studio", ["studio-engine"])})

      bundle_at = out.index("RAN: bin/bundle check")
      probe_at  = out.index("RAN: bin/rails -T studio_engine:install:migrations")
      refute_nil bundle_at, "the workspace bundle must be ensured: #{out}"
      refute_nil probe_at, "and then the app asked what it ships: #{out}"
      assert bundle_at < probe_at, "the bundle must be installed BEFORE the probe: #{out}"
    end
  end

  # A gem that is not an engine. Exit 0, nothing listed — the only silent skip
  # there is, and it must stay silent: most published gems are not engines.
  def test_it_skips_a_gem_that_ships_no_migrations
    out = run_release(SH_RECORDING_STUB + %(RAILS_TASK_LISTED = false\n),
                      %{install_engine_migrations!("/tmp/ws", "mcritchie-studio", ["solana-studio"]); puts("RETURNED")})

    assert_includes out, "RETURNED", "an absent task is a skip, not an abort: #{out}"
    refute_includes out, "RAN: bin/rails solana_studio:install:migrations",
                     "nothing to install means nothing was run"
  end

  # THE REGRESSION ITSELF. A non-zero probe means the app did not boot — and in a
  # function whose whole design is fail-closed, "I could not tell" must never read
  # as "nothing to do".
  def test_it_aborts_when_the_app_cannot_boot
    out = run_release(SH_RECORDING_STUB + %(RAILS_PROBE_OK = false\n),
                      %{install_engine_migrations!("/tmp/ws", "mcritchie-studio", ["studio-engine"]); puts("NO-ABORT")})

    assert_includes out, "ABORTED", "a probe nobody could answer must stop the sweep: #{out}"
    assert_includes out, "could not boot the app", "and say what actually happened"
    refute_includes out, "NO-ABORT", "it must never fall through as 'not an engine'"
  end

  # The happy path: the task is listed, so it runs — and the schema refresh
  # follows only because db/migrate actually changed. A copied-but-unrun migration
  # is PENDING, and Rails refuses to run a suite with one.
  def test_it_runs_the_installer_and_refreshes_the_schema
    out = run_release(SH_RECORDING_STUB + %(RAILS_TASK_LISTED = true\nMIGRATE_DIR_CHANGED = true\n),
                      %{install_engine_migrations!("/tmp/ws", "mcritchie-studio", ["studio-engine"])})

    assert_includes out, "RAN: bin/rails studio_engine:install:migrations",
                    "the installer must actually run: #{out}"
    assert_includes out, "installed 1 engine migration(s)", "and say what it installed"
    assert_includes out, "RAN: bin/rails db:create db:schema:load db:migrate",
                    "the schema is refreshed in the same pass"
  end
end
