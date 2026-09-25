# frozen_string_literal: true

# DeskDatabaseGuard — a dev-env rails command in a desk refuses the SHARED dev DB.
# Standalone:
#   ruby -Itest test/lib/desk_database_guard_test.rb
#
# THE DEFECT (2026-09-25, three builders): `bin/rails db:prepare` in a fresh desk
# resolved to the shared mcritchie_studio_development, because the desk had a
# .env.test.local but nothing that pointed the DEVELOPMENT env at its own DB.
require "minitest/autorun"
require_relative "../../lib/desk_database_guard"

class DeskDatabaseGuardTest < Minitest::Test
  SHARED = "mcritchie_studio_development"
  DESK = "/Users/x/projects/mcritchie-studio/.worktrees/some-task"

  def refusal(root: DESK, rails_env: "development", database_url: nil, override: nil)
    DeskDatabaseGuard.refusal(root: root, rails_env: rails_env, database_url: database_url,
                              shared_database: SHARED, override: override)
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
end
