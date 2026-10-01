# frozen_string_literal: true

# DeskDatabaseGuard — a dev-env rails command in a desk refuses the SHARED dev DB.
# Standalone:
#   ruby -Itest test/lib/desk_database_guard_test.rb
#
# THE DEFECT (2026-09-25, three builders): `bin/rails db:prepare` in a fresh desk
# resolved to the shared mcritchie_studio_development, because the desk had a
# .env.test.local but nothing that pointed the DEVELOPMENT env at its own DB.
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../lib/desk_database_guard"

class DeskDatabaseGuardTest < Minitest::Test
  SHARED = "mcritchie_studio_development"
  DESK = "/Users/x/projects/mcritchie-studio/.worktrees/some-task"

  SCRATCH = "/private/tmp/claude-501/scratchpad/tmp.Xy12/zap-some-task"

  def refusal(root: DESK, rails_env: "development", database_url: nil, override: nil, linked_worktree: false)
    DeskDatabaseGuard.refusal(root: root, rails_env: rails_env, database_url: database_url,
                              shared_database: SHARED, override: override, linked_worktree: linked_worktree)
  end

  def test_a_desk_with_no_database_url_is_refused_and_told_the_fix
    message = refusal
    assert message, "no DATABASE_URL means database.yml's shared dev DB — refuse it"
    assert_includes message, SHARED
    assert_includes message, "bin/agent-worktree new mcritchie-studio some-task",
                    "the refusal names the one command that writes the desk's own pointer"
  end

  def test_a_desk_whose_url_names_the_shared_db_is_refused
    assert refusal(database_url: "postgresql://localhost/#{SHARED}")
    assert refusal(database_url: "postgresql://localhost/#{SHARED}?pool=5"), "a query string does not hide the name"
  end

  def test_a_desk_pointed_at_its_own_db_passes
    assert_nil refusal(database_url: "postgresql://localhost/#{SHARED}_some_task")
  end

  def test_the_primary_checkout_is_never_refused
    assert_nil refusal(root: "/Users/x/projects/mcritchie-studio")
  end

  def test_only_the_development_env_is_guarded
    assert_nil refusal(rails_env: "test")
    assert_nil refusal(rails_env: "production")
  end

  def test_an_explicit_override_passes
    assert_nil refusal(override: "1")
    assert refusal(override: ""), "a blank override is not an override"
  end

  # REGRESSION (2026-09-25): a host-only URL was read as database "localhost" and
  # passed, while Rails merged it over database.yml and connected to the shared DB.
  def test_a_host_only_url_resolves_to_the_configured_database_and_is_refused
    assert refusal(database_url: "postgresql://localhost"), "no path means database.yml's shared DB"
    assert refusal(database_url: "postgresql://localhost/"), "a bare trailing slash names no database"
    assert refusal(database_url: "postgresql://localhost:5432?pool=5"), "a port and query name no database"
    assert refusal(database_url: "postgresql://user:pw@localhost:5432"), "credentials name no database"
  end

  def test_effective_database_reads_the_path_not_the_last_segment_of_the_whole_url
    assert_equal SHARED, DeskDatabaseGuard.effective_database("postgresql://localhost", SHARED)
    assert_equal "desk_db", DeskDatabaseGuard.effective_database("postgresql://localhost:5432/desk_db?pool=5", SHARED)
    assert_equal SHARED, DeskDatabaseGuard.effective_database(nil, SHARED)
  end

  def test_the_refusal_names_the_cause_it_saw
    unset = refusal
    assert_includes unset, "no development pointer"
    pointed = refusal(database_url: "postgresql://localhost")
    refute_includes pointed, "no development pointer",
                    "a pointer that exists but resolves to the shared DB is not 'no pointer'"
    assert_includes pointed, "DATABASE_URL resolves to the shared database"
  end

  # ── scratch worktrees (/tasks/harden-scratch-worktree-recipes) ─────────────────────
  #
  # THE HOLE. Reviewer, zap and arbitration throwaways moved to `$(mktemp -d)/<name>`,
  # outside `.worktrees/`, so DESK_ROOT stopped matching and a bare `bin/rails runner` in
  # one reached the shared development DB with nothing in the way.

  def test_a_scratch_worktree_outside_the_desk_root_is_refused_on_a_development_boot
    message = refusal(root: SCRATCH, linked_worktree: true)

    assert message, "a linked worktree outside .worktrees/ with no pointer resolves to the shared DB — refuse it"
    assert_includes message, SHARED
    assert_includes message, SCRATCH, "the refusal names the tree it refused"
    assert_includes message, "RAILS_ENV=test", "a throwaway is for tests; the refusal says how"
    refute_includes message, "bin/agent-worktree new mcritchie-studio zap-some-task",
                    "a scratch tree is not a desk, so the desk's re-provision line would be a false remedy"
  end

  def test_a_scratch_worktree_keeps_every_existing_escape
    assert_nil refusal(root: SCRATCH, linked_worktree: true, rails_env: "test"), "RAILS_ENV=test is the recipe's path"
    assert_nil refusal(root: SCRATCH, linked_worktree: true, override: "1"), "ALLOW_SHARED_DEV_DB=1 still overrides"
    assert_nil refusal(root: SCRATCH, linked_worktree: true, database_url: "postgresql://localhost/own_db"),
               "a scratch tree pointed at its own DB is not touching the shared one"
    assert refusal(root: SCRATCH, linked_worktree: true, database_url: "postgresql://localhost"),
           "a host-only URL still resolves to the shared DB from a scratch tree"
  end

  def test_a_plain_directory_outside_the_desk_root_is_not_refused
    assert_nil refusal(root: SCRATCH, linked_worktree: false),
               "only a linked worktree is guarded outside .worktrees/ — the primary checkout is never refused"
  end

  # The predicate the initializer feeds in, against REAL git: a primary checkout has a
  # `.git` directory, a `git worktree add` target outside .worktrees/ has a `.git` file.
  def test_linked_worktree_tells_a_scratch_worktree_from_its_primary
    Dir.mktmpdir("desk-db-guard") do |dir|
      primary = File.join(dir, "hub")
      scratch = File.join(dir, "scratch", "zap-some-task")
      git!(dir, "init", "--quiet", "--initial-branch=main", primary)
      git!(primary, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
           "commit", "--quiet", "--allow-empty", "--message", "seed")
      git!(primary, "worktree", "add", "--quiet", "--detach", scratch, "HEAD")

      refute DeskDatabaseGuard.linked_worktree?(primary), "the primary checkout is not a linked worktree"
      assert DeskDatabaseGuard.linked_worktree?(scratch), "a `git worktree add` target is a linked worktree"
      refute DeskDatabaseGuard.linked_worktree?(dir), "a directory that is no checkout at all is not one"
    end
  end

  private

  def git!(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end
end
