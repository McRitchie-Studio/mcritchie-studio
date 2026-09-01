# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require Rails.root.join("bin", "lib", "agent_worktree_cli").to_s

# [integration] bin/agent-worktree's ARGUMENT GUARD, driven through the REAL script
# and proven BY RECEIPT — a pinned spy that stays silent, beside a control that
# lights the same spy up.
#
# THE DEFECT (/tasks/worktree-subcommand-drops-help). The dispatcher did
# `cmd = ARGV.shift || "help"` and no arm validated what was left, so
#
#     bin/agent-worktree new <app> <task> --help
#
# CREATED A REAL DESK: `git worktree add -b`, a port and a Redis DB written into
# `.env.agent-stack`, the `.agent-context.json` marker, and a Postgres database from
# prepare_test_env. The `new` arm did not merely ignore the flag — it destructured
# `app_name, raw_task, maybe_type, *rest = ARGV` and then chose the branch type with
# `maybe_type&.start_with?("--") ? "feat" : ...`, so `--help` was RECOGNISED as
# flag-shaped and thrown away on purpose, while `*rest` was never inspected at all.
# Four more arms were reachable the same way: `bind-task … --help` wrote the stack
# env and marker, `up … --help` STARTED the stack, `status … --help` wrote the
# marker, and `scale out --help` GREW the persisted Redis band.
#
# WHY THIS FILE NEVER RUNS THE PROBE. The thing under test allocates a worktree, a
# port, a Redis DB and a Postgres database when probed, so "run it and see" is the
# one experiment that must never be performed: if the guard has regressed, the probe
# IS the allocation. config/test_health.yml already records what the cheaper version
# of this mistake cost — two under-stubbed tests once ran bin/clean-artifacts and
# bin/archive-docs FOR REAL against a developer's machine. So the verdict is proven
# three ways, none of which can create a desk:
#
#   1. THE REAL METHOD, DRIVEN DIRECTLY. A bare ruby subprocess `load`s
#      bin/agent-worktree — which does NOT dispatch when it is not $PROGRAM_NAME —
#      and calls `guard_argv!` with an injected exiter. That is the production
#      method reading the production dictionary (AgentWorktreeCli::COMMANDS), with
#      the `case` statement never reached.
#
#   2. ONE REAL EXECUTION, of a subcommand that CANNOT mutate. `bin/agent-worktree
#      apps` reads config/satellites.yml and prints the registry — no git, no
#      Postgres, no Redis, no network, no write. Its `--help` form is the sharpest
#      probe in the file because the arm reads no argv at all: unguarded, `apps
#      --help` prints the whole registry, so an EMPTY stdout is a direct measurement
#      that the guard ran.
#
#   3. A PINNED SPY, WITH A CONTROL. `list <app>` shells git once per desk
#      (stack_record → base_ref_for → git_ahead_behind). With PROJECTS_DIR pinned
#      into a throwaway sandbox holding one desk-shaped directory, and a `git` on
#      PATH that only appends its argv to a log, the guarded probe leaves NO LOG
#      FILE AT ALL — while the identical line without `--help` fills it. Without
#      that control, "the log is empty" and "the spy was never wired" are the same
#      observation, which is exactly how a green manifest once certified a fully
#      unguarded script (finding-e429a953ff23): with the guard's CALL deleted and
#      its definition intact, test/lib/bin_help_flag_class_test.rb passed 16 runs,
#      209 assertions, 0 failures.
#
#   bin/rails test test/integration/agent_worktree_argv_guard_test.rb
class AgentWorktreeArgvGuardTest < ActionDispatch::IntegrationTest
  WORKTREE = Rails.root.join("bin", "agent-worktree")

  # bin/agent-worktree is plain Ruby with NO bundler — every probe below runs it the
  # way an operator's shell does. Inheriting the suite's RUBYOPT would re-enter
  # bundler in the child and bury the verdict under a page of warnings.
  BARE = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def bare_env(extra = {}) = SessionEnv.neutralized(BARE.merge(extra))

  # Drive the REAL `guard_argv!` for each command line, in a subprocess that loads
  # bin/agent-worktree WITHOUT dispatching. Returns one result hash per line:
  #   exit — the code the guard exited with, or "returned" when it let the
  #          dispatcher proceed (a clean line, or a token that is not a subcommand)
  def guard(*command_lines)
    script = <<~RUBY
      require "json"
      require "stringio"
      # `load`, not `require`: the file has no .rb extension. It does not dispatch,
      # because __FILE__ is this path and $PROGRAM_NAME is the -e script.
      load #{WORKTREE.to_s.inspect}

      results = #{JSON.dump(command_lines)}.map do |argv|
        out = StringIO.new
        err = StringIO.new
        code = "returned"
        catch(:guarded) do
          guard_argv!(argv, out: out, err: err, exiter: ->(c) { code = c; throw :guarded, c })
        end
        { "argv" => argv, "exit" => code, "out" => out.string, "err" => err.string }
      end
      puts JSON.dump(results)
    RUBY

    out, status = Open3.capture2(bare_env, RbConfig.ruby, "-e", script)
    assert status.success?, "the guard probe itself failed to run:\n#{out}"
    JSON.parse(out.lines.last)
  end

  def one(argv) = guard(argv).first

  # --- 1. the real method, dispatcher never reached ---------------------------

  # THE regression, driven through the production guard. The five probes the task
  # record measured at source as reaching a durable write.
  MEASURED_PROBES = {
    %w[new mcritchie-studio some-task --help] =>
      /NO worktree, branch, port, Redis DB, Postgres database/,
    %w[bind-task mcritchie-studio some-task some-slug --help] =>
      /the task was NOT bound/,
    %w[up mcritchie-studio some-task --help] =>
      /NO stack was started/,
    %w[status mcritchie-studio some-task --help] =>
      /NO context marker was written/,
    %w[scale out --help] =>
      /persisted Redis band was NOT changed/
  }.freeze

  test "every measured mutating probe answers help and allocates nothing" do
    MEASURED_PROBES.each do |argv, consequence|
      result = one(argv)

      assert_equal 1, result["exit"],
                   "bin/agent-worktree #{argv.join(' ')} must answer help with 1 — never 0, which " \
                   "bin/task begin reads as \"the worktree was created\""
      assert_match consequence, result["err"],
                   "the operator's question after a refused probe is whether the desk was created"
      assert_empty result["out"],
                   "a non-zero answer must not print to stdout as though it succeeded — " \
                   "`shell-hook zsh` is consumed as eval \"$(...)\" from the login shell"
    end
  end

  # Every subcommand, both help spellings, from a position AFTER a real argument —
  # the position the old dispatcher dropped.
  test "every subcommand answers help in trailing position without acting" do
    AgentWorktreeCli::COMMANDS.each_key do |cmd|
      %w[--help -h].each do |flag|
        result = one([cmd, "mcritchie-studio", flag])

        assert_equal 1, result["exit"],
                     "bin/agent-worktree #{cmd} mcritchie-studio #{flag} must answer help"
      end
    end
  end

  test "an argument no subcommand accounts for refuses with exit 2" do
    result = one(%w[new mcritchie-studio some-task --force])

    assert_equal 2, result["exit"]
    assert_match(/unrecognized argument "--force"/, result["err"])
    assert_match(/NO worktree, branch, port/, result["err"])
  end

  # A flag listed on ANOTHER subcommand is still unaccounted-for here. This is the
  # silent no-op half of the defect: `up <app> <task> --yes` used to be accepted and
  # do nothing, so an operator who believed `--yes` meant something was wrong and
  # never told.
  test "a flag that belongs to a different subcommand refuses" do
    assert_equal 2, one(%w[up mcritchie-studio some-task --yes])["exit"]
    assert_equal 2, one(%w[list mcritchie-studio --write])["exit"]
    assert_equal 2, one(%w[apps mcritchie-studio])["exit"]
  end

  # The other half, and the one that wedges every lane if it is wrong: the real
  # calls must still be handed to the dispatcher. bin/task:1869 shells `new` and
  # `bind-task` on EVERY `bin/task begin`; bin/release.rb shells `restore-primary`
  # and `cleanup --reclaim --yes` on every ship; bin/qa-intake shells
  # `snapshot --write` on every refresh.
  test "the documented invocations are still handed to the dispatcher" do
    lines = [
      %w[apps],
      %w[list],
      %w[list mcritchie-studio],
      %w[plan turf-monster button-color],
      %w[plan turf-monster button-color feat],
      %w[new mcritchie-studio button-color],
      %w[new turf-monster button-color feat],
      %w[new turf-monster button-color --start],
      %w[bind-task mcritchie-studio button-color https://mcritchie.studio/tasks/button-color],
      %w[env mcritchie-studio button-color],
      %w[up mcritchie-studio button-color],
      %w[test mcritchie-studio button-color],
      %w[status mcritchie-studio button-color],
      %w[whereami],
      %w[whereami mcritchie-studio button-color --json],
      %w[whereami --shell],
      %w[shell-hook zsh],
      %w[finish mcritchie-studio button-color --push --pr],
      %w[restore-primary mcritchie-studio --dry-run],
      %w[doctor],
      %w[doctor studio-engine],
      %w[snapshot --write],
      %w[cleanup],
      %w[cleanup --reclaim --yes],
      %w[cleanup mcritchie-studio --write],
      %w[remove mcritchie-studio button-color --yes],
      %w[remove mcritchie-studio button-color --force --yes],
      %w[down mcritchie-studio button-color],
      %w[sweep-orphan-dbs],
      %w[sweep-orphan-dbs --yes],
      %w[scale],
      %w[scale status],
      %w[scale out],
      %w[scale --provision --yes]
    ]

    guard(*lines).each do |result|
      assert_equal "returned", result["exit"],
                   "bin/agent-worktree #{result['argv'].join(' ')} is a REAL documented call — a " \
                   "guard that refuses it wedges bin/task begin, the ship, or the QA intake"
    end
  end

  # A token that is not a subcommand stays the dispatcher's `else` to answer, as it
  # always did — that path was never the defect.
  test "a bare help flag falls through to the dispatchers own usage" do
    assert_equal "returned", one(%w[--help])["exit"]
    assert_equal "returned", one(%w[not-a-subcommand])["exit"]
  end

  # --- the ONE forwarding arm --------------------------------------------------

  # `test <app> <task> [-- rails-test-args]` hands its tail to `bin/rails test`, so
  # the tail is minitest's to account for and NOT this script's. Guarding it with the
  # dictionary would refuse `-n /pattern/` and `--` itself and wedge the documented
  # form — a top-level guard wearing a per-arm guard's clothes.
  test "the test arm forwards its tail untouched" do
    [
      %w[test mcritchie-studio button-color test/models/x_test.rb],
      %w[test mcritchie-studio button-color -- -n /pattern/],
      %w[test mcritchie-studio button-color --seed 1234]
    ].each do |argv|
      assert_equal "returned", one(argv)["exit"],
                   "bin/agent-worktree #{argv.join(' ')} forwards to bin/rails test — the guard " \
                   "must not answer for a tool downstream of it"
    end
  end

  # …but it still answers the help probe itself, because that is the defect: the arm
  # reached clear_orphan_test_procs (which SIGKILLs matching processes) and
  # prepare_test_env (which CREATES the desk's Postgres test database and builds the
  # Tailwind bundle) before ever shelling bin/rails.
  test "the test arm still answers a help probe before it prepares anything" do
    result = one(%w[test mcritchie-studio button-color --help])

    assert_equal 1, result["exit"]
    assert_match(/NO test database was prepared/, result["err"])
  end

  # --- 2. the real script: apps --help prints nothing --------------------------

  # `apps` is the sharpest real-execution probe in the file, because the arm reads
  # NO argv: unguarded, `apps --help` prints the entire registry. An empty stdout is
  # therefore a direct measurement that the guard ran, not an inference.
  test "the real script answers apps --help without listing the registry" do
    out, err, status = Open3.capture3(bare_env, WORKTREE.to_s, "apps", "--help")

    assert_equal 1, status.exitstatus, "help exits 1 from the real script"
    assert_match(%r{bin/agent-worktree apps}, err)
    assert_empty out.strip, "the registry was NOT printed — the arm never ran"
  end

  # THE CONTROL for the assertion above. Without it, "stdout was empty" and "the
  # script is broken" are the same observation.
  test "the real script still runs its read-only subcommand" do
    out, _err, status = Open3.capture3(bare_env, WORKTREE.to_s, "apps")

    assert_predicate status, :success?, "bin/agent-worktree apps must still work"
    assert_match(/mcritchie-studio/, out, "the registry is still printed")
  end

  test "the real script refuses an unknown argument on its read-only subcommand" do
    out, err, status = Open3.capture3(bare_env, WORKTREE.to_s, "list", "--force")

    assert_equal 2, status.exitstatus
    assert_match(/unrecognized argument/, err)
    assert_empty out.strip, "nothing was listed"
  end

  # --- 3. the pinned spy, and its control --------------------------------------

  # `list <app>` shells git once per desk (stack_record → base_ref_for →
  # git_ahead_behind). Pinning PROJECTS_DIR into a sandbox with ONE desk-shaped
  # directory and putting a recording `git` first on PATH turns "did the guard stop
  # the script before it acted?" into a file that either exists or does not.
  #
  # `list <app> --help` is the right pair for this because, UNGUARDED, the flag is
  # simply ignored — ARGV[0] is the app slug, so the arm runs in full and reaches
  # git. Deleting the guard's CALL therefore turns the probe into the control, which
  # is precisely the mutation a static position assertion cannot see.
  def with_spied_git
    Dir.mktmpdir("agent-worktree-argv-guard") do |sandbox|
      desk = File.join(sandbox, "projects", "mcritchie-studio", ".worktrees", "probe-desk")
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".env.agent-stack"), "APP_PORT=3999\n")

      bin = File.join(sandbox, "bin")
      FileUtils.mkdir_p(bin)
      log = File.join(sandbox, "git-spy.log")
      File.write(File.join(bin, "git"), <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{log}"
        exit 0
      SH
      FileUtils.chmod("+x", File.join(bin, "git"))

      env = bare_env(
        "PROJECTS_DIR" => File.join(sandbox, "projects"),
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}"
      )
      yield env, log
    end
  end

  test "a guarded probe never reaches a subprocess, and the same line without the flag does" do
    with_spied_git do |env, log|
      _out, _err, status = Open3.capture3(env, WORKTREE.to_s, "list", "mcritchie-studio", "--help")

      assert_equal 1, status.exitstatus
      refute File.exist?(log),
             "the guarded probe spawned git — the guard is defined but not in the script's path"
    end

    # THE CONTROL, in its own sandbox so the two receipts cannot contaminate each
    # other: the identical command line MINUS the flag must light the spy up.
    with_spied_git do |env, log|
      Open3.capture3(env, WORKTREE.to_s, "list", "mcritchie-studio")

      assert File.exist?(log),
             "the spy never fired even on the UNGUARDED line — an empty log would then " \
             "prove nothing, which is the whole reason this control exists"
      refute_empty File.read(log).strip
    end
  end
end
