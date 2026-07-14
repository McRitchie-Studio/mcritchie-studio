# frozen_string_literal: true

# Unit tests for bin/lib/desk_guard.rb — the desk guard both G1 cert runners
# (bin/fast-check, bin/full-suite-check) consult before running a test lane.
#
# A worktree desk with no isolated test DB does not fail; config/database.yml falls
# back to the SHARED base `<app>_test` whenever TEST_DATABASE_URL is blank, so the
# suite silently joins the database the primary checkout and the release gate
# workspaces use. bin/agent-worktree's bringup is atomic now and cannot leave such a
# desk behind — this guard is the second lock: old half-built desks are still on disk,
# .env.test.local can be deleted by hand, and a rollback that misses a case must still
# never produce a silently-shared suite.
#
# The invariant is POSITIVE — a tree under .worktrees/ must HAVE a test DB of its own,
# from a file or from the env — so a breakage nobody enumerated still refuses.
#   ruby -Itest test/lib/desk_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep. The shelled end-to-end refusals
# live in test/lib/fast_check_test.rb and test/lib/full_suite_check_test.rb.

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../../bin/lib/desk_guard"

class DeskGuardTest < Minitest::Test
  # A repo laid out the way bin/agent-worktree lays one out: <repo>/.worktrees/<slug>.
  def with_desk(slug: "some-task", test_env_local: nil)
    Dir.mktmpdir do |root|
      desk = File.join(root, "repo", ".worktrees", slug)
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".env.test.local"), test_env_local) if test_env_local
      yield desk, root
    end
  end

  # --- the hazard: a desk with no isolated test DB --------------------------------

  def test_refuses_a_desk_with_no_test_env_local
    with_desk do |desk|
      refusal = DeskGuard.refusal(desk, env: {})

      refute_nil refusal, "a desk with no isolated test DB must be refused, not silently shared"
      assert_includes refusal, "no isolated test DB"
      assert_includes refusal, "SHARED base test database"
      # Names it as an ENV problem so nobody hunts their diff for a phantom regression.
      assert_includes refusal, "ENV issue"
      assert_includes refusal, "bin/agent-worktree new"
    end
  end

  def test_refuses_a_desk_whose_test_database_url_is_declared_but_blank
    # The half-written file: present, but pinning nothing. Existence is not the
    # property — a non-empty TEST_DATABASE_URL is.
    with_desk(test_env_local: "TEST_DATABASE_URL=\n") do |desk|
      refute_nil DeskGuard.refusal(desk, env: {})
    end
  end

  def test_refusal_names_the_desk_and_the_missing_file
    with_desk(slug: "half-built") do |desk|
      refusal = DeskGuard.refusal(desk, env: {})

      assert_includes refusal, desk
      assert_includes refusal, ".env.test.local"
      assert_includes refusal, "half-built" # the slug, so the repair command is copyable
    end
  end

  # --- the passing cases ----------------------------------------------------------

  def test_allows_a_desk_pinned_to_its_own_test_db
    with_desk(test_env_local: "TEST_DATABASE_URL=postgresql://localhost/studio_test_some_task\n") do |desk|
      assert_nil DeskGuard.refusal(desk, env: {})
    end
  end

  def test_allows_a_desk_whose_test_db_is_exported_in_the_env
    # A caller that exports TEST_DATABASE_URL (Release::GateEnv does) satisfies the
    # invariant without a file: what matters is that the tree HAS an isolated test DB,
    # not where it said so.
    with_desk(slug: "some-task") do |desk|
      assert_nil DeskGuard.refusal(desk, env: { "TEST_DATABASE_URL" => "postgresql://localhost/studio_test_some_task" })
    end
  end

  def test_ignores_the_reserved_release_workspaces
    # .worktrees/_gate and .worktrees/_ship are NOT agent desks (Release::GateWorkspace
    # reserves the leading underscore to say so) and they are not covered by this rule but
    # by a stricter one: assert_private_gate_db! proves their DB is private before
    # db:test:purge destroys it. A SQLite app's workspace (rolio) also has NO
    # TEST_DATABASE_URL BY DESIGN — its test DB is a file inside the workspace, already
    # private — so demanding one here would refuse a perfectly isolated tree.
    %w[_gate _ship].each do |reserved|
      with_desk(slug: reserved) do |workspace|
        refute DeskGuard.desk?(workspace), "#{reserved} is a release workspace, not an agent desk"
        assert_nil DeskGuard.refusal(workspace, env: {})
      end
    end
  end

  def test_allows_a_non_desk_root
    # The primary checkout / CI / a bare clone: the shared <app>_test IS the right
    # database there. Guarding it would refuse every normal run.
    Dir.mktmpdir do |root|
      repo = File.join(root, "mcritchie-studio")
      FileUtils.mkdir_p(repo)

      assert_nil DeskGuard.refusal(repo, env: {})
      refute DeskGuard.desk?(repo)
    end
  end

  def test_desk_detection_keys_on_the_path_not_the_stack_env
    # Keying "is this a desk?" on .env.agent-stack would let the broken case walk
    # through: a half-built desk is missing exactly that file.
    with_desk do |desk|
      assert DeskGuard.desk?(desk), "a dir under .worktrees/ is a desk even with no stack env"
      refute File.exist?(File.join(desk, ".env.agent-stack")), "premise: the half-built desk has no stack env"
    end
  end

  def test_reads_test_database_url_past_comments_and_blank_lines
    body = <<~ENVFILE
      # Generated by mcritchie-studio/bin/agent-worktree.

      TEST_DATABASE_URL=postgresql://localhost/studio_test_x
    ENVFILE
    with_desk(test_env_local: body) do |desk|
      assert_equal "postgresql://localhost/studio_test_x", DeskGuard.declared_test_database_url(desk)
      assert_nil DeskGuard.refusal(desk, env: {})
    end
  end

  def test_a_blank_env_value_does_not_satisfy_the_guard
    # ENV["TEST_DATABASE_URL"] = "" is how a cleared export looks; it pins nothing.
    with_desk do |desk|
      refute_nil DeskGuard.refusal(desk, env: { "TEST_DATABASE_URL" => "  " })
    end
  end
end
