require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

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
    assert_includes out, "RAN: bin/rails db:create db:schema:load",
                    "the schema is refreshed in the same pass: #{out}"
    assert_includes out, "RAN: bin/rails db:migrate\n", "and the engine migration runs as its own stage: #{out}"
  end

  # A re-printed check constraint, through the REAL dump function. The psql verdict
  # is stubbed; the model test proves what Postgres answers. Here: psql is asked of
  # the throwaway database, and a SQLite app gets no callable at all.
  OLD_CHECK = %(    t.check_constraint "role::text = ANY (ARRAY['viewer'::character varying, 'admin'::character varying]::text[])", name: "users_role_known"\n)
  NEW_CHECK = %(    t.check_constraint "role::text = ANY (ARRAY['viewer'::character varying::text, 'admin'::character varying::text])", name: "users_role_known"\n)

  def dump_stub(url)
    schema = ->(check) { %(  create_table "users", force: :cascade do |t|\n#{check}  end\n) }
    <<~RUBY
      def gate_env(_repo, role: "gate") = {}
      def gate_database_url(_repo, role: "gate") = #{url.inspect}
      def sh(*a, **k)
        cmd = a.reject { |x| x.is_a?(Hash) }.join(" ")
        $stdout.puts("RAN: \#{cmd}")
        cmd.start_with?("psql") ? ["t\\n", true] : ["", true]
      end
      def git_capture(*a)
        j = a.join(" ")
        return [#{"-#{OLD_CHECK}+#{NEW_CHECK}".inspect}, true] if j.include?(" diff ")
        return [#{schema.call(OLD_CHECK).inspect}, true] if j.include?(" show ")
        ["", true]
      end
    RUBY
  end

  def run_dump(url)
    Dir.mktmpdir do |ws|
      FileUtils.mkdir_p(File.join(ws, "db"))
      File.write(File.join(ws, "db/schema.rb"), %(  create_table "users", force: :cascade do |t|\n#{NEW_CHECK}  end\n))
      run_release(dump_stub(url), %{dump_consumer_schema!(#{ws.inspect}, "turf-monster"); puts("RETURNED")})
    end
  end

  def test_a_reprinted_check_constraint_is_asked_of_the_throwaway_database
    out = run_dump("postgres://localhost/turf_monster_test")

    assert_match %r{RAN: psql postgres://localhost/turf_monster_release_schema_\d+ }, out,
                 "psql must run against the throwaway database, never the gate's: #{out}"
    refute_includes out, "RAN: psql postgres://localhost/turf_monster_test", out
    assert_includes out, "RETURNED", "a 't' verdict lets the dump through: #{out}"
  end

  def test_a_sqlite_app_gets_no_equivalence_and_still_aborts
    out = run_dump(nil)

    refute_includes out, "RAN: psql", "no URL, no psql: #{out}"
    assert_includes out, "ABORTED", "the same rewrite still refuses without Postgres's word: #{out}"
  end

  # THE 2026-11-08 REFUSAL, staged. sh writes db/schema.rb as the migrate it was
  # asked for would: this repo's own stage changes nothing, the engine stage sets
  # NOT NULL. The abort must name that engine migration and the line, per app.
  SLUG = %(  create_table "error_logs", force: :cascade do |t|\n    t.string "slug"\n  end\n)
  ENGINE = "20261108160000_require_slugs.studio_engine.rb"

  def staged_stub(schema_path)
    <<~RUBY
      def gate_env(_repo, role: "gate") = {}
      def gate_database_url(_repo, role: "gate") = nil
      def sh(*a, **k)
        cmd = a.reject { |x| x.is_a?(Hash) }.join(" ")
        version = (k[:env] || {})["VERSION"]
        $stdout.puts("RAN: \#{cmd} VERSION=\#{version}")
        File.write(#{schema_path.inspect}, #{SLUG.sub('"slug"', '"slug", null: false').inspect}) if version == "20261108160000"
        ["", true]
      end
      def git_capture(*a) = a.join(" ").include?(" show ") ? [#{SLUG.inspect}, true] : ["", true]
    RUBY
  end

  def test_a_refused_engine_migration_is_named_with_its_lines
    Dir.mktmpdir do |ws|
      FileUtils.mkdir_p(File.join(ws, "db/migrate"))
      File.write(File.join(ws, "db/schema.rb"), SLUG)
      %W[20261001000000_own.rb #{ENGINE}].each { |name| File.write(File.join(ws, "db/migrate", name), "") }

      out = run_release(staged_stub(File.join(ws, "db/schema.rb")),
                        %{dump_consumer_schema!(#{ws.inspect}, "turf-monster", ["?? db/migrate/#{ENGINE}"])})

      assert_includes out, "RAN: bin/rails db:create db:schema:load db:migrate VERSION=20261001000000", out
      assert_includes out, "RAN: bin/rails db:migrate VERSION=20261108160000", out
      assert_includes out, "ABORTED: ✗ turf-monster: refreshing db/schema.rb", out
      assert_includes out, "Engine migration #{ENGINE} changed existing db/schema.rb lines", out
      assert_includes out, %(-    t.string "slug"\n), out
      assert_includes out, %(+    t.string "slug", null: false), out
      refute_includes out, "behind its own migrations", out
    end
  end
end
