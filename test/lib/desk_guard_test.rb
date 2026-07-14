# frozen_string_literal: true

# Unit tests for bin/lib/desk_guard.rb — the desk guard both G1 cert runners
# (bin/fast-check, bin/full-suite-check) consult before running a test lane, and that
# bin/agent-worktree's bringup asserts the desk with.
#
# THE BUG THESE VECTORS EXIST FOR (live, 2026-07-14). The first cut of this guard allowed on
# the PRESENCE OF A STRING — a non-empty TEST_DATABASE_URL — and all ten of its tests were
# studio-shaped, so a green suite said NOTHING about either satellite:
#
#   * turf-monster IGNORED the pin (bare `database: turf_monster_test`, no `url:` key), so
#     the guard ALLOWED desks that resolved to the SHARED turf_monster_test — and the cert's
#     next lane purged it. It reported an isolation it had never proven: worse than no guard.
#   * rolio is SQLite and has NO pin BY DESIGN (its test DB is a file inside the desk), so a
#     guard demanding the string refuses a perfectly isolated tree — and bringup's rollback
#     then deleted it.
#
# ONE root cause — a POSTGRES-SHAPED, DECLARATION-TRUSTING model — wrong in BOTH directions.
# The missing vector WAS the blocker, so these vectors are organised by the two ADAPTER
# SHAPES and both directions of each. The guard is driven through its `resolver:` seam: each
# test states what the BOOTED APP would answer and asserts the verdict that follows. What a
# desk DECLARES is varied INDEPENDENTLY of what it RESOLVES to, because the whole lesson of
# this file is that those are not the same thing.
#
#   ruby -Itest test/lib/desk_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep. The resolver's own plumbing (env
# pass-through, chdir, boot failure) is proven against a shimmed `bin/rails` at the bottom.
# The shelled end-to-end refusals live in test/lib/fast_check_test.rb and
# test/lib/full_suite_check_test.rb.

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../../bin/lib/desk_guard"

class DeskGuardTest < Minitest::Test
  # A POSTGRES repo whose database.yml HONOURS the pin (mcritchie-studio).
  PG_HONOURING = <<~YAML
    default: &default
      adapter: postgresql
    test:
      <<: *default
      database: studio_test
      url: <%= ENV["TEST_DATABASE_URL"] %>
  YAML

  # A POSTGRES repo whose database.yml IGNORES the pin — turf-monster, as it actually was.
  # ERB-stripped, the two files declare the SAME `database:`; only a BOOT tells them apart.
  PG_IGNORING = <<~YAML
    default: &default
      adapter: postgresql
    test:
      <<: *default
      database: studio_test
  YAML

  # A SQLITE repo (rolio): the test DB is a FILE, resolved against the tree that boots.
  SQLITE = <<~YAML
    default: &default
      adapter: sqlite3
    test:
      <<: *default
      database: storage/test.sqlite3
  YAML

  # A repo laid out the way bin/agent-worktree lays one out: <repo>/.worktrees/<slug>.
  def with_desk(slug: "some-task", database_yml: PG_HONOURING, test_env_local: nil)
    Dir.mktmpdir do |root|
      repo = File.join(root, "repo")
      desk = File.join(repo, ".worktrees", slug)
      FileUtils.mkdir_p(desk)
      FileUtils.mkdir_p(File.join(repo, "config"))
      File.write(File.join(repo, "config", "database.yml"), database_yml) if database_yml
      File.write(File.join(desk, ".env.test.local"), test_env_local) if test_env_local
      yield desk, repo
    end
  end

  # The seam: state what the BOOTED app resolves to. `booted: false` is a boot that died.
  def resolver(resolved, booted: true, output: "", spy: nil)
    lambda do |desk, env:|
      spy&.push(desk: desk, env: env)
      [resolved, output, booted]
    end
  end

  # ═══ SHAPE 1 — POSTGRES ═══════════════════════════════════════════════════════════════

  # BLOCKER A, the exact live case. The desk DECLARES an isolated URL; the app IGNORES it and
  # lands on the SHARED database. Presence of the string said ALLOW. The truth is REFUSE.
  def test_refuses_a_pg_desk_whose_pin_is_inert_and_resolves_to_the_shared_db
    with_desk(database_yml: PG_IGNORING,
              test_env_local: "TEST_DATABASE_URL=postgresql://localhost/studio_test_some_task\n") do |desk|
      refusal = DeskGuard.refusal(desk, env: {}, resolver: resolver("studio_test"))

      refute_nil refusal, "a desk that RESOLVES to the shared test DB must be refused, however it is pinned"
      assert_includes refusal, "SHARED test database"
      assert_includes refusal, "studio_test"
      # It must say the APP is ignoring the pin: sending the operator back to bringup (which
      # would faithfully rewrite the same inert pin) is an infinite loop.
      assert_includes refusal, "IGNORES it"
      assert_includes refusal, 'url: <%= ENV["TEST_DATABASE_URL"] %>'
      assert_includes refusal, "ENV/config issue"
    end
  end

  # THE ANTI-PLACEBO PROOF, and the one vector that would have caught the blocker by itself:
  # hold the DECLARATION fixed and vary only what the app RESOLVES to. A guard that reads the
  # declaration cannot tell these two apart — it allowed both. The verdict must follow the
  # BOOT, not the string.
  def test_the_verdict_follows_the_resolution_not_the_declaration
    pin = "TEST_DATABASE_URL=postgresql://localhost/studio_test_some_task\n"

    with_desk(test_env_local: pin) do |desk|
      assert_nil DeskGuard.refusal(desk, env: {}, resolver: resolver("studio_test_some_task")),
                 "same pin, and the app HONOURED it: allow"
    end

    with_desk(test_env_local: pin) do |desk|
      refute_nil DeskGuard.refusal(desk, env: {}, resolver: resolver("studio_test")),
                 "same pin, and the app IGNORED it: refuse"
    end
  end

  def test_allows_a_pg_desk_that_resolves_to_its_own_test_db
    with_desk(test_env_local: "TEST_DATABASE_URL=postgresql://localhost/studio_test_some_task\n") do |desk|
      assert_nil DeskGuard.refusal(desk, env: {}, resolver: resolver("studio_test_some_task"))
    end
  end

  # The half-built desk: nothing pinned, so it falls back to the shared DB. Same refusal
  # class, DIFFERENT cause and different fix — so it gets the bringup repair command, not the
  # config advice.
  def test_refuses_a_half_built_pg_desk_and_sends_it_to_bringup
    with_desk(slug: "half-built") do |desk|
      refusal = DeskGuard.refusal(desk, env: {}, resolver: resolver("studio_test"))

      refute_nil refusal
      assert_includes refusal, "no isolated test DB"
      assert_includes refusal, "SHARED base test database"
      assert_includes refusal, "ENV issue"
      assert_includes refusal, "bin/agent-worktree new repo half-built"
      refute_includes refusal, "IGNORES it", "no pin was declared, so the app is not ignoring one"
    end
  end

  # A caller that EXPORTS the pin (Release::GateEnv does) is diagnosed from the env rather
  # than the file — but, again, only for WHICH message. The verdict is still the boot's.
  def test_an_exported_pin_that_resolves_shared_is_still_refused
    with_desk do |desk|
      refusal = DeskGuard.refusal(
        desk,
        env: { "TEST_DATABASE_URL" => "postgresql://localhost/studio_test_some_task" },
        resolver: resolver("studio_test")
      )

      refute_nil refusal
      assert_includes refusal, "IGNORES it"
    end
  end

  # ═══ SHAPE 2 — SQLITE ═════════════════════════════════════════════════════════════════

  # BLOCKER B. rolio: no pin, no Postgres, and correctly isolated all along — its test DB is a
  # FILE inside the desk. The guard must ALLOW it, or `new rolio <task>` creates nothing, ever.
  def test_allows_a_sqlite_desk_whose_db_file_is_inside_the_desk
    with_desk(database_yml: SQLITE) do |desk|
      assert_nil DeskGuard.refusal(desk, env: {}, resolver: resolver("storage/test.sqlite3")),
                 "a SQLite desk's test DB is a file INSIDE the desk — private by construction, and no " \
                 "TEST_DATABASE_URL exists or is needed"
    end
  end

  # Containment is the property — not "it is SQLite, wave it through". A file-backed DB
  # resolved OUTSIDE the desk (the primary checkout's own storage/test.sqlite3) is shared with
  # whoever owns it.
  def test_refuses_a_sqlite_desk_whose_db_file_escapes_the_desk
    with_desk(database_yml: SQLITE) do |desk, repo|
      escaped = File.join(repo, "storage", "test.sqlite3")

      refute_nil DeskGuard.refusal(desk, env: {}, resolver: resolver(escaped)),
                 "a file-backed DB outside the desk is the PRIMARY's — refuse"
    end
  end

  def test_a_sqlite_desk_is_never_told_to_restart_postgres
    with_desk(database_yml: SQLITE) do |desk, repo|
      refusal = DeskGuard.refusal(desk, env: {},
                                        resolver: resolver(File.join(repo, "storage", "test.sqlite3")))

      refute_includes refusal.to_s, "pg_isready"
      refute_includes refusal.to_s, "brew services"
    end
  end

  # ═══ FAIL CLOSED — when it can prove NEITHER ══════════════════════════════════════════

  def test_refuses_when_the_app_will_not_boot
    with_desk do |desk|
      refusal = DeskGuard.refusal(
        desk, env: {},
        resolver: resolver("", booted: false, output: "Gem::LoadError: pg is not part of the bundle")
      )

      refute_nil refusal, "cannot prove isolation => must not allow"
      assert_includes refusal, "could not resolve"
      # Honest in both directions: a boot-breaking diff lands here too, so it must not be
      # pinned on the env alone.
      assert_includes refusal, "boot-time error in your own diff"
      assert_includes refusal, "pg is not part of the bundle", "the captured output is the only evidence"
    end
  end

  def test_refuses_when_the_probe_resolves_nothing
    with_desk do |desk|
      refute_nil DeskGuard.refusal(desk, env: {}, resolver: resolver("   "))
    end
  end

  def test_refuses_when_the_shared_name_cannot_be_read
    # No config/database.yml => nothing trustworthy to compare against. Refuse rather than
    # assume: an unprovable isolation claim is the failure this guard exists to end.
    with_desk(database_yml: nil) do |desk|
      refusal = DeskGuard.refusal(desk, env: {}, resolver: resolver("studio_test_some_task"))

      refute_nil refusal
      assert_includes refusal, "cannot be proven"
    end
  end

  # ═══ WHO IS GUARDED ═══════════════════════════════════════════════════════════════════

  def test_ignores_the_reserved_release_workspaces_without_even_booting
    # .worktrees/_gate and .worktrees/_ship are NOT agent desks (Release::GateWorkspace
    # reserves the leading underscore to say so). They are covered by a stricter rule of their
    # own — assert_private_gate_db! proves their DB is private BEFORE db:test:purge destroys
    # it — so this guard must not boot them a second time, and must not refuse a SQLite
    # workspace for lacking a pin it does not need.
    %w[_gate _ship].each do |reserved|
      with_desk(slug: reserved) do |workspace|
        spy = []
        refute DeskGuard.desk?(workspace), "#{reserved} is a release workspace, not an agent desk"
        assert_nil DeskGuard.refusal(workspace, env: {}, resolver: resolver("studio_test", spy: spy))
        assert_empty spy, "a reserved workspace must not even be booted"
      end
    end
  end

  def test_allows_a_non_desk_root_without_booting
    # The primary checkout / CI / a bare clone: the shared <app>_test IS the right database
    # there. Guarding it would refuse every normal run — and booting it would tax every one.
    Dir.mktmpdir do |root|
      repo = File.join(root, "mcritchie-studio")
      FileUtils.mkdir_p(repo)
      spy = []

      assert_nil DeskGuard.refusal(repo, env: {}, resolver: resolver("studio_test", spy: spy))
      refute DeskGuard.desk?(repo)
      assert_empty spy
    end
  end

  def test_desk_detection_keys_on_the_path_not_the_stack_env
    # Keying "is this a desk?" on .env.agent-stack would let the broken case walk through: a
    # half-built desk is missing exactly that file.
    with_desk do |desk|
      assert DeskGuard.desk?(desk), "a dir under .worktrees/ is a desk even with no stack env"
      refute File.exist?(File.join(desk, ".env.agent-stack")), "premise: the half-built desk has no stack env"
    end
  end

  # ═══ THE PURE PREDICATE ═══════════════════════════════════════════════════════════════

  def test_private_db_predicate_vectors
    desk = "/repo/.worktrees/task"

    # Postgres: private iff it is not the shared name.
    refute DeskGuard.private_db?(resolved: "studio_test", desk: desk, shared: "studio_test")
    assert DeskGuard.private_db?(resolved: "studio_test_task", desk: desk, shared: "studio_test")

    # SQLite: private iff the FILE is inside the desk.
    assert DeskGuard.private_db?(resolved: "storage/test.sqlite3", desk: desk, shared: "storage/test.sqlite3")
    refute DeskGuard.private_db?(resolved: "/repo/storage/test.sqlite3", desk: desk, shared: "storage/test.sqlite3")
    refute DeskGuard.private_db?(resolved: "../other/storage/test.sqlite3", desk: desk, shared: "x")

    # A near-miss path that shares the desk's PREFIX but is a different directory.
    refute DeskGuard.private_db?(resolved: "/repo/.worktrees/task-2/storage/test.sqlite3", desk: desk, shared: "x")

    # Nothing to compare against, or nothing resolved: never private.
    refute DeskGuard.private_db?(resolved: "studio_test_task", desk: desk, shared: "")
    refute DeskGuard.private_db?(resolved: "", desk: desk, shared: "studio_test")
  end

  # ═══ THE RESOLVER'S OWN PLUMBING ══════════════════════════════════════════════════════

  # The real resolve() shells `bin/rails runner` in the desk. Driven here against a SHIM, so
  # the plumbing — chdir, env pass-through, RAILS_ENV, plucking the token out of a noisy
  # stream, the exit status — is proven without a five-second Rails boot.
  def with_shim(script)
    Dir.mktmpdir do |root|
      desk = File.join(root, "repo", ".worktrees", "task")
      FileUtils.mkdir_p(File.join(desk, "bin"))
      shim = File.join(desk, "bin", "rails")
      File.write(shim, script)
      File.chmod(0o755, shim)
      yield desk
    end
  end

  def test_resolve_plucks_the_token_out_of_a_noisy_stream_and_boots_at_rails_env_test
    with_shim(<<~SH) do |desk|
      #!/bin/sh
      echo "warning: already initialized constant" >&2
      echo "DESKDB=studio_test_task_${RAILS_ENV}"
      echo "trailing noise"
    SH
      resolved, output, booted = DeskGuard.resolve(desk, env: {})

      assert booted
      assert_equal "studio_test_task_test", resolved, "RAILS_ENV=test must reach the child"
      assert_includes output, "trailing noise", "the whole stream is kept as evidence"
    end
  end

  def test_resolve_passes_the_callers_env_through_to_the_boot
    # The lane inherits the ambient env, so the probe must too — including a DATABASE_URL the
    # caller happens to export. Prove the run you are about to do, not a tidier one.
    with_shim(<<~SH) do |desk|
      #!/bin/sh
      echo "DESKDB=${TEST_DATABASE_URL}"
    SH
      resolved, = DeskGuard.resolve(desk, env: { "TEST_DATABASE_URL" => "from_the_env" })

      assert_equal "from_the_env", resolved
    end
  end

  def test_resolve_reports_a_failed_boot_rather_than_an_empty_answer
    with_shim(<<~SH) do |desk|
      #!/bin/sh
      echo "Gem::LoadError: pg is not part of the bundle" >&2
      exit 1
    SH
      resolved, output, booted = DeskGuard.resolve(desk, env: {})

      refute booted
      assert_empty resolved
      assert_includes output, "pg is not part of the bundle"
    end
  end

  def test_resolve_survives_a_missing_bin_rails
    Dir.mktmpdir do |desk|
      resolved, _output, booted = DeskGuard.resolve(desk, env: {})

      refute booted, "a repo with no bin/rails must fail closed, not raise"
      assert_empty resolved
    end
  end
end
