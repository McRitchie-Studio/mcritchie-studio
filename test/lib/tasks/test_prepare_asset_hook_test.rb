require "test_helper"
require "rake"

# Integration tier: the LIVE wiring the G1 cert leans on.
#
# app/assets/builds/ is gitignored (only .keep is tracked), so any virgin checkout —
# a fresh `bin/agent-worktree new` worktree, the release gate's `.worktrees/_gate`,
# a CI runner — starts with NO built tailwind.css, and every view-rendering test
# would error with `The asset "tailwind.css" is not present in the asset pipeline`.
#
# What saves an ARGLESS `bin/rails test` (CI, bin/full-suite-check, the gate workspace)
# is that Rails runs `test:prepare` first, and tailwindcss-rails enhances that task with
# `tailwindcss:build`. Runs that pass EXPLICIT TEST PATHS do not get that for free —
# Rails::Command::TestCommand skips the prepare task whenever an argument looks like a
# path — so bin/fast-check's lanes and `bin/agent-worktree test <file>` invoke
# `test:prepare` THEMSELVES (see bin/fast-check, bin/agent-worktree#prepare_test_env).
#
# This test pins the seam that makes that work. If a future gem bump or a swap of the
# CSS/JS bundler drops the enhancement, those callers would silently stop building the
# asset and the false-red cert would return — so fail HERE, at the cause, rather than as
# ~77 unexplained asset errors on an unrelated diff.
class TestPrepareAssetHookTest < ActiveSupport::TestCase
  test "test:prepare carries the bundled-asset build, so preparing the test env builds the CSS" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("test:prepare")

    prerequisites = Rake::Task["test:prepare"].prerequisites

    assert_includes prerequisites, "tailwindcss:build",
                    "test:prepare is the hook that builds app/assets/builds/tailwind.css. " \
                    "Without it, every runner that passes explicit test paths (bin/fast-check's " \
                    "lanes) goes red on a virgin checkout with a missing-asset error."
  end
end
