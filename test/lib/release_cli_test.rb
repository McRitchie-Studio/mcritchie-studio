# frozen_string_literal: true

# Standalone test for bin/release's pure helpers (no Rails needed — it `load`s
# the script in a subprocess so the guarded dispatch never fires and the test
# process's top-level namespace stays clean). Run directly:
#   ruby -Itest test/lib/release_cli_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# The git + qa-server orchestration in bin/release is shell-only and is verified
# via `bin/release {init,prepare} --dry-run` (below); this also covers the one
# piece of pure logic — .worktrees-aware sibling-repo path resolution
# (projects_root / repo_path).

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

  # Run a bin/release subcommand in a clean subprocess with the given argv (which
  # MUST include --dry-run — DRY/PROD are read from ARGV at load time, so argv is
  # set before `load`). `setup` is extra ruby injected AFTER load (e.g. to stub
  # `conductor` so the shell orchestration runs WITHOUT Rails/a DB), `call` is the
  # entrypoint method to invoke. stderr is discarded (method-redefined warnings).
  def run_cli(argv, call:, setup: "")
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{setup}; #{call})
    IO.popen(["ruby", "-e", script, { err: File::NULL }], &:read)
  end

  # A canned multi-repo deploy plan (gem + two apps) so `prepare` exercises the
  # real shell orchestration without touching Rails or the DB.
  STUB_CONDUCTOR = <<~RUBY
    def conductor(ruby, read_only: false)
      { "slug" => "rel-cli", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "studio-engine", "kind" => "gem",
          "members" => [{ "slug" => "t-gem", "branch" => nil }] },
        { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
          "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "t-studio", "branch" => "feat/studio" }] },
        { "repo" => "turf-monster", "kind" => "app", "release_branch" => "release",
          "qa_app" => "turf-monster", "members" => [{ "slug" => "t-turf", "branch" => "feat/turf" }] }
      ] }
    end
  RUBY

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

  # --- init --dry-run: create the persistent `release` branch per repo ---

  def test_init_dry_run_previews_the_release_branch_push_per_repo
    out = run_cli(["--dry-run"], call: "init")

    # Idempotent push of origin/main → origin/release in every registered repo.
    assert_includes out, "origin/main:refs/heads/release",
                     "init must preview creating the persistent release branch"
    # Both a gem repo and the app repos are seeded (producer + consumers).
    assert_includes out, "studio-engine"
    assert_includes out, "mcritchie-studio"
    # More than one repo gets the branch (gems + apps).
    assert_operator out.scan("origin/main:refs/heads/release").size, :>=, 2
  end

  # --- prepare --dry-run: deploy origin/release per app (no branch-cut) ---

  def test_prepare_dry_run_deploys_origin_release_per_app
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    # Each APP repo deploys the persistent `release` branch by ref — qa-server
    # resolves origin/release in the sibling and pushes its SHA.
    assert_includes out, "bin/qa-server deploy mcritchie-studio origin/release"
    assert_includes out, "bin/qa-server deploy turf-monster origin/release"
  end

  def test_prepare_dry_run_runs_the_merge_forward_guard
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    assert_includes out, "merge-forward guard",
                     "prepare must keep `release` ahead of main"
  end

  def test_prepare_dry_run_no_longer_cuts_a_release_branch_or_merges_members
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    # The old model cut release/<slug> and merged member branches in prepare; the
    # persistent-branch model does neither — merges happen at PR-merge time.
    refute_includes out, "checkout -b", "prepare must not cut a release branch"
    refute_includes out, "merge --no-ff", "prepare must not merge member branches"
  end

  def test_prepare_dry_run_gem_member_rides_the_release
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    assert_includes out, "rides the release", "a gem member is published at ship, not deployed in prepare"
  end
end
