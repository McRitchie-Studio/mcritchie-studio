# frozen_string_literal: true

# Standalone test for bin/release's launcher plus bin/release.rb's pure helpers
# (no Rails needed — it `load`s the Ruby implementation in a subprocess so the
# guarded dispatch never fires and the test process's top-level namespace stays
# clean). Run directly:
#   ruby -Itest test/lib/release_cli_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# The git + qa-server orchestration in bin/release is shell-only and is verified
# via `bin/release {init,prepare} --dry-run` (below); this also covers the one
# piece of pure logic — .worktrees-aware sibling-repo path resolution
# (projects_root / repo_path).

require "minitest/autorun"
require "shellwords"
require "open3"
require "tmpdir"
# Several payload tests decode/parse the runner snippet (JSON + url-safe Base64).
# Require both here so they don't depend on test seed order (a prior test having
# pulled them in first) — without this, a seed that runs a payload test before any
# json-requiring test errored with `uninitialized constant JSON`.
require "json"
require "base64"

class ReleaseCliTest < Minitest::Test
  WRAPPER = File.expand_path("../../bin/release", __dir__)
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # How many times to re-spawn a helper whose subprocess EXITED NONZERO / was
  # killed before we treat it as a genuine failure. Each helper drives the same
  # deterministic CLI logic (it `load`s the static script and prints a pure value),
  # so a nonzero/killed spawn is a transient worth retrying — see run_ruby.
  SUBPROCESS_ATTEMPTS = 3

  # Run `ruby -e script` in a clean subprocess and return its stdout.
  #
  # `load`ing bin/release defines the script's helpers WITHOUT dispatching a
  # command (it's guarded on __FILE__ == $PROGRAM_NAME), so each caller exercises
  # the real CLI logic in isolation and `print`s a deterministic value.
  #
  # The old helpers used `IO.popen([..., { err: File::NULL }], &:read)`, which
  # discarded BOTH the child's stderr AND its exit status. Under CI's parallel-fork
  # harness a child occasionally got reaped/killed before flushing stdout, and with
  # the status thrown away that transient surfaced as a bare, undiagnosable
  # empty-output assertion failure — the identical flake hardened in
  # agent_worktree_test.rb (PR #186).
  #
  # GENTLER than the #186 guard on purpose: there every check returned non-empty,
  # so flunk-on-empty-stdout was safe; HERE it is not —
  # test_unparsed_flag_returns_nil_through_the_bin_boundary LEGITIMATELY asserts
  # "" (empty output is the correct result). So we key the guard on EXIT STATUS,
  # never on emptiness:
  #   * Open3.capture3 blocking-reads stdout AND stderr and waits for the child to
  #     exit — no early-read / unflushed-output race.
  #   * A CLEAN exit is authoritative: return its stdout as-is (empty or not).
  #   * ONLY a nonzero exit / signal (the spawn transient, or a genuine load error)
  #     is retried up to SUBPROCESS_ATTEMPTS; a real error exits nonzero on every
  #     attempt, so the retry cannot mask a regression.
  #   * If every attempt exits nonzero it FLUNKS with the captured exit/signal +
  #     stderr, so the swallowed-failure mode can never again recur silently.
  #     (rubygems "already initialized" warnings land on the child's stderr but are
  #     ignored on success — stderr is only surfaced when flunking.)
  # Null the ambient agent-session vars for every release subprocess. A live
  # Claude/Codex session exports CLAUDE_CODE_SESSION_ID / CODEX_THREAD_ID, which the
  # subprocess would otherwise inherit — making bin/release's best-effort deploy-lane
  # narration (atomic_event) resolve a real session and shell out to bin/atomic-event
  # mid-test. Neutralizing them keeps narration inert unless a test opts in (the
  # deploy-span tests stub atomic_event directly). Tests that need a session set it
  # inline via ENV[...] (see the with_conductor_session tests).
  NEUTRALIZED_ENV = { "CLAUDE_CODE_SESSION_ID" => nil, "CODEX_THREAD_ID" => nil }.freeze

  def run_ruby(script)
    last = nil
    SUBPROCESS_ATTEMPTS.times do
      out, err, status = Open3.capture3(NEUTRALIZED_ENV, "ruby", "-e", script)
      return out if status.success?

      last = { out: out, err: err, status: status }
    end

    status = last[:status]
    flunk <<~MSG
      bin/release subprocess exited nonzero after #{SUBPROCESS_ATTEMPTS} attempts.
        exit=#{status.exitstatus.inspect} signal=#{status.termsig.inspect}
        stdout=#{last[:out].inspect}
        stderr:
      #{last[:err].to_s.gsub(/^/, "    ")}
    MSG
  end

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

  # Evaluate a bin/release helper in a clean subprocess (see run_ruby).
  def eval_helper(expr)
    run_ruby(%(load #{BIN.inspect}; print(#{expr})))
  end

  # Like eval_helper, but sets ARGV BEFORE load so the DRY/PROD/ASSUME_YES
  # constants (read from ARGV at load time) reflect the given flags.
  def eval_with_argv(argv, expr)
    run_ruby(%(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; print(#{expr})))
  end

  # Run a bin/release subcommand in a clean subprocess with the given argv (which
  # MUST include --dry-run — DRY/PROD are read from ARGV at load time, so argv is
  # set before `load`). `setup` is extra ruby injected AFTER load (e.g. to stub
  # `conductor` so the shell orchestration runs WITHOUT Rails/a DB), `call` is the
  # entrypoint method to invoke.
  def run_cli(argv, call:, setup: "")
    run_ruby(%(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{setup}; #{call}))
  end

  # A canned multi-repo deploy plan (gem + two apps) so `prepare` exercises the
  # real shell orchestration without touching Rails or the DB.
  STUB_CONDUCTOR = <<~RUBY
    def conductor(ruby, read_only: false)
      # prepare's detection read: nothing new to sweep, an active RC in flight —
      # the self-healing re-run shape, so the deploy half previews the plan below.
      return { "tasks" => [], "release" => { "slug" => "rel-cli", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
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

  # --- confirm: a non-interactive shell ABORTS loudly (never a silent no-op) ---
  # The old `$stdin.gets.to_s.strip.casecmp("y").zero?` returned FALSE on EOF, so
  # `prepare` (return unless confirm) silently no-op'd on a non-TTY — "looked like
  # it ran but nothing deployed". confirm now aborts on a non-TTY / EOF so prepare
  # fails VISIBLY like ship/archive already do, while --yes still bypasses the gate.

  # Stub $stdin so the (subprocess) confirm sees a non-interactive shell
  # deterministically (the test runner's real stdin may or may not be a TTY).
  NON_TTY_STDIN = %($stdin = (o = Object.new; def o.tty?; false; end; def o.gets; nil; end; o))
  # A TTY whose read immediately hits EOF (Ctrl-D) — tty? true, gets nil.
  TTY_EOF_STDIN = %($stdin = (o = Object.new; def o.tty?; true; end; def o.gets; nil; end; o))

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

  # A release with a registered app that has NO qa_environments.yml entry
  # (tax-studio): prepare must WARN + skip its QA deploy, not abort the release.
  ELIGIBILITY_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-cli", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      { "slug" => "rel-elig", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
          "members" => [{ "slug" => "t-studio", "branch" => "feat/studio" }] },
        { "repo" => "tax-studio", "kind" => "app", "qa_app" => "tax-studio",
          "members" => [{ "slug" => "t-tax", "branch" => "feat/tax" }] }
      ] }
    end
  RUBY

  def test_prepare_dry_run_warns_and_skips_an_app_with_no_qa_environment
    out = run_cli(["--dry-run"], call: "prepare", setup: ELIGIBILITY_STUB)

    assert_includes out, "tax-studio: no QA environment registered",
                     "a registered app with no qa_environments.yml entry must warn"
    refute_includes out, "bin/qa-server deploy tax-studio",
                     "an app with no QA env is skipped, not deployed"
    # a properly registered app on the same release still deploys
    assert_includes out, "bin/qa-server deploy mcritchie-studio origin/release"
  end

  # --- prepare: the self-healing sweep (detect → merge/skip → record → flip) ---

  # Detection returns NOTHING and no release is active → the idempotent no-op.
  NOOP_PREP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      { "tasks" => [], "release" => nil, "screen" => {} }
    end
  RUBY

  def test_prepare_is_an_idempotent_noop_when_nothing_is_detected_and_nothing_active
    out = run_cli(["--yes"], call: "prepare; puts('CLEAN-EXIT')", setup: NOOP_PREP_STUB)

    assert_includes out, "Nothing to prepare", "an empty queue reports, never fabricates work"
    assert_includes out, "idempotent no-op"
    assert_includes out, "CLEAN-EXIT", "the no-op exits zero (schedule-ready)"
    refute_includes out, "bin/qa-server deploy", "nothing deploys on a no-op"
  end

  # A full self-healing sweep: one fresh candidate (gh merge needed), one already
  # merged (crash-recovery skip), one with no PR (left behind, warning only).
  SWEEP_FLOW_STUB = <<~'RUBY'
    def repo_path(_repo) = Dir.pwd
    def conductor(ruby, read_only: false)
      if ruby.include?("sweep_candidates")
        { "tasks" => [
            { "slug" => "task-new", "stage" => "reviewed", "merged" => "", "pr_url" => "https://gh/pr/9", "repo" => "mcritchie-studio" },
            { "slug" => "task-swept", "stage" => "reviewed", "merged" => "release", "pr_url" => "https://gh/pr/8", "repo" => "mcritchie-studio" },
            { "slug" => "task-naked", "stage" => "reviewed", "merged" => "", "pr_url" => "", "repo" => "mcritchie-studio" }
          ],
          "release" => nil,
          "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      elsif ruby.include?("sweep!")
        $stdout.puts("SWEEP-CALL " + ruby.gsub("\n", " "))
        { "slug" => "rel-sweep", "state" => "assembling", "swept" => %w[task-swept task-new], "repos" => [
          { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
            "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "task-new", "branch" => "feat/n" }] }
        ] }
      elsif ruby.include?("qa_green!")
        $stdout.puts("QA-GREEN-CALL")
        { "state" => "assembled" }
      else
        {}
      end
    end
    def sh(*a, **_k)
      return ["release", true] if a.include?("baseRefName")
      if a[0] == "gh" && a.include?("merge")
        $stdout.puts("GH-MERGE " + a.find { |x| x.to_s.start_with?("https") }.to_s)
        return ["", true]
      end
      return ["200", true] if a.join(" ").include?("curl")
      ["", true]
    end
    def gh_pr_files(_pr) = []
  RUBY

  def test_prepare_sweeps_the_detected_queue_with_the_crash_recovery_skip
    out = run_cli(["--yes"], call: "prepare", setup: SWEEP_FLOW_STUB)

    # The crash-recovery skip: the already-merged PR is NEVER re-merged.
    assert_includes out, "skip gh pr merge for task-swept — already merged: release"
    assert_equal 1, out.scan("GH-MERGE").size, "only the fresh PR gh-merges"
    assert_includes out, "GH-MERGE https://gh/pr/9"
    refute_includes out, "GH-MERGE https://gh/pr/8", "the merged: release PR skips the gh merge"

    # The unmergeable task is warned + left reviewed — never an abort in prepare.
    assert_includes out, "task-naked: no PR url"
    assert_includes out, "left `reviewed` for a later sweep"

    # ONE batched record write sweeps skip + fresh (not the naked one).
    assert_equal 1, out.scan("SWEEP-CALL").size, "the sweep records in ONE heroku run"
    sweep = out.lines.find { |l| l.start_with?("SWEEP-CALL") }
    assert_includes sweep, "task-swept"
    assert_includes sweep, "task-new"
    refute_includes sweep, "task-naked", "nothing to merge and nothing merged → not swept"

    # QA booted green → the QA-green flip fires and the RC assembles.
    assert_equal 1, out.scan("QA-GREEN-CALL").size, "QA-green flips the swept members via qa_green!"
    assert_includes out, "Assembled rel-sweep"
  end

  def test_prepare_dry_run_previews_the_sweep_without_recording
    out = run_cli(["--dry-run"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "sweep task-new (reviewed)", "the dry run previews the detected sweep"
    assert_includes out, "skip gh pr merge for task-swept — already merged: release"
    refute_includes out, "SWEEP-CALL", "a dry run records nothing"
    refute_includes out, "QA-GREEN-CALL", "a dry run flips nothing"
  end

  # --task names a slug detection DROPPED (typo, or neither `reviewed` nor an
  # assembled straggler): the filter runs BEFORE the review-gate screen, so
  # without the loud fail the slug vanished silently and the run could still end
  # "✓". prepare must abort BEFORE any merge or deploy.
  def test_prepare_task_flag_fails_loudly_when_a_named_slug_is_not_sweepable
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        { "tasks" => [
            { "slug" => "task-real", "stage" => "reviewed", "merged" => "", "pr_url" => "https://gh/pr/9", "repo" => "mcritchie-studio" }
          ],
          "release" => nil,
          "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      end
    RUBY
    out = run_cli(["--yes", "--task", "task-real", "--task", "task-typo"], setup: setup,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a dropped --task slug must abort — never a silent drop / false success"
    assert_includes out, "task-typo", "the abort names the missing slug"
    assert_includes out, "not sweepable", "the abort names the eligibility rule"
    assert_includes out, "Nothing was merged or deployed", "the loud fail lands before any side effect"
    refute_includes out, "NO-ABORT"
    refute_includes out, "gh pr merge", "no PR merges after the loud fail"
    refute_includes out, "bin/qa-server deploy", "no QA deploy after the loud fail"
  end

  # The surviving --task list still previews/sweeps normally (the loud fail only
  # fires on a MISSING slug, not on curation itself).
  def test_prepare_task_flag_sweeps_a_named_slug_that_survives_detection
    out = run_cli(["--dry-run", "--task", "task-new"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "sweep task-new (reviewed)", "the named survivor previews"
    refute_includes out, "not sweepable", "no loud fail when every named slug survived"
  end

  # --- the Avi handoff line: printed on QA-green ONLY ---------------------------

  def test_prepare_prints_the_avi_handoff_only_on_qa_green
    out = run_cli(["--yes"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "Assembled rel-sweep"
    assert_includes out, "hand off to Avi: `bin/release ship`", "QA-green prepare hands the RC to Avi"
  end

  def test_prepare_omits_the_avi_handoff_when_qa_is_not_green
    setup = SWEEP_FLOW_STUB + %(\ndef wait_for_boot(_url) = false)
    out = run_cli(["--yes"], call: "prepare", setup: setup)

    assert_includes out, "QA is NOT green", "the boot failure is reported"
    assert_includes out, "Prepared (NOT assembled — QA not green)"
    refute_includes out, "hand off to Avi",
                    "a NOT-green prepare must not point at `bin/release ship` — there is nothing to ship yet"
    refute_includes out, "QA-GREEN-CALL", "no flip on a QA-red prepare"
  end

  # --- pre-QA gate: the prepare-owned test tier on origin/release --------------

  def test_prepare_dry_run_previews_the_pre_qa_gate_per_app
    setup = STUB_CONDUCTOR + %(\ndef qa_gate_cmd(repo) = repo == "mcritchie-studio" ? "bin/rails test:integration" : "")
    out = run_cli(["--dry-run"], call: "prepare", setup: setup)

    assert_includes out, "pre-QA gate: integration + e2e-smoke on origin/release (before any QA deploy)"
    assert_includes out, "[dry-run] pre-QA gate mcritchie-studio: (cd mcritchie-studio) bin/rails test:integration @ origin/release"
    assert_includes out, "turf-monster: no qa_test_cmd registered", "an unregistered app self-gates (skip)"
  end

  def test_pre_qa_gate_runs_before_any_qa_deploy
    setup = STUB_CONDUCTOR + %(\ndef qa_gate_cmd(_repo) = "bin/rails test:integration")
    out = run_cli(["--dry-run"], call: "prepare", setup: setup)

    gate_at   = out.index("pre-QA gate mcritchie-studio")
    deploy_at = out.index("bin/qa-server deploy mcritchie-studio")
    assert gate_at && deploy_at, "both the gate and the deploy must appear"
    assert_operator gate_at, :<, deploy_at, "the gate runs BEFORE the QA deploy (members still reviewed)"
  end

  def test_pre_qa_gate_red_aborts_with_eject_guidance_and_restores_main
    setup = <<~'RUBY'
      def repo_path(_repo) = Dir.pwd
      def qa_gate_cmd(_repo) = "bin/failing-suite"
      def sh(*a, **_k)
        $stdout.puts("GIT " + a.join(" ")) if a[0] == "git"
        return ["", false] if a[0] == "bin/failing-suite" # the tier suite is RED
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{begin; pre_qa_gate([{ "repo" => "mcritchie-studio" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a red pre-QA gate aborts prepare"
    assert_includes out, "bin/release eject", "the abort points at the block-on-regression move"
    assert_includes out, "git revert -m 1", "…and the merge-commit revert"
    assert_includes out, "REST of the RC rides on", "keep-the-rest is the stated recovery"
    refute_includes out, "PASSED"
    assert_includes out, "checkout main", "the sibling checkout is restored to main (ensure)"
  end

  # --- eject: block-on-regression (detach + block ONE offender, keep the rest) ---

  def test_eject_records_the_conductor_eject_and_prints_the_revert_guidance
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("EJECT-CALL " + ruby.gsub("\n", " "))
        { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
      end
    RUBY
    out = run_cli(["task-bad", "--feedback", "integration regression on release"], call: "eject", setup: setup)

    eject = out.lines.find { |l| l.start_with?("EJECT-CALL") }
    assert_includes eject, "Release::Conductor.eject!", "the record side detaches + blocks via eject!"
    assert_includes eject, "integration regression on release", "the feedback threads into the qa_feedback note"
    assert_includes out, "task-bad → blocked (rework)"
    assert_includes out, "git revert -m 1", "the git unwind guidance is printed"
    assert_includes out, "bin/release prepare", "…ending at the self-healing re-run"
  end

  def test_eject_without_a_slug_aborts_with_usage
    out = run_cli([], call: "begin; eject; rescue SystemExit => e; puts('ABORTED: ' + e.message); end", setup: "")
    assert_includes out, "ABORTED"
    assert_includes out, "usage: bin/release eject"
  end

  # --- record_merged_main: the ship-side merged:"main" stamp -------------------

  def test_record_merged_main_records_the_ff_stamp_through_the_conductor
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("MERGED-CALL " + ruby.gsub("\n", " "))
        {}
      end
    RUBY
    out = run_cli(["--yes"], call: %(record_merged_main(["t-a", "t-b"])), setup: setup)

    merged = out.lines.find { |l| l.start_with?("MERGED-CALL") }
    assert_includes merged, "Release::Conductor.record_merged!", "the stamp rides the tested conductor primitive"
    assert_includes merged, "'main'"
    assert_includes merged, "t-a"
    assert_includes merged, "t-b"
  end

  def test_record_merged_main_is_best_effort_and_never_aborts_the_ship
    setup = %(def conductor(ruby, read_only: false) = abort!("record op failed: board blip"))
    out = run_cli(["--yes"], call: %(record_merged_main(["t-a"]); puts("CONTINUED")), setup: setup)

    assert_includes out, "merged:main not recorded", "a board blip WARNS"
    assert_includes out, "CONTINUED", "…and the ship continues (git ffs no-op; ship! re-stamps)"
  end

  def test_record_merged_main_skips_empty_slugs_and_dry_run
    setup = %(def conductor(ruby, read_only: false); $stdout.puts("MERGED-CALL"); {}; end)
    out = run_cli(["--yes"], call: %(record_merged_main([])), setup: setup)
    refute_includes out, "MERGED-CALL", "no members → no write"

    out = run_cli(["--dry-run"], call: %(record_merged_main(["t-a"])), setup: setup)
    refute_includes out, "MERGED-CALL", "a dry run stamps nothing"
  end

  # --- status / the clean-release GUARD (`Deploy with Task`'s first step) ---
  # `status` gathers two signals — the board's assembled-but-unshipped tasks (via
  # `conductor`) and per-repo release-ahead-of-main (via `release_ahead_states`) —
  # then Release::CleanCheck decides clean vs dirty. Both reads are stubbed here so
  # the guard is exercised with no Rails/DB/git. `--clean-only` turns a dirty
  # verdict into a non-zero abort (rescued in-band so run_ruby sees a clean exit).

  # Stub the board read + git seam. `pending` = assembled-task hashes, `ahead` =
  # per-repo release-ahead counts.
  def status_stub(pending:, ahead:)
    <<~RUBY
      def conductor(ruby, read_only: false)
        { "pending" => #{pending.inspect}, "release" => { "slug" => "rel-cli", "state" => "assembling" } }
      end
      def release_ahead_states
        #{ahead.inspect}
      end
    RUBY
  end

  def test_status_clean_release_reports_release_equals_main
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]),
                  call: "status")

    assert_includes out, "release == main", "a clean release reports release == main"
    assert_includes out, "safe to expedite one task"
    refute_includes out, "refused", "a clean release is not refused"
  end

  def test_status_clean_only_refuses_a_dirty_release_and_offers_the_composition
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [{ "slug" => "other-work", "title" => "Other feature" }], ahead: []),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message.to_s); end")

    assert_includes out, "refused", "a dirty release is refused"
    assert_includes out, "other-work", "the refusal lists the pending assembled task"
    assert_includes out, "full-cycle", "it offers shipping the whole release instead"
    assert_includes out, "ABORTED", "--clean-only gates: a dirty release aborts the expedite (non-zero exit)"
    refute_includes out, "NO-ABORT", "the expedite must not fall through past the guard"
  end

  def test_status_clean_only_refuses_when_release_is_ahead_of_main
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 2 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "ahead of main", "the git signal alone (a stray release commit) makes it dirty"
    assert_includes out, "mcritchie-studio (+2)"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  def test_status_without_clean_only_reports_but_never_aborts
    out = run_cli(["status"],
                  setup: status_stub(pending: [{ "slug" => "other-work", "title" => "Other feature" }], ahead: []),
                  call: "status; puts('DONE-NO-ABORT')")

    assert_includes out, "other-work", "plain status still reports the dirty state"
    assert_includes out, "DONE-NO-ABORT", "plain status is informational — it reports but never aborts"
  end

  # --- ship --dry-run: multi-repo, producer-first, hub-before-satellites ---

  # A mixed release: a gem (producer) + two apps with DIFFERENT prod adapters,
  # plus per-repo QA-frozen SHAs. turf-monster is listed BEFORE mcritchie-studio
  # on purpose so the dry-run proves ship reorders the hub to the front.
  SHIP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return {} unless ruby.include?("repo_plan")
      { "slug" => "rel-ship", "state" => "assembled", "branch" => "release",
        "qa_shas" => {
          "studio-engine" => "aaaaaaa1111111111111111111111111111111111",
          "turf-monster" => "ccccccc3333333333333333333333333333333333",
          "mcritchie-studio" => "bbbbbbb2222222222222222222222222222222222"
        },
        "repos" => [
          { "repo" => "studio-engine", "kind" => "gem", "prod_deploy" => nil,
            "members" => [{ "slug" => "t-gem", "version" => "0.9.0", "branch" => nil }] },
          { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
            "members" => [{ "slug" => "t-turf", "version" => nil, "branch" => "feat/turf" }],
            "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy", "args" => ["--yes"] } },
          { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
            "members" => [{ "slug" => "t-studio", "version" => nil, "branch" => "feat/studio" }],
            "prod_deploy" => { "strategy" => "git_push_heroku", "remote" => "heroku",
                               "branch" => "main", "smoke_url" => "https://mcritchie.studio" } }
        ] }
    end
  RUBY

  def test_ship_dry_run_publishes_gems_first_with_skip_idempotency
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "gem studio-engine 0.9.0", "the gem is shipped by its resolved version"
    assert_includes out, "skip if already live", "publish is idempotent against RubyGems"
    # No "ABORT if yanked" branch: yank safety is delegated to `gem push` failing
    # closed (the versions API omits yanked versions, so there's nothing to detect
    # in the listing). The dry-run plan must NOT promise a listing-based yank abort.
    refute_includes out, "yanked", "ship has no listing-based yank check in its plan"
    assert_includes out, "tag v0.9.0", "publish tags the published version"
  end

  def test_ship_dry_run_runs_the_auto_repin_pass
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "auto-repin consumers of studio-engine"
    assert_includes out, "bundle lock --update", "re-pin re-locks the consumer against the published gem"
  end

  def test_ship_dry_run_dispatches_per_repo_prod_adapters
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    # hub: git_push_heroku + smoke its smoke_url
    assert_includes out, "push heroku main"
    assert_includes out, "https://mcritchie.studio/up"
    # satellite: repo_script runs the repo's own deploy; the repo owns smoke/rollback
    assert_includes out, "bin/deploy --yes"
    assert_includes out, "repo owns its smoke + rollback"
  end

  def test_ship_dry_run_test_cmd_gate_hub_only
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    # hub carries a conductor test_cmd; satellites self-gate (skip it).
    assert_includes out, "bin/rails test", "the hub runs its conductor test_cmd before prod"
    assert_includes out, "self-gates", "a repo_script satellite skips the conductor test_cmd"
  end

  def test_ship_dry_run_ships_the_frozen_sha
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "frozen", "ship fast-forwards each repo to its QA-frozen SHA"
    assert_includes out, "bbbbbbb", "the hub's frozen SHA prefix appears in the plan"
  end

  def test_ship_dry_run_order_is_gems_then_hub_then_satellites
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gem_at = out.index("gem studio-engine") # gem publish
    hub_at = out.index("push heroku main")  # hub DEPLOY (the test gate now runs up front, in avi_ship_gate)
    sat_at = out.index("bin/deploy --yes")  # satellite's deploy

    assert gem_at && hub_at && sat_at, "all three phases must appear"
    assert_operator gem_at, :<, hub_at, "gems publish before the hub deploys"
    assert_operator hub_at, :<, sat_at, "the hub deploys before the satellites"
  end

  # --- Avi ship gate: full e2e on the FROZEN SHA, THEN ship authority (§1.2) ---

  def test_ship_runs_the_avi_e2e_gate_before_ship_authority_and_any_deploy
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gate_at   = out.index("Avi ship gate")
    e2e_at    = out.index("bin/rails test")            # the hub's highest-tier run on the frozen SHA
    ship_at   = out.index("confirming production deploy") # the ship-authority step (unique marker)
    deploy_at = out.index("push heroku main")

    assert gate_at && e2e_at && ship_at && deploy_at, "gate, e2e, ship authority, and a deploy must all appear"
    assert_operator gate_at, :<, ship_at, "the Avi gate precedes ship authority"
    assert_operator e2e_at, :<, ship_at, "the full suite runs on the frozen SHA BEFORE ship authority"
    assert_operator ship_at, :<, deploy_at, "ship authority precedes any deploy"
  end

  def test_ship_avi_gate_runs_the_suite_on_the_frozen_sha
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)
    # The gate ff's main → the frozen hub SHA, then runs the suite on that tree.
    assert_includes out, "Avi ship gate"
    assert_includes out, "FROZEN ship SHA"
    assert_includes out, "bbbbbbb", "the gate runs on the hub's QA-frozen SHA"
  end

  # --- prepare: wait_for_boot closes the /up-smoke race before assembling ---

  def test_prepare_dry_run_waits_for_the_qa_dyno_to_boot
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    assert_includes out, "wait for boot", "prepare must poll /up before recording QA + assembling"
    assert_includes out, "/up until 200"
  end

  # wait_for_boot drives a REAL retry loop (DRY=false): poll /up until 200, with
  # `sh` (the curl) + `sleep` stubbed so the loop runs instantly.
  WAIT_BOOT_STUB = <<~RUBY
    $codes = ["000", "000", "200"]
    def sh(*_a, **_k)
      [($codes.shift || "200"), true]
    end
    def sleep(*_a); end
  RUBY

  def test_wait_for_boot_retries_until_up_returns_200
    out = run_cli(["--yes"], setup: WAIT_BOOT_STUB,
                  call: "print(wait_for_boot('https://qa.example', attempts: 5, delay: 0))")
    assert_includes out, "booted after 3 polls", "polls /up until it returns 200"
    assert out.end_with?("true"), "returns true once booted: #{out.inspect}"
  end

  def test_wait_for_boot_times_out_to_false_when_never_200
    setup = <<~RUBY
      def sh(*_a, **_k) = ["503", true]
      def sleep(*_a); end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "print(wait_for_boot('https://qa.example', attempts: 3, delay: 0))")
    assert_includes out, "never returned 200 after 3 polls"
    assert out.end_with?("false"), "times out to false: #{out.inspect}"
  end

  def test_wait_for_boot_skips_an_empty_url
    out = run_cli(["--yes"], setup: "", call: "print(wait_for_boot('', attempts: 3, delay: 0))")
    assert_equal "true", out, "an app with no QA url has nothing to smoke"
  end

  def test_ship_dry_run_states_the_partial_ship_policy_and_executes_nothing
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "abort on first failure", "partial-ship policy is surfaced"
    assert_includes out, "DRY RUN", "a dry-run executes nothing"
  end

  # --- gem version resolution: read the QA-frozen SHA, not the stale local checkout ---
  # The publish-skip bug: gem_version_for read the version from the pre-ff LOCAL
  # checkout (still on stale `main`), so a release that BUMPED the gem on its release
  # SHA reported the OLD version → publish_needed? saw it "already live" → SKIPPED the
  # real publish, shipping the release with the bumped gem never published. The fix
  # reads the version at the QA-frozen ref (`git show <ref>:<version_file>`) — the
  # exact commit ship builds + publishes from. `git_capture` is stubbed so the test
  # needs NO on-disk sibling gem checkout (the #181/#191 CI-portability lesson).

  GEM_VERSION_STUB = <<~RUBY
    # The version_file AT the frozen SHA carries the BUMPED 0.11.0; the local checkout
    # (gem_version_local) still sits on stale main at 0.10.0 — the bug's exact shape.
    def git_capture(*args)
      line = args.join(" ")
      if line.include?("show") && line.include?("frozensha")
        ['VERSION = "0.11.0"', true]
      else
        ["", false]
      end
    end
    def gem_version_local(_repo) = "0.10.0"
    GROUP = { "repo" => "studio-engine", "kind" => "gem",
              "members" => [{ "slug" => "t-gem", "version" => nil }] }
  RUBY

  def test_gem_version_for_reads_the_frozen_ref_not_the_stale_local_checkout
    out = run_cli(["--dry-run"], setup: GEM_VERSION_STUB,
                  call: "print(gem_version_for('studio-engine', GROUP, 'frozensha'))")
    assert_equal "0.11.0", out,
                 "the gem version is read at the QA-frozen SHA (the version that publishes), not stale local main"
  end

  def test_gem_version_for_falls_back_to_the_local_checkout_without_a_frozen_ref
    # No frozen ref to read (a release prepared before SHA recording) → the local
    # checkout is the documented fallback. Proves the fix preserved the fallback.
    out = run_cli(["--dry-run"], setup: GEM_VERSION_STUB,
                  call: "print(gem_version_for('studio-engine', GROUP, nil))")
    assert_equal "0.10.0", out, "with no frozen ref the resolver falls back to the local checkout"
  end

  # [integration] A release whose gem is version-bumped ABOVE the live version must
  # PUBLISH (not skip) — driving the real `ship` flow end-to-end through the resolver
  # + ship_gem's publish-vs-skip decision, with only the git/gem/heroku I/O seams
  # stubbed (CI has no sibling checkout — the #181/#191 lesson). A gem-ONLY release
  # keeps the app deploy/ff machinery out of the picture; `sh` is guarded to prove
  # NO real shell I/O is reached.
  PUBLISH_DECISION_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if ruby.include?("repo_plan")
        { "slug" => "rel-pub", "state" => "assembled", "branch" => "release",
          "qa_shas" => { "studio-engine" => "frozensha000000000000000000000000000000000" },
          "repos" => [
            { "repo" => "studio-engine", "kind" => "gem", "prod_deploy" => nil,
              "members" => [{ "slug" => "t-gem", "version" => nil, "branch" => nil }] }
          ] }
      else
        {} # the ship! record write (+ any other conductor call) is a no-op
      end
    end
    # version_file AT the frozen SHA = BUMPED 0.11.0; the stale local checkout = 0.10.0.
    def git_capture(*args)
      line = args.join(" ")
      if line.include?("show") && line.include?("frozensha")
        ['VERSION = "0.11.0"', true]
      else
        ["deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", true] # rev-parse HEAD etc.
      end
    end
    def gem_version_local(_repo) = "0.10.0"
    def rubygems_versions(_gem) = [{ "number" => "0.10.0" }] # 0.10.0 LIVE, 0.11.0 not yet
    # I/O seams stubbed — the test needs NO sibling gem checkout on disk.
    def checkout_detached(_repo, _sha); end
    def publish_gem(repo, version) = $stdout.puts("PUBLISH-CALLED " + repo + " " + version)
    def ff_main_local(_repo, _sha); end
    def push_origin_main(_repo); end
    def sh(*a, **_k) = raise("no real shell I/O expected in this test: " + a.inspect)
  RUBY

  def test_ship_publishes_a_version_bumped_gem_instead_of_skipping_it
    out = run_cli(["--yes"], call: "ship", setup: PUBLISH_DECISION_STUB)

    assert_includes out, "PUBLISH-CALLED studio-engine 0.11.0",
                     "a gem bumped above the live version publishes (resolved from the frozen SHA)"
    refute_includes out, "already live on RubyGems — skip publish",
                     "the resolver must not read stale local 0.10.0 and skip the real publish"
    # the pre-flight reflects the same truth — the bumped version will publish
    assert_includes out, "studio-engine 0.11.0: not published — will publish"
  end

  # --- archive --dry-run / run: the DevOps loop's conclusion (shipped → archived) ---

  # A dry-run archive must ONLY read (read_only conductor) + run the reclaim tool's
  # own dry-run; the WRITE conductor and the --yes teardown must NEVER fire — both
  # stubs raise if hit, so reaching the DRY-RUN line proves nothing was mutated.
  ARCHIVE_DRY_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      raise "dry-run archive must not call a WRITE conductor" unless read_only
      { "archivable" => ["old-ship-a", "old-ship-b", "pre-conductor-c"],
        "kept" => ["last-member-1", "last-member-2"] }
    end
    def reclaim_worktrees(apply:)
      raise "dry-run must not apply the reclaim teardown" if apply
      puts "reclaim candidates:"
      puts "  - mcritchie-studio/old-ship-a redis=11"
      ["reclaim candidates:", true]
    end
  RUBY

  def test_archive_dry_run_previews_the_plan_and_mutates_nothing
    out = run_cli(["--dry-run"], call: "archive", setup: ARCHIVE_DRY_STUB)

    assert_includes out, "3 shipped task(s) to archive", "the archivable count + sample is shown"
    assert_includes out, "old-ship-a", "a sample of the archivable slugs is shown"
    assert_includes out, "2 last-release member(s) KEPT", "the kept last-release members are shown"
    assert_includes out, "worktree reclaim preview", "the reclaim preview runs in dry-run"
    assert_includes out, "reclaim candidates", "the reclaim tool's own dry-run lists candidates"
    assert_includes out, "DRY RUN", "a dry-run executes nothing"
  end

  # A real archive: read the plan, WRITE the archive on the board, reclaim with
  # --yes, then print the summary line.
  ARCHIVE_RUN_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        { "archivable" => ["a", "b"], "kept" => ["m1"] }
      else
        { "archived" => ["a", "b"], "kept" => ["m1"], "count" => 2 }
      end
    end
    def reclaim_worktrees(apply:)
      apply ? ["reclaimed 3 worktree(s); freed redis DBs: 11, 12, 13", true]
            : ["reclaim candidates:", true]
    end
  RUBY

  def test_archive_run_archives_then_reclaims_and_summarizes
    out = run_cli(["--yes"], call: "archive", setup: ARCHIVE_RUN_STUB)

    assert_includes out, "Archived 2 tasks"
    assert_includes out, "reclaimed 3 worktrees"
    assert_includes out, "SHIPPED → 1"
  end

  def test_reclaimed_count_parses_the_agent_worktree_summary
    assert_equal "5", eval_helper(%(reclaimed_count("reclaimed 5 worktree(s); freed redis DBs: 9").to_s))
    assert_equal "0", eval_helper(%(reclaimed_count("reclaim: nothing reclaimed").to_s))
  end

  # --- retro: the NON-BLOCKING post-ship review step -----------------------

  # gather + render run server-side (stubbed conductor returns canned markdown);
  # the CLI writes the returned doc to the LOCAL tree. RETRO_DOCS_DIR points the
  # write at a tmpdir so the test never touches the repo's docs/.
  RETRO_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      raise "retro gather must be a read" unless read_only
      { "slug" => "rel-retro", "markdown" => "# Release Retro — rel-retro\\n\\n## Summary\\n\\n- demo\\n" }
    end
  RUBY

  def test_retro_writes_the_doc_to_disk_in_non_interactive_mode
    require "tmpdir"
    Dir.mktmpdir do |dir|
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB})
      # --yes → fully non-interactive (no TTY prompt); an explicit slug positional.
      out = run_cli(["rel-retro", "--yes"], call: "retro", setup: setup)

      path = File.join(dir, "retro-rel-retro.md")
      assert File.exist?(path), "retro writes the durable doc: #{out}"
      assert_includes File.read(path), "# Release Retro — rel-retro"
      assert_includes out, "wrote"
    end
  end

  def test_retro_dry_run_previews_without_writing
    require "tmpdir"
    Dir.mktmpdir do |dir|
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB})
      out = run_cli(["rel-retro", "--dry-run"], call: "retro", setup: setup)

      refute File.exist?(File.join(dir, "retro-rel-retro.md")), "a dry-run writes nothing"
      assert_includes out, "DRY RUN"
      assert_includes out, "would write retro doc"
    end
  end

  def test_retro_resolves_the_default_release_when_no_slug_is_given
    require "tmpdir"
    Dir.mktmpdir do |dir|
      # No positional slug → CLI passes nil; the (stubbed) resolver returns the
      # current/last-shipped release's slug, which the CLI writes the doc for.
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB})
      run_cli(["--yes"], call: "retro", setup: setup)
      assert File.exist?(File.join(dir, "retro-rel-retro.md")), "default-release retro still writes a doc"
    end
  end

  def test_retro_collects_repeated_answer_flags_into_the_runner_payload
    require "tmpdir"
    Dir.mktmpdir do |dir|
      # Capture the snippet the CLI hands the (server-side) renderer: the stubbed
      # conductor echoes it back so we can prove the flags rode through. The
      # payload now rides as a Base64 blob (see the round-trip test below), so we
      # decode it rather than grep for the raw text.
      capture = <<~RUBY
        def conductor(ruby, read_only: false)
          File.write(#{File.join(dir, 'snippet.txt').inspect}, ruby)
          { "slug" => "rel-retro", "markdown" => "# Release Retro — rel-retro\\n" }
        end
      RUBY
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{capture})
      run_cli(["rel-retro", "--yes", "--worked", "fast review", "--friction", "flaky e2e", "--followup", "fix flake"],
              call: "retro", setup: setup)

      answers = decode_retro_payload(File.read(File.join(dir, "snippet.txt")))
      assert_includes answers["worked"], "fast review", "--worked rides into the render payload"
      assert_includes answers["friction"], "flaky e2e", "--friction rides into the render payload"
      assert_includes answers["followups"], "fix flake", "--followup rides into the render payload"
    end
  end

  # --- retro payload shell-safety: the heroku-run round-trip bug -------------
  # The retro answers are operator free-text — they can carry quotes, parens, &&,
  # pipes, backticks. Raw-interpolating their JSON into `rails runner "<code>"`
  # broke the `heroku run` round-trip: heroku's remote re-quoting ATE the embedded
  # \"-escaping, so even EMPTY answers arrived corrupted (`JSON::ParserError ...
  # got 'worked:[],riction:[],ollowups:'`) and parens triggered a remote
  # `bash: syntax error near unexpected token '('`. The fix passes the payload as
  # a url-safe Base64 blob (alphabet [A-Za-z0-9_-]=, zero shell metacharacters) —
  # exactly as quote-free as the bare `slug.inspect` literal the other conductor
  # callers already pass safely.

  # Pull the Base64 payload literal the CLI embedded and decode it the way the
  # remote runner does. Asserts the snippet does NOT raw-interpolate JSON.
  def decode_retro_payload(snippet)
    require "base64"
    require "json"
    b64 = snippet[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, "the retro snippet must embed a url-safe Base64 payload literal: #{snippet}"
    JSON.parse(Base64.urlsafe_decode64(b64))
  end

  def test_retro_record_ruby_passes_the_payload_shell_safe_not_raw_json
    # An adversarial payload: the exact metacharacters that broke heroku run.
    answers = { "worked" => ["fixed (a) bug && shipped"],
                "friction" => ['flaky "e2e" | pipe'], "followups" => [] }
    out = eval_helper(%(retro_record_ruby("rel-x", #{answers.inspect})))

    # The raw JSON (the thing heroku's re-quoting eats) must NOT be interpolated.
    refute_includes out, %q("worked":), "the raw answers JSON must not ride into the runner command"
    refute_includes out, "&&", "no payload shell metacharacter rides raw into the command"
    refute_includes out, "(a)", "no payload parens ride raw into the command (remote bash syntax error)"
    refute_includes out, "| pipe", "no payload pipe rides raw into the command"
    # It rides as a url-safe Base64 blob the remote runner decodes, and still
    # renders through the retro model.
    assert_includes out, "Base64.urlsafe_decode64", "the payload is base64-decoded server-side"
    assert_includes out, "Release::Retro.render", "the snippet still renders via the retro model"
  end

  def test_retro_record_ruby_round_trips_quotes_parens_and_ampersands
    require "base64"
    require "json"
    answers = { "worked" => ['used "quotes" & (parens)', "shipped && done"],
                "friction" => ["bash $(danger) | pipe; rm -rf"],
                "followups" => ["file `backticks` and \\backslash" ] }
    out = eval_helper(%(retro_record_ruby("rel-x", #{answers.inspect})))

    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, "the snippet embeds a url-safe Base64 literal: #{out}"
    assert_equal answers, JSON.parse(Base64.urlsafe_decode64(b64)),
                 "quotes/parens/&&/pipes/backticks/backslashes round-trip byte-for-byte through the payload encoding"
  end

  def test_retro_empty_answers_survive_the_runner_payload
    # The simplest repro: even all-empty answers were corrupted by the old raw
    # interpolation (quotes + leading chars eaten by heroku's re-quoting).
    answers = { "worked" => [], "friction" => [], "followups" => [] }
    out = eval_helper(%(retro_record_ruby("rel-x", #{answers.inspect})))

    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, out
    assert_equal answers, JSON.parse(Base64.urlsafe_decode64(b64)),
                 "empty answers must survive intact (the JSON::ParserError repro)"
  end

  # NON-BLOCKING: archive must complete WITHOUT ever invoking retro. The stub
  # raises if `retro` is touched, so reaching the summary line proves archive does
  # not depend on (or trigger) the retro step in any way.
  ARCHIVE_NO_RETRO_STUB = <<~RUBY
    def retro(*); raise "non-blocking violation: archive invoked retro"; end
    def conductor(ruby, read_only: false)
      read_only ? { "archivable" => ["a"], "kept" => ["m1"] }
                : { "archived" => ["a"], "kept" => ["m1"], "count" => 1 }
    end
    def reclaim_worktrees(apply:)
      apply ? ["reclaimed 1 worktree(s); freed redis DBs: 11", true] : ["reclaim candidates:", true]
    end
  RUBY

  def test_archive_is_non_blocking_and_never_invokes_retro
    out = run_cli(["--yes"], call: "archive", setup: ARCHIVE_NO_RETRO_STUB)
    assert_includes out, "Archived 1 tasks", "archive completes independently of retro"
  end

  # --- post-deploy command hook: prepare → QA app, ship → prod app ---------
  # The target apps below (turf-monster-qa / turf-monster-mainnet) are resolved
  # from the REAL config/qa_environments.yml the CLI loads at boot, so these also
  # prove the qa-server-key → heroku-app resolution against the live registry.

  # A prepare plan where a member declares a post_deploy_cmd. turf-monster boots
  # ok in dry-run (deployed.ok = DRY), so step 4 runs the QA post-deploy hook.
  POST_DEPLOY_PREP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-cli", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      { "slug" => "rel-pd", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "turf-monster", "kind" => "app", "release_branch" => "release",
          "qa_app" => "turf-monster",
          "members" => [{ "slug" => "t-turf", "branch" => "feat/turf",
                          "post_deploy_cmd" => "rake pokemon:backfill_mascots" }] }
      ] }
    end
  RUBY

  def test_prepare_dry_run_prints_the_post_deploy_command_on_the_qa_app
    out = run_cli(["--dry-run"], call: "prepare", setup: POST_DEPLOY_PREP_STUB)

    assert_includes out, "post-deploy hooks (QA)"
    # The printed command is byte-for-byte what executes: `--exit-code` (so heroku
    # passes through the remote exit status — the abort-on-failure linchpin) and the
    # `--` flag-terminator before the task-declared command.
    assert_includes out, "heroku run -a turf-monster-qa --no-tty --exit-code -- rake pokemon:backfill_mascots",
                     "prepare runs the post-deploy command on the QA heroku app with --exit-code"
  end

  # [integration] The seed-54 blocker, end-to-end through the record path: a member
  # declares a paren/quote post_deploy_cmd, and prepare must RUN the QA post-deploy
  # hook, record it, and REACH assemble! — without the paren cmd corrupting any
  # conductor snippet. The conductor stub flags any snippet whose REAL
  # conductor_payload would put a raw paren / Rails.root.join on the heroku command
  # line (the old bug); reaching "Assembled" proves every snippet rode shell-safe.
  PAREN_POST_DEPLOY_PREP_STUB = <<~'RUBY'
    # CI has no sibling repo checkouts, so the real repo_path → Dir.exist? guard in
    # `prepare` (bin/release: "app repo not found at #{path}") would abort before the
    # post-deploy/assemble step this test proves. Resolve the repo to an always-present
    # dir (Dir.pwd) — the git/qa-server I/O against it is already fully stubbed by `sh`,
    # so the repo's identity on disk is irrelevant to what this test asserts.
    def repo_path(_repo) = Dir.pwd
    def conductor(ruby, read_only: false)
      payload = conductor_payload(ruby)               # the REAL shell-safe encoder
      $stdout.puts("UNSAFE-PAYLOAD") if payload.include?("Rails.root.join") || payload.include?("(%q(")
      if ruby.include?("sweep_candidates")
        { "tasks" => [], "release" => { "slug" => "rel-paren", "state" => "assembling" }, "screen" => {} }
      elsif ruby.include?("repo_plan")
        { "slug" => "rel-paren", "state" => "assembling", "branch" => "release", "repos" => [
          { "repo" => "turf-monster", "kind" => "app", "release_branch" => "release",
            "qa_app" => "turf-monster",
            "members" => [{ "slug" => "t-turf", "branch" => "feat/turf",
              "post_deploy_cmd" => %q{bin/rails runner "load Rails.root.join(%q(db/seeds/54_demo.rb)).to_s"} }] }
        ] }
      elsif ruby.include?("qa_green!")
        $stdout.puts("ASSEMBLE-REACHED")
        { "state" => "assembled" }
      else
        {}
      end
    end
    def sh(*a, **_k)
      a.join(" ").include?("curl") ? ["200", true] : ["", true]
    end
  RUBY

  def test_prepare_reaches_assemble_with_a_paren_post_deploy_cmd
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB)

    refute_includes out, "UNSAFE-PAYLOAD",
                     "every conductor snippet (incl. the paren/quote post_deploy_cmd record) rides shell-safe"
    assert_includes out, "post-deploy hooks (QA)", "the QA post-deploy hook ran for the paren cmd"
    assert_includes out, "ASSEMBLE-REACHED",
                     "prepare reaches Release::Conductor.assemble! even with a paren/quote post_deploy_cmd"
    assert_includes out, "Assembled rel-paren", "the release assembles cleanly"
  end

  def test_prepare_dry_run_has_no_post_deploy_hook_when_no_member_declares_one
    # STUB_CONDUCTOR's members carry no post_deploy_cmd — the hook is opt-in.
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    refute_includes out, "post-deploy hooks", "no member declares a command → no hook runs"
  end

  # A ship plan (assembled + qa_shas) where a member declares a post_deploy_cmd.
  POST_DEPLOY_SHIP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return {} unless ruby.include?("repo_plan")
      { "slug" => "rel-pd-ship", "state" => "assembled", "branch" => "release",
        "qa_shas" => { "turf-monster" => "ccccccc3333333333333333333333333333333333" },
        "repos" => [
          { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
            "members" => [{ "slug" => "t-turf", "version" => nil, "branch" => "feat/turf",
                            "post_deploy_cmd" => "rake pokemon:backfill_mascots" }],
            "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy", "args" => ["--yes"] } }
        ] }
    end
  RUBY

  def test_ship_dry_run_prints_the_post_deploy_command_on_the_prod_app
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)

    assert_includes out, "post-deploy hooks (prod)"
    assert_includes out, "heroku run -a turf-monster-mainnet --no-tty --exit-code -- rake pokemon:backfill_mascots",
                     "ship runs the post-deploy command on the production app with --exit-code"
  end

  def test_ship_dry_run_runs_post_deploy_after_the_app_deploys
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)
    deploy_at = out.index("bin/deploy --yes")     # the app's prod deploy
    hook_at   = out.index("post-deploy hooks")    # the post-deploy hook
    assert deploy_at && hook_at, "both the deploy and the hook must appear"
    assert_operator deploy_at, :<, hook_at, "the post-deploy hook runs AFTER the app deploys + smokes"
  end

  # A non-zero exit from `heroku run` must ABORT the pipeline. Drive run_post_deploy
  # directly (DRY=false) with `sh` stubbed to FAIL — but the stub first ECHOES its
  # argv, so we also prove the EXECUTED command carries `--exit-code` (the flag that
  # makes heroku passthrough the remote exit status; without it heroku returns 0 at
  # dyno launch and abort-on-failure never fires). `conductor` (record write) is a
  # no-op. Keeps the stubbed-false branch for abort coverage without a real dyno.
  def test_post_deploy_aborts_the_pipeline_on_a_nonzero_exit
    setup = <<~RUBY
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)  # echo the executed heroku argv...
        ["the command exploded", false]        # ...then fail (non-zero remote exit)
      end
      def conductor(*_a, **_k) = {}             # record write is a no-op
      REPOS = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
                 "members" => [{ "slug" => "t-turf", "post_deploy_cmd" => "rake boom" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; run_post_deploy(REPOS, target: :qa); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, %q("--exit-code"),
                     "the EXECUTED heroku argv passes --exit-code so a failing remote command returns non-zero"
    assert_includes out, %q("turf-monster-qa"), "it attempted the command on the QA app"
    assert_includes out, "ABORTED", "a non-zero post-deploy exit aborts the pipeline"
  end

  # `heroku run` argv hardening: Shellwords.split keeps a quoted/spaced arg as ONE
  # token, and a `--` terminator precedes the task command so a flag-shaped arg
  # can't be reparsed as a `heroku run` option. Drive run_post_deploy (DRY=false)
  # with `sh` echoing its argv (and returning ok, so no abort).
  POST_DEPLOY_ARGV_STUB = <<~RUBY
    def sh(*a, **_k)
      $stdout.puts("SH-ARGV " + a.inspect)
      ["", true]
    end
    def conductor(*_a, **_k) = {}
  RUBY

  def test_post_deploy_shell_splits_and_terminates_heroku_flags
    setup = POST_DEPLOY_ARGV_STUB + <<~RUBY
      REPOS = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
                 "members" => [{ "slug" => "t-turf",
                                 "post_deploy_cmd" => %q(rake "db:migrate[hello world]") }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "run_post_deploy(REPOS, target: :qa)")

    assert_includes out, %q("--"),
                     "a `--` terminator stops heroku flag parsing before the task command"
    assert_includes out, %q("db:migrate[hello world]"),
                     "Shellwords keeps a quoted/spaced arg as a single token (not two argv entries)"
  end

  # A declared post_deploy_cmd on a repo with no resolvable target app (a gem, or
  # an app missing from qa_environments.yml) is a HARD abort — never a silent no-op.
  def test_post_deploy_aborts_when_a_declared_command_has_no_target_app
    setup = <<~RUBY
      def conductor(*_a, **_k) = {}
      REPOS = [{ "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
                 "members" => [{ "slug" => "t-gem", "post_deploy_cmd" => "rake noop" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; run_post_deploy(REPOS, target: :prod); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "ABORTED", "an unroutable declared command aborts rather than silently skipping"
  end

  # --- batched merge: N slugs, ONE heroku-run adopt (the timeout fix) -------
  # The old `merge` did `gh pr merge` + a COLD-START `heroku run` adopt PER PR; 3
  # in a loop blew the 2-min tool timeout and a mid-run timeout left a PR merged
  # but its task stuck `reviewed`. Now `bin/release merge a b c` resolves all PRs
  # in ONE read, then runs ALL the adopts in ONE `heroku run` (single dyno, N
  # flips). These drive the real shell orchestration with conductor/sh/gh stubbed.

  # A stub that ECHOES the adopt vs resolve conductor calls so we can count them
  # and inspect the embedded slugs from the subprocess's stdout. The (read-only)
  # resolve returns two reviewed PRs; the (write) adopt returns the release.
  MERGE_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        $stdout.puts("RESOLVE-CALL")
        { "tasks" => [
          { "slug" => "task-a", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" },
          { "slug" => "task-b", "pr_url" => "https://gh/pr/2", "repo" => "mcritchie-studio", "stage" => "reviewed" }
        ] }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
    def sh(*a, **_k)
      a.include?("baseRefName") ? ["release", true] : ["", true]
    end
    def gh_pr_files(pr_url)
      pr_url.end_with?("1") ? ["app/models/task.rb", "a-only.rb"] : ["app/models/task.rb", "b-only.rb"]
    end
  RUBY

  def test_merge_runs_all_adopts_in_a_single_heroku_run
    out = run_cli(%w[task-a task-b], call: "merge", setup: MERGE_STUB)

    # The whole batch resolves in ONE read and adopts in ONE write — not one
    # heroku-run per PR (the cold-start that blew the timeout).
    assert_equal 1, out.scan("RESOLVE-CALL").size, "all PRs resolve in ONE read conductor call"
    assert_equal 1, out.scan("ADOPT-CALL").size, "all adopts run in ONE write conductor call (single dyno)"

    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "task-a", "the single sweep call covers task-a"
    assert_includes adopt, "task-b", "the single sweep call covers task-b"
    assert_includes adopt, "sweep!", "the batched call drives Release::Conductor.sweep!"
  end

  def test_merge_collapses_duplicate_pr_urls_but_adopts_every_task
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "task-a", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" },
            { "slug" => "task-b", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
          { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
        end
      end
      def sh(*a, **_k)
        pr_url = a.find { |arg| arg.to_s.start_with?("https://") }
        if a.include?("baseRefName")
          $stdout.puts("BASE-CALL " + pr_url.to_s)
          ["release", true]
        else
          $stdout.puts("MERGE-CALL " + pr_url.to_s)
          ["", true]
        end
      end
      def gh_pr_files(pr_url)
        $stdout.puts("FILES-CALL " + pr_url)
        ["app/models/task.rb"]
      end
    RUBY

    out = run_cli(%w[task-a task-b], call: "merge", setup: setup)

    assert_includes out, "2 task(s) map to 1 unique PR(s)"
    assert_equal 1, out.scan("BASE-CALL https://gh/pr/1").size, "the shared PR base is read once"
    assert_equal 1, out.scan("MERGE-CALL https://gh/pr/1").size, "the shared PR is merged once"
    assert_equal 0, out.scan("FILES-CALL").size, "one unique PR needs no overlap report"

    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "task-a", "the first task riding the PR is adopted"
    assert_includes adopt, "task-b", "the second task riding the PR is adopted"
  end

  # A resolve that returns exactly ONE reviewed PR — for the single-slug path.
  SINGLE_MERGE_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        { "tasks" => [
          { "slug" => "task-a", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
        ] }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
    def sh(*a, **_k)
      a.include?("baseRefName") ? ["release", true] : ["", true]
    end
    def gh_pr_files(_pr) = []
  RUBY

  def test_merge_single_slug_is_backward_compatible
    out = run_cli(%w[task-a], call: "merge", setup: SINGLE_MERGE_STUB)
    # Single slug still works: one adopt, summary names the task.
    assert_equal 1, out.scan("ADOPT-CALL").size
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "task-a"
    assert_includes out, "Swept task-a"
  end

  def test_merge_with_no_slug_aborts_with_usage
    out = run_cli([], call: "begin; merge; rescue SystemExit => e; puts('ABORTED: ' + e.message); end",
                  setup: MERGE_STUB)
    assert_includes out, "ABORTED"
    assert_includes out, "usage: bin/release merge", "no slug → usage abort"
  end

  # The ensure-adopt is the half-state killer: if a LATER gh pr merge fails, the
  # batched adopt STILL records the PRs that DID merge (so none is left "merged
  # but stuck reviewed"), then the command aborts.
  def test_merge_adopts_the_already_merged_prs_even_when_a_later_merge_fails
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "task-a", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" },
            { "slug" => "task-b", "pr_url" => "https://gh/pr/2", "repo" => "mcritchie-studio", "stage" => "reviewed" }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
          { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
        end
      end
      $merge_n = 0
      def sh(*a, **_k)
        return ["release", true] if a.include?("baseRefName")
        $merge_n += 1            # a `gh pr merge` call
        $merge_n >= 2 ? ["", false] : ["", true]  # first merge ok, second FAILS
      end
      def gh_pr_files(_pr) = []
    RUBY
    out = run_cli(%w[task-a task-b], setup: setup,
                  call: "begin; merge; rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "ABORTED", "a failed gh pr merge aborts the command"
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    refute_nil adopt, "the merged PR(s) are still adopted via the ensure block"
    assert_includes adopt, "task-a", "the PR that DID merge is adopted (no half-state)"
    refute_includes adopt, "task-b", "the PR that never merged is NOT adopted"
  end

  # --- overlap planner: pairwise file overlap, suggested order, rebase ------
  # WARNING ONLY — it never blocks the merge. With both PRs touching task.rb it
  # must print the collision, a suggested order, and the post-merge rebase note.
  def test_merge_prints_the_overlap_planner_when_prs_collide
    out = run_cli(%w[task-a task-b], call: "merge", setup: MERGE_STUB)

    assert_includes out, "overlap planner", "the planner runs before the batch merge"
    assert_includes out, "app/models/task.rb", "the shared file is named"
    assert_includes out, "suggested merge order", "a suggested order is printed"
    assert_includes out, "rebase", "the post-merge rebase heads-up is printed"
    assert_includes out, "warning only", "the planner never blocks the merge"
    # Warning-only: the merge still proceeds (the adopt still runs).
    assert_equal 1, out.scan("ADOPT-CALL").size
  end

  def test_merge_overlap_planner_reports_no_collision_when_files_are_disjoint
    # Re-define gh_pr_files AFTER MERGE_STUB (later def wins) so the two PRs touch
    # disjoint files — the planner must then report independence.
    setup = MERGE_STUB + %(\ndef gh_pr_files(pr_url); pr_url.end_with?("1") ? ["a-only.rb"] : ["b-only.rb"]; end)
    out = run_cli(%w[task-a task-b], call: "merge", setup: setup)
    assert_includes out, "no overlapping files", "disjoint batches report independence"
  end

  # --- review-gate guard: refuse an unreviewed merge unless --override ---------
  # The decision is Release::Conductor.screen_merge's (unit-tested in
  # conductor_test); these exercise the CLI ENTRY PATH — the guard renders the
  # screen, aborts BEFORE any gh pr merge on a block, and threads the audited
  # bypass through to the batched adopt on --override. The (stubbed) resolve now
  # returns a `screen` block alongside `tasks`.

  # A resolve whose single task is NOT reviewed → the screen blocks it.
  BLOCKED_MERGE_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        { "tasks" => [
            { "slug" => "task-a", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "submitted" }
          ],
          "screen" => { "rows" => [{ "slug" => "task-a", "stage" => "submitted", "status" => "blocked" }],
                        "blocked" => ["task-a"], "overridden" => [], "missing" => [], "proceed" => false } }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
    def sh(*a, **_k)
      a.include?("baseRefName") ? ["release", true] : ["", true]
    end
    def gh_pr_files(_pr) = []
  RUBY

  def test_merge_refuses_an_unreviewed_task_without_override
    # abort writes the message to STDERR (discarded by run_cli) AND raises
    # SystemExit carrying it — capture e.message, mirroring the usage-abort test.
    out = run_cli(%w[task-a], setup: BLOCKED_MERGE_STUB,
                  call: "begin; merge; rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "an unreviewed task aborts the merge"
    assert_includes out, "review gate", "the abort names the review gate"
    assert_includes out, "task-a (submitted)", "it prints exactly which task is in which stage"
    assert_includes out, "--override", "the abort points to the override escape hatch"
    assert_equal 0, out.scan("ADOPT-CALL").size, "nothing is merged or adopted — the guard runs BEFORE gh pr merge"
  end

  # The same unreviewed task, now with --override → the run proceeds and the
  # bypass threads into the adopt snippet.
  OVERRIDE_MERGE_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      if read_only
        { "tasks" => [
            { "slug" => "task-a", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "submitted" }
          ],
          "screen" => { "rows" => [{ "slug" => "task-a", "stage" => "submitted", "status" => "overridden" }],
                        "blocked" => [], "overridden" => ["task-a"], "missing" => [], "proceed" => true } }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
    def sh(*a, **_k)
      a.include?("baseRefName") ? ["release", true] : ["", true]
    end
    def gh_pr_files(_pr) = []
  RUBY

  def test_merge_override_merges_an_unreviewed_task_and_threads_the_bypass_to_adopt
    out = run_cli(%w[task-a --override], call: "merge", setup: OVERRIDE_MERGE_STUB)

    assert_includes out, "OVERRIDE", "the override banner is printed"
    assert_includes out, "review_bypassed", "the banner names the audit event it records"
    assert_equal 1, out.scan("ADOPT-CALL").size, "the override proceeds to merge + adopt"
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "override: true", "the adopt snippet threads the audited bypass"
  end

  def test_merge_default_threads_no_override_into_adopt
    # MERGE_STUB returns reviewed tasks + NO screen → the guard is a no-op and the
    # normal path threads override: false (no bypass).
    out = run_cli(%w[task-a task-b], call: "merge", setup: MERGE_STUB)
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "override: false", "a normal merge threads NO bypass"
  end

  # --- batch_sweep_ruby / batch_resolve_ruby: pure snippet builders ---------
  # These build the ONE-shot conductor snippets the batched merge runs; unit-test
  # them directly (eval_helper) so the single-call guarantee + slug embedding are
  # pinned independent of the orchestration.

  def test_batch_sweep_ruby_embeds_every_slug_in_one_runner_snippet
    out = eval_helper(%(batch_sweep_ruby(["task-a", "task-b", "task-c"])))
    assert_includes out, "task-a"
    assert_includes out, "task-b"
    assert_includes out, "task-c"
    assert_includes out, "Release::Conductor.sweep!", "the snippet drives sweep!"
    assert_equal 1, out.scan("puts(").size, "the snippet emits exactly ONE JSON line for the whole batch"
  end

  def test_batch_sweep_ruby_threads_the_override_flag
    assert_includes eval_helper(%(batch_sweep_ruby(["task-a"]))), "override: false",
                    "sweep defaults to NO override"
    assert_includes eval_helper(%(batch_sweep_ruby(["task-a"], override: true))), "override: true",
                    "the audited bypass threads into the sweep snippet"
  end

  def test_batch_resolve_ruby_embeds_every_slug_and_reads_one_line
    out = eval_helper(%(batch_resolve_ruby(["task-a", "task-b"])))
    assert_includes out, "task-a"
    assert_includes out, "task-b"
    assert_includes out, "devops_url", "the resolve snippet reads each task's PR url"
    assert_equal 1, out.scan("puts(").size, "the resolve snippet emits ONE JSON line for the batch"
  end

  def test_batch_resolve_ruby_runs_the_review_gate_screen
    out = eval_helper(%(batch_resolve_ruby(["task-a"], override: true)))
    assert_includes out, "screen_merge", "the resolve snippet runs the review-gate screen in the same read"
    assert_includes out, "override: true", "the override flag threads into the screen"
    assert_equal 1, out.scan("puts(").size, "resolve + screen still emit ONE JSON line"
  end

  # --- conductor_payload: the shell-safe rails-runner bootstrap (the blocker) --
  # record_post_deploy_check interpolated a post_deploy_cmd via cmd.inspect; a
  # seed-54-style `bin/rails runner "load Rails.root.join(%q(...)).to_s"` arrived
  # as escaped quotes + parens, heroku's remote re-quoting ATE the \"-escaping, and
  # the exposed `(` triggered `bash: syntax error near unexpected token '('` —
  # conductor then hit "record op returned no JSON" and aborted prepare BEFORE
  # assemble!. conductor_payload base64-wraps the WHOLE snippet at the shared seam
  # so EVERY conductor caller rides shell-safe.

  def test_conductor_payload_is_a_shell_safe_base64_bootstrap_for_paren_quote_snippets
    require "base64"
    # The exact shape record_post_deploy_check builds: the cmd interpolated via
    # .inspect — escaped quotes + parens, the bytes that broke `heroku run`.
    cmd = %q{bin/rails runner "load Rails.root.join(%q(db/seeds/54_demo.rb)).to_s"}
    snippet = %{c = Release::Conductor.record_post_deploy_check(cmd: #{cmd.inspect}, ok: true); puts({ checks: c.size }.to_json)}
    out = eval_helper(%(conductor_payload(#{snippet.inspect}))).strip

    # The command line carries ONLY a url-safe Base64 eval bootstrap — between the
    # quotes is nothing but [A-Za-z0-9_-]=, so heroku's re-quoting can't mangle it.
    assert_match(/\Aeval\(Base64\.urlsafe_decode64\("[A-Za-z0-9_\-=]+"\)\)\z/, out,
                 "the payload is a single shell-safe Base64 eval bootstrap: #{out}")
    refute_includes out, "Rails.root.join", "the raw paren/quote snippet must not reach the command line"
    refute_includes out, "%q(", "no payload parens reach the command line (remote bash syntax error)"

    # And it round-trips byte-for-byte: the blob decodes to the wrapped snippet
    # (the cmd rides inside via .inspect, so the seed path survives intact).
    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    decoded = Base64.urlsafe_decode64(b64).force_encoding("UTF-8")
    assert_equal "require 'json'; #{snippet}", decoded,
                 "the wrapped snippet round-trips byte-for-byte through the payload encoding"
    assert_includes decoded, "db/seeds/54_demo.rb", "the seed path survives in the payload"
  end

  def test_conductor_payload_round_trips_an_ordinary_snippet
    require "base64"
    out = eval_helper(%(conductor_payload("puts({ok: true}.to_json)"))).strip
    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, out
    assert_equal "require 'json'; puts({ok: true}.to_json)", Base64.urlsafe_decode64(b64),
                 "an ordinary snippet round-trips unchanged through the payload encoding"
  end

  # --- with_conductor_session: tag the deployment with the running session -----
  # The conductor's local session id lives in THIS shell's env and does NOT cross
  # the `heroku run` boundary, so conductor() passes it in-band ahead of the
  # snippet. The prod runner drains Current.conductor_session_id onto the release
  # so the board shows which agent worked the deploy. `Current.try(:…=)` so an
  # older prod (pre-attribute) ignores it instead of erroring mid-ship.

  def test_with_conductor_session_prefixes_the_session_id_when_present
    out = eval_helper(%{(ENV['CLAUDE_CODE_SESSION_ID']='sess-z'; with_conductor_session("puts :ok"))}).strip
    assert_equal %(Current.try(:conductor_session_id=, "sess-z"); puts :ok), out,
                 "the snippet is prefixed with the in-band session id so prod can stamp the mascot"
  end

  def test_with_conductor_session_falls_back_to_codex_thread_id
    expr = %{(ENV.delete('CLAUDE_CODE_SESSION_ID'); ENV['CODEX_THREAD_ID']='codex-1'; with_conductor_session("puts :ok"))}
    assert_equal %(Current.try(:conductor_session_id=, "codex-1"); puts :ok), eval_helper(expr).strip
  end

  def test_with_conductor_session_is_a_no_op_without_a_session
    expr = %{(ENV.delete('CLAUDE_CODE_SESSION_ID'); ENV.delete('CODEX_THREAD_ID'); with_conductor_session("puts :ok"))}
    assert_equal "puts :ok", eval_helper(expr).strip,
                 "a session-less run passes the snippet through untouched"
  end

  # --- deploy-lane self-narration: Steffon assembles, Avi ships ---------------
  # bin/release opens+closes an AtomicEvent SPAN around its deploy phases stamped
  # with the ROLE soul the board already attributes them to — Steffon on prepare
  # (assemble → QA), Avi on ship (→ prod) — so the heartbeat's deploy spans match
  # the board's stage timeline. Best-effort + non-fatal: skipped under --dry-run
  # and when no conductor session is resolvable.

  # Capture the narration args instead of shelling out to the real bin/atomic-event.
  NARRATION_CAPTURE = <<~RUBY
    def atomic_event(*a) = $stdout.puts("ATOMIC " + a.join(" "))
  RUBY

  def test_narration_helpers_stamp_the_role_agent_and_close_with_an_outcome
    setup = <<~RUBY
      $events = []
      def atomic_event(*a) = ($events << a)
      def conductor_session_id = "sess-x"
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %(open_role_span("steffon", "assemble → deploy RC to QA"); ) +
                        %(close_role_span("assembled rel-x → QA"); print($events.inspect)))

    assert_includes out, %(["start", "--category", "Remote", "--reason", "assemble → deploy RC to QA", "--agent", "steffon"]),
                     "open_role_span opens a Remote span stamped with the role soul"
    assert_includes out, %(["end", "--outcome", "assembled rel-x → QA"]),
                     "close_role_span closes it with an outcome"
  end

  def test_atomic_event_is_a_noop_under_dry_run
    setup = %(def conductor_session_id = "sess-x")
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(print(atomic_event("start", "--category", "Remote", "--reason", "x").inspect)))
    assert_equal "nil", out, "a dry-run narrates nothing (best-effort no-op)"
  end

  def test_atomic_event_is_a_noop_without_a_conductor_session
    # NEUTRALIZED_ENV nulls the session vars → conductor_session_id is nil → no-op;
    # telemetry must never shell out (or fail) when there's no session to attribute.
    out = run_cli(["--yes"], setup: "",
                  call: %(print(atomic_event("start", "--category", "Remote", "--reason", "x").inspect)))
    assert_equal "nil", out, "no conductor session → nothing to narrate"
  end

  # [integration] prepare records a Steffon deploy span end-to-end (the paren
  # post_deploy stub reaches assemble under --yes; narration is captured, not shelled).
  def test_prepare_narrates_a_steffon_deploy_span
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB + NARRATION_CAPTURE)

    assert_includes out, "ATOMIC start --category Remote --reason sweep → deploy RC to QA --agent steffon",
                     "prepare opens a Steffon span"
    assert_match(/ATOMIC end --outcome assembled/, out, "and closes it once the RC is assembled")
  end

  # [integration] ship records an Avi deploy span end-to-end (the publish-decision
  # stub runs the real ship flow under --yes with only the git/gem/heroku I/O stubbed).
  def test_ship_narrates_an_avi_deploy_span
    out = run_cli(["--yes"], call: "ship", setup: PUBLISH_DECISION_STUB + NARRATION_CAPTURE)

    assert_includes out, "ATOMIC start --category Remote --reason ship → prod --agent avi",
                     "ship opens an Avi span after ship authority"
    assert_match(/ATOMIC end --outcome shipped/, out, "and closes it once shipped to prod")
  end

  # --- ship preflight: every app checkout on a clean `main` before any ff ----
  # ship ff's each app repo's main → frozen SHA; a checkout left on a pr-NNN
  # branch (review agent) or with a stale schema.rb breaks the ff mid-ship. The
  # preflight catches it BEFORE any ff. Drive ship_preflight directly with
  # repo_git_state stubbed (DRY=false via --yes) so no real sibling git runs.
  APP_GROUPS = %q([{ "repo" => "mcritchie-studio" }, { "repo" => "turf-monster" }])

  def test_ship_preflight_aborts_when_a_checkout_is_off_main
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        if repo == "turf-monster"
          { "repo" => repo, "branch" => "pr-161", "dirty" => false, "dirty_files" => [] }
        else
          { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [] }
        end
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "an off-main checkout aborts ship at the preflight"
    assert_includes out, "turf-monster", "the abort names the offending repo"
    assert_includes out, "pr-161", "the abort names the offending branch"
    refute_includes out, "PASSED", "ship must not proceed past a failed preflight"
  end

  def test_ship_preflight_aborts_on_a_dirty_main_tree
    # reconcile_offender stubbed to a no-op (returns the offender un-reconciled) so
    # the dirty offender stays BLOCKING — and, crucially, NO real git/reset runs
    # against the sibling checkout. The default-refuse (no reconcile_checked) keeps
    # this a hard abort, exactly as before the auto-clean pass existed.
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        files = repo == "mcritchie-studio" ? ["db/schema.rb"] : []
        { "repo" => repo, "branch" => "main", "dirty" => files.any?, "dirty_files" => files }
      end
      def reconcile_offender(offender) = offender
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED"
    assert_includes out, "db/schema.rb", "the abort names the dirty file"
  end

  def test_ship_preflight_passes_when_all_checkouts_are_on_clean_main
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); puts('PASSED'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "PASSED", "a clean-main batch passes the preflight"
    refute_includes out, "ABORTED"
  end

  def test_ship_dry_run_previews_the_preflight_without_touching_git
    # In dry-run the preflight prints its plan and runs NO real git (so a dry-run
    # never aborts on a legitimately-dirty dev sibling). repo_git_state raises if
    # consulted, proving the DRY branch skips it.
    setup = SHIP_STUB + %(\ndef repo_git_state(*); raise "git consulted in dry-run preflight"; end)
    out = run_cli(["--dry-run"], call: "ship", setup: setup)
    assert_includes out, "ship preflight", "ship previews the preflight in dry-run"
  end

  # --- ship preflight: generated artifacts are NOT counted as dirt -----------
  # A retro-*.md (bin/release retro) and the delete-later.md ledger (agent-worktree)
  # routinely sit uncommitted in the deploy checkout and blocked EVERY ship's ff.
  # The preflight now ignores those (allowlist) while STILL gating on real dirt.

  def test_ship_preflight_passes_when_only_generated_artifacts_are_dirty
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        files = repo == "mcritchie-studio" ?
          ["docs/agents/audits/retro-rel-20260624-b2f18e.md", "docs/agents/maintenance/delete-later.md"] : []
        { "repo" => repo, "branch" => "main", "dirty" => files.any?, "dirty_files" => files }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); puts('PASSED'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "PASSED", "a retro doc + the worktree ledger are generated artifacts, not real dirt"
    refute_includes out, "ABORTED"
  end

  def test_ship_preflight_still_aborts_on_real_dirt_beside_a_generated_artifact
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        files = repo == "mcritchie-studio" ?
          ["docs/agents/audits/retro-rel-1.md", "db/schema.rb"] : []
        { "repo" => repo, "branch" => "main", "dirty" => files.any?, "dirty_files" => files }
      end
      def reconcile_offender(offender) = offender
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "real code dirt still gates the ship"
    assert_includes out, "db/schema.rb", "the abort names the real dirty file"
    refute_includes out, "retro-rel-1.md", "the generated artifact is not named as dirt"
  end

  # --- ship preflight AUTO-CLEAN: the release-identical dirty-primary case ----
  # feedback_ship_preflight_dirty_primary: `bin/release merge` re-stages the merged
  # PR files on the primary's `main`, byte-identical to origin/release. That
  # redundant noise blocked EVERY ship's ff. Now the preflight auto-cleans it (reset
  # to origin/main; the ff re-applies release) and still refuses genuine local work.
  # The reconcile/reset git I/O are stubbed so no real sibling checkout is touched.

  def test_ship_preflight_auto_cleans_a_release_identical_dirty_primary
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        files = repo == "mcritchie-studio" ? ["db/schema.rb", "app/x.rb"] : []
        { "repo" => repo, "branch" => "main", "dirty" => files.any?, "dirty_files" => files }
      end
      # Facts say: on main, main behind release, and EVERY dirty file already on
      # origin/release → nothing local is lost → auto-cleanable.
      def reconcile_offender(offender)
        offender.merge("reconcile_checked" => true, "main_ancestor_of_release" => true, "unreconciled_files" => [])
      end
      def autoclean_primary!(offender) = puts("AUTOCLEANED " + offender["repo"] + ": " + offender["dirty_files"].join(","))
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "AUTOCLEANED mcritchie-studio: db/schema.rb,app/x.rb", "the release-identical primary is reset"
    assert_includes out, "PASSED", "the ship proceeds after the auto-clean"
    refute_includes out, "ABORTED", "a provably-safe dirty primary does not block the ship"
  end

  def test_ship_preflight_refuses_when_the_dirt_is_not_all_on_release
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        files = repo == "mcritchie-studio" ? ["db/schema.rb"] : []
        { "repo" => repo, "branch" => "main", "dirty" => files.any?, "dirty_files" => files }
      end
      # A dirty file that is NOT on origin/release = genuine local work → REFUSE,
      # never auto-reset (nothing is discarded without the operator).
      def reconcile_offender(offender)
        offender.merge("reconcile_checked" => true, "main_ancestor_of_release" => true, "unreconciled_files" => offender["dirty_files"])
      end
      def autoclean_primary!(offender) = puts("WRONGLY AUTO-CLEANED " + offender["repo"])
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "un-reconciled local dirt still blocks the ship"
    assert_includes out, "db/schema.rb", "the abort names the offending file"
    refute_includes out, "WRONGLY AUTO-CLEANED", "local work is NEVER discarded"
    refute_includes out, "PASSED"
  end

  # --- [integration] ship preflight auto-clean over a REAL git tree -----------
  # The stubbed tests above cover the WIRING; this drives the DESTRUCTIVE seams for
  # real — reconcile_offender → file_on_release? → autoclean_primary! (the actual
  # `git reset --hard origin/main`) — against a temp primary checkout with real
  # origin/main + origin/release refs. A boolean inversion in file_on_release? or a
  # wrong ref in autoclean_primary! would silently reset a live primary and destroy
  # un-merged work with the suite still green; this is the test that would catch it.
  # NONE of the three seams are stubbed (only repo_path is redirected to the temp
  # repo). Covers the full adversarial matrix the design claims to handle.

  # A temp PRIMARY checkout on `main` with real remote-tracking refs: origin/release
  # is AHEAD of origin/main (release ADDS from_release.rb; main is a clean ancestor).
  # Yields the repo dir, with the working `main` reset to a clean origin/main.
  def with_primary_repo
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      File.write(File.join(dir, "shared.rb"), "base\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m base")
      git.call("branch -M main")
      git.call("update-ref refs/remotes/origin/main HEAD")     # origin/main = base
      File.write(File.join(dir, "from_release.rb"), "release-added\n")
      git.call("add -A")
      git.call("commit -q -m release")
      git.call("update-ref refs/remotes/origin/release HEAD")  # origin/release ahead of main
      git.call("reset --hard refs/remotes/origin/main")        # working main behind release, clean
      yield dir
    end
  end

  # Drive the REAL ship_preflight against `dir`: only repo_path is redirected; the
  # reconcile / file_on_release? / reset seams all run for real. Returns the output.
  def run_real_preflight(dir)
    run_cli(["--yes"], setup: %(def repo_path(_repo) = #{dir.inspect}),
            call: "begin; ship_preflight([{ 'repo' => 'mcritchie-studio' }]); puts('PASSED'); " \
                  "rescue SystemExit => e; puts('ABORTED: ' + e.message); end")
  end

  def porcelain(dir)
    IO.popen(["git", "-C", dir, "status", "--porcelain"], &:read).to_s.strip
  end

  def test_ship_preflight_real_git_autoclean_adversarial_matrix
    # (1) A release-identical STAGED file → AUTO-CLEANED. The real `git reset --hard
    #     origin/main` runs; the working tree ends clean and nothing is lost (the
    #     discarded content still lives on origin/release, which the ship ff re-applies).
    with_primary_repo do |dir|
      File.write(File.join(dir, "from_release.rb"), "release-added\n") # byte-identical to origin/release
      assert system("git -C #{dir} add from_release.rb")
      out = run_real_preflight(dir)

      assert_includes out, "PASSED", out
      refute_includes out, "ABORTED", out
      assert_match(%r{auto-cleaning with `git reset --hard origin/main`}, out, "the real reset path ran")
      assert_equal "", porcelain(dir), "auto-clean leaves the working tree clean"
      assert system("git -C #{dir} rev-parse --verify --quiet origin/release:from_release.rb >/dev/null"),
             "nothing lost: the discarded content still lives on origin/release"
    end

    # (2) A genuinely-new UNTRACKED file mixed in with release-identical dirt → REFUSED.
    #     NO reset runs, and the untracked local work survives intact.
    with_primary_repo do |dir|
      File.write(File.join(dir, "from_release.rb"), "release-added\n")
      assert system("git -C #{dir} add from_release.rb")               # release-identical, staged
      File.write(File.join(dir, "brand_new.rb"), "unmerged local work\n") # untracked, NOT on release
      out = run_real_preflight(dir)

      assert_includes out, "ABORTED", out
      refute_includes out, "PASSED", out
      refute_match(%r{auto-cleaning}, out, "no reset is attempted when any dirt is unreconciled")
      assert_equal "unmerged local work\n", File.read(File.join(dir, "brand_new.rb")),
                   "untracked local work is NEVER discarded — no reset ran"
      assert File.exist?(File.join(dir, "from_release.rb")), "no reset ran, so the staged file also remains"
    end

    # (3) A locally-modified TRACKED file whose content is NOT on release → REFUSED.
    #     The local modification survives (no reset).
    with_primary_repo do |dir|
      File.write(File.join(dir, "shared.rb"), "local hack not on release\n")
      out = run_real_preflight(dir)

      assert_includes out, "ABORTED", out
      refute_includes out, "PASSED", out
      assert_equal "local hack not on release\n", File.read(File.join(dir, "shared.rb")),
                   "a tracked local change not on release survives — no reset ran"
    end
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

  # --- crew-ticker intents are BEST-EFFORT — never abort a deploy (PR #229 QA rework) ---
  #
  # `prepare` (Steffon assembled QA intent) and `ship` (Avi shipped intent) auto-record
  # a COSMETIC /deployments crew-ticker intent. conductor() abort!s (→ SystemExit) on ANY
  # non-zero heroku-run exit, so a transient prod-board outage — the documented 2026-06-25
  # essential-PG "too many connections" incidents — on this cosmetic write would otherwise
  # abort a production deploy. record_deploy_intent wraps the write best-effort (rescue
  # SystemExit, StandardError → warn → continue), mirroring bin/reviewer-select's
  # best-effort review-intent write. These stubs make conductor abort! on the intent
  # snippet ONLY (the exact production failure mode) and prove the deploy still proceeds.

  # The repo plan succeeds; the crew-ticker intent write abort!s (transient prod-board).
  INTENT_FAIL_PREPARE_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      abort!("record op failed:\\nFATAL: remaining connection slots are reserved") if ruby.include?("record_deploy_intents!")
      return { "tasks" => [], "release" => { "slug" => "rel-cli", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
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

  def test_prepare_continues_when_the_crew_ticker_intent_write_fails
    out = run_cli(["--dry-run"], call: "prepare", setup: INTENT_FAIL_PREPARE_STUB)

    assert_includes out, "crew-ticker board write failed",
                     "the cosmetic intent write WARNS on a transient prod-board failure (it does not abort)"
    assert_includes out, "deploy continues",
                     "the warning states the deploy is not aborted"
    assert_includes out, "bin/qa-server deploy mcritchie-studio origin/release",
                     "prepare PROCEEDS to the QA deploy — the failed cosmetic intent's SystemExit did NOT abort it"
  end

  # SHIP_STUB's full plan + the intent write abort!ing (the prod-board failure).
  INTENT_FAIL_SHIP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      abort!("record op failed:\\nFATAL: remaining connection slots are reserved") if ruby.include?("record_deploy_intents!")
      return {} unless ruby.include?("repo_plan")
      { "slug" => "rel-ship", "state" => "assembled", "branch" => "release",
        "qa_shas" => {
          "studio-engine" => "aaaaaaa1111111111111111111111111111111111",
          "turf-monster" => "ccccccc3333333333333333333333333333333333",
          "mcritchie-studio" => "bbbbbbb2222222222222222222222222222222222"
        },
        "repos" => [
          { "repo" => "studio-engine", "kind" => "gem", "prod_deploy" => nil,
            "members" => [{ "slug" => "t-gem", "version" => "0.9.0", "branch" => nil }] },
          { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
            "members" => [{ "slug" => "t-turf", "version" => nil, "branch" => "feat/turf" }],
            "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy", "args" => ["--yes"] } },
          { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
            "members" => [{ "slug" => "t-studio", "version" => nil, "branch" => "feat/studio" }],
            "prod_deploy" => { "strategy" => "git_push_heroku", "remote" => "heroku",
                               "branch" => "main", "smoke_url" => "https://mcritchie.studio" } }
        ] }
    end
  RUBY

  def test_ship_continues_when_the_crew_ticker_intent_write_fails
    out = run_cli(["--dry-run"], call: "ship", setup: INTENT_FAIL_SHIP_STUB)

    assert_includes out, "crew-ticker board write failed",
                     "the cosmetic ship-slot intent write WARNS on a transient prod-board failure"
    assert_includes out, "deploy continues",
                     "the warning states the production deploy is not aborted"
    assert_includes out, "push heroku main",
                     "ship PROCEEDS to the production deploy — the failed cosmetic intent's SystemExit did NOT abort it"
  end

  # Guard against over-broadening: making the COSMETIC intent best-effort must NOT swallow
  # real deploy errors. A non-intent conductor failure (here the deploy-critical repo-plan
  # read) is FATAL and must STILL abort — record_deploy_intent's rescue is scoped to the
  # intent write alone, never the deploy path.
  def test_real_deploy_conductor_failures_still_abort_prepare
    setup = %(def conductor(ruby, read_only: false); abort!("record op failed: prod board down"); end)
    out = run_cli(["--dry-run"], setup: setup,
                  call: "begin; prepare; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a real (non-intent) conductor failure still aborts the deploy"
    assert_includes out, "prod board down", "the abort surfaces the real failure cause"
    refute_includes out, "NO-ABORT", "the best-effort rescue must not swallow a deploy-critical conductor failure"
  end
end
