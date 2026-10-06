# frozen_string_literal: true

# bin/release plumbing: the mise wrapper, the conductor-lock pin, the sealed child
# env, projects_root / repo_path, target and option flags, confirm, the primary-checkout
# lock paths, and the harness's own self-tests.
#
# Part of the bin/release CLI suite, split by subcommand from the old
# test/lib/release_cli_test.rb (release-cli-tests-by-subcommand, 2026-10-05). The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_core_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliCoreTest < ReleaseCliHarness
  def test_bin_release_wrapper_dispatches_through_mise_with_the_pinned_ruby
    Dir.mktmpdir do |dir|
      fake_mise = File.join(dir, "mise")
      File.write(fake_mise, <<~SH)
        #!/usr/bin/env sh
        printf '%s\\n' "$@"
      SH
      File.chmod(0o755, fake_mise)

      out, err, status = Open3.capture3({ "PATH" => "#{dir}:#{ENV.fetch('PATH', '')}" }, WRAPPER, "merge", "task-a")

      assert status.success?, err
      lines = out.lines.map(&:strip)
      assert_equal "x", lines[0]
      assert_equal "ruby@3.3.11", lines[1]
      assert_equal "--", lines[2]
      assert_equal "ruby", lines[3]
      assert_equal BIN, lines[4]
      assert_equal ["merge", "task-a"], lines[5..]
    end
  end

  def test_bin_release_wrapper_fails_helpfully_without_mise_or_ruby_three
    Dir.mktmpdir do |dir|
      fake_ruby = File.join(dir, "ruby")
      File.write(fake_ruby, <<~SH)
        #!/usr/bin/env sh
        if [ "$1" = "-e" ]; then
          printf '2'
          exit 0
        fi
        echo "unexpected ruby exec" >&2
        exit 99
      SH
      File.chmod(0o755, fake_ruby)

      _out, err, status = Open3.capture3({ "PATH" => "#{dir}:/usr/bin:/bin" }, WRAPPER, "merge", "task-a")

      refute status.success?, "the wrapper must not hand Ruby 3 syntax to Ruby 2"
      assert_includes err, "requires Ruby 3.3.11"
      assert_includes err, "install mise"
    end
  end

  # ── [unit] the conductor's locks live in the operator's real .agents ──────────
  #
  # <projects>/.agents/locks resolves by the same env-else-real-root fallback that
  # leaked the cost store (PR #525) and the narration markers (PR #549). The comment
  # on primary_checkout_lock_path has always SAID every test must pin
  # MCR_PRIMARY_LOCK_DIR — and the stakes are real: a test that flocks the LIVE file
  # while a G3 gate holds it (the gate holds it for its whole suite run) deadlocks the
  # gate against itself. A pin you have to remember is exactly the bug this family is
  # about, so it is now enforced, not requested.
  #
  # The guard aborts BEFORE mkdir_p, so this proves the refusal without creating the
  # real lock dir. `abort` raises SystemExit carrying the message, so the wording is
  # assertable in-process by rescuing that SystemExit.
  def test_unit_an_unpinned_conductor_lock_aborts_instead_of_flocking_the_real_one
    %w[primary_checkout_lock_path gate_workspace_lock_path].each do |helper|
      out = run_ruby_unpinned(<<~RUBY)
        load #{BIN.inspect}
        begin
          #{helper}("mcritchie-studio")
          print "NO_ABORT"
        rescue SystemExit => e
          print "ABORTED|" + e.message.to_s
        end
      RUBY

      assert_match(/\AABORTED\|/, out, "#{helper} must refuse to fall back to the LIVE conductor lock dir")
      assert_match(/sandbox/i, out, "the abort must say WHY")
      assert_match(/MCR_PRIMARY_LOCK_DIR/, out, "and must name the var to pin")
    end
  end

  # The happy path the guard must not break: pinned, the locks still resolve.
  def test_unit_a_pinned_conductor_lock_still_resolves
    path = eval_helper(%(primary_checkout_lock_path("mcritchie-studio")))
    assert_equal self.class.lock_dir, File.dirname(path), "a pinned lock must still land in the pinned dir"
  end

  # Run a bin/release subcommand in a clean subprocess with the given argv (which
  # MUST include --dry-run — DRY/PROD are read from ARGV at load time, so argv is
  # set before `load`). `setup` is extra ruby injected AFTER load (e.g. to stub
  # `conductor` so the shell orchestration runs WITHOUT Rails/a DB), `call` is the
  # entrypoint method to invoke.
  # GUARD THE FLOOR ITSELF. run_ruby's env is the only thing between a case that
  # forgets to stub `sh` and the developer's real `gh` / `heroku` / `op` / `ssh`.
  #
  # DRIVEN THROUGH THE REAL RUNNER, and read from the RECEIPT rather than the env
  # hash. Asserting the env merely NAMES the stub directory would pass against a
  # PATH that still resolves the real binary first — the exact shape of a guard
  # that looks armed and is not. This spawns a child through run_ruby and asserts
  # the stub actually intercepted the call.
  def test_the_child_env_seals_outbound_binaries
    OutboundSeams.reset!
    out = run_ruby(%(system("gh", "--version"); puts "CHILD-DONE"))

    assert_includes out, "CHILD-DONE", "the child must run to completion"
    refute_empty OutboundSeams.calls_to("gh"),
                 "run_ruby's child resolved the REAL `gh`. Its env must come from " \
                 "OutboundSeams.env, not SessionEnv.neutralized — otherwise a case " \
                 "that forgets to stub `sh` reaches the network with the operator's " \
                 "own credentials. Receipts seen: #{OutboundSeams.calls.inspect}"
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

  # The FIXED-PATH TOOLING install (<projects>/.agents/tooling/<sha>/, stamped
  # `.complete` by bin/install-agent-docs). bin/release used to carry its own climb,
  # which read this layout's projects root as <projects>/.agents/tooling — so the
  # siblings, the release lock dir and the task-usage store all pointed nowhere, and a
  # release run from /Users/alex/projects/.agents/bin could not see one from the hub.
  def test_projects_root_climbs_out_of_the_fixed_path_tooling_install
    Dir.mktmpdir do |projects|
      tree = File.join(projects, ".agents", "tooling", "0123abc")
      FileUtils.mkdir_p(tree)
      File.write(File.join(tree, ".complete"), "0123abc\n")
      assert_equal File.realpath(projects), File.realpath(eval_helper(%(projects_root(#{tree.inspect}))))
    end
  end

  # --- target flags: production is the DEFAULT; --local opts out ---

  def test_prod_is_the_default_target
    # The board IS production, so record ops default to prod with no flag.
    assert_equal "true", eval_with_argv([], "PROD")
  end

  def test_local_flag_opts_into_the_stale_local_db
    assert_equal "false", eval_with_argv(["--local"], "PROD")
  end

  def test_legacy_prod_flag_is_a_harmless_noop
    # --prod predates the default flip; it still parses (so old invocations keep
    # working) but no longer changes anything — and it's consumed from ARGV so a
    # subcommand parser never sees it.
    assert_equal "true", eval_with_argv(["--prod"], "PROD")
    assert_equal "false", eval_with_argv(["--prod"], "ARGV.include?('--prod')")
  end

  def test_repo_path_resolves_a_sibling_never_inside_worktrees
    # repo_path uses projects_root's default (the running script's own app root),
    # so the path lands a sibling next to the hub and never under .worktrees —
    # whether bin/release runs from a primary checkout or a worktree.
    out = eval_helper(%(repo_path("turf-monster")))
    assert out.end_with?("/turf-monster"), out
    refute_includes out, "/.worktrees/", "repo_path must climb out of .worktrees"
  end

  # --- ARGV parsing via Release::Cli (extracted from this CLI) ---
  # These drive the REAL bin/release wrappers in a clean, Rails-free subprocess,
  # proving the require_relative wiring loads standalone and each flag is consumed
  # from ARGV exactly as the old inline parsers did — the boundary the CLI relies
  # on every run.

  def test_bin_release_loads_release_cli_standalone
    # The extracted module must be reachable after a plain `ruby` load (no Rails).
    assert_equal "true", eval_helper("defined?(Release::Cli) ? 'true' : 'false'")
  end

  def test_opt_value_is_parsed_through_release_cli_across_the_bin_boundary
    # load consumes --dry-run at load time; --by survives for opt_value to pull.
    out = eval_with_argv(["ship", "--dry-run", "--by", "carl"], "opt_value('--by')")
    assert_equal "carl", out
  end

  def test_opt_values_collects_repeated_flags_through_the_bin_boundary
    out = eval_with_argv(["prepare", "--dry-run", "--task", "t-a", "--task", "t-b"],
                         "opt_values('--task').inspect")
    assert_equal '["t-a", "t-b"]', out
  end

  def test_unparsed_flag_returns_nil_through_the_bin_boundary
    assert_equal "", eval_with_argv(["ship", "--dry-run"], "opt_value('--by').to_s")
  end

  def test_confirm_aborts_on_a_non_interactive_shell
    # No --yes / --dry-run, so confirm reaches the TTY check; abort! raises
    # SystemExit and we surface its message (abort writes to the discarded stderr,
    # but SystemExit#message carries the text) to assert the loud, helpful abort.
    out = run_cli([], setup: NON_TTY_STDIN,
                  call: "begin; confirm('Proceed?'); puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a non-TTY confirm must abort, not silently return false"
    assert_includes out, "non-interactive shell", "the abort names the cause"
    assert_includes out, "--yes", "the abort points at the --yes escape hatch"
    refute_includes out, "NO-ABORT", "confirm must not fall through to a return value on a non-TTY"
  end

  def test_confirm_aborts_on_eof_even_with_a_tty
    out = run_cli([], setup: TTY_EOF_STDIN,
                  call: "begin; confirm('Proceed?'); puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "EOF on stdin must abort, never fold into a false 'no'"
    assert_includes out, "EOF on stdin", "the abort names EOF as the cause"
    refute_includes out, "NO-ABORT"
  end

  def test_confirm_yes_flag_bypasses_the_prompt_without_touching_stdin
    # --yes short-circuits to true BEFORE the TTY check — the stub's tty?/gets raise
    # if consulted, proving the hands-off bypass never reads stdin.
    setup = %($stdin = (o = Object.new; def o.tty?; raise 'tty? consulted under --yes'; end; def o.gets; raise 'gets consulted under --yes'; end; o))
    out = run_cli(["--yes"], setup: setup, call: "print(confirm('Proceed?'))")

    assert_equal "true", out, "--yes returns true without prompting or reading stdin (hands-off bypass preserved)"
  end

  def test_confirm_dry_run_also_bypasses_the_prompt
    # --dry-run likewise returns true without consulting stdin (previews execute nothing).
    setup = %($stdin = (o = Object.new; def o.tty?; raise 'tty? consulted under --dry-run'; end; o))
    out = run_cli(["--dry-run"], setup: setup, call: "print(confirm('Proceed?'))")

    assert_equal "true", out, "--dry-run returns true without prompting"
  end

  # [unit] REGRESSION (activity-1307): every subprocess this file spawns must
  # resolve the primary-checkout lock INSIDE the per-run isolated dir — never
  # the real conductor dir. A live G3 gate holds the real hub lock while its
  # suite runs THIS file; one child flocking the real path wedges `bin/release
  # prepare` against its own suite, indefinitely and silently. This pins the
  # run_ruby seam every helper (run_cli / eval_helper) rides through.
  def test_release_subprocesses_resolve_the_lock_inside_the_isolated_dir
    out = eval_helper(%(primary_checkout_lock_path("mcritchie-studio").start_with?(#{self.class.lock_dir.inspect}).inspect))
    assert_equal "true", out,
                 "children must inherit the isolated MCR_PRIMARY_LOCK_DIR, not the live conductor's lock dir"
  end

  # [unit] The DEFAULT lock dir (no override) anchors to <projects_root>/
  # .agents/locks — TMPDIR-independent, so two conductors launched with
  # different TMPDIR values contend on the SAME file (round-2 review nit).
  # Asserted on the PURE resolver, not the guarded seam. This test used to delete
  # MCR_PRIMARY_LOCK_DIR and call primary_checkout_lock_path — which mkdir_p's the dir
  # — so proving "the default is <projects>/.agents/locks" CREATED the operator's real
  # <projects>/.agents/locks, on every suite run. A test that has to perform the write
  # it is describing in order to describe it is the leak, not the proof.
  def test_primary_checkout_lock_dir_defaults_to_projects_root_agents_locks
    out = run_cli(["--yes"], setup: %(ENV.delete("MCR_PRIMARY_LOCK_DIR")),
                  call: %{print((primary_checkout_lock_dir == File.join(projects_root, ".agents", "locks")).inspect)})
    assert_equal "true", out
  end

  # And the FILENAME shape, through the guarded seam with the pin on (run_ruby pins it).
  def test_primary_checkout_lock_path_is_named_per_repo
    out = eval_helper(%(File.basename(primary_checkout_lock_path("x"))))
    assert_equal "mcr-primary-checkout-x.lock", out
  end

  # --- the GATE-WORKSPACE lock: the workspace is private to the CONDUCTOR -------
  #
  # BLOCKER (Avi, review of PR #511): the first cut of this change asserted the gate
  # workspace needed no lock ("nothing else touches this tree"). FALSE — another
  # `bin/release` does. The workspace PATH (<repo>/.worktrees/_gate) and its DB
  # (<repo>_gate_test) are FIXED, and two concurrent conductors are a DOCUMENTED
  # occurrence here (two QA-release sessions have already raced). Unlocked, conductor
  # B's `reset --hard` moves the tree and its `db:test:prepare` PURGES the DB under
  # conductor A's live, lazily-autoloading suite — the exact two root causes this gate
  # exists to close, relocated one directory over (plus the parallel-full-suite
  # SIGSEGV class).
  #
  # So the gate holds its OWN flock across pin → prepare → suite. It is deliberately
  # NOT the primary-checkout lock: the primary must stay FREE (feature sessions live
  # there, and monopolising it for the length of a suite was half of what made the old
  # gate hostile), and the two are never nested, so they cannot deadlock.

  # [unit] The gate lock is its OWN file, in the SAME shared lock dir (TMPDIR-
  # independent, so two conductors contend on one file) — never the primary's. If
  # these two ever resolved to the same path the gate would hold the primary hostage
  # for its whole suite again, which is the shape this change exists to retire.
  # Same split as above: the SHARED dir is asserted on the pure resolver (no IO), the
  # per-role filenames through the guarded seam with the pin on. Both locks live in
  # one dir on purpose — see guarded_lock_dir.
  def test_gate_workspace_lock_path_is_a_separate_file_from_the_primary_checkout_lock
    expr = '[gate_workspace_lock_path("x") != primary_checkout_lock_path("x"), ' \
           'File.basename(gate_workspace_lock_path("x")), ' \
           'File.dirname(gate_workspace_lock_path("x")) == File.dirname(primary_checkout_lock_path("x"))].inspect'
    out = eval_helper(expr)

    assert_equal %([true, "mcr-gate-workspace-x.lock", true]), out
  end

  # [unit] the pin that keeps this file off the production board, asserted rather
  # than trusted — a pin you have to remember is the bug it is closing.
  def test_unit_this_suites_subprocesses_never_point_at_the_production_board
    base = run_ruby(%(print(ENV.fetch("TASK_API_BASE", "UNSET"))))

    refute_includes base, "mcritchie.studio", "a subprocess of this suite must never resolve the LIVE board"
    assert_match(%r{\Ahttp://127\.0\.0\.1:}, base, "…it is pinned at an unroutable loopback base instead")
  end

  # --- regression: the silent swallowed-subprocess flake ------------------------
  #
  # A subprocess that EXITS NONZERO must fail LOUD with its stderr surfaced — it
  # must never slip through as a bare `Actual: ""` (how the original
  # agent_worktree_test CI flake masqueraded, because the old
  # `IO.popen(err: File::NULL)` helper discarded stderr + exit status). We force
  # that mode deterministically: a script that writes to stderr and exits nonzero
  # on every attempt. The old helper returned "" silently (no raise) and would fail
  # THIS assertion; the hardened run_ruby flunks with the stderr included.
  def test_run_ruby_flunks_loudly_when_subprocess_exits_nonzero
    error = assert_raises(Minitest::Assertion) do
      run_cli([], call: "STDERR.puts 'forced-subprocess-failure'; exit 1")
    end
    assert_match(/forced-subprocess-failure/, error.message,
                 "the swallowed subprocess stderr must surface in the failure message")
    assert_match(/exited nonzero/, error.message)
    assert_match(/exit=1/, error.message, "the captured exit status is reported")
  end

  # The GENTLER half of the guard: a CLEAN exit with EMPTY stdout is a VALID
  # result, NOT a flake. This is the canary for over-guarding — it must return ""
  # without retrying or flunking, mirroring
  # test_unparsed_flag_returns_nil_through_the_bin_boundary at the helper level.
  def test_run_ruby_returns_empty_stdout_on_a_clean_exit_without_flunking
    assert_equal "", run_cli([], call: "print('')"),
                 "empty stdout with a zero exit is a legitimate, returnable result"
  end
end
