require "test_helper"
require "rake"
require "rails/test_unit/runner"
require "rails/commands/test/test_command"
require "minitest/mock"

# Integration tier: the LIVE wiring the G1 cert leans on.
#
# app/assets/builds/ is gitignored (only .keep is tracked), so any virgin checkout —
# a fresh `bin/agent-worktree new` worktree, the release gate's `.worktrees/_gate`,
# a CI runner — starts with NO built tailwind.css, and every view-rendering test
# would error with `The asset "tailwind.css" is not present in the asset pipeline`.
#
# What saves an ARGLESS `bin/rails test` (CI, bin/full-suite-check) is that Rails runs
# `test:prepare` first, and tailwindcss-rails enhances that task with
# `tailwindcss:build`. Runs that pass EXPLICIT TEST PATHS do not get it for free —
# Rails::Command::TestCommand skips the prepare task whenever an argument looks like a
# path — so every path-arg caller invokes `test:prepare` ITSELF: bin/fast-check's
# lanes, `bin/agent-worktree test <file>` (see bin/agent-worktree#prepare_test_env),
# and the release gate workspaces (`bin/release.rb`'s `prepare_gate_workspace!` runs
# `db:test:prepare test:prepare` since gate-workspace-skips-test-prepare, PR #522).
#
# This test pins the seam that makes that work. If a future gem bump or a swap of the
# CSS/JS bundler drops the enhancement, those callers would silently stop building the
# asset and the false-red cert would return — so fail HERE, at the cause, rather than as
# ~77 unexplained asset errors on an unrelated diff.
#
# ---------------------------------------------------------------------------
# THE WHOLE CHAIN, not just its last link (added by hub-hook-comment-overreaches).
#
# bin/lib/ci_test_command.rb documents WHY the ecosystem's CI line keeps the shape
# `bin/rails db:test:prepare test test:system`, and part of that rationale is that the
# line builds its own stylesheet. That paragraph used to state the condition as "a
# rake-routed, path-free line fires the hook for free" — a condition CELL A below
# satisfies and fails. Prose cannot be trusted with a five-link mechanism, and grepping
# a sentence can never catch it drifting, so each link is asserted here instead and the
# comment points at this file.
#
# Measured on ubuntu-latest, each cell deleting app/assets/builds/tailwind.css first
# (turf-monster run 34382943177):
#
#   A. `bin/rails db:test:prepare`                    → stylesheet ABSENT
#   B. `bin/rails db:test:prepare test`               → PRESENT at 7s
#   C. `TEST=<path> bin/rails db:test:prepare test`   → ABSENT
#
# The links that produce those three outcomes:
#
#   1. `db:test:prepare` is not a rails COMMAND, so the whole line routes through RAKE
#      and every token becomes a rake task. (Owned by test/lib/ci_test_command_test.rb,
#      which pins the line's shape.)
#   2. Rake's `test` task carries NO prerequisites — the true half of the old claim, and
#      the half that made a false conclusion look sound elsewhere.
#   3. Its BODY is `Rails::TestUnit::Runner.run_from_rake`, i.e. `system("rails", "test",
#      *argv)`: it SHELLS OUT to the argless `rails test` COMMAND. That is the link
#      prose keeps skipping.
#   4. `Rails::Command::TestCommand#perform` calls `run_prepare_task` — and so invokes
#      `test:prepare` — whenever nothing in `self.args` looks like a path or `-n`.
#   5. tailwindcss-rails enhances `test:prepare` and NOT `db:test:prepare`, which is the
#      entire reason cell A differs from cell B.
#
# Cell C is the one that costs money. Both `ENV["TEST"]` and `ENV["TESTOPTS"]` reach the
# spawned argv — from different layers — so adding a filter to a CI test line silences
# the hook WITHOUT CHANGING A VISIBLE WORD of the command. That is why the explicit
# `test:prepare` steps (bin/ci-shard, bin/fast-check's test-prepare lane) stay.
#
# WHAT THIS FILE DOES NOT COVER, stated rather than implied. It does not spawn
# `bin/rails db:test:prepare test` and watch the file appear — that is a recursive
# full-suite spawn, and no unit test should pay for one. The end-to-end observation is
# the CI receipt quoted above. What is asserted here is every link that receipt depends
# on, so a gem upgrade that breaks the chain reddens here instead of quietly deleting
# the hook and leaving the comment lying.
#
# Run directly:
#   bin/rails test test/lib/tasks/test_prepare_asset_hook_test.rb
class TestPrepareAssetHookTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("test:prepare")
  end

  test "test:prepare carries the bundled-asset build, so preparing the test env builds the CSS" do
    prerequisites = Rake::Task["test:prepare"].prerequisites

    assert_includes prerequisites, "tailwindcss:build",
                    "test:prepare is the hook that builds app/assets/builds/tailwind.css. " \
                    "Without it, every runner that passes explicit test paths (bin/fast-check's " \
                    "lanes) goes red on a virgin checkout with a missing-asset error."
  end

  # LINK 5, second half — the asymmetry that makes cell A differ from cell B at all.
  #
  # tailwindcss-rails' build.rake picks ONE task to enhance, by an if/elsif chain:
  # `test:prepare`, else `spec:prepare`, else `db:test:prepare`. railties always defines
  # `test:prepare`, so the first branch always wins in a Rails app and `db:test:prepare`
  # is never enhanced. Lose that asymmetry and `bin/rails db:test:prepare` alone would
  # build the stylesheet, and ci_test_command.rb's cell A would stop being true.
  test "[unit] the build hangs off test:prepare and NOT off db:test:prepare" do
    refute_includes Rake::Task["db:test:prepare"].prerequisites, "tailwindcss:build",
                    "db:test:prepare now builds the stylesheet too, so the bare form and the " \
                    "form that names a test task no longer differ. bin/lib/ci_test_command.rb " \
                    "describes an asymmetry that has stopped existing."
  end

  # LINKS 2 + 3 — the step prose reasons past.
  #
  # Read only the prerequisite list and rake's `test` task looks like a dead end: it
  # depends on nothing, so nothing invokes `test:prepare` through the graph. True — and
  # irrelevant, because the task's BODY shells out to the rails command that does. Both
  # halves are asserted together so the pair cannot drift apart.
  test "[unit] rake's test task reaches the hook by SPAWNING the argless rails command" do
    assert_empty Rake::Task["test"].prerequisites,
                 "rake's `test` task grew a prerequisite. The mechanism " \
                 "bin/lib/ci_test_command.rb documents (no prerequisite, but a shell-out in " \
                 "the body) is out of date."

    spawned = with_env("TEST" => nil, "TESTOPTS" => nil) { spawn_from_rake_task("test") }

    assert_equal %w[rails test], spawned,
                 "rake's `test` task no longer spawns an argless `rails test`. That spawn is " \
                 "the only route from the rake-routed CI line to Rails' test:prepare hook."
  end

  # LINK 4 — and the reason the explicit test:prepare steps STAY.
  #
  # TestCommand runs the prepare task only when nothing in `self.args` looks like a path
  # or a `-n` filter. Assert the gate on the COMMAND rather than on the regexp alone, so
  # a refactor that keeps the pattern but moves the check still reddens here.
  test "[unit] a path or -n argument suppresses the prepare task the hook rides on" do
    assert_equal ["test:prepare"], prepare_tasks_invoked_by([]),
                 "an argless `rails test` must reach run_prepare_task — that is what builds " \
                 "the CSS for CI and bin/full-suite-check."

    assert_empty prepare_tasks_invoked_by(["test/lib/tasks/test_prepare_asset_hook_test.rb"]),
                 "a path argument must suppress run_prepare_task; if it stopped doing so, " \
                 "bin/ci-shard and bin/fast-check no longer need their explicit test:prepare " \
                 "step and bin/lib/ci_test_command.rb's cell C needs rewriting."

    assert_empty prepare_tasks_invoked_by(["-n", "/some_test/"]),
                 "a -n filter must suppress run_prepare_task, for the same reason."
  end

  # CELL C, at its two source layers.
  #
  # The forwarding is split, and naming the wrong layer is how this paragraph drifted
  # before: the rake `test` task passes `ENV["TEST"]` POSITIONALLY (railties'
  # testing.rake), while `run_from_rake` splices `ENV["TESTOPTS"]` into every spawn it
  # makes (its runner.rb). Either one lands in the argv LINK 4 inspects, so either one
  # silences the hook while the CI line still reads the same.
  test "[unit] ENV TEST and ENV TESTOPTS both reach the argv that suppresses the hook" do
    with_env("TEST" => "test/lib/tasks/test_prepare_asset_hook_test.rb", "TESTOPTS" => nil) do
      assert_equal %w[rails test test/lib/tasks/test_prepare_asset_hook_test.rb],
                   spawn_from_rake_task("test"),
                   "the rake `test` task no longer forwards ENV[\"TEST\"] into the spawned " \
                   "argv, so a TEST= filter on a CI line no longer silences the tailwind hook."
    end

    with_env("TEST" => nil, "TESTOPTS" => "-n /some_test/") do
      assert_equal ["rails", "test", "-n", "/some_test/"], spawn_from_rake_task("test"),
                   "run_from_rake no longer splices ENV[\"TESTOPTS\"] into the spawned argv, " \
                   "so a TESTOPTS= filter on a CI line no longer silences the tailwind hook."
    end

    assert_empty prepare_tasks_invoked_by(["test/lib/tasks/test_prepare_asset_hook_test.rb"]),
                 "the forwarded filter must land in the argv the prepare-task gate reads."
  end

  # The tier the hub's `system` CI job runs, which the `test` task's story does NOT cover.
  #
  # ci.yml's system job is `bin/rails db:test:prepare test:system` — a rake-routed line
  # that names a test task, so it fires the hook too, by a slightly different route:
  # the rake task passes NO argv (so ENV["TEST"] cannot reach it — only TESTOPTS can),
  # and the spawned `rails test:system` command hands `"test/system"` to `perform`
  # WITHOUT it counting as a path, because the gate reads Thor's `self.args`, not the
  # argument the command synthesises for itself.
  test "[unit] test:system also reaches the hook, and ENV TEST cannot silence that line" do
    assert_empty Rake::Task["test:system"].prerequisites,
                 "rake's `test:system` task grew a prerequisite; re-derive how the hub's " \
                 "system CI job reaches test:prepare before trusting this file."

    with_env("TEST" => "test/lib/tasks/test_prepare_asset_hook_test.rb", "TESTOPTS" => nil) do
      assert_equal %w[rails test:system], spawn_from_rake_task("test:system"),
                   "rake's `test:system` task now forwards arguments into its spawn. A TEST= " \
                   "filter on ci.yml's system job would then silence the tailwind hook there " \
                   "too, and that job has no explicit test:prepare step to fall back on."
    end

    assert_equal ["test:prepare"], prepare_tasks_invoked_by([], command: :system),
                 "`rails test:system` no longer reaches run_prepare_task, so ci.yml's system " \
                 "job stopped building app/assets/builds/tailwind.css for itself."
  end

  private
    # Drive the real Rails::Command::TestCommand with `args` as its Thor arguments and
    # report which rake tasks it asked for, with the actual suite run stubbed out.
    def prepare_tasks_invoked_by(args, command: :perform)
      invoked = []
      test_command = Rails::Command::TestCommand.new(args.dup)

      Rails::Command::RakeCommand.stub(:perform, ->(task, *_rest) { invoked << task }) do
        Rails::TestUnit::Runner.stub(:run, ->(*_) { true }) do
          test_command.public_send(command, *args.dup)
        end
      end

      invoked
    end

    # Run the REAL rake task's body — the one railties' testing.rake defines — with only
    # the outbound `system` call stubbed. Reimplementing the body here would assert this
    # file's copy of it instead of the graph the CI line actually walks.
    def spawn_from_rake_task(name)
      spawned = nil
      Rails::TestUnit::Runner.stub(:system, ->(*args) { spawned = args; true }) do
        Rake::Task[name].execute
      end
      spawned
    end

    def with_env(values)
      original = values.keys.to_h { |key| [key, ENV[key]] }
      values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
