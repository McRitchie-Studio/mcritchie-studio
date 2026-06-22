# frozen_string_literal: true

# Standalone test for bin/release's pure helpers (no Rails needed — it `load`s
# the script in a subprocess so the guarded dispatch never fires and the test
# process's top-level namespace stays clean). Run directly:
#   ruby -Itest test/lib/release_cli_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# The git + qa-server orchestration in bin/release is shell-only and is verified
# via `bin/release prepare --dry-run`; this covers the one piece of pure logic —
# .worktrees-aware sibling-repo path resolution (projects_root / repo_path).

require "minitest/autorun"
require "shellwords"

class ReleaseCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/release", __dir__)

  # Evaluate a bin/release helper in a clean subprocess. `load` defines the
  # script's helpers WITHOUT dispatching a command (it's guarded on
  # __FILE__ == $PROGRAM_NAME), so we exercise the real CLI logic in isolation.
  # stderr is discarded so rubygems "already initialized" warnings (emitted under
  # `bin/rails test`'s bundler env) don't corrupt the printed value.
  def eval_helper(expr)
    script = %(load #{BIN.inspect}; print(#{expr}))
    IO.popen(["ruby", "-e", script, { err: File::NULL }], &:read)
  end

  def test_projects_root_from_a_primary_checkout
    assert_equal "/srv/projects",
                 eval_helper(%(projects_root("/srv/projects/mcritchie-studio")))
  end

  def test_projects_root_climbs_out_of_worktrees
    # A worktree's app root sits under <hub>/.worktrees/<wt>; the projects root
    # that holds the siblings is two levels above .worktrees, not inside it.
    assert_equal "/srv/projects",
                 eval_helper(%(projects_root("/srv/projects/mcritchie-studio/.worktrees/feat-x")))
  end

  def test_repo_path_resolves_a_sibling_never_inside_worktrees
    # repo_path uses projects_root's default (the running script's own app root),
    # so the path lands a sibling next to the hub and never under .worktrees —
    # whether bin/release runs from a primary checkout or a worktree.
    out = eval_helper(%(repo_path("turf-monster")))
    assert out.end_with?("/turf-monster"), out
    refute_includes out, "/.worktrees/", "repo_path must climb out of .worktrees"
  end
end
