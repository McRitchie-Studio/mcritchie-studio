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
require "fileutils" # lock_dir cleanup (Minitest.after_run remove_entry)
require "English"   # $CHILD_STATUS — the gate-lock queue test reaps its own child
require_relative "../support/session_env"

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
  # Every release subprocess runs session-less, via the SHARED neutralizer
  # (test/support/session_env.rb — the same one every spawner test uses). A live
  # Claude/Codex session exports CLAUDE_CODE_SESSION_ID / CODEX_THREAD_ID, which the
  # subprocess would otherwise inherit — making bin/release's best-effort deploy-lane
  # narration (agent_activity) resolve a real session and shell out to bin/atomic-event
  # mid-test. Neutralizing them keeps narration inert unless a test opts in (the
  # deploy-span tests stub agent_activity directly). Tests that need a session set it
  # inline via ENV[...] (see the with_conductor_session tests).

  # ISOLATE the primary-checkout lock dir for EVERY release subprocess. The
  # real <projects_root>/.agents/locks dir belongs to the live conductor: a G3
  # pre-QA gate HOLDS the hub lock there for its WHOLE suite run — which
  # includes THIS file — so any child that touched the real dir would either
  # deadlock the gate against its own suite (pre_qa_gate / ff_main_local wait
  # on the lock the gate holds; run_ruby has no timeout) or flake on contention
  # (the artifact dance's busy-skip changes its output). Reproduced as a wedge
  # in activity-1307. Lazy + memoized so forked test workers each get their own
  # dir; tests that assert lock SEMANTICS still override it per-test inside the
  # child (ENV["MCR_PRIMARY_LOCK_DIR"] in their setup).
  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("release-cli-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # A throwaway stand-in for a sibling repo CHECKOUT, for the stubs whose `sh` is
  # fully faked (their assertions never depend on the repo's identity on disk).
  # It replaces the old `def repo_path(_repo) = Dir.pwd`: a gate now MATERIALIZES
  # its isolated workspace under <repo>/.worktrees/_gate (a real `mkdir_p` before
  # the stubbed `git worktree add`), and Dir.pwd is the RUNNING checkout — a
  # stubbed gate would litter the live repo with an empty `.worktrees/`. Memoized
  # + removed after the run, like lock_dir.
  def self.stub_repo
    @stub_repo ||= begin
      dir = Dir.mktmpdir("release-cli-repo")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # The SHA a stubbed `git rev-parse origin/release` answers with. The gate now
  # RESOLVES the SHA under test and pins its isolated workspace at it, so a stub
  # that answers rev-parse with "" aborts the gate ("no SHA to pin the isolated
  # gate checkout at") long before the suite.
  GATE_SHA = "f00dcafe11111111111111111111111111111111"

  # The gate's git/DB PLUMBING, canned — prepended to every stub whose test rides
  # a real pre_qa_gate/test_gate but is not asserting on the plumbing itself:
  #   * `git rev-parse origin/release` → the SHA under test (see GATE_SHA),
  #   * the workspace pin (`git worktree add|prune` / `reset` / `clean`) → ok,
  #   * `bin/rails runner` — the PRIVATE-DB PROBE (assert_private_gate_db!) →
  #     answered the way a COMPLIANT app would: it echoes back the DATABASE_URL the
  #     gate overlaid (a postgres app: Rails merges that builtin into the test
  #     config), or, when the gate overlaid NO url (a SQLite app — rolio), a file
  #     INSIDE the gate workspace. Both satisfy GateWorkspace.private_db?, so the
  #     plumbing rides on; the tests that OWN this probe answer it themselves.
  #   * `bin/rails db:test:prepare` (the gate DB, exactly what CI runs) → ok.
  # BOTH `bin/rails` subcommands key on a[1] — `runner` and `db:test:prepare` share
  # an argv[0].
  # It returns nil for everything else, so each stub's own `sh` keeps full control
  # of the commands it asserts on (`g = gate_git(a, k); return g if g` first, then
  # the test's own branches). Every stub must take **k and pass it: the probe's
  # answer depends on the env overlay + chdir the gate hands the command.
  GATE_GIT_STUB = <<~RUBY
    GATE_SHA = #{GATE_SHA.inspect}
    def gate_git(a, k)
      return [GATE_SHA, true] if a[0] == "git" && a.include?("rev-parse")
      return ["", true] if a[0] == "git" && %w[fetch worktree reset clean].include?(a[3].to_s)
      if a[0] == "bin/rails" && a[1] == "runner"
        url = k[:env].to_h["DATABASE_URL"].to_s
        db  = url.empty? ? File.join(k[:chdir].to_s, "storage", "test.sqlite3") : url.split("/").last
        return ["GATEDB=" + db, true]
      end
      return ["", true] if a[0] == "bin/rails" && a[1] == "db:test:prepare"
      nil
    end
  RUBY

  # A postgres `config/database.yml` for a fixture repo. Release::GateWorkspace
  # reads the app's OWN file to decide whether the gate needs a DB url at all
  # (postgres → the private gate DB; SQLite → none, its test DB is already a file
  # inside the workspace), so a fixture that asserts on the DB overlay must carry
  # one. Planted in the PRIMARY (that is the path database_url_for reads).
  def plant_database_yml(repo_path, adapter: "postgresql")
    FileUtils.mkdir_p(File.join(repo_path, "config"))
    File.write(File.join(repo_path, "config", "database.yml"), <<~YML)
      default: &default
        adapter: #{adapter}
      test:
        <<: *default
        database: fixture_test
    YML
    repo_path
  end

  # An unroutable loopback base for TASK_API_BASE. Every OTHER board-touching CLI
  # suite (task_cli, task_begin, reviewer_select, statusline, session_preflight)
  # pins TASK_API_BASE at a local stub server; THIS file pinned nothing, and that
  # gap reached production data: `retro`'s follow-up filing shells out to
  # bin/triage, which defaults to https://mcritchie.studio, so every run of
  # test_retro_collects_repeated_answer_flags_into_the_runner_payload filed a REAL
  # "fix flake" finding into the operator's live triage inbox. That is where 39 of
  # the 86 open findings came from — the suite, not a release.
  #
  # A stub server would be the richer fix; fail-closed is the SAFER one and needs
  # no server: any board call from this suite gets connection-refused on a
  # loopback port instead of reaching production. Every test here stubs
  # `conductor` (the board seam) already, so a real board call in this file is a
  # bug by definition and should fail locally rather than succeed remotely.
  UNROUTABLE_API_BASE = "http://127.0.0.1:1"

  def run_ruby(script)
    # SEAL_RETRY_DELAY_SECONDS=0: these subprocesses drive the REAL ship seal
    # (production_smoke_seal), whose red path retries once after a 30s
    # boot-window wait. A sleeper cannot be injected through the loaded script,
    # so without this every red-seal test below would burn a genuine 30s. Zero
    # keeps the retry PATH exercised end-to-end at no wall-clock cost.
    env = SessionEnv.neutralized(
      "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir,
      "SEAL_RETRY_DELAY_SECONDS" => "0",
      "TASK_API_BASE" => UNROUTABLE_API_BASE
    )
    last = nil
    SUBPROCESS_ATTEMPTS.times do
      out, err, status = Open3.capture3(env, "ruby", "-e", script)
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

  # run_ruby, but with MCR_PRIMARY_LOCK_DIR explicitly UNSET — the fallback that
  # reaches the operator's real lock dir. (run_ruby pins it, which is the point of it.)
  def run_ruby_unpinned(script)
    env = SessionEnv.neutralized("MCR_PRIMARY_LOCK_DIR" => nil)
    out, err, status = Open3.capture3(env, "ruby", "-e", script)
    assert_predicate status, :success?, "the abort must be caught in-process, not crash the child: #{err}"
    out
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

  # The ISOLATED GATE WORKSPACE for a repo — <repo>/.worktrees/_gate — resolved
  # through bin/release's OWN seam (Release::GateWorkspace.path + repo_path,
  # each unit-tested on its own), so an assertion never re-implements the
  # sibling-path climb it is checking.
  def gate_workspace_path(repo)
    eval_helper(%(Release::GateWorkspace.path(repo_path(#{repo.inspect}))))
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

  # [integration] THE PLACEMENT FIX (rel-20260809-3b8f3d, 2026-08-09). The guard
  # used to run inside the QA-deploy loop, i.e. AFTER the pre-QA gate — so a merge
  # that landed moved origin/release PAST the SHA the gate had just certified, and
  # QA deployed (and ship froze) a tree G3 never verified. It now runs above the
  # gate, and this pins that order in the real emitted plan, not just in the source.
  def test_prepare_dry_run_merge_forward_precedes_the_gate_and_the_qa_deploy
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    # Anchor on each phase's OWN step line. Plain "pre-QA gate" also appears in
    # the lock-bump message ("…the pre-QA gate, QA, and prod must all build this
    # SAME committed lock"), which sits earlier and would make this pass on prose.
    merge  = out.index("merge-forward guard: origin/release must CONTAIN")
    gate   = out.index("pre-QA gate: GitHub CI")
    deploy = out.index("bin/qa-server deploy")

    assert merge && gate && deploy, "the plan must show all three phases: #{out}"
    assert_operator merge, :<, gate,
                    "merge-forward comes BEFORE the gate, so the gate certifies the tree that deploys"
    assert_operator gate, :<, deploy, "the gate still precedes the QA deploy"
  end

  # A deploy plan where the hub carries the github_actions adapter (as the real
  # registry now does) alongside a repo_script app, so prepare's QA path dispatches
  # qa-deploy.yml for the hub while the non-Actions app keeps the qa-server push.
  GHA_QA_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-gha", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      { "slug" => "rel-gha", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
          "qa_app" => "mcritchie-studio",
          "prod_deploy" => { "strategy" => "github_actions", "workflow" => "prod-deploy.yml" },
          "members" => [{ "slug" => "t-studio", "branch" => "feat/studio" }] },
        { "repo" => "turf-monster", "kind" => "app", "release_branch" => "release",
          "qa_app" => "turf-monster",
          "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy", "args" => ["--yes"] },
          "members" => [{ "slug" => "t-turf", "branch" => "feat/turf" }] }
      ] }
    end
  RUBY

  # DevOps v2 Phase 2: the hub's QA deploy is scoped by prod_deploy strategy. A
  # github_actions app dispatches ONE qa-deploy.yml run at the release tip
  # (workflow_dispatch, so the N PR-merge pushes of the sweep don't fire N deploys);
  # a non-Actions app keeps the local qa-server force-push, byte-unchanged.
  def test_prepare_dry_run_dispatches_github_actions_qa_only_for_the_hub
    out = run_cli(["--dry-run"], call: "prepare", setup: GHA_QA_STUB)

    assert_includes out, "gh workflow run qa-deploy.yml",
                     "the hub (github_actions) dispatches qa-deploy.yml for QA, not qa-server"
    refute_includes out, "bin/qa-server deploy mcritchie-studio",
                     "the hub no longer QA-deploys via qa-server"
    assert_includes out, "bin/qa-server deploy turf-monster origin/release",
                     "a non-github_actions app keeps the qa-server force-push (mechanic scoped to the hub)"
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
    assert_includes out, "rides the release",
                    "a gem member is published before QA + verified at ship — never QA-deployed itself"
  end

  # --- prepare: producer-first gem publish + consumer lock bump (before QA) ----
  #
  # publish-gems-before-qa: prepare publishes each swept gem member's
  # origin/release version and commits each consumer's Gemfile.lock bump onto its
  # release branch BEFORE the pre-QA gate reads CI's verdict and BEFORE any QA
  # deploy — so the gate's SHA, the QA tree, and the prod tree are the SAME tree
  # (ship's publish stays as the idempotent verify). These drive the REAL prepare
  # flow with the publish/bump I/O seams stubbed: RubyGems, the ship workspace,
  # bundler, and every git read/write — no network, no real remotes.

  # `version` is what origin/release's version_file declares; the last published
  # tag is pinned at v0.10.0 and the tip is one commit past it, so:
  #   version 1.0.0/0.11.0 → bumped (healthy publish); 0.10.0 → STRANDED (guard).
  # `live` is the RubyGems listing; `lock_dirty` is whether the bundle-lock run
  # left the workspace lock changed (false = already-bumped idempotent re-run).
  #
  # This double models bundler's EFFECT ON THE LOCKFILE, not just its exit status:
  # it rewrites the resolved version, because prepare now reads that version back.
  # The propagation-lag case (exit 0, OLD version still resolved) is deliberately
  # NOT expressible here — this stub REPLACES bundle_lock, so simulating the
  # failure would only assert the double. That case is driven against the live
  # implementation by stubbing `sh` instead; see
  # test_bundle_lock_retries_a_stale_resolution_then_aborts_naming_the_compact_index.
  # `allocate: false` stubs step 4d's PHASE 0 (`allocate_gem_versions!`) to a
  # no-op. Prepare normally allocates each swept gem's version before phase 1
  # reads it, which means the stranded-work guard has nothing left to catch on
  # the happy path — so the two guard tests below drive the state the guard
  # actually exists for: allocation skipped, refused, or wrong. Allocation's own
  # behaviour is driven against REAL git in test/lib/release_gem_allocation_test.rb.
  def gem_publish_stub(version: "1.0.0", live: [], lock_dirty: true, allocate: true)
    GATE_GIT_STUB +
      (allocate ? "" : %(def allocate_gem_versions!(_groups) = nil\n)) +
      %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
      %(def repo_path(_repo) = #{self.class.stub_repo.inspect}\n) +
      %(def gem_version_from_ref(_repo, _ref) = #{version.inspect}\n) +
      %(def rubygems_versions(_gem) = #{live.inspect}\n) +
      %(LOCK_DIRTY = #{lock_dirty.inspect}\n) +
      %(PUBLISHED_VERSION = #{version.inspect}\n) +
      %(STALE_LOCK_VERSION = "0.10.0"\n) + <<~'RUBY'
        def conductor(ruby, read_only: false)
          return { "tasks" => [], "release" => { "slug" => "rel-gempub", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
          return { "state" => "assembled" } if ruby.include?("qa_green!")
          { "slug" => "rel-gempub", "state" => "assembling", "branch" => "release", "repos" => [
            { "repo" => "studio-engine", "kind" => "gem", "members" => [{ "slug" => "t-gem", "branch" => nil }] },
            { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
              "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "t-studio", "branch" => "feat/s" }] }
          ] }
        end
        def repo_git_state(repo, _path) = { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
        def git_capture(*a)
          j = a.join(" ")
          return ["v0.10.0", true] if j.include?("describe")
          return ["abc123 stranded engine commit", true] if j.include?("log --oneline")
          return [(LOCK_DIRTY ? " M Gemfile\n M Gemfile.lock" : ""), true] if j.include?("status --porcelain")
          # Phase 1's consumer-coverage read: the swept app's Gemfile AT origin/release.
          return [%(gem "studio-engine", "~> 0.10"\n), true] if j.include?(":Gemfile")
          return [GATE_SHA, true] if j.include?("rev-parse")
          ["", true]
        end
        def with_ship_workspace(_repo) = yield
        # The workspace starts with a Gemfile.lock resolving the OLD version —
        # what a consumer checkout really looks like before the bump.
        def ship_workspace!(repo, _sha)
          dir = File.join(Dir.tmpdir, "prep-ws-#{Process.pid}-#{repo}")
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "Gemfile"), %(gem "studio-engine", "~> 0.10"\n))
          File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
            GEM
              remote: https://rubygems.org/
              specs:
                studio-engine (#{STALE_LOCK_VERSION})

            DEPENDENCIES
              studio-engine (~> 0.10)
          LOCK
          dir
        end
        # Model bundler's REAL effect on the lockfile, not just its exit status:
        # it rewrites the resolved version when it can see the gem, and silently
        # leaves the old one when the index has not propagated. Both exit 0.
        #
        # This stands in for the `bundle` INVOCATION, so it keeps bundle_lock's
        # full signature (including `expect:`); the LADDER itself — retry on a
        # stale resolution, then abort — is driven for real in
        # test_prepare_retries_then_aborts_when_the_lock_never_lands, which stubs
        # `sh` instead of this.
        # Stubbed for the same reason bundle_lock is: these tests are about the
        # BUMP flow, and the install does real bundler/rails work in a workspace
        # that is a bare tmpdir here. Its own behaviour — the bundle-first order,
        # the discriminating probe, the abort on an unbootable app — is driven
        # against the live implementation in the three tests that stub `sh`.
        def install_engine_migrations!(_workspace, repo, gem_names)
          $stdout.puts("MIGRATION-INSTALL #{repo} #{gem_names.join(',')}")
        end
        def bundle_lock(path, gem, attempts: 3, conservative: false, expect: nil)
          $stdout.puts("BUNDLE-LOCK #{gem} conservative=#{conservative} expect=#{expect}")
          lock = File.join(path, "Gemfile.lock")
          File.write(lock, File.read(lock).sub(/^    #{Regexp.escape(gem)} \([^)]+\)$/,
                                               "    #{gem} (#{PUBLISHED_VERSION})"))
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          if a[0] == "gem" && a[1] == "build"
            $stdout.puts("GEM-BUILD")
            return ["", true]
          end
          if a[0] == "gem" && a[1] == "push"
            $stdout.puts("GEM-PUSH")
            return ["", true]
          end
          if a[0] == "git" && a.include?("add")
            gemfile = File.join(a[a.index("-C") + 1].to_s, "Gemfile")
            $stdout.puts("GEMFILE-AFTER " + File.read(gemfile).strip) if File.exist?(gemfile)
            return ["", true]
          end
          if a[0] == "git" && a.any? { |x| x.to_s == "HEAD:refs/heads/release" }
            $stdout.puts("LOCK-PUSH")
            return ["", true]
          end
          $stdout.puts("QA-DEPLOY") if a[0] == "bin/qa-server"
          return ["200", true] if a.join(" ").include?("curl")
          ["", true]
        end
      RUBY
  end

  # [integration] The ordering that IS the feature: gem publish → consumer lock
  # bump commit → pre-QA gate → QA deploy. The lock commit landing BEFORE the gate
  # is what points the CI verdict at the post-bump release SHA.
  def test_prepare_publishes_gems_and_bumps_locks_before_the_pre_qa_gate_and_qa_deploy
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub)

    publish = out.index("GEM-PUSH")
    bump    = out.index("LOCK-PUSH")
    gate    = out.index("pre-QA gate mcritchie-studio")
    deploy  = out.index("QA-DEPLOY")
    assert publish && bump && gate && deploy,
           "publish, lock-bump, gate, and QA deploy must ALL appear: #{out}"
    assert_operator publish, :<, bump,   "gems publish before any consumer lock bump (producer-first)"
    assert_operator bump, :<, gate,      "the lock bump commits BEFORE the pre-QA gate reads origin/release"
    assert_operator gate, :<, deploy,    "the gate still precedes the QA deploy"
    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0",
                    "a single-gem bump uses conservative lock semantics"
    assert_includes out, "committed studio-engine 1.0.0",
                    "the bump commit narrates what landed on origin/release"
  end

  # [integration] The constraint-escape rule: `~> 0.10` HOLDS a minor bump
  # (lock-only — the Gemfile pin is untouched) and is REWRITTEN by a major bump
  # that escapes it.
  def test_prepare_rewrites_the_consumer_pin_only_when_the_published_version_escapes_it
    escaped = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0"))
    assert_includes escaped, %(GEMFILE-AFTER gem "studio-engine", "~> 1.0"),
                    "a major bump escapes `~> 0.10` — the pin advances with the lock"

    held = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "0.11.0"))
    assert_includes held, %(GEMFILE-AFTER gem "studio-engine", "~> 0.10"),
                    "a minor bump is WITHIN `~> 0.10` — lock-only, the pin stays"
    assert_includes held, "BUNDLE-LOCK studio-engine conservative=true expect=0.11.0"
  end

  # [integration] The STRANDED-WORK guard: origin/release ahead of the last
  # published tag with an UNBUMPED version_file must BLOCK loudly BEFORE anything
  # publishes or deploys — the silent publish-skip that stranded engine commits.
  #
  # THE GUARD IS NOW A BACKSTOP, and this drives it as one. Step 4d's phase 0
  # allocates the version, so on the happy path prepare fixes this state before
  # the guard ever sees it — which is exactly why the guard must keep firing when
  # allocation does NOT happen (skipped, refused, or wrong). `allocate: false`
  # models that, and the guard has to behave precisely as it always did.
  def test_prepare_blocks_loudly_on_stranded_gem_work_when_allocation_did_not_run
    out = run_cli(["--yes"], setup: gem_publish_stub(version: "0.10.0", allocate: false),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "stranded gem work must abort prepare, never silently skip"
    assert_includes out, "abc123 stranded engine commit", "the abort NAMES the stranded commits"
    assert_includes out, "STRANDING"
    assert_includes out, "Bump the version in studio-engine/", "the abort hands over the exact fix"
    assert_includes out, "re-run `bin/release prepare`"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes past the guard"
    refute_includes out, "LOCK-PUSH", "no lock bump past the guard"
    refute_includes out, "QA-DEPLOY", "no QA deploy past the guard"
  end

  # [integration] THE PROPAGATION-LAG GUARD (rel-20260809-3b8f3d, 2026-08-09).
  #
  # `bundle lock --update` exits 0 whether or not it could SEE the version we
  # published seconds earlier. When the RubyGems index has not propagated it
  # resolves the OLD version and leaves the tree unchanged — which is byte-for-byte
  # what a genuine already-bumped re-run looks like. prepare used to read that
  # unchanged tree and announce "lock already at studio-engine 1.0.0", a version it
  # had never read. turf-monster rode QA on the old engine while the release record
  # asserted the new one, and the pre-QA gate CREDITED its identical-tree green, so
  # no CI run contradicted it either.
  #
  # [integration] THE CALLER'S HALF of the guarantee: prepare hands every touched
  # gem's PUBLISHED version to bundle_lock as `expect:`, so the read-back+ladder
  # can run at all. Without this wiring the guard is inert no matter how correct
  # bundle_lock is.
  #
  # (The abort itself is NOT asserted here on purpose. This harness stubs
  # bundle_lock wholesale, so an abort in this test would come from the stub, not
  # the code — it would assert the double. The real refusal and its retry ladder
  # are driven against the live implementation in
  # test_bundle_lock_retries_a_stale_resolution_then_aborts_naming_the_compact_index.)
  def test_prepare_passes_the_published_version_to_bundle_lock_as_expect
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: ["1.0.0"], lock_dirty: false))

    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0",
                    "prepare must tell bundle_lock which version has to land: #{out}"

    # The old wording was the lie itself — a version claimed but never read. It
    # must not survive anywhere, even on the genuine no-op path.
    refute_includes out, "lock already at",
                     "prepare must never claim a version it has not read out of the lockfile"
    assert_includes out, "lock verified at studio-engine 1.0.0",
                    "the no-op message is now EARNED — bundle_lock proved the version before returning"
  end

  # [integration] THE LADDER, driven for real. The stub above replaces
  # bundle_lock wholesale, so it proves the CALLER refuses a stale lock but says
  # nothing about the retry. Here `sh` is stubbed instead: `bundle lock` "succeeds"
  # every time while the lockfile stays stale, so the REAL bundle_lock runs its
  # propagation ladder — retry, retry, then abort.
  #
  # This is review finding (1): the ladder already existed but only ever retried a
  # NON-ZERO exit, and this bug's signature is exit 0 with the old version still
  # resolved. Aborting on first observation would turn an ordinary, self-curing
  # index delay into a manual stop moments after an IRREVERSIBLE gem push.
  def test_bundle_lock_retries_a_stale_resolution_then_aborts_naming_the_compact_index
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            studio-engine (0.10.0)
      LOCK

      setup = %(ENV["RELEASE_BUNDLE_LOCK_BACKOFF"] = "0"\n) + <<~'RUBY'
        # `bundle` always succeeds; the lockfile never changes — the propagation case.
        def sh(*a, **k)
          $stdout.puts("BUNDLE-RAN") if a[0] == "bundle"
          ["", true]
        end
      RUBY

      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; bundle_lock(#{dir.inspect}, "studio-engine", expect: "1.0.0"); } +
                          %{puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_equal 3, out.scan("BUNDLE-RAN").size,
                   "the stale resolution must ride the SAME 3-attempt ladder a non-zero exit does: #{out}"
      assert_includes out, "resolves 0.10.0, wanted 1.0.0",
                      "each retry names what it actually saw"
      assert_includes out, "ABORTED", "and it aborts once the ladder is exhausted"
      refute_includes out, "NO-ABORT"

      # Point at the surface BUNDLER reads. What failed is `bundle lock`, and
      # bundler resolves through the COMPACT INDEX. The versions JSON API (what
      # rubygems_versions reads, for publish idempotency only) and the HTML gem
      # page are separate services with their own CDN caching, so a version
      # visible on either is not proof bundler can resolve it — and an operator
      # who waits on one re-enters the publish branch, gets `gem push` refused as
      # already-live, and is then advised to bump — burning a number for nothing.
      assert_includes out, "https://index.rubygems.org/info/studio-engine",
                      "the abort names the compact index bundler resolves through"
      refute_includes out, "https://rubygems.org/api/v1/versions/studio-engine.json",
                       "never send the operator to the versions JSON API — bundler does not read it"
      refute_includes out, "https://rubygems.org/gems/studio-engine",
                       "never send the operator to the HTML gem page either"
    end
  end

  # [integration] A lock that DOES land mid-ladder stops retrying and returns.
  def test_bundle_lock_stops_as_soon_as_the_version_lands
    Dir.mktmpdir do |dir|
      lock = File.join(dir, "Gemfile.lock")
      File.write(lock, "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (0.10.0)\n")

      setup = %(ENV["RELEASE_BUNDLE_LOCK_BACKOFF"] = "0"\n) +
              %(LOCKFILE = #{lock.inspect}\n) + <<~'RUBY'
                # Propagation arrives on the SECOND attempt.
                $attempt = 0
                def sh(*a, **k)
                  if a[0] == "bundle"
                    $attempt += 1
                    $stdout.puts("BUNDLE-RAN #{$attempt}")
                    if $attempt >= 2
                      File.write(LOCKFILE, File.read(LOCKFILE).sub("(0.10.0)", "(1.0.0)"))
                    end
                  end
                  ["", true]
                end
              RUBY

      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; bundle_lock(#{dir.inspect}, "studio-engine", expect: "1.0.0"); } +
                          %{puts("LANDED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "LANDED", "a version that arrives mid-ladder must succeed: #{out}"
      assert_equal 2, out.scan(/BUNDLE-RAN \d/).size, "and stop retrying the moment it lands"
      refute_includes out, "ABORTED"
    end
  end

  # [integration] The self-healing re-run: version already live + lock already
  # bumped → publish and commit both skip, and the QA half still runs.
  def test_prepare_gem_publish_and_lock_bump_are_idempotent_on_a_re_run
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: [{ "number" => "1.0.0" }], lock_dirty: false))

    assert_includes out, "already live on RubyGems — skip publish", "an already-published version skips"
    assert_includes out, "nothing to commit (idempotent re-run)", "an already-bumped lock commits nothing"
    refute_includes out, "GEM-BUILD"
    refute_includes out, "GEM-PUSH"
    refute_includes out, "LOCK-PUSH"
    assert_includes out, "QA-DEPLOY", "the re-run still deploys QA (self-healing resumes the deploy half)"
  end

  def test_prepare_dry_run_previews_the_gem_publish_and_lock_bump_without_executing
    out = run_cli(["--dry-run"], call: "prepare", setup: gem_publish_stub)

    assert_includes out, "stranded-work guard", "the dry run previews the guard"
    assert_includes out, "bump consumer locks", "the dry run previews the consumer bump"
    assert_includes out, "idempotent; no-op when already current"
    refute_includes out, "GEM-BUILD", "a dry run builds nothing"
    refute_includes out, "GEM-PUSH", "a dry run publishes nothing"
    refute_includes out, "BUNDLE-LOCK", "a dry run locks nothing"
    refute_includes out, "LOCK-PUSH", "a dry run pushes nothing"
  end

  # --- prepare: the two-phase preflight (validate EVERY gem, THEN publish) ----
  #
  # A RubyGems push can never be re-pushed, so phase 1 must validate ALL swept
  # gems before phase 2 pushes the first one. These vectors pin the discipline:
  # a LATE validation failure publishes ZERO gems, and a failed fetch fails
  # closed instead of publishing from a stale origin/release.

  # A second gem member (solana-studio) rides the same release. Its version is
  # parametrized per-repo so one gem can be healthy while the other fails.
  TWO_GEM_SECOND_STRANDED = <<~'RUBY'
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-gempub", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      return { "state" => "assembled" } if ruby.include?("qa_green!")
      { "slug" => "rel-gempub", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "studio-engine", "kind" => "gem", "members" => [{ "slug" => "t-gem1", "branch" => nil }] },
        { "repo" => "solana-studio", "kind" => "gem", "members" => [{ "slug" => "t-gem2", "branch" => nil }] },
        { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
          "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "t-studio", "branch" => "feat/s" }] }
      ] }
    end
    def gem_version_from_ref(repo, _ref) = repo == "solana-studio" ? "0.10.0" : "1.0.0"
  RUBY

  # [integration] THE irreversible-ordering regression: gem 1 (studio-engine
  # 1.0.0) is healthy and would publish; gem 2 (solana-studio 0.10.0 == its last
  # tag, one commit ahead) fails the stranded-work guard. Interleaved code pushes
  # gem 1 BEFORE gem 2 aborts; the two-phase preflight must abort with ZERO
  # pushes — nothing builds, nothing publishes, nothing bumps, nothing deploys.
  def test_prepare_second_gem_validation_failure_publishes_zero_gems
    out = run_cli(["--yes"], setup: gem_publish_stub + TWO_GEM_SECOND_STRANDED,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a late validation failure must abort the whole publish step"
    assert_includes out, "solana-studio", "the abort names the failing gem"
    assert_includes out, "NOTHING was published", "the abort states the zero-publish guarantee"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-BUILD", "the healthy FIRST gem must not even build before the preflight settles"
    refute_includes out, "GEM-PUSH", "ZERO gems publish when ANY swept gem fails validation"
    refute_includes out, "LOCK-PUSH", "no consumer lock bump past a failed preflight"
    refute_includes out, "QA-DEPLOY", "no QA deploy past a failed preflight"
  end

  # The gem repo's own fetch (`fetch origin --tags`) fails; the app fetches
  # (no --tags) stay healthy, so the failure is exactly the gem's stale-ref lane.
  GEM_FETCH_FAIL = <<~'RUBY'
    alias sh_before_fetch_fail sh
    def sh(*a, **k)
      return ["", false] if a[0] == "git" && a.include?("fetch") && a.include?("--tags")
      sh_before_fetch_fail(*a, **k)
    end
  RUBY

  # [integration] FAIL CLOSED on a failed fetch: a transient fetch failure must
  # never let a stale origin/release drive an irreversible publish (or silently
  # skip a new gem, then gate + QA the old lock). Named abort, zero pushes.
  def test_prepare_gem_fetch_failure_fails_closed_before_any_publish
    out = run_cli(["--yes"], setup: gem_publish_stub + GEM_FETCH_FAIL,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a failed gem fetch must abort, not proceed on a stale ref"
    assert_includes out, "git fetch failed in gem studio-engine", "the abort names the repo and the failed fetch"
    assert_includes out, "fail closed", "the abort states the discipline"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes from a possibly-stale origin/release"
    refute_includes out, "LOCK-PUSH", "no lock bump on a failed preflight"
  end

  # A SELF-GATED gem-only candidate: the sweep carries studio-engine (its
  # registry `release_check` makes it self-gated) and NO app member.
  GEM_ONLY_CONDUCTOR = <<~'RUBY'
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-gemonly", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      return { "state" => "assembled" } if ruby.include?("qa_green!")
      { "slug" => "rel-gemonly", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "studio-engine", "kind" => "gem", "members" => [{ "slug" => "t-gem", "branch" => nil }] }
      ] }
    end
  RUBY

  # A NON-self-gated gem-only candidate: solana-studio has no `release_check`, so
  # it cannot be its own release — it still needs a consuming app.
  # solana-studio registered a `release_check` on 2026-08-20 (it grew
  # bin/release-check alongside its Rails engine), so NO registered gem is
  # non-self-gated any more. The two guards below still have to bite for the next
  # gem onboarded without a runner, so the condition is CREATED here rather than
  # borrowed from the registry — a test that needed some real gem to stay
  # runner-less was testing the registry, not the guard.
  NOT_SELF_GATED = <<~'RUBY'
    def self_gated_gem?(repo)
      return false if repo.to_s == "solana-studio"

      !gem_meta_for(repo)["release_check"].to_s.strip.empty?
    end
  RUBY

  SOLANA_GEM_ONLY_CONDUCTOR = <<~'RUBY'
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-gemonly", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      return { "state" => "assembled" } if ruby.include?("qa_green!")
      { "slug" => "rel-gemonly", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "solana-studio", "kind" => "gem", "members" => [{ "slug" => "t-gem", "branch" => nil }] }
      ] }
    end
  RUBY

  # [integration] The SELF-GATED gem-only candidate IS ALLOWED (gem-only-deployments):
  # a gem whose registry `release_check` is its own release-candidate verdict may be
  # its OWN release — it publishes, gets a first-class G3 verdict on its OWN suite's
  # CI (the self-gated-gem pass, resolved through the same tree-identical credit the
  # apps use), and assembles QA-green with NO app QA deploy. This is the whole point
  # of the change: a gem-only publish flows through the tracker instead of being
  # hard-refused.
  def test_prepare_self_gated_gem_only_candidate_is_allowed_and_gated_on_its_own_ci
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub + GEM_ONLY_CONDUCTOR)

    refute_includes out, "ABORTED", "a self-gated gem-only candidate must NOT be refused"
    assert_includes out, "GEM-PUSH", "a self-gated gem-only candidate publishes"
    assert_includes out, "pre-QA gate studio-engine (self-gated gem): GitHub CI GREEN",
                    "the self-gated gem earns its own G3 verdict on its own suite's CI"
    assert_includes out, "Assembled rel-gemonly", "the gem-only release assembles QA-green"
    refute_includes out, "QA-DEPLOY", "a gem-only release has NO app QA deploy"
  end

  # [integration] The gem-only bypass still bites for a NON-self-gated gem: with no
  # app member AND no `release_check` to gate itself, the candidate would publish and
  # assemble QA-green with nothing ever exercising the gem. Preflight must abort it
  # BEFORE the irreversible publish, naming BOTH the missing app and the
  # not-self-gated reason, plus the enroll-a-consumer fix.
  def test_prepare_non_self_gated_gem_only_candidate_aborts_before_any_publish
    out = run_cli(["--yes"], setup: gem_publish_stub + SOLANA_GEM_ONLY_CONDUCTOR + NOT_SELF_GATED,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a NON-self-gated gem-only candidate must not publish + assemble unQA'd"
    assert_includes out, "NO app member", "the abort names the gem-only condition"
    assert_includes out, "not self-gated", "the abort names WHY solana-studio can't release alone"
    assert_includes out, "solana-studio", "the abort names the offending gem"
    assert_includes out, "enroll the consuming app", "the abort hands over the fix"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes on a non-self-gated gem-only candidate"
    refute_includes out, "QA-DEPLOY"
  end

  # [integration] THE PRODUCTION-DOWNGRADE vector, end to end (round-5 blocker).
  # version_file declares 0.9.0 while the last published tag is v0.10.0 — the
  # route in is a version.rb conflict resolved the wrong way on a merge into
  # release. Before the ordering fix this walked the ENTIRE pipeline green:
  # guard passed, publish "skipped" as already-live, and the consumer pin was
  # rewritten DOWNWARD to `~> 0.9` and committed to origin/release. Now it must
  # abort in phase 1: zero publishes, and — the assertion that matters most —
  # NO downward pin rewrite ever reaches a commit.
  #
  # Driven with allocation OFF (`allocate: false`) for the same reason as the
  # stranded test above: phase 0 now allocates forward over this backward version
  # (0.10.1 for these inputs — the last tag v0.10.0 plus the patch an untyped
  # member earns) before phase 1 reads it, so the DOWNGRADE branch is reachable
  # only when allocation did not run. It must still fail closed there.
  def test_prepare_backward_gem_version_aborts_and_never_downgrades_a_consumer
    out = run_cli(["--yes"], setup: gem_publish_stub(version: "0.9.0", live: [{ "number" => "0.9.0" }],
                                                    allocate: false),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a backward version must BLOCK, never publish or skip"
    assert_includes out, "DOWNGRADE", "the abort names the downgrade it prevented"
    assert_includes out, "past the last published tag v0.10.0", "the abort names the REAL tag"
    refute_includes out, "NO-ABORT"
    refute_includes out, "already live on RubyGems — skip publish",
                    "the misleading idempotent-skip line must NOT appear for a backward version"
    refute_includes out, "GEM-PUSH", "zero gems publish on a backward version"
    refute_includes out, %(GEMFILE-AFTER gem "studio-engine", "~> 0.9"),
                    "the consumer pin must NEVER be rewritten downward"
    refute_includes out, "LOCK-PUSH", "no downgrade commit reaches origin/release"
    refute_includes out, "QA-DEPLOY"
  end

  # A NON-self-gated gem (solana-studio) riding alongside an app whose Gemfile does
  # NOT declare it — no swept consumer bundles it. (gem_publish_stub's app Gemfile
  # declares studio-engine, never solana-studio, so solana has no consumer here.)
  SOLANA_MIXED_CONDUCTOR = <<~'RUBY'
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-gempub", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      return { "state" => "assembled" } if ruby.include?("qa_green!")
      { "slug" => "rel-gempub", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "solana-studio", "kind" => "gem", "members" => [{ "slug" => "t-gem", "branch" => nil }] },
        { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
          "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "t-studio", "branch" => "feat/s" }] }
      ] }
    end
  RUBY

  # The swept app's origin/release Gemfile does not declare the gem.
  EMPTY_CONSUMER_GEMFILE = <<~'RUBY'
    alias git_capture_before_empty_gemfile git_capture
    def git_capture(*a)
      return ["", true] if a.join(" ").include?(":Gemfile")
      git_capture_before_empty_gemfile(*a)
    end
  RUBY

  # [integration] The no-consumer guard still bites for a NON-self-gated gem: a gem
  # NO swept consumer bundles AND with no `release_check` to gate itself would still
  # assemble QA-green untested. Preflight must catch the missing coverage before the
  # publish. (solana-studio is not self-gated, so the per-gem consumer check applies.)
  def test_prepare_non_self_gated_gem_with_no_swept_consumer_aborts_before_any_publish
    out = run_cli(["--yes"], setup: gem_publish_stub + SOLANA_MIXED_CONDUCTOR + NOT_SELF_GATED,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a non-self-gated gem with no swept consumer must not publish"
    assert_includes out, "no consuming app in this sweep", "the abort names the missing coverage"
    assert_includes out, "solana-studio", "the abort names the offending gem"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GEM-PUSH", "nothing publishes without a consumer to QA it through"
    refute_includes out, "LOCK-PUSH"
  end

  # [integration] The relaxation's companion: a SELF-GATED gem (studio-engine)
  # riding an app whose Gemfile does NOT declare it is ALLOWED to publish — a
  # self-gated gem does not need a consumer to be QA'd (its own suite is its
  # verdict), so the per-gem no-consumer guard is correctly skipped for it.
  def test_prepare_self_gated_gem_with_no_swept_consumer_still_publishes
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub + EMPTY_CONSUMER_GEMFILE)

    refute_includes out, "ABORTED", "a self-gated gem needs no consumer — it must not be refused"
    refute_includes out, "no consuming app in this sweep", "the no-consumer guard is skipped for a self-gated gem"
    assert_includes out, "GEM-PUSH", "the self-gated gem publishes even with no consumer bundling it"
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

  # A full self-healing sweep, accepted-ladder edition: review already merged each
  # feat PR into `accepted`, so a reviewed member carries merged:"accepted". The
  # sweep PROMOTES accepted→release (ONE batch PR per repo), records the members,
  # and flips them on QA-green. Candidates: one reviewed member on accepted (promote
  # + record), one crash-recovery straggler already on release (record, no promote),
  # one anomaly with NO merged stamp (HELD — warned, left reviewed). RELEASE_CI_STATUS
  # =green is the G3 pre-QA gate precondition (GitHub CI is the verdict).
  SWEEP_FLOW_STUB = GATE_GIT_STUB + %(ENV["RELEASE_CI_STATUS"] = "green"\ndef repo_path(_repo) = #{stub_repo.inspect}\n) + <<~'RUBY'
    def conductor(ruby, read_only: false)
      if ruby.include?("sweep_candidates")
        { "tasks" => [
            { "slug" => "task-accepted", "stage" => "reviewed", "merged" => "accepted", "pr_url" => "https://gh/pr/9", "repo" => "mcritchie-studio" },
            { "slug" => "task-swept", "stage" => "reviewed", "merged" => "release", "pr_url" => "https://gh/pr/8", "repo" => "mcritchie-studio" },
            { "slug" => "task-held", "stage" => "reviewed", "merged" => "", "pr_url" => "", "repo" => "mcritchie-studio" }
          ],
          "release" => nil,
          "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      elsif ruby.include?("sweep!")
        $stdout.puts("SWEEP-CALL " + ruby.gsub("\n", " "))
        { "slug" => "rel-sweep", "state" => "assembling", "swept" => %w[task-accepted task-swept], "repos" => [
          { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
            "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "task-accepted", "branch" => "feat/n" }] }
        ] }
      elsif ruby.include?("qa_green!")
        $stdout.puts("QA-GREEN-CALL")
        { "state" => "assembled" }
      else
        {}
      end
    end
    # PROMOTE-AWARE, because prepare now VERIFIES the promote's effect (step 3b's
    # stale-tree gate) instead of trusting that it ran. A stub that answered
    # "accepted is 2 ahead" both before AND after `gh pr merge` would be
    # describing a promote that did nothing, and the gate would rightly refuse it.
    # So the batch merge flips $promoted and the rung goes level — exactly what
    # landing accepted on release does to the real rev-list.
    $promoted = false
    def sh(*a, **k)
      g = gate_git(a, k)
      return g if g
      return [($promoted ? "0" : "2"), true] if a[0] == "git" && a.include?("rev-list") # accepted ahead of release
      return ["git@github.com:McRitchie-Studio/mcritchie-studio.git", true] if a[0] == "git" && a.include?("remote")
      return ["", true] if a[0] == "gh" && a[1] == "pr" && a[2] == "list"   # no existing batch PR
      if a[0] == "gh" && a[1] == "pr" && a[2] == "create"
        $stdout.puts("GH-CREATE " + a.join(" "))
        return ["https://gh/pr/accepted-release", true]
      end
      if a[0] == "gh" && a.include?("merge")
        $stdout.puts("GH-MERGE " + a.find { |x| x.to_s.start_with?("https") }.to_s)
        $promoted = true
        return ["", true]
      end
      return ["200", true] if a.join(" ").include?("curl")
      ["", true]
    end
    # REPO-AWARE, for prepare's accepted-COVERAGE guard (step 4a-bis): a repo THIS
    # RELEASE'S MEMBERS NAME whose `accepted` is ahead of `release` must be in the
    # promote list, or the sweep leaves that repo's work behind while stamping its
    # tasks shipped (the 2026-08-13 half-ship). The `sh` stub above answers "2
    # ahead" to ANY rev-list, so through the REAL reader every registered repo
    # would read as carrying unpromoted work — which, as Carl noted reviewing this,
    # is the ecosystem's NORMAL state, not a fixture artifact. The guard survives
    # that because it judges only member-named repos; this override just keeps the
    # fixture's world small and $promoted-aware, exactly as the sh stub is.
    def ladder_ahead_states(repos: nil, require_checkout: false)
      { "release" => [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
        "accepted" => [{ "repo" => "mcritchie-studio", "ahead" => ($promoted ? 0 : 2) }],
        "unreadable" => [] }
    end
  RUBY

  # --- prepare: the MULTI-REPO member (the 2026-08-13 half-ship) ---------------
  #
  # `land-rails-security-patch` named [mcritchie-studio, turf-monster] and carried
  # the hub's PR url. `promote_repos` read the SINGULAR `repo` off each candidate,
  # so it promoted the hub alone; turf was never promoted, QA'd or shipped, and the
  # task was still stamped shipped + merged:"main" while turf production ran the
  # unpatched code. Two guards and one fix meet here at the pre-promote seam.
  def multi_repo_stub(pr_urls: nil, tasks: nil,
                      ahead: [{ "repo" => "mcritchie-studio", "ahead" => 2 },
                              { "repo" => "turf-monster", "ahead" => 2 }])
    tasks ||= [ { "slug" => "land-rails-security-patch", "stage" => "reviewed", "merged" => "accepted",
                  "pr_url" => "https://gh/pr/836", "repo" => "mcritchie-studio",
                  "repos" => [ "mcritchie-studio", "turf-monster" ], "pr_urls" => pr_urls } ]
    SWEEP_FLOW_STUB + <<~RUBY
      alias single_repo_conductor conductor
      def conductor(ruby, read_only: false)
        return single_repo_conductor(ruby, read_only: read_only) unless ruby.include?("sweep_candidates")

        { "tasks" => #{tasks.inspect},
          "release" => nil,
          "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      end
      def ladder_ahead_states(repos: nil, require_checkout: false)
        { "release" => [], "accepted" => ($promoted ? [] : #{ahead.inspect}), "unreadable" => [] }
      end
    RUBY
  end

  # A hub-only candidate — the "included app" of a --task hold-back sweep.
  HUB_ONLY_CANDIDATE = { "slug" => "land-hub-fix", "stage" => "reviewed", "merged" => "accepted",
                         "pr_url" => "https://gh/pr/900", "repo" => "mcritchie-studio",
                         "repos" => [ "mcritchie-studio" ],
                         "pr_urls" => { "mcritchie-studio" => "https://gh/pr/900" } }.freeze

  def test_prepare_refuses_a_multi_repo_candidate_whose_pr_record_is_incomplete
    out = run_cli(["--dry-run"], setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836" }),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a multi-repo task with one PR must not sweep"
    assert_includes out, "turf-monster", "the refusal names the repo with no PR url"
    assert_includes out, "NOTHING was promoted", "fail-closed BEFORE the promote"
    refute_includes out, "NO-ABORT"
    refute_includes out, "promote accepted → release", "nothing may be promoted"
    refute_includes out, "SWEEP-CALL", "nothing may be recorded"
  end

  # THE GEM RELEASE MUST NOT BE REFUSED. A `library` candidate names its gem plus
  # the consumers that adopt it and carries ONE PR — the gem's — because a
  # consumer's change in a gem release is committed by the pipeline itself
  # (bump_consumer_locks_for_qa), not by a person opening a PR. Live shape:
  # guard-engine-migration-rollback, four repos behind one studio-engine PR.
  # Without the `kind: "gem"` exemption this abort would fire on every engine
  # release, demanding a URL that does not exist.
  def test_prepare_does_not_refuse_a_GEM_candidate_carrying_only_the_gem_pr
    out = run_cli(["--dry-run"],
                  setup: multi_repo_stub(
                    tasks: [ { "slug" => "guard-engine-migration-rollback", "stage" => "reviewed",
                               "merged" => "accepted", "kind" => "gem",
                               "pr_url" => "https://gh/pr/124", "repo" => "studio-engine",
                               "repos" => [ "studio-engine", "mcritchie-studio", "turf-monster" ],
                               "pr_urls" => { "studio-engine" => "https://gh/pr/124" } } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "NO-ABORT", "a gem release with one gem PR must sweep"
    refute_includes out, "incomplete PR record"
    assert_includes out, "promote accepted → release in studio-engine"
    assert_includes out, "promote accepted → release in mcritchie-studio",
                     "the consumers still ride the promote — only the PR demand is exempt"
  end

  # The CONTROL: the identical candidate as an APP is the 2026-08-13 incident, and
  # is still refused. Only the gem kind earns the pass.
  def test_prepare_refuses_the_same_candidate_when_it_is_an_APP
    out = run_cli(["--dry-run"],
                  setup: multi_repo_stub(
                    tasks: [ { "slug" => "guard-engine-migration-rollback", "stage" => "reviewed",
                               "merged" => "accepted", "kind" => "app",
                               "pr_url" => "https://gh/pr/124", "repo" => "studio-engine",
                               "repos" => [ "studio-engine", "mcritchie-studio", "turf-monster" ],
                               "pr_urls" => { "studio-engine" => "https://gh/pr/124" } } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED"
    assert_includes out, "incomplete PR record"
    refute_includes out, "NO-ABORT"
  end

  def test_prepare_promotes_EVERY_repo_a_multi_repo_candidate_names
    out = run_cli(["--dry-run"], call: "prepare",
                  setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                    "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "promote accepted → release in mcritchie-studio"
    assert_includes out, "promote accepted → release in turf-monster",
                     "THE fix: the promote list is every repo the task NAMES, not the one its pr_url parses to"
  end

  # The check `bin/release status` already printed and no gate consulted: git says a
  # repo's `accepted` carries commits, and this sweep would not carry it.
  #
  # SCOPED TO MEMBER-NAMED REPOS. The candidate here is the shape a PARTIAL earlier
  # promote leaves behind: `half-promoted-patch` names [hub, turf] and is stamped
  # merged:"release", so it is RECORDED as a member but contributes nothing to the
  # promote list — while turf's `accepted` is still ahead. That is exactly the
  # 2026-08-13 half-ship arriving one sweep later, and the guard must still bite.
  def test_prepare_refuses_when_a_MEMBER_NAMED_repo_ahead_on_accepted_is_not_promoted
    out = run_cli(["--yes"],
                  setup: multi_repo_stub(
                    tasks: [ HUB_ONLY_CANDIDATE,
                             { "slug" => "half-promoted-patch", "stage" => "reviewed", "merged" => "release",
                               "pr_url" => "https://gh/pr/836", "repo" => "mcritchie-studio",
                               "repos" => [ "mcritchie-studio", "turf-monster" ],
                               "pr_urls" => { "mcritchie-studio" => "https://gh/pr/836",
                                              "turf-monster" => "https://gh/pr/305" } } ],
                    ahead: [ { "repo" => "mcritchie-studio", "ahead" => 2 },
                             { "repo" => "turf-monster", "ahead" => 2 } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED"
    assert_includes out, "turf-monster", "the refusal names the repo that would be left behind"
    assert_includes out, "NOTHING was promoted, recorded or deployed"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GH-MERGE", "fail-closed BEFORE the irreversible promote"
    refute_includes out, "SWEEP-CALL"
  end

  # THE FALSE ABORT this guard shipped with, and the reason it is scoped: the git
  # read spans EVERY registered repo, but `--task` deliberately narrows the sweep.
  # Avi's documented per-app hold-back (qa-release.md, "sweep only the included
  # apps") IS a --task run, and a held-back app's reviewed work sits on `accepted`
  # BY CONSTRUCTION — so the unscoped comparison refused the hold-back every time,
  # with no --override and a message whose prescribed fixes would have undone it.
  # Here turf and industries are ahead and no member names either: prepare must
  # promote the hub and carry on.
  def test_prepare_allows_a_task_narrowed_holdback_over_repos_no_member_names
    out = run_cli(["--yes"],
                  setup: multi_repo_stub(
                    tasks: [ HUB_ONLY_CANDIDATE ],
                    ahead: [ { "repo" => "mcritchie-studio", "ahead" => 2 },
                             { "repo" => "turf-monster", "ahead" => 7 },
                             { "repo" => "mcritchie-industries", "ahead" => 3 } ]
                  ),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "NO-ABORT", "a hold-back sweep must not be refused for the repo it is holding back"
    refute_includes out, "prepare refused"
    refute_includes out, "turf-monster", "a repo no member names is out of this guard's scope"
    assert_includes out, "GH-MERGE", "the included app still promotes"
    assert_includes out, "SWEEP-CALL", "…and still records"
  end

  def test_prepare_proceeds_when_every_accepted_ahead_repo_rides_the_promote
    out = run_cli(["--yes"], call: "prepare",
                  setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                    "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "GH-MERGE", "a fully-covered promote is not refused"
    assert_includes out, "SWEEP-CALL", "…and still records"
  end

  # The transcript line is the last place a human can catch a half-ship before it is
  # recorded, and printing only the primary repo is what made 2026-08-13 look
  # complete. A multi-repo candidate names every repo it carries; a single-repo one
  # renders exactly as it always did.
  def test_prepare_sweep_line_names_every_repo_a_multi_repo_candidate_carries
    out = run_cli(["--dry-run"], call: "prepare",
                  setup: multi_repo_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                    "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "sweep land-rails-security-patch (reviewed · merged: accepted) · " \
                         "mcritchie-studio, turf-monster · https://gh/pr/836"
  end

  # --- prepare step 3b: the STALE-TREE GATE ------------------------------------
  #
  # THE INCIDENT, reproduced (measured live 2026-08-11): a fix was committed to
  # `accepted` AFTER a candidate reached `assembled`. It had no task behind it (a
  # conductor zap onto a sanctioned seam), so it was not a sweep candidate, so no
  # repo carried a merged:"accepted" stamp, so `promote_repos` was EMPTY and the
  # promote never ran. prepare then re-recorded, re-deployed the SAME SHA, and
  # printed `✓ Assembled`. Both sentences were true — of a tree missing the fix.
  # `accepted` ed4d16a, `release` b032e58, one commit stranded, QA on the old tree.
  #
  # The stub drives the REAL git reads (fetch / rev-list / log / remote) through
  # `sh`, so these exercise the whole wiring — the repos: scope, require_checkout:,
  # the commit parse, the remote lookup — not just the pure verdict.
  def stale_tree_stub(ahead: 1, state: "assembled", rev_list_ok: true)
    GATE_GIT_STUB +
      %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
      %(def repo_path(_repo) = #{self.class.stub_repo.inspect}\n) +
      %(ACCEPTED_AHEAD = #{ahead}\n) +
      %(REV_LIST_OK = #{rev_list_ok.inspect}\n) +
      %(RC_STATE = #{state.inspect}\n) + <<~'RUBY'
        def conductor(ruby, read_only: false)
          # Nothing to sweep — the stranded commit has NO task behind it — but a
          # candidate IS in flight. That is prepare's self-healing re-run shape.
          if ruby.include?("sweep_candidates")
            return { "tasks" => [], "release" => { "slug" => "rel-strand", "state" => RC_STATE }, "screen" => {} }
          end
          return { "state" => "assembled" } if ruby.include?("qa_green!")
          { "slug" => "rel-strand", "state" => RC_STATE, "branch" => "release", "repos" => [
            { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
              "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "t-shipped", "branch" => "feat/s" }] }
          ] }
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          range = a.last.to_s
          if a[0] == "git" && a.include?("rev-list")
            return ["", false] unless REV_LIST_OK
            # accepted-ahead-of-release is the rung under test; release-ahead-of-main is level.
            return [(range.include?("origin/accepted") ? ACCEPTED_AHEAD.to_s : "0"), true]
          end
          if a[0] == "git" && a.include?("log") && range.include?("origin/accepted")
            return ["ed4d16a Correct the public price claim\n", true]
          end
          return ["git@github.com:McRitchie-Studio/mcritchie-studio.git", true] if a[0] == "git" && a.include?("remote")
          $stdout.puts("QA-DEPLOY") if a[0] == "bin/qa-server"
          return ["200", true] if a.join(" ").include?("curl")
          ["", true]
        end
      RUBY
  end

  # [integration] MUTATION DIRECTION 1 — the stranded commit is CAUGHT, and the
  # run does not reach the deploy at all.
  def test_prepare_refuses_when_a_commit_is_stranded_on_accepted
    out = run_cli(["--yes"], call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end},
                  setup: stale_tree_stub)

    assert_includes out, "ABORTED", "a stale tree must abort, never fall through"
    refute_includes out, "NO-ABORT"
    # THE WHOLE DEFECT: the sweep must never print success over a stale tree.
    refute_includes out, "✓ Assembled rel-strand", "prepare must NOT report the candidate assembled"
    refute_includes out, "QA-DEPLOY", "…and must not deploy the old tree to QA first"
  end

  # [integration] The refusal has to be ACTIONABLE: the repo, the stranded SHA,
  # and the recovery with both filled in. A refusal that does not name its remedy
  # just moves the confusion.
  def test_prepare_stale_tree_refusal_names_the_commits_and_the_recovery
    out = run_cli(["--yes"], call: %{begin; prepare; rescue SystemExit => e; puts("ABORTED: " + e.message); end},
                  setup: stale_tree_stub)

    assert_includes out, "1 commit stranded on `accepted`"
    assert_includes out, "ed4d16a Correct the public price claim", "the SHA and subject, read from git log"
    assert_includes out, "gh pr create --repo McRitchie-Studio/mcritchie-studio --base release --head accepted",
                     "the recovery names the repo it resolved from the remote"
    assert_includes out, "--match-head-commit ed4d16a", "the recovery merge is pinned at the accepted head"
    assert_includes out, "bin/release prepare", "…and the re-run that finishes it"
    assert_includes out, "NOTHING was published, gated, or deployed"
  end

  # [integration] WHY it refuses rather than quietly promoting onto a QA-green
  # candidate — the judgment call, printed where the operator will read it.
  def test_prepare_stale_tree_refusal_explains_why_it_will_not_re_promote
    out = run_cli(["--yes"], call: %{begin; prepare; rescue SystemExit; end}, setup: stale_tree_stub)

    assert_includes out, "already `assembled` (QA-green)"
    assert_includes out, "will NOT silently promote onto it"
    assert_includes out, "BOARD STAMPS", "and why the promote missed it in the first place"
  end

  # [integration] MUTATION DIRECTION 2 — the one people skip. A genuinely
  # up-to-date assembled candidate must still PASS. Interrupted sweeps are common
  # (a foreground shell timeout kills one mid-run); if re-runs started refusing,
  # every one of them would become a manual repair and the lane would be unusable.
  def test_prepare_still_re_runs_a_genuinely_current_assembled_candidate
    out = run_cli(["--yes"], call: "prepare", setup: stale_tree_stub(ahead: 0))

    refute_includes out, "prepare refused", "a level ladder must not refuse — resumability depends on it"
    assert_includes out, "carries every `accepted` commit (mcritchie-studio)", "the gate says what it verified"
    assert_includes out, "QA-DEPLOY", "the re-run still deploys QA"
    assert_includes out, "Assembled rel-strand", "…and still reports the candidate assembled"
  end

  # [integration] A failed read is not a clean read. An unreadable rung on a repo
  # the candidate is about to DEPLOY is unverified, and unverified is stale.
  def test_prepare_refuses_when_the_accepted_rung_cannot_be_read
    out = run_cli(["--yes"], call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end},
                  setup: stale_tree_stub(rev_list_ok: false))

    assert_includes out, "ABORTED"
    assert_includes out, "could NOT be read"
    assert_includes out, "a failed read is not a clean read"
    refute_includes out, "QA-DEPLOY", "an unmeasurable rung must not be deployed over"
    refute_includes out, "NO-ABORT"
  end

  # [integration] The gate is a LIVE-run gate: a dry run takes no fetch, so it
  # says so rather than passing on an unmeasured signal it never took.
  def test_prepare_dry_run_says_the_stale_tree_gate_runs_live_only
    out = run_cli(["--dry-run"], call: "prepare", setup: stale_tree_stub)

    assert_includes out, "a dry run takes no fetch"
    refute_includes out, "prepare refused", "a preview must not manufacture a refusal from an unmeasured rung"
  end

  # [integration] The gate runs BEFORE the deploy half's irreversible work. This
  # is what makes a refusal free: no gem is on RubyGems, no QA app has moved, and
  # member stages are untouched, so the re-run after the hand-landed batch PR is
  # a clean resume rather than a repair.
  def test_prepare_stale_tree_gate_precedes_the_merge_forward_gate_and_deploy
    out = run_cli(["--yes"], call: %{begin; prepare; rescue SystemExit; end}, setup: stale_tree_stub)

    verify = out.index("verify: `release` carries `accepted`")
    refute_nil verify, "the gate must announce itself: #{out}"
    ["merge-forward", "pre-QA gate", "QA-DEPLOY"].each do |later|
      idx = out.index(later)
      assert(idx.nil? || idx > verify, "#{later} must not run before the stale-tree gate")
    end
  end

  def test_prepare_promotes_accepted_to_release_and_records_the_members
    out = run_cli(["--yes"], call: "prepare", setup: SWEEP_FLOW_STUB)

    # ONE accepted→release batch PR promotes the whole repo — NOT one merge per task.
    assert_equal 1, out.scan("GH-MERGE").size, "one accepted→release batch PR per repo, not one per task"
    assert_includes out, "GH-MERGE https://gh/pr/accepted-release"
    assert_includes out, "promote accepted → release in mcritchie-studio"
    refute_includes out, "GH-MERGE https://gh/pr/9", "no per-feat-PR merge — review already landed it on accepted"

    # The crash-recovery straggler (merged:release) records but is not re-promoted.
    assert_includes out, "skip promote for task-swept — already merged: release"

    # The anomaly (merged:"") is warned + left reviewed — never an abort in prepare.
    assert_includes out, "task-held"
    assert_includes out, "left `reviewed` (re-review to heal)"

    # ONE batched record write sweeps the two members with code (not the held one).
    assert_equal 1, out.scan("SWEEP-CALL").size, "the sweep records in ONE heroku run"
    sweep = out.lines.find { |l| l.start_with?("SWEEP-CALL") }
    assert_includes sweep, "task-accepted"
    assert_includes sweep, "task-swept"
    refute_includes sweep, "task-held", "an unstamped reviewed member is never swept onto the RC"

    # QA booted green → the QA-green flip fires and the RC assembles.
    assert_equal 1, out.scan("QA-GREEN-CALL").size, "QA-green flips the swept members via qa_green!"
    assert_includes out, "Assembled rel-sweep"
  end

  def test_prepare_dry_run_previews_the_promote_without_recording
    out = run_cli(["--dry-run"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "sweep task-accepted (reviewed", "the dry run previews the detected sweep"
    assert_includes out, "promote accepted → release in mcritchie-studio", "the dry run previews the ONE batch PR"
    assert_includes out, "skip promote for task-swept — already merged: release"
    refute_includes out, "GH-MERGE", "a dry run merges nothing"
    refute_includes out, "GH-CREATE", "a dry run opens no PR"
    refute_includes out, "SWEEP-CALL", "a dry run records nothing"
    refute_includes out, "QA-GREEN-CALL", "a dry run flips nothing"
  end

  # The plan's key assertion: the sweep promotes accepted→release as ONE batch PR per
  # repo — NOT one merge per reviewed task (the old per-feat-PR sweep). Three reviewed
  # tasks in one repo → exactly one promote line, zero per-feat-PR merges.
  ONE_BATCH_STUB = %(def repo_path(_repo) = #{stub_repo.inspect}\n) + <<~'RUBY'
    def conductor(ruby, read_only: false)
      if ruby.include?("sweep_candidates")
        { "tasks" => [
            { "slug" => "t1", "stage" => "reviewed", "merged" => "accepted", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio" },
            { "slug" => "t2", "stage" => "reviewed", "merged" => "accepted", "pr_url" => "https://gh/pr/2", "repo" => "mcritchie-studio" },
            { "slug" => "t3", "stage" => "reviewed", "merged" => "accepted", "pr_url" => "https://gh/pr/3", "repo" => "mcritchie-studio" }
          ], "release" => nil, "screen" => { "proceed" => true } }
      else
        {}
      end
    end
  RUBY

  def test_prepare_dry_run_promotes_one_accepted_to_release_batch_pr_not_one_per_task
    out = run_cli(["--dry-run"], call: "prepare", setup: ONE_BATCH_STUB)

    promote_lines = out.lines.select { |l| l.include?("promote accepted → release in mcritchie-studio") }
    assert_equal 1, promote_lines.size,
                 "3 reviewed tasks in one repo → ONE accepted→release batch PR, not 3 per-task merges"
    %w[1 2 3].each do |n|
      refute_match(%r{gh pr merge https://gh/pr/#{n}}, out, "no per-feat-PR merge in the accepted-ladder sweep")
    end
  end

  # ahead == 0: accepted is level with release (a prior run promoted it, or nothing
  # new). promote SKIPS the batch PR — the caller still records + deploys.
  def test_promote_skips_the_batch_pr_when_accepted_is_level_with_release
    setup = %(def repo_path(_r) = #{self.class.stub_repo.inspect}\n) + <<~'RUBY'
      def sh(*a, **k)
        return ["", true] if a[0] == "git" && a.include?("fetch")
        return ["0", true] if a[0] == "git" && a.include?("rev-list")   # ahead == 0
        $stdout.puts("GH " + a.join(" ")) if a[0] == "gh"
        ["", true]
      end
    RUBY
    out = run_cli([], call: %(promote_accepted_to_release!(["mcritchie-studio"])), setup: setup)

    assert_includes out, "level with `release` — nothing to promote"
    refute_includes out, "GH ", "no gh PR is opened or merged when accepted is level with release"
  end

  # ahead > 0: promote opens/reuses ONE `--base release --head accepted` batch PR
  # and merges it.
  def test_promote_opens_and_merges_one_batch_pr_when_accepted_is_ahead
    setup = %(def repo_path(_r) = #{self.class.stub_repo.inspect}\n) + <<~'RUBY'
      def sh(*a, **k)
        return ["", true] if a[0] == "git" && a.include?("fetch")
        return ["3", true] if a[0] == "git" && a.include?("rev-list")   # accepted 3 ahead
        return ["git@github.com:McRitchie-Studio/mcritchie-studio.git", true] if a[0] == "git" && a.include?("remote")
        return ["", true] if a[0] == "gh" && a[2] == "list"             # no existing batch PR
        if a[0] == "gh" && a[2] == "create"
          $stdout.puts("CREATE " + a.join(" "))
          return ["https://gh/pr/batch", true]
        end
        if a[0] == "gh" && a.include?("merge")
          $stdout.puts("MERGE " + a.find { |x| x.to_s.start_with?("https") }.to_s)
          return ["", true]
        end
        ["", true]
      end
    RUBY
    out = run_cli([], call: %(promote_accepted_to_release!(["mcritchie-studio"], label: "rel-x")), setup: setup)

    assert_includes out, "promote accepted → release in mcritchie-studio (3 commits)"
    assert_equal 1, out.scan("CREATE").size, "opens exactly ONE batch PR"
    assert_includes out, "--base release"
    assert_includes out, "--head accepted"
    assert_equal 1, out.scan("MERGE").size, "merges the batch PR once"
    assert_includes out, "MERGE https://gh/pr/batch"
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
    out = run_cli(["--dry-run", "--task", "task-accepted"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "sweep task-accepted (reviewed", "the named survivor previews"
    refute_includes out, "not sweepable", "no loud fail when every named slug survived"
  end

  # --- `prepare --expedite`: the PROMOTE-TIME clean-ladder guard -----------------
  # `status --clean-only` answers "is it safe to START?" at the top of
  # `deploy-with-task`. The promote runs 15-25 minutes later — review plus two CI
  # payments — and `bin/review-autopilot` can merge another task onto `accepted`
  # inside that window. Since the promote lands the WHOLE `accepted` branch on
  # `release` (`--task` curates MEMBERSHIP, never which COMMITS ride), a guard
  # consulted only at the start is answering about a world that has since changed.
  # `--expedite` re-derives the same verdict in the same command that promotes.

  # Layer a ladder-guard board read + git seam over the normal sweep flow. The
  # sweep's own `conductor` branches still answer through the alias, so the
  # promote/record/QA path is unchanged.
  def expedite_stub(accepted:, accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 2 }])
    SWEEP_FLOW_STUB + <<~RUBY
      alias sweep_conductor conductor
      def conductor(ruby, read_only: false)
        return sweep_conductor(ruby, read_only: read_only) unless ruby.include?("Task.where(stage: 'assembled')")

        { "pending" => [], "accepted" => #{accepted.inspect}, "release" => nil }
      end
      # Keyword-compatible with the real reader, and PROMOTE-AWARE: prepare's
      # stale-tree gate (step 3b) calls this a second time AFTER the promote, and
      # a stub still reporting `accepted` ahead there would be describing a batch
      # merge that landed nothing. $promoted is flipped by SWEEP_FLOW_STUB's
      # `gh pr merge`, so the expedite guard sees the pre-promote rung and the
      # stale-tree gate sees the post-promote one — from the same stub.
      def ladder_ahead_states(repos: nil, require_checkout: false)
        { "release" => [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
          "accepted" => ($promoted ? [{ "repo" => "mcritchie-studio", "ahead" => 0 }] : #{accepted_ahead.inspect}),
          "unreadable" => [] }
      end
    RUBY
  end

  def test_prepare_expedite_promotes_when_accepted_still_carries_only_that_task
    out = run_cli(["--yes", "--task", "task-accepted", "--expedite"], call: "prepare",
                  setup: expedite_stub(accepted: [{ "slug" => "task-accepted", "title" => "The one task" }]))

    assert_includes out, "re-prove the `accepted → release → main` ladder", "the guard runs at the promote"
    assert_includes out, "attributed to the expedited task `task-accepted`"
    assert_includes out, "GH-MERGE https://gh/pr/accepted-release", "a clean ladder still PROMOTES — the lane stays usable"
    assert_includes out, "SWEEP-CALL", "…and still records"
  end

  def test_prepare_expedite_refuses_a_task_the_autopilot_landed_mid_review
    out = run_cli(["--yes", "--task", "task-accepted", "--expedite"],
                  setup: expedite_stub(accepted: [{ "slug" => "task-accepted", "title" => "" },
                                                  { "slug" => "autopilot-landed", "title" => "Merged mid-review" }]),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "the promote-time guard is what actually protects production"
    assert_includes out, "autopilot-landed", "the refusal names the work that would have ridden along"
    assert_includes out, "full-cycle", "it offers shipping the whole release instead"
    assert_includes out, "NOTHING was promoted, recorded, or deployed"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GH-MERGE", "fail-closed BEFORE the irreversible promote"
    refute_includes out, "SWEEP-CALL", "nothing recorded"
    refute_includes out, "QA-GREEN-CALL", "nothing flipped"
  end

  def test_prepare_expedite_refuses_unstamped_commits_on_accepted
    out = run_cli(["--yes", "--task", "task-accepted", "--expedite"],
                  setup: expedite_stub(accepted: []),
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit; puts("ABORTED"); end})

    assert_includes out, "ABORTED", "commits on `accepted` with no stamped owner are never attributed away"
    assert_includes out, "DISAGREE", "the board/git disagreement is named, not swallowed"
    refute_includes out, "GH-MERGE"
    refute_includes out, "NO-ABORT"
  end

  def test_prepare_expedite_requires_exactly_one_named_task
    out = run_cli(["--yes", "--expedite"], setup: SWEEP_FLOW_STUB,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "an expedite with no named task has nothing to attribute to"
    assert_includes out, "exactly one `--task <slug>`"
    refute_includes out, "NO-ABORT"
    refute_includes out, "GH-MERGE"
  end

  # A bare `prepare` — the normal full-queue sweep, where promoting ALL of
  # `accepted` is exactly the intent — must be completely unaffected by the
  # opt-in guard. Otherwise the fix breaks the pipeline it was meant to protect.
  def test_prepare_without_expedite_never_runs_the_ladder_guard
    out = run_cli(["--yes"], call: "prepare",
                  setup: expedite_stub(accepted: [{ "slug" => "someone-else", "title" => "Parked" }]))

    refute_includes out, "re-prove the `accepted → release → main` ladder", "the guard is opt-in"
    assert_includes out, "GH-MERGE https://gh/pr/accepted-release", "the normal sweep promotes as before"
    assert_includes out, "SWEEP-CALL"
  end

  # --- the Steffon handoff line: printed on QA-green ONLY ------------------------

  def test_prepare_prints_the_steffon_handoff_only_on_qa_green
    out = run_cli(["--yes"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "Assembled rel-sweep"
    assert_includes out, "hand off to Steffon: `bin/release ship`", "QA-green prepare hands the RC to Steffon"
  end

  def test_prepare_omits_the_steffon_handoff_when_qa_is_not_green
    setup = SWEEP_FLOW_STUB + %(\ndef wait_for_boot(_url) = false)
    out = run_cli(["--yes"], call: "prepare", setup: setup)

    assert_includes out, "QA is NOT green", "the boot failure is reported"
    assert_includes out, "Prepared (NOT assembled — QA not green)"
    refute_includes out, "hand off to Steffon",
                    "a NOT-green prepare must not point at `bin/release ship` — there is nothing to ship yet"
    refute_includes out, "QA-GREEN-CALL", "no flip on a QA-red prepare"
  end

  # --- pre-QA gate: the prepare-owned test tier on origin/release --------------

  def test_prepare_dry_run_previews_the_pre_qa_gate_per_app
    setup = STUB_CONDUCTOR + %(\ndef qa_gate_cmd(repo) = repo == "mcritchie-studio" ? "bin/rails test:integration" : "")
    out = run_cli(["--dry-run"], call: "prepare", setup: setup)

    # DevOps v2 Phase 3: the banner names what the step does now — read GitHub CI's
    # verdict for each app's origin/release SHA. The registered qa_test_cmd is still
    # RECORDED for the G4 drift check, just no longer executed in a local workspace.
    assert_includes out, "pre-QA gate: GitHub CI's verdict for each app's origin/release SHA " \
                         "(before any QA deploy)"
    # The preview states the CI verdict is the gate and the command is RECORDED (not
    # run) — the plan matches what a real run executes.
    assert_includes out, "[dry-run] pre-QA gate mcritchie-studio: GitHub CI verdict for origin/release " \
                         "(bin/rails test:integration recorded for the G4 drift check, not run)"
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

  def test_pre_qa_gate_red_aborts_with_eject_guidance
    # DevOps v2 Phase 3: the RED verdict now comes from GitHub CI, not a local suite —
    # a red CI is a regression riding origin/release, and the abort routes to the
    # eject/revert/keep-the-rest recovery exactly as the local-suite red used to.
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "red"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a red CI verdict aborts prepare (fail-closed)"
      assert_includes out, "GitHub CI called", "…NAMING GitHub CI as the source of the RED verdict"
      assert_includes out, "regression is riding origin/release"
      assert_includes out, "bin/release eject", "the abort points at the block-on-regression move"
      assert_includes out, "git revert -m 1", "…and the merge-commit revert"
      assert_includes out, "REST of the RC rides on", "keep-the-rest is the stated recovery"
      refute_includes out, "PASSED"
    end
  end

  # --- G3's VERDICT: GitHub CI on the SAME SHA (DevOps v2 Phase 3) --------------
  #
  # GitHub CI's conclusion for the SHA under test IS the G3 verdict now (ci_pass?):
  # the gate queries CiStatus.for_sha (→ gh api …/commits/<sha>/check-runs), passes
  # on ONLY a green conclusion, and FAILS CLOSED on red AND on every no-data/pending
  # state (none/pending/unverified/unreadable) — the local suite it used to run in an
  # isolated workspace is demoted. A false green would deploy an untested SHA to QA.
  #
  # RELEASE_CI_STATUS injects the verdict (a bare token, or a raw check-runs
  # payload), so these never touch the network — the DOR_CHECK_CI_STATUS seam,
  # reused. An injected verdict also skips the `git remote get-url` lookup.

  # A gate whose CI verdict is injected. `rel-cli` is passed as the release slug so
  # record_qa_gate actually fires (it no-ops on a blank slug). No suite runs here —
  # `bin/suite` is registered only so a real code path would have had something to
  # record; the gate never executes it (see qa_gate_cmd / the demoted apparatus).
  def ci_gate_stub(dir, ci_status)
    %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
      %(ENV["RELEASE_CI_STATUS"] = #{ci_status.inspect}\n) +
      # Collapse the poll window to a SINGLE read: RELEASE_CI_STATUS injects ONE static
      # verdict, so a :wait state (none/pending/unverified) would otherwise poll for the
      # default ~20 min. timeout 0 makes the gate read once and fail closed at once —
      # the single-read fail-closed these no-data tests assert. The polling behavior is
      # driven end-to-end by ci_poll_gate_stub, whose ci_verdict CHANGES between reads.
      %(ENV["RELEASE_CI_POLL_TIMEOUT"] = "0"\nENV["RELEASE_CI_POLL_INTERVAL"] = "0"\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false) = $stdout.puts("CONDUCTOR " + ruby)
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          return ["", false] if a[0] == "bin/failing-suite" # opt-in RED gate
          ["", true]
        end
      RUBY
  end

  # [unit] ci_pass? is THE gate verdict, fail-closed: :green is the ONLY pass; red and
  # EVERY no-data/pending/unknown state fail closed, and so do nil and a stateless hash.
  # This is the single invariant a false-green would violate — an untested SHA would ship.
  # A STRING "green" is not the :green symbol ci_verdict returns, so it fails closed too:
  # no loose coercion where a false pass ships code.
  def test_ci_pass_is_true_only_for_green_and_fails_closed_on_everything_else
    assert_equal "true", eval_helper(%(ci_pass?({ state: :green }))), "green is the ONLY pass"
    %i[red none pending unverified unreadable no_pr closed merged conflicted].each do |state|
      assert_equal "false", eval_helper(%(ci_pass?({ state: #{state.inspect} }))),
                   "#{state} must FAIL CLOSED — an absent/unknown/red verdict never certifies a SHA"
    end
    assert_equal "false", eval_helper(%(ci_pass?(nil))), "a nil verdict fails closed"
    assert_equal "false", eval_helper(%(ci_pass?({}))), "a stateless verdict fails closed"
    assert_equal "false", eval_helper(%(ci_pass?({ state: "green" }))),
                 "a STRING 'green' is not the :green symbol — fail closed, no loose coercion"
  end

  # [unit] ci_poll_action is the PURE poll decision (the CI-verdict analogue of
  # Release::ShipSequence.run_watch_verdict), factored so pending→hold / green→certify /
  # red→abort / unreadable→abort is testable without a poll loop or a clock. The POSITIVE
  # invariant, asserted directly (not by blacklisting failure spellings): GREEN is the
  # ONLY :pass; :red, :unreadable and :ci_less are the ONLY :abort — a terminal
  # non-green that waiting can never turn green (:ci_less because GitHub will run NO
  # CI at all for a stale base, so there is no run to wait for — task
  # detect-ci-less-stale-prs); EVERY other state is :wait, so a just-merged SHA's
  # not-yet-concluded CI is HELD and re-read instead of aborting the sweep's first run.
  # It is also proven against states the gate never actually feeds it (no_pr/closed/
  # merged/conflicted) so the rule holds for vectors nobody has to enumerate — they hold
  # then fail closed at the timeout, never a false pass.
  def test_ci_poll_action_classifies_each_verdict
    assert_equal ":pass", eval_helper(%(ci_poll_action({ state: :green }).inspect)), "green certifies"
    assert_equal ":pass", eval_helper(%(ci_poll_action({ state: :green, count: 3 }).inspect)),
                 "green with detail still certifies"
    %i[red unreadable ci_less].each do |state|
      assert_equal ":abort", eval_helper(%(ci_poll_action({ state: #{state.inspect} }).inspect)),
                   "#{state} is terminal — abort now, never poll a verdict waiting cannot fix"
    end
    %i[none pending unverified no_pr closed merged conflicted].each do |state|
      assert_equal ":wait", eval_helper(%(ci_poll_action({ state: #{state.inspect} }).inspect)),
                   "#{state} has no green verdict YET — hold and re-read, do not abort the sweep"
    end
    assert_equal ":wait", eval_helper(%(ci_poll_action(nil).inspect)),
                 "a nil verdict holds (fails closed at the timeout, never a false pass)"
    assert_equal ":wait", eval_helper(%(ci_poll_action({}).inspect)), "a stateless verdict holds"
  end

  # [unit] fast_forward_promote? — the SAME-SHA precondition for the G3 credit
  # (task dedupe-hub-release-suite), mirroring ship_gate_skip?'s discipline: the
  # credit may engage ONLY when origin/release IS the accepted head CI already
  # built. A diverged tip (the batch-PR merge commit), an unresolvable accepted
  # ref, and a blank release SHA all answer false — no credit, normal poll, never
  # an abort.
  def test_fast_forward_promote_is_true_only_when_release_is_the_accepted_head
    same = %(def sh(*a, **_k)\n  a.include?("origin/accepted") ? [GATE_SHA, true] : ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + same,
                  call: %(print fast_forward_promote?("/x", GATE_SHA).inspect))
    assert_equal "true", out, "release SHA == accepted head is the fast-forward shape"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + same,
                  call: %(print fast_forward_promote?("/x", "1111111111111111111111111111111111111111").inspect))
    assert_equal "false", out, "a diverged release tip (merge-commit promote) must not read as a fast-forward"

    failed = %(def sh(*a, **_k) = ["", false]\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + failed,
                  call: %(print fast_forward_promote?("/x", GATE_SHA).inspect))
    assert_equal "false", out, "an unresolvable accepted ref answers false, never an abort"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + same,
                  call: %(print fast_forward_promote?("/x", "").inspect))
    assert_equal "false", out, "a blank release SHA can never be a fast-forward"
  end

  # [integration] GREEN CI certifies: the gate passes on a green CI verdict for the
  # SHA under test, states that verdict, and records ok:true WITH CI's verdict for the
  # audit trail (record_qa_gate — the ONLY evidence G4 accepts for skipping its gate).
  def test_pre_qa_gate_records_a_green_ci_verdict_as_the_certification
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "green"),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "GitHub CI GREEN @ #{GATE_SHA[0, 7]}", "the gate STATES the CI verdict it gated on"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a green gate records its certification: #{out}"
      assert_includes record, "record_qa_gate", "…through the same conductor write as before"
      assert_includes record, "ok: true", "a green CI records ok:true so G4 may self-skip"
      assert_match(/ci:\s*\{/, record, "…carrying CI's verdict for the same SHA")
      assert_match(/"state"\s*=>\s*"green"/, record)
      assert_includes out, "PASSED"
    end
  end

  # [integration] RED CI FAILS CLOSED. GitHub says RED for the SHA under test —
  # under DevOps v2 Phase 3 CI IS the verdict, so the gate ABORTS (it does not deploy
  # to QA) and records ok:FALSE with CI's verdict (a red G3 must be recorded as failed,
  # never silently un-stamped). A RAW check-runs payload exercises the mapping shim
  # end-to-end: status+conclusion → bucket → verdict, no network.
  def test_pre_qa_gate_fails_closed_when_ci_is_red
    Dir.mktmpdir do |dir|
      payload = '{"total_count":2,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"completed","conclusion":"failure"}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a RED CI verdict FAILS the gate — CI is the verdict now, not an auditor"
      assert_includes out, "GitHub CI called #{GATE_SHA[0, 7]} RED", "…naming the SHA and the source"
      assert_includes out, "test:system", "…and the failing check"
      assert_includes out, "regression is riding origin/release"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a red gate must be RECORDED as failed, not silently un-stamped: #{out}"
      assert_includes record, "ok: false", "the red verdict records ok:false"
      assert_match(/"state"\s*=>\s*"red"/, record, "…carrying CI's red verdict for the audit trail")
      refute_includes out, "PASSED"
    end
  end

  # A gate whose CI verdict CHANGES across reads: :pending for the first two polls, then
  # :green — the just-merged-SHA timeline (CI STARTS on the fresh origin/release SHA and
  # concludes a few polls later). RELEASE_CI_STATUS injects a STATIC verdict, so the poll
  # loop is exercised by overriding ci_verdict itself. interval 0 keeps the test instant;
  # the timeout is generous so the green is REACHED, never timed out. `$ci_reads` counts
  # the reads so a test can prove it polled (3) rather than read once.
  def ci_poll_gate_stub(dir)
    %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
      %(ENV["RELEASE_CI_POLL_INTERVAL"] = "0"\nENV["RELEASE_CI_POLL_TIMEOUT"] = "60"\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        $ci_reads = 0
        def ci_verdict(_repo, _sha)
          $ci_reads += 1
          $ci_reads <= 2 ? { state: :pending, pending: ["ci"] } : { state: :green, count: 3 }
        end
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false) = $stdout.puts("CONDUCTOR " + ruby)
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
  end

  # [integration] A PENDING CI IS POLLED UNTIL IT CONCLUDES — THE FIX. A just-merged
  # release SHA reports its push CI :pending for the first minutes; Slice 3's single read
  # aborted every sweep's first run on it (observed @ 015241f, @ f05cdf5), forcing a manual
  # "wait for release CI, re-run bin/release prepare" round-trip. The gate now HOLDS and
  # re-reads: two pending reads, then green → it PASSES and certifies. ci_verdict CHANGES
  # across reads, so this drives the real poll loop, not a static injected verdict.
  def test_pre_qa_gate_polls_a_pending_ci_until_it_concludes_green
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_poll_gate_stub(dir),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("READS=" + $ci_reads.to_s); puts("PASSED")})

      assert_includes out, "holding for it to conclude", "a pending CI is HELD, not aborted on the first read"
      assert_includes out, "READS=3", "it re-read until CI concluded (2 pending + 1 green), not once"
      assert_includes out, "GitHub CI GREEN @ #{GATE_SHA[0, 7]}", "the concluded verdict is the one it gates on"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "the green conclusion is certified: #{out}"
      assert_includes record, "ok: true", "a polled-to-green CI records ok:true so G4 may self-skip"
      assert_includes out, "PASSED", "the gate passes once CI concludes green"
    end
  end

  # [integration] NO GREEN VERDICT FAILS CLOSED after the poll times out — the single most
  # important invariant. A missing run (:none), a still-running push CI (:pending), and a
  # gh/network read miss (:unverified) are all "GitHub has no GREEN verdict for this SHA
  # YET". These are :wait states, so the gate POLLS them; with the window collapsed to a
  # single read (ci_gate_stub sets RELEASE_CI_POLL_TIMEOUT=0) a verdict that never turns
  # green fails CLOSED — an absent/unknown verdict must NEVER read as a pass (a false green
  # deploys an untested SHA to QA). It records ok:false rather than certifying blind.
  def test_pre_qa_gate_fails_closed_when_ci_never_reaches_green
    %w[none pending unverified].each do |state|
      Dir.mktmpdir do |dir|
        out = run_cli(["--yes"], setup: ci_gate_stub(dir, state),
                      call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

        assert_includes out, "ABORTED", "#{state}: an absent/unknown CI verdict must FAIL CLOSED, never pass"
        assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}", "#{state}: names what it could not certify"
        assert_includes out, "FAILS CLOSED", "#{state}: the gate says why it held"
        assert_includes out, "poll timed out", "#{state}: it POLLED for a conclusion, not aborted on the first read"
        refute_includes out, "PASSED", "#{state}: a green never comes out of no-data"
      end
    end
  end

  # [integration] AN UNREADABLE CI ABORTS IMMEDIATELY — it does NOT poll. :unreadable is a
  # token/credential fault, and a refused token never heals mid-sweep, so polling it would
  # only burn the whole timeout to no end. The gate fails closed on the FIRST read and
  # prints the one shared credential remedy (CiStatus.unreadable_remedy), never a "wait for
  # CI to conclude" hold. This is the deliberate split from the no-data hold above.
  def test_pre_qa_gate_fails_closed_immediately_on_an_unreadable_ci
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "unreadable"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "an unreadable CI verdict fails the gate closed"
      assert_includes out, "UNREADABLE for #{GATE_SHA[0, 7]}", "…naming the SHA it could not read"
      assert_includes out, "credential/token fault", "…as a credential fault, not a missing CI"
      assert_includes out, "does NOT poll it", "…and it did NOT poll a broken token"
      refute_includes out, "poll timed out", "unreadable aborts on the FIRST read — no poll window is spent"
      refute_includes out, "PASSED"
    end
  end

  # --- G3 CREDIT: dedupe the hub's duplicate release suite (same SHA) ----------
  #
  # task dedupe-hub-release-suite. The hub registers the identical full suite at
  # the accepted-PR seam and again on the release push. When the promote was a
  # FAST-FORWARD (origin/release == origin/accepted — GATE_GIT_STUB answers both
  # rev-parses with GATE_SHA), the exact SHA under test already carries the
  # accepted seam's COMPLETED green check-runs, and the release push merely queues
  # duplicates of them — which used to hold the gate for the whole poll window.
  # The gate now credits that existing conclusion instead. Every one of these
  # stubs collapses the poll window to a SINGLE read (RELEASE_CI_POLL_TIMEOUT=0,
  # via ci_gate_stub), so a PASS can ONLY come from the credit path — a credit
  # that failed to engage would fail closed on the pending duplicates.

  # The credited shape: the accepted seam's suite concluded green, and the release
  # push queued duplicate runs of the SAME check names.
  CREDIT_PAYLOAD = '{"total_count":4,"check_runs":[' \
                   '{"name":"test","status":"completed","conclusion":"success"},' \
                   '{"name":"test:system","status":"completed","conclusion":"success"},' \
                   '{"name":"test","status":"queued","conclusion":null},' \
                   '{"name":"test:system","status":"in_progress","conclusion":null}]}'

  # [integration] EXISTING GREEN CREDITED — the fix. A fast-forwarded promote +
  # an already-green SHA passes the gate WITHOUT polling out the duplicate run
  # (timeout 0: a poll would have failed closed), states the credit, and records
  # the credited source in the gate note (record_qa_gate's ci half) with ok:true
  # so G4 still self-skips against the same record.
  def test_pre_qa_gate_credits_an_existing_green_conclusion_on_a_fast_forward_promote
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, CREDIT_PAYLOAD),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}",
                      "the gate SAYS it credited, and for which SHA"
      assert_includes out, "no duplicate run awaited", "…and that no poll window was spent on the duplicate"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}",
                      "the gate line marks the credited verdict apart from a polled one"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a credited gate still certifies through record_qa_gate: #{out}"
      assert_includes record, "ok: true", "a credited green records ok:true so G4 may self-skip"
      assert_match(/"credited"\s*=>/, record, "the gate note records the credited source")
      assert_includes record, "fast-forward promote", "…naming WHY the credit applied"
      assert_includes out, "PASSED", "the gate passes on the credit — no duplicate suite run awaited"
    end
  end

  # [integration] NO FAST-FORWARD, NO SAME-SHA CREDIT — and diverged TREES refuse
  # the tree credit too. The promote here minted a merge commit (origin/release !=
  # origin/accepted) whose tree ALSO differs from accepted's, so NEITHER credit may
  # engage: not the same-SHA one (ship_gate_skip?'s discipline) and not the
  # tree one (a different tree is different content — nothing vouches for it).
  # With the poll window collapsed, the pending duplicates fail closed exactly as
  # before the credit existed. (The diverged-SHA-but-IDENTICAL-tree shape credits —
  # that is the live batch-PR case, asserted by the tree-credit tests below.)
  def test_pre_qa_gate_does_not_credit_without_a_fast_forward_promote
    Dir.mktmpdir do |dir|
      diverged = %(\ndef sh(*a, **k)\n) +
                 %(  return ["2222222222222222222222222222222222222222", true] if a.include?("origin/accepted")\n) +
                 %(  return ["1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a", true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
                 %(  return ["2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b", true] if a.last.to_s.end_with?("^{tree}")\n) +
                 %(  g = gate_git(a, k)\n  return g if g\n  ["", true]\nend\n)
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, CREDIT_PAYLOAD) + diverged,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a diverged promote must never engage either credit"
      assert_includes out, "shares neither SHA nor tree", "the non-credit is NAMED, not silent (no hand-forensics)"
      assert_includes out, "ABORTED", "…so the pending duplicates fail closed exactly as before"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}"
      refute_includes out, "PASSED"
    end
  end

  # [integration] RED STILL BLOCKS — byte-for-byte. A failed run anywhere in the
  # record refuses the credit (even alongside completed greens and their queued
  # duplicates, on a genuine fast-forward), so the gate reads the SHA RED and
  # aborts with the same eject/revert guidance as ever.
  def test_pre_qa_gate_credit_never_overrides_a_red
    Dir.mktmpdir do |dir|
      payload = '{"total_count":4,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"completed","conclusion":"failure"},' \
                '{"name":"test","status":"queued","conclusion":null},' \
                '{"name":"test:system","status":"queued","conclusion":null}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a red record must never be re-read as a credit"
      assert_includes out, "ABORTED", "a red CI verdict still fails the gate closed"
      assert_includes out, "GitHub CI called #{GATE_SHA[0, 7]} RED"
      assert_includes out, "test:system", "…naming the failing check"
      refute_includes out, "PASSED"
    end
  end

  # [integration] A GENUINE WAIT STILL WAITS. A pending check with NO completed
  # counterpart is the ORIGINAL suite still running — not a duplicate — so the
  # credit declines and the gate holds/fails closed on the poll exactly as before.
  def test_pre_qa_gate_does_not_credit_a_half_finished_original_suite
    Dir.mktmpdir do |dir|
      payload = '{"total_count":2,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"in_progress","conclusion":null}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a half-finished first run must never credit"
      assert_includes out, "no completed green to credit yet", "the fast-forward decline is NAMED, not silent"
      assert_includes out, "ABORTED", "…the still-running suite fails closed at the (collapsed) poll window"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}"
      refute_includes out, "PASSED"
    end
  end

  # --- G3 TREE credit: the LIVE batch-PR promote (round 2 of the dedupe) --------
  #
  # The real accepted→release promote is `gh pr merge --merge` — a NEW merge-commit
  # SHA, so the same-SHA credit above is unreachable on the normal path (the review
  # block). But that merge commit usually snapshots the IDENTICAL TREE as the
  # accepted head (promotion #582: accepted 5b10402d / release cf93bab6, one tree
  # 5b1c78e0), and CI checks out content, not history — so the accepted head's OWN
  # completed green vouches for the merge commit. These drive the REAL pre_qa_gate
  # with per-SHA verdicts: GATE_SHA is origin/release (the merge commit), ACC_SHA
  # the accepted head. The poll window is collapsed to a single read, so a PASS on
  # a pending release SHA can ONLY come from the tree credit.

  ACC_SHA = "acce97ed22222222222222222222222222222222"
  SHARED_TREE = "5b1c78e033333333333333333333333333333333"

  # `accepted_tree:` controls the divergence under test; `release_ci:` /
  # `accepted_ci:` the per-SHA verdicts ci_verdict answers (the poll reads the
  # release SHA; the tree credit reads the accepted head).
  def tree_gate_stub(dir, accepted_tree:, release_ci: ":pending", accepted_ci: ":green")
    %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
      %(ENV["RELEASE_CI_POLL_TIMEOUT"] = "0"\nENV["RELEASE_CI_POLL_INTERVAL"] = "0"\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB +
      %(ACC_SHA = #{ACC_SHA.inspect}\n) +
      %(def qa_gate_cmd(_repo) = "bin/suite"\n) +
      %(def conductor(ruby, read_only: false) = $stdout.puts("CONDUCTOR " + ruby)\n) +
      %(def ci_verdict(_repo, sha)\n) +
      %(  return { state: #{accepted_ci}, count: 8, pending: ["test"] } if sha == ACC_SHA\n) +
      %(  { state: #{release_ci}, count: 8, pending: ["test"] }\n) +
      %(end\n) +
      %(def sh(*a, **k)\n) +
      %(  return [ACC_SHA, true] if a.include?("origin/accepted")\n) +
      %(  return [#{SHARED_TREE.inspect}, true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
      %(  return [#{accepted_tree.inspect}, true] if a.last.to_s == ACC_SHA + "^{tree}"\n) +
      %(  g = gate_git(a, k)\n  return g if g\n  ["", true]\nend\n)
  end

  # [integration] THE LIVE PATH CREDITS BY TREE — the round-2 fix. A batch-PR merge
  # commit (release != accepted) with the accepted head's tree, whose accepted-head
  # CI already concluded green, passes the gate WITHOUT polling out the duplicate
  # release-push run (timeout 0: the release SHA reads pending, so a poll would
  # have failed closed). The gate note records BOTH full SHAs + the shared tree.
  def test_pre_qa_gate_credits_the_accepted_head_green_on_a_tree_identical_promote
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: SHARED_TREE),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}",
                      "the gate SAYS it credited, and for which release SHA"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}",
                      "the gate line marks the credited verdict apart from a polled one"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "a tree-credited gate still certifies through record_qa_gate: #{out}"
      assert_includes record, "ok: true", "a tree-credited green records ok:true so G4 may self-skip"
      assert_includes record, "tree-identical promote", "the note names WHY the credit applied"
      assert_includes record, ACC_SHA, "…and the accepted head whose run vouched (full SHA)"
      assert_includes record, GATE_SHA, "…and the release merge commit it vouched for (full SHA)"
      assert_includes record, SHARED_TREE, "…and the one tree both SHAs snapshot"
      assert_includes out, "PASSED"
    end
  end

  # [integration] THE LOCK-BUMP INTERACTION (cross-PR contract pinned on PR #588,
  # publish-gems-before-qa). When a gem rides, prepare's step 4c commits each
  # consumer's Gemfile.lock bump onto `release` BEFORE pre_qa_gate resolves
  # origin/release — so the SHA gated here is the post-bump commit and its tree NO
  # LONGER matches the accepted head's. The credit must REFUSE (nothing green ever
  # ran the bumped tree) and the poll path must RUN: with the window collapsed and
  # the post-bump SHA's own CI still pending, the gate fails closed via today's
  # exact abort — proof the verdict came from the poll, not a credit.
  def test_pre_qa_gate_lock_bump_on_release_refuses_the_tree_credit_and_polls
    Dir.mktmpdir do |dir|
      bumped_tree = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: bumped_tree),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a lock-bumped release tree has NO green run behind it — never credit"
      assert_includes out, "ABORTED", "…so the gate holds/fails closed at the poll exactly as today"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}",
                      "today's poll-path abort, naming the post-bump SHA under test"
      refute_includes out, "PASSED"
    end
  end

  # [integration] The lock-bump companion: the post-bump SHA earns its OWN verdict.
  # Same diverged-tree shape, but the release SHA's CI (the push run on the bumped
  # commit) concluded green — the gate passes off the POLL, and the record carries
  # NO credited key: the verdict was earned, not vouched.
  def test_pre_qa_gate_lock_bump_sha_passes_on_its_own_polled_green
    Dir.mktmpdir do |dir|
      bumped_tree = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: bumped_tree, release_ci: ":green"),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      refute_includes out, "crediting", "no credit engaged — the bumped tree earned its own green"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "the polled green still certifies through record_qa_gate: #{out}"
      assert_includes record, "ok: true"
      refute_includes record, "credited", "a polled verdict records NO credited source"
      assert_includes out, "PASSED"
    end
  end

  # [integration] THE WAIT TIMES OUT → FALL THROUGH. The accepted head is IN FLIGHT
  # but never concludes, and here the poll budget is collapsed to zero — so the gate
  # tries the in-flight wait, finds no budget, and falls through to poll the release
  # SHA's own run exactly as today (also pending → fails closed). Pending evidence
  # still certifies NOTHING, and a wait that cannot conclude never fabricates a green.
  def test_pre_qa_gate_tree_credit_wait_times_out_and_falls_through_when_pending
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: SHARED_TREE, accepted_ci: ":pending"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "pending evidence certifies nothing — no credit"
      assert_includes out, "did not conclude before the poll budget", "it TRIED the in-flight wait, then fell through"
      assert_includes out, "ABORTED", "…the gate holds/fails closed at the (collapsed) release-SHA poll"
      refute_includes out, "PASSED"
    end
  end

  # [integration] STRICT FALL-THROUGH: red evidence never credits — and never
  # aborts THROUGH the credit either. A red accepted-head run refuses the credit
  # and the gate takes today's poll on the release SHA (whose own run delivers its
  # own verdict — here still pending, so the collapsed window fails closed with
  # today's abort, not a credit-path one).
  def test_pre_qa_gate_tree_credit_declines_on_red_accepted_evidence
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_gate_stub(dir, accepted_tree: SHARED_TREE, accepted_ci: ":red"),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      refute_includes out, "crediting", "a red evidence run must never be re-read as a credit"
      assert_includes out, "ABORTED"
      assert_includes out, "NO green verdict for #{GATE_SHA[0, 7]}", "…failing closed on the RELEASE SHA's own poll"
      refute_includes out, "PASSED"
    end
  end

  # A tree-identical promote whose accepted-head run is IN FLIGHT: it reports
  # :pending for the first two reads, then concludes :green — the live first-sweep
  # timeline (the batch PR opened seconds earlier, so the accepted run is still
  # building when the sweep reaches the gate). The RELEASE SHA's own run NEVER
  # concludes (:pending forever), so a PASS can come ONLY from WAITING ON THE
  # ACCEPTED RUN, never from falling through to poll the duplicate. $acc_reads
  # counts the accepted-head reads so a test can prove it polled to conclusion.
  def tree_wait_gate_stub(dir)
    %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
      %(ENV["RELEASE_CI_POLL_TIMEOUT"] = "10"\nENV["RELEASE_CI_POLL_INTERVAL"] = "0"\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB +
      %(ACC_SHA = #{ACC_SHA.inspect}\n) +
      %(def qa_gate_cmd(_repo) = "bin/suite"\n) +
      %(def conductor(ruby, read_only: false) = $stdout.puts("CONDUCTOR " + ruby)\n) +
      %($acc_reads = 0\n) +
      %(def ci_verdict(_repo, sha)\n) +
      %(  if sha == ACC_SHA\n) +
      %(    $acc_reads += 1\n) +
      %(    return $acc_reads <= 2 ? { state: :pending, pending: ["test"] } : { state: :green, count: 8 }\n) +
      %(  end\n) +
      %(  { state: :pending, pending: ["test"] }\n) +
      %(end\n) +
      %(def sh(*a, **k)\n) +
      %(  return [ACC_SHA, true] if a.include?("origin/accepted")\n) +
      %(  return [#{SHARED_TREE.inspect}, true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
      %(  return [#{SHARED_TREE.inspect}, true] if a.last.to_s == ACC_SHA + "^{tree}"\n) +
      %(  g = gate_git(a, k)\n  return g if g\n  ["", true]\nend\n)
  end

  # [integration] THE FIX — an IN-FLIGHT accepted run is WAITED ON, not duplicated.
  # MEASURED on rel-20260720-1fc111: in a fast pipeline the accepted CI is still
  # BUILDING when the sweep reaches the gate, so the completed-green credit fell
  # through and the hub ran the identical suite TWICE. The gate now recognises an
  # in-flight accepted run on the identical tree and WAITS on it (same wall-clock,
  # the duplicate release run skipped) — polling it to its green conclusion and
  # crediting it, while the release SHA's own run is never awaited.
  def test_pre_qa_gate_waits_on_the_inflight_accepted_run_and_credits_it
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: tree_wait_gate_stub(dir),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("ACC_READS=" + $acc_reads.to_s); puts("PASSED")})

      assert_includes out, "waiting on it instead of re-running the duplicate",
                      "an in-flight accepted run on the identical tree is WAITED ON, not fallen-through"
      assert_includes out, "ACC_READS=3", "it polled the ACCEPTED head to its green conclusion (2 pending + 1 green)"
      assert_includes out, "crediting the existing green conclusion for #{GATE_SHA[0, 7]}",
                      "…then credited the accepted head's green — the duplicate release run is skipped"
      assert_includes out, "GitHub CI GREEN (credited) @ #{GATE_SHA[0, 7]}"
      refute_includes out, "poll timed out", "it NEVER fell through to poll the still-pending release SHA"
      assert_includes out, "PASSED"
    end
  end

  # [unit] tree_identical_promote — the SAME-TREE precondition, answered from git:
  # {accepted_sha, tree} ONLY when the SHAs differ and the trees match; the
  # same-SHA case belongs to fast_forward_promote? (checked first), and every git
  # fault answers nil — no credit, normal poll, never an abort.
  def test_tree_identical_promote_matches_trees_only_across_differing_shas
    trees = %(def sh(*a, **_k)\n) +
            %(  return [#{ACC_SHA.inspect}, true] if a.include?("origin/accepted")\n) +
            %(  return ["5b1c78e0aaaa", true] if a.last.to_s.end_with?("^{tree}")\n) +
            %(  ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + trees,
                  call: %(p = tree_identical_promote("/x", GATE_SHA); print [p[:accepted_sha], p[:tree]].inspect))
    assert_equal %(["#{ACC_SHA}", "5b1c78e0aaaa"]), out,
                 "differing SHAs + one tree = the live batch-PR promote shape"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + trees,
                  call: %(print tree_identical_promote("/x", #{ACC_SHA.inspect}).inspect))
    assert_equal "nil", out, "release == accepted head is the fast-forward credit's case, not this one"

    split = %(def sh(*a, **_k)\n) +
            %(  return [#{ACC_SHA.inspect}, true] if a.include?("origin/accepted")\n) +
            %(  return ["1a1a1a", true] if a.last.to_s == GATE_SHA + "^{tree}"\n) +
            %(  return ["2b2b2b", true] if a.last.to_s.end_with?("^{tree}")\n) +
            %(  ["", false]\nend\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + split,
                  call: %(print tree_identical_promote("/x", GATE_SHA).inspect))
    assert_equal "nil", out, "diverged trees (a lock-bump commit on release) must answer nil"

    failed = %(def sh(*a, **_k) = ["", false]\n)
    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + failed,
                  call: %(print tree_identical_promote("/x", GATE_SHA).inspect))
    assert_equal "nil", out, "an unresolvable ref answers nil, never an abort"

    out = run_cli(["--dry-run"], setup: GATE_GIT_STUB + trees,
                  call: %(print tree_identical_promote("/x", "").inspect))
    assert_equal "nil", out, "a blank release SHA can never match"
  end

  # [unit] tree_identical_ci_outcome — the accepted-head decision for an identical
  # tree. It CREDITS a completed green (both SHAs + the tree in the note), and for
  # EVERY non-green verdict returns no credit plus a DIAGNOSTIC naming why — the gate
  # was previously silent here, which is exactly why the round-3 bug was invisible
  # without hand-forensics. A pending run with the budget already spent, and a raising
  # probe, both fall through with their own reason. (`deadline: 0` collapses the wait so
  # a :pending verdict times out at once instead of polling; the live in-flight WAIT is
  # driven end to end by test_pre_qa_gate_waits_on_the_inflight_accepted_run_and_credits_it.)
  def test_tree_identical_ci_outcome_credits_green_and_diagnoses_every_fall_through
    promote = %({ accepted_sha: #{ACC_SHA.inspect}, tree: #{SHARED_TREE.inspect} })

    green = %(def ci_verdict(_r, _s) = { state: :green, count: 8 }\n)
    out = run_cli(["--dry-run"], setup: green,
                  call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                        %(print [o[:credit] && o[:credit][:state], o[:credit] && o[:credit][:credited], o[:diagnostic]].inspect))
    assert_includes out, ":green", "a completed green is credited"
    assert_includes out, "tree-identical promote"
    assert_includes out, ACC_SHA, "the note names the accepted head that vouched"
    assert_includes out, GATE_SHA, "…the release merge commit vouched for"
    assert_includes out, SHARED_TREE, "…and the shared tree"

    %i[red none unverified unreadable].each do |state|
      declined = %(def ci_verdict(_r, _s) = { state: #{state.inspect} }\n)
      out = run_cli(["--dry-run"], setup: declined,
                    call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                          %(print [o[:credit], o[:diagnostic]].inspect))
      assert_match(/\Anil,|\[nil,/, out.gsub(/\s/, ""), "#{state}: nothing is credited")
      assert_includes out, "no green to credit", "#{state}: it says WHY — polling the release run instead"
      assert_includes out, state.to_s, "#{state}: the diagnostic names the verdict it saw"
    end

    pending = %(def ci_verdict(_r, _s) = { state: :pending }\n)
    out = run_cli(["--dry-run"], setup: pending,
                  call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                        %(print [o[:credit], o[:diagnostic]].inspect))
    assert_includes out, "nil", "a pending run with no budget credits nothing"
    assert_includes out, "did not conclude before the poll budget", "…and says the in-flight wait timed out"

    raises = %(def ci_verdict(_r, _s) = raise("boom")\n)
    out = run_cli(["--dry-run"], setup: raises,
                  call: %(o = tree_identical_ci_outcome("x", #{GATE_SHA.inspect}, #{promote}, deadline: 0); ) +
                        %(print [o[:credit], o[:diagnostic]].inspect))
    assert_includes out, "nil"
    assert_includes out, "tree-credit probe errored", "a raising probe falls through with a reason"
  end

  # [integration] THE DEMOTION, affirmatively pinned (the positive replacement for the
  # skipped apparatus tests): on a GREEN CI verdict the G3 gate PASSES without ever
  # pinning an isolated workspace or booting the local suite — the verdict comes off the
  # laptop. `git worktree add`, `bin/suite`, and `bin/rails db:test:prepare` must NOT run.
  def test_pre_qa_gate_does_not_execute_the_local_suite
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false) = {}
        def sh(*a, **k)
          $stdout.puts("SUITE-RAN") if a[0] == "bin/suite"
          $stdout.puts("WORKTREE-ADD") if a[0] == "git" && a.include?("worktree") && a.include?("add")
          $stdout.puts("DB-PREPARE") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "PASSED", "a green CI verdict passes the gate"
      refute_includes out, "SUITE-RAN", "the demoted local suite must NOT run — CI is the verdict"
      refute_includes out, "WORKTREE-ADD", "…and no isolated workspace is pinned"
      refute_includes out, "DB-PREPARE", "…and no gate DB is prepared"
    end
  end

  # [unit] The url the overlay carries is read from the APP's OWN config/database.yml
  # (not a registry column that can drift): a postgres app gets the gate's private DB;
  # a SQLite app gets NOTHING.
  def test_gate_database_url_is_private_for_a_pg_app_and_nil_for_a_sqlite_app
    Dir.mktmpdir do |dir|
      pg   = plant_database_yml(File.join(dir, "pg"))
      lite = plant_database_yml(File.join(dir, "lite"), adapter: "sqlite3")
      setup = %(def repo_path(repo) = repo == "turf-monster" ? #{pg.inspect} : #{lite.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{print([gate_database_url("turf-monster"), gate_database_url("rolio")].inspect)})

      assert_equal %(["postgres:///turf_monster_gate_test", nil]), out
    end
  end

  # --- G3 certification: the ONLY evidence G4 accepts for skipping its gate ------
  #
  # A GREEN CI verdict stamps release.metadata["qa_gates"][repo] = {sha, cmd, ok:true}.
  # A RED CI verdict stamps the SAME shape with ok:FALSE — an honest failed record, not
  # a silent omission (record_qa_gate's caveat). A skipped/absent gate leaves NOTHING.
  # Only a green ok:true record lets G4 self-skip (ship_gate_skip?); ok:false AND an
  # absent record both make G4 re-derive the verdict from CI on the frozen SHA. The cmd
  # is recorded in every case so the G4 drift assertion (certified_cmd == cmd) can hold.

  # [unit] A GREEN CI verdict records what it CERTIFIED: this repo, this SHA, this cmd,
  # ok:true. The cmd is RECORDED (not run), which is what keeps the G4 drift check valid.
  def test_pre_qa_gate_records_the_g3_certification_on_a_green_ci_verdict
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cert"); puts("PASSED")})

      cert = out.lines.find { |l| l.start_with?("CERT-CALL") }
      assert cert, "a GREEN CI verdict must record its certification: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate", "the stamp rides the tested conductor primitive"
      assert_includes cert, %(slug: "rel-cert")
      assert_includes cert, %(repo: "sibling")
      assert_includes cert, %(sha: "#{GATE_SHA}"), "it certifies the SHA CI gave a verdict on"
      assert_includes cert, %(cmd: "bin/suite"), "…and RECORDS the command (for the G4 drift check), never runs it"
      assert_includes cert, "ok: true"
      assert_includes out, "PASSED"
    end
  end

  # [unit] A RED CI verdict RECORDS ok:false — it must NOT silently un-stamp (the
  # record_qa_gate caveat). ok:false is not a green record, so G4's ship_gate_skip? still
  # runs the gate; the honest failed stamp is what the release audit trail reads.
  def test_pre_qa_gate_records_ok_false_when_ci_is_red
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "red"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cert"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a red CI verdict still aborts the prepare (fail-closed)"
      cert = out.lines.find { |l| l.start_with?("CERT-CALL") }
      assert cert, "a RED gate must RECORD its failure, not silently skip recording: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate"
      assert_includes cert, "ok: false", "…as ok:false — an honest failed stamp, never a green one"
      assert_includes cert, %(cmd: "bin/suite"), "the cmd is recorded even on a red verdict"
      refute_includes out, "PASSED"
    end
  end

  # [integration] The SELF-GATED-GEM pass records a first-class G3 verdict for a
  # gem-only release (gem-only-deployments). With NO app member, pre_qa_gate's gem
  # pass gates studio-engine (self-gated) on its OWN suite's CI — resolved through
  # the same repo-generic credit the apps use — and records the certification via
  # the SAME Release::Conductor.record_qa_gate primitive, with the gem's registry
  # release_check as the recorded cmd. This is what makes a gem-only publish show as
  # a first-class deployment instead of being invisible.
  def test_pre_qa_gate_self_gated_gem_records_a_g3_verdict_on_its_own_ci
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([], "rel-cert", gem_groups: [{ "repo" => "studio-engine" }]); puts("PASSED")})

      assert_includes out, "pre-QA gate studio-engine (self-gated gem): GitHub CI GREEN",
                      "the self-gated gem is gated on its own CI: #{out}"
      cert = out.lines.find { |l| l.start_with?("CERT-CALL") }
      assert cert, "the self-gated gem must RECORD its G3 certification: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate", "the stamp rides the tested conductor primitive"
      assert_includes cert, %(slug: "rel-cert")
      assert_includes cert, %(repo: "studio-engine")
      assert_includes cert, %(sha: "#{GATE_SHA}"), "it certifies the SHA CI gave a verdict on"
      assert_includes cert, %(cmd: "bin/release-check"), "…and RECORDS the gem's own release_check as the gate cmd"
      assert_includes cert, "ok: true"
      assert_includes out, "PASSED"
    end
  end

  # [integration] The gem pass is SCOPED to a gem-only release: a self-gated gem
  # member alongside an APP member gets NO extra gem G3 gate — it is QA'd through
  # its consumer, exactly as before. Proves the gem-riding-app path is untouched.
  def test_pre_qa_gate_skips_the_gem_pass_when_an_app_rides_the_release
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false) = {}
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{pre_qa_gate([{ "repo" => "sibling-app" }], "rel-cert", gem_groups: [{ "repo" => "studio-engine" }]); puts("PASSED")})

      assert_includes out, "pre-QA gate sibling-app: GitHub CI GREEN", "the app gate still runs"
      refute_includes out, "self-gated gem", "no gem G3 pass fires when an app rides the release"
      assert_includes out, "PASSED"
    end
  end

  # --- suite-toolchain guard: bundle check/install under the SUITE ruby -------
  #
  # REGRESSION (rel-20260708-32701b): the gate boots the suite via the repo's
  # binstubs (`#!/usr/bin/env ruby` → mise's pinned ruby on this machine), but
  # the conductor/operator shell's `bundle` resolved HOMEBREW ruby — DIVERGENT
  # gem homes. PR #456's engine bump was "satisfied" in brew's gem home while
  # missing from mise's (the one the suite boots) → Bundler::GemNotFound at
  # suite boot → the gate aborted TWICE with "a regression is riding
  # origin/release" (eject/revert guidance) for a pure env problem. The gate
  # must bundle-check/install through the SAME env-resolved ruby that boots the
  # suite (the repo's bin/bundle binstub), and a still-broken bundle must abort
  # as an ENV/toolchain diagnosis — never the eject path.

  # A minimal repo fixture with a Gemfile (the guard self-gates without one) and a
  # bin/bundle binstub (suite_bundle_argv's probe) — planted in the ISOLATED GATE
  # WORKSPACE (<repo>/.worktrees/_gate), because THAT is the tree the guard now
  # reads: the suite boots there, so its gem home is the one that must be
  # satisfied. Returns [primary, workspace]; the git/bundle/suite commands
  # themselves are stubbed via sh.
  def build_binstub_fixture(dir)
    primary   = File.join(dir, "repo")
    workspace = File.join(primary, ".worktrees", "_gate")
    FileUtils.mkdir_p(File.join(workspace, "bin"))
    File.write(File.join(workspace, "Gemfile"), "source \"https://rubygems.org\"\n")
    File.write(File.join(workspace, "bin", "bundle"), "#!/usr/bin/env ruby\n")
    [primary, workspace]
  end

  # [unit] suite_bundle_argv prefers a repo's bin/bundle binstub (same
  # env-resolved ruby as bin/rails) and falls back to `ruby -S bundle` — NEVER
  # bare `bundle` — when it carries no binstub, so the fallback still runs under
  # the mise-pinned ruby (carl + shannon's PR #480 request-changes).
  def test_suite_bundle_argv_prefers_the_binstub_and_falls_back_to_ruby_dash_s
    Dir.mktmpdir do |dir|
      _primary, workspace = build_binstub_fixture(dir)
      out = eval_helper(%([suite_bundle_argv(#{workspace.inspect}), suite_bundle_argv(#{dir.inspect})].inspect))
      assert_equal %([["bin/bundle"], ["ruby", "-S", "bundle"]]), out
    end
  end

  # --- qa_test_cmd registry values + test_cmd_argv (Shellwords) parsing --------

  # The hub's registered gate command (G3 qa_test_cmd == G4 test_cmd) — ci.yml's
  # test command verbatim, INCLUDING the system tier. Named once so the CLI
  # assertions below don't each re-pin a literal that can drift; the registry
  # itself is held to ci.yml by Release::ReposTest's drift guard.
  HUB_GATE_CMD = "bin/rails db:test:prepare test test:system"

  def test_qa_gate_cmd_reads_the_registered_g3_tier_from_the_real_registry
    # ONE subprocess reads all five apps through the REAL config/release_repos.yml
    # — the exact seam pre_qa_gate reads at run time. The tier a repo registers
    # turns on whether its DEPLOY runs the suite, not on hub-vs-satellite:
    #   * the HUB and ROLIO both deploy via git_push_heroku (NO test step), so each
    #     registers CI's full suite VERBATIM — base AND system tiers. It is the same
    #     STRING for both (HUB_GATE_CMD), which is why rolio reuses the constant:
    #     both ci.yml `test` jobs run `bin/rails db:test:prepare test test:system`.
    #     For rolio this is its LAST gate before prod, and `bin/rails test` alone
    #     SKIPS its test/system — the gap this pins shut.
    #   * turf-monster keeps the integration subset — bin/deploy runs its full
    #     suite pre-prod, and it has no test/system at all.
    out = eval_helper(%(%w[mcritchie-studio turf-monster rolio tax-studio chain-ops].map { |r| qa_gate_cmd(r) }.inspect))

    expected = [HUB_GATE_CMD,
                "bin/rails test test/integration", HUB_GATE_CMD,
                "", ""]
    assert_equal expected.inspect, out,
                 "hub + rolio certify CI's full suite at G3 (no test step in their deploy); turf-monster " \
                 "gates on integration; planned apps self-gate"
  end

  def test_test_cmd_argv_matches_plain_split_for_flag_style_commands
    # The behavior-preserving half of the Shellwords switch: every flag-style
    # command (the shape the registry carries) parses byte-identically both ways.
    out = eval_helper(%(["bin/rails test", "bin/rails test test/integration", "bin/deploy --yes"].map { |c| test_cmd_argv(c) == c.split }.inspect))
    assert_equal "[true, true, true]", out
  end

  def test_test_cmd_argv_keeps_a_quoted_spaced_arg_as_one_element
    out = eval_helper(%(test_cmd_argv(%q{bin/rails test "test/integration/a b_test.rb"}).inspect))
    assert_equal %(["bin/rails", "test", "test/integration/a b_test.rb"]), out
  end

  def test_test_cmd_argv_aborts_naming_an_unbalanced_quote
    out = run_cli(["--yes"], setup: "",
                  call: %{begin; test_cmd_argv(%q{bin/rails test "unclosed}); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED", "a malformed command must never exec a garbled argv"
    assert_includes out, "unparseable test command"
    assert_includes out, "unclosed", "the abort names the offending string"
    assert_includes out, "config/release_repos.yml", "…and points at the registry to fix"
  end

  def test_pre_qa_gate_dry_run_still_aborts_on_a_malformed_command
    # The parse is hoisted BEFORE the dry-run return, so a broken registry value
    # surfaces in a preview instead of detonating mid-conductor later.
    setup = %(def qa_gate_cmd(_repo) = %q{bin/rails test "unclosed})
    out = run_cli(["--dry-run"], setup: setup,
                  call: %{begin; pre_qa_gate([{ "repo" => "mcritchie-studio" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_includes out, "ABORTED"
    assert_includes out, "unparseable test command"
    refute_includes out, "PASSED"
  end

  # --- primary-checkout lock: who still holds it, and who no longer does -------
  #
  # REGRESSION (rel-20260708-496cd8, then rel-20260711-7f2913): the gates used to
  # run their multi-minute suite ON the primary after a transient `git checkout
  # release`, so a concurrent `bin/release archive`/`retro` artifact dance
  # (commit_artifact_to_release) — or any process the ADVISORY flock does not bind
  # (another agent session, a hand-run git) — could flip that primary main↔release
  # mid-suite. With the test env autoloading LAZILY, the running suite then
  # resolved code from the WRONG tree → false failures → a false-negative gate.
  #
  # Widening the flock could not fix it (it binds only other bin/release runs), so
  # the suite MOVED: it now runs in the isolated gate workspace, and the gate takes
  # NO primary lock at all. What remains locked is only the primary-HEAD FLIP
  # SITES — ship's local ff (ff_main_local) and the artifact dance — which still
  # must hold the per-repo flock (with_primary_checkout) so they can't interleave
  # with each other.

  # A real git sibling fixture — bare origin + a clone with main/release
  # branches — so the lock/gate tests exercise the REAL `sh`, a REAL `git worktree
  # add`, and REAL flock contention across process boundaries. Returns the clone
  # path.
  def build_sibling_fixture(dir)
    origin = File.join(dir, "origin.git")
    clone  = File.join(dir, "repo")
    git = lambda do |*a|
      ok = system("git", "-C", clone, "-c", "user.email=t@t.t", "-c", "user.name=t", *a,
                  out: File::NULL, err: File::NULL)
      flunk("git #{a.join(' ')} failed") unless ok
    end
    system("git", "init", "--bare", "-q", origin, out: File::NULL, err: File::NULL) || flunk("git init --bare failed")
    system("git", "clone", "-q", origin, clone, out: File::NULL, err: File::NULL) || flunk("git clone failed")
    git.call("symbolic-ref", "HEAD", "refs/heads/main")
    # Self-contained identity IN the repo config (not just the lambda's -c
    # flags): the code under test runs its own bare `git commit`, which has no
    # identity on CI runners ("Please tell me who you are") — green-local /
    # red-CI without these. gpgsign off so a signing global can't break it.
    git.call("config", "user.email", "t@t.t")
    git.call("config", "user.name", "t")
    git.call("config", "commit.gpgsign", "false")
    File.write(File.join(clone, "README"), "lock fixture")
    # A COMMITTED config/database.yml, so the gate resolves a REAL adapter off the
    # fixture's own disk (postgres → the private gate DB url in the env overlay),
    # exactly as it does for a real app.
    plant_database_yml(clone)
    # A COMMITTED bin/rails, so it lands in the gate's detached workspace too. A real
    # gate runs TWO bin/rails commands there before the suite: the private-DB probe
    # (`runner`, whose stdout it plucks `GATEDB=` out of) and `db:test:prepare`
    # (exactly what CI runs) — and aborts as an ENV issue if either fails. The
    # fixture is not a Rails app, so it answers the probe the way a COMPLIANT app
    # does — echoing back the DATABASE_URL the gate overlaid (Rails merges that
    # builtin into the test config) — and answers everything else green.
    FileUtils.mkdir_p(File.join(clone, "bin"))
    File.write(File.join(clone, "bin", "rails"), <<~SH)
      #!/usr/bin/env sh
      if [ "$1" = "runner" ]; then
        printf 'GATEDB=%s' "${DATABASE_URL##*/}"
      fi
      exit 0
    SH
    File.chmod(0o755, File.join(clone, "bin", "rails"))
    git.call("add", ".")
    git.call("commit", "-q", "-m", "init")
    git.call("branch", "release")
    git.call("push", "-q", "origin", "main", "release")
    clone
  end

  # Run a git command in a fixture repo, flunking on failure (the fixtures are
  # built by this file, so a git failure here is a broken test, not a finding).
  def run_git(repo, *args)
    ok = system("git", "-C", repo, "-c", "user.email=t@t.t", "-c", "user.name=t", *args,
                out: File::NULL, err: File::NULL)
    flunk("git #{args.join(' ')} failed in #{repo}") unless ok
  end

  # A stripped git READ out of a fixture repo (`rev-parse`, `status --porcelain`, …).
  def git_out(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    flunk("git #{args.join(' ')} failed in #{repo}: #{out}") unless status.success?
    out.strip
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

  # Poll until the block goes truthy, or flunk. The cross-process lock tests observe
  # a QUEUE, which only exists over time.
  def wait_until(timeout, what)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      flunk("timed out after #{timeout}s waiting for #{what}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  # A file the CHILD writes, read from the parent mid-run: it may not exist yet (the
  # queued conductor has run nothing), and a MISSING marks file is the strongest
  # possible "it did nothing".
  def file_text(path) = File.exist?(path) ? File.read(path) : ""

  def mark_lines(path) = file_text(path).lines.map(&:strip)

  def refute_mark(path, mark, msg) = refute_includes(mark_lines(path), mark, msg)

  def assert_mark(path, mark, msg) = assert_includes(mark_lines(path), mark, msg)

  # [unit] While another invocation holds the checkout (the gate's suite run),
  # the artifact dance must SKIP — best-effort, non-fatal, HEAD untouched — not
  # queue behind a ~6-min suite and never flip main↔release under it. The test
  # process holds the flock exactly as the gate does.
  def test_commit_artifact_to_release_skips_without_flipping_while_the_checkout_is_locked
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      doc = File.join(clone, "retro.md")
      File.write(doc, "retro fixture") # the SOLE uncommitted change → safe_to_commit? passes

      lock = File.open(File.join(dir, "mcr-primary-checkout-sibling.lock"), File::CREAT | File::RDWR, 0o644)
      assert lock.flock(File::LOCK_EX | File::LOCK_NB), "test setup: the lock must start free"

      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{commit_artifact_to_release("sibling", #{doc.inspect}, "retro: fixture"); puts("DONE")})

      assert_includes out, "left retro.md uncommitted", "the dance must skip while the checkout is locked"
      assert_includes out, "primary checkout busy", "…naming the concurrent holder as the reason"
      refute_includes out, "committed retro.md", "…never committing mid-gate"
      assert_includes out, "DONE", "the skip stays NON-FATAL (archive/retro ride on)"
      head, = Open3.capture2("git", "-C", clone, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal "main", head.strip, "HEAD must never leave main while the lock is held elsewhere"
      count, = Open3.capture2("git", "-C", clone, "rev-list", "--count", "release")
      assert_equal "1", count.strip, "no commit lands on release while the checkout is locked"
    ensure
      lock&.close
    end
  end

  # [unit] Uncontended, the dance still works end-to-end: takes the lock,
  # commits the doc onto release, pushes, restores main, releases the lock.
  def test_commit_artifact_to_release_commits_and_restores_main_when_uncontended
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      doc = File.join(clone, "retro.md")
      File.write(doc, "retro fixture")

      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{commit_artifact_to_release("sibling", #{doc.inspect}, "retro: fixture"); puts("DONE")})

      assert_includes out, "committed retro.md to release", "a free checkout commits the artifact"
      assert_includes out, "DONE"
      head, = Open3.capture2("git", "-C", clone, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal "main", head.strip, "the checkout is restored to main (ensure)"
      count, = Open3.capture2("git", "-C", clone, "rev-list", "--count", "origin/release")
      assert_equal "2", count.strip, "the artifact commit is pushed onto origin/release"
      File.open(File.join(dir, "mcr-primary-checkout-sibling.lock"), File::RDWR | File::CREAT, 0o644) do |f|
        assert f.flock(File::LOCK_EX | File::LOCK_NB), "the dance must RELEASE the lock afterwards"
      end
    end
  end

  # --- the ship's own checkout: main advances by REF PUSH, not by ff -----------
  #
  # HISTORY (2026-07-12). ship used to advance `main` by flipping the SHARED PRIMARY
  # (checkout main → pull → merge --ff-only → push), so it had to REFUSE a dirty
  # primary — and that refusal aborted a real production ship, after the gems had
  # published, because a concurrent feature session had staged work there. Advancing
  # a remote branch never needed a working tree: `git push origin
  # <frozen>:refs/heads/main` reads the shared object store, moves no HEAD, touches
  # no index, and is still fast-forward-checked by git. These are the proofs, on a
  # REAL git fixture, that the deploy is now indifferent to the primary's state.

  # [integration] The core acceptance: origin/main reaches the frozen SHA while the
  # primary is DIRTY and sitting on a feature branch — and comes out of it dirty, on
  # that same branch, with the stranded work untouched. Nothing is stashed, nothing
  # is discarded, nothing is checked out.
  def test_push_frozen_main_advances_origin_from_a_dirty_off_main_primary
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      frozen = git_out(clone, "rev-parse", "release")

      # A live feature session's floor: a branch, a staged file, an untracked file.
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")
      run_git(clone, "add", "app.rb")
      File.write(File.join(clone, "notes.txt"), "scratch")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "a dirty primary must NOT abort the ship: #{out}"
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "origin/main must reach the frozen SHA — that is what prod deploys"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary must still be on the session's branch — the ship never checked it out"
      status = git_out(clone, "status", "--porcelain")
      assert_includes status, "app.rb",   "the session's staged work must survive untouched"
      assert_includes status, "notes.txt", "…and its untracked file too"
    end
  end

  # [integration] FAILS CLOSED. If origin/main has diverged from the frozen SHA, git
  # refuses the non-fast-forward ref update and the ship ABORTS — it must never
  # --force a rewind onto production.
  def test_push_frozen_main_aborts_on_a_diverged_origin_main_and_never_forces
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # origin/main moves somewhere our frozen SHA cannot fast-forward to.
      run_git(clone, "checkout", "-q", "-b", "rogue", base)
      File.write(File.join(clone, "rogue.txt"), "pushed straight to main")
      run_git(clone, "add", "rogue.txt")
      run_git(clone, "commit", "-q", "-m", "rogue")
      run_git(clone, "push", "-q", "origin", "rogue:main")
      diverged = git_out(origin, "rev-parse", "main")
      frozen   = git_out(clone, "rev-parse", "release")

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a diverged origin/main must abort, not force: #{out}"
      assert_includes out, "NOT forcing", "the abort must say it refused to force"
      assert_equal diverged, git_out(origin, "rev-parse", "main"),
                   "production's main must be left EXACTLY as it was — never rewound"
    end
  end

  # --- post-ship: re-baseline origin/accepted onto the shipped SHA -------------
  #
  # DevOps v2 Phase 3, Slice 1. After push_frozen_main advances `main`, it also
  # fast-forwards this repo's persistent `accepted` integration branch onto the
  # same frozen SHA — retiring the manual `git push origin
  # origin/main:refs/heads/accepted` the conductor ran by hand after every ship.
  # Guarded (only where accepted exists), fail-closed (no --force), NON-FATAL (a
  # failed advance never aborts a live ship). These are the proofs on a REAL git
  # fixture.

  # [integration] The core acceptance: with an origin/accepted present, it advances
  # to the shipped SHA alongside main. accepted starts BEHIND at the base commit, so
  # reaching the frozen SHA proves the advance actually pushed.
  def test_push_frozen_main_advances_origin_accepted_when_it_exists
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # accepted exists on origin, sitting BEHIND at the base commit.
      run_git(clone, "push", "-q", "origin", "main:accepted")

      # The frozen SHA is one commit ahead — a real fast-forward for BOTH main and
      # accepted, so reaching it proves the ref push happened.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", out
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "origin/main must reach the frozen SHA"
      assert_equal frozen, git_out(origin, "rev-parse", "accepted"),
                   "origin/accepted must be re-baselined onto the shipped SHA"
      refute_equal base, git_out(origin, "rev-parse", "accepted"),
                   "accepted must have actually advanced off its stale base"
    end
  end

  # [integration] GUARDED. A repo with no origin/accepted (rolio/turf pre-Phase-5)
  # is a clean no-op — main advances, and NO accepted branch is conjured into being.
  def test_push_frozen_main_is_a_clean_noop_on_accepted_when_the_branch_is_absent
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      frozen = git_out(clone, "rev-parse", "release")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", out
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "main still advances for a repo with no accepted branch"
      _, status = Open3.capture2e("git", "-C", origin, "rev-parse", "--verify", "--quiet", "refs/heads/accepted")
      refute status.success?, "no accepted branch may be created for a repo that had none"
    end
  end

  # [integration] NON-FATAL + FAIL-CLOSED. A DIVERGED accepted (a commit the frozen
  # SHA cannot fast-forward onto) must NOT abort the ship and must NOT be force-
  # rewound: main still advances, the warning names the refusal, and accepted is
  # left exactly as it was — the same best-effort contract as the merged:main stamp.
  def test_push_frozen_main_accepted_advance_is_non_fatal_and_never_forces
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # The frozen SHA: one commit ahead of base on release.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # accepted has DIVERGED off base on its own line — the frozen SHA cannot
      # fast-forward onto it, so the advance must refuse rather than --force.
      run_git(clone, "checkout", "-q", "-b", "accepted-work", base)
      File.write(File.join(clone, "hotfix.txt"), "pushed straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted-work:accepted")
      diverged = git_out(origin, "rev-parse", "accepted")

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "a diverged accepted must NOT abort the ship: #{out}"
      refute_includes out, "ABORTED", "the accepted advance is non-fatal — it never aborts the deploy"
      assert_includes out, "NOT forcing", "the warning must say it refused to force accepted"
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "main still advances to the frozen SHA — the accepted failure doesn't block the deploy"
      assert_equal diverged, git_out(origin, "rev-parse", "accepted"),
                   "a diverged accepted must be left EXACTLY as it was — never force-rewound"
    end
  end

  # [integration] REGRESSION (rel-20260720-1fc111): accepted AHEAD, not diverged.
  #
  # A review pass merged two PRs into accepted WHILE the ship ran — a lane the
  # pipeline explicitly supports. The advance correctly refused the non-ff, then
  # mislabelled it "DIVERGED" and suggested `git push origin <sha>:refs/heads/accepted`.
  # Running that would have DESTROYED both merges. accepted was missing NOTHING.
  #
  # The fixture reproduces the exact topology that defeats a naive ancestor check:
  # the sweep merges accepted INTO release (--no-ff), so the frozen main is a MERGE
  # COMMIT whose tree equals the accepted head it came from — and that merge commit
  # is never in accepted's history. `merge-base --is-ancestor` is FALSE here (the
  # test asserts it) even though every byte of main is already in accepted.
  def test_push_frozen_main_reports_accepted_ahead_and_suggests_nothing
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # accepted carries the work that is about to ship.
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "work that ships")
      run_git(clone, "push", "-q", "origin", "accepted")
      absorbed = git_out(clone, "rev-parse", "accepted")

      # The sweep: accepted merged INTO release with --no-ff → a merge commit whose
      # TREE equals accepted's, but which accepted's own history never contains.
      run_git(clone, "checkout", "-q", "release")
      run_git(clone, "merge", "-q", "--no-ff", "-m", "sweep: accepted → release", "accepted")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")
      assert_equal git_out(clone, "rev-parse", "#{absorbed}^{tree}"),
                   git_out(clone, "rev-parse", "#{frozen}^{tree}"),
                   "fixture precondition: the sweep merge's tree equals the accepted head it came from"

      # Concurrent review merges land on accepted DURING the ship — one brand-new
      # file and one MODIFICATION of an already-shipped file (the real incident had
      # both: a new module plus an index entry). CRUCIALLY they arrive from a SEPARATE
      # clone, as a review pass on another machine does, so the ship's own clone never
      # fetches them and its origin/accepted stays STALE at `absorbed`. A same-clone
      # push (rounds 1-3) freshened that ref in a way production never does and hid a
      # missing fetch in the classifier — the round-4 gap that printed "AHEAD by 0
      # commits" against a truth of 13.
      ahead = land_concurrent_merge_on_accepted(dir, origin, label: "ahead",
                                                files: { "zap-protocol.md" => "merged mid-ship",
                                                         "shipped.rb" => "shipped\nindex entry added mid-ship" })

      # The staleness, pinned as the fixture precondition: the ship's clone still
      # sees the PRE-merge accepted, while the true origin has moved ahead of it.
      assert_equal absorbed, git_out(clone, "rev-parse", "origin/accepted"),
                   "fixture precondition: the ship's clone must have a STALE origin/accepted (it never fetched the concurrent merge)"
      refute_equal absorbed, ahead,
                   "fixture precondition: the TRUE origin/accepted moved ahead of what the ship's clone last saw"

      # The subtlety, pinned: plain ancestry says NO even though nothing is missing.
      _, ancestry = Open3.capture2e("git", "-C", clone, "merge-base", "--is-ancestor", frozen, ahead)
      refute ancestry.success?,
             "fixture precondition: the sweep merge commit is NOT an ancestor of accepted"

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "an accepted that is merely ahead must NOT abort the ship: #{out}"
      # THE ROUND-4 LOCK: the count must reflect the TRUE accepted, which the ship can
      # only see if it FETCHES first. Against the stale ref this reads "0 commits"
      # while claiming work merged concurrently — self-contradictory. Only the fetch
      # makes it honest.
      assert_match(/AHEAD of main by 1 commit\b/, out,
                   "the report must name the AHEAD relation and the TRUE commit count (needs a fetch): #{out}")
      refute_match(/DIVERGED|missing shipped content/, out,
                   "accepted is ahead, not diverged — no missing-content alarm may appear: #{out}")
      refute_includes out, "refs/heads/accepted",
                       "NOTHING may be suggested when accepted is ahead — a bare ref push here DESTROYS merged work"
      refute_includes out, "reconcile",
                       "an ahead accepted needs no reconciliation at all: #{out}"
      assert_equal frozen, git_out(origin, "rev-parse", "main"),
                   "main still advances to the frozen SHA"
      assert_equal ahead, git_out(origin, "rev-parse", "accepted"),
                   "the concurrently-merged work on accepted must be left EXACTLY as it was"
    end
  end

  # [integration] REGRESSION (rel-20260720-1fc111), the OTHER shape: accepted is
  # GENUINELY missing shipped content. The report must still say so — but must
  # suggest a MERGE of main into accepted, never a bare ref push, which would
  # discard whatever accepted holds that main does not.
  def test_push_frozen_main_advises_a_merge_when_accepted_is_genuinely_missing_shipped_content
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # The frozen SHA carries content that never reached accepted.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # accepted went its own way off base and never absorbed the shipped file.
      run_git(clone, "checkout", "-q", "-b", "accepted-work", base)
      File.write(File.join(clone, "hotfix.txt"), "pushed straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted-work:accepted")
      diverged = git_out(origin, "rev-parse", "accepted")

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "a genuinely diverged accepted must NOT abort the ship: #{out}"
      assert_includes out, "appears to be missing shipped content",
                      "genuine divergence must be reported as missing shipped content: #{out}"
      assert_match(/git -C .* merge/, out,
                   "the reconcile advice must be a MERGE of main into accepted: #{out}")
      refute_match(/push origin \h+:refs\/heads\/accepted/, out,
                   "a bare ref push must NEVER be suggested — it discards accepted's own commits: #{out}")
      assert_equal diverged, git_out(origin, "rev-parse", "accepted"),
                   "a diverged accepted must be left EXACTLY as it was"
    end
  end

  # The reconcile command the ship PRINTS, pulled back out of its own output and
  # run for real. Advice that has never been executed is a guess; these tests
  # execute it. Returns [ok, combined_output].
  # The happy-path steps the ship PRINTS, in order. Deliberately NOT an && chain
  # any more (round 3): a chain implies all-or-nothing, and this procedure has a
  # branch in the middle. Indented six spaces and starting with `git -C`; the
  # FINISH IT / BAIL OUT lines start with their label, so they do not match.
  def printed_reconcile_steps(out)
    steps = out.scan(/^ {6}(git -C \S.*)$/).flatten
    flunk("no reconcile steps found in output: #{out}") if steps.empty?

    steps
  end

  # Run the printed steps IN ORDER, stopping at the first failure — exactly what an
  # operator following the recipe top to bottom experiences. Returns
  # [ok, output, failed_step].
  def run_printed_reconcile(out)
    printed_reconcile_steps(out).each do |step|
      result, status = Open3.capture2e("bash", "-c", step)
      return [false, result, step] unless status.success?
    end
    [true, "", nil]
  end

  # The two labeled exits from a conflicted merge.
  def printed_finish_command(out) = out[/FINISH IT — .*?then: (git -C .+)$/, 1]
  def printed_bailout_command(out) = out[/BAIL OUT — .*?residue: (git -C .+)$/, 1]

  # The accepted-advance stubs: the repo under test, plus a per-test scratch path.
  # PRODUCTION uses a fixed /tmp path (predictable for the operator, and its own
  # BAIL OUT command clears a leftover); tests must not share one, or two parallel
  # CI workers would race for the same worktree directory.
  def advance_setup(clone, dir)
    %(def repo_path(_repo) = #{clone.inspect}\n) +
      %(def reconcile_scratch_path(_repo) = #{File.join(dir, 'scratch-reconcile').inspect}\n)
  end

  # Land a commit on origin/accepted from a SEPARATE clone — the way a concurrent
  # review merge arrives in production (another agent, another machine). The point
  # is what it does NOT do: the ship's own `clone` never fetches it, so that clone's
  # origin/accepted remote-tracking ref stays STALE. A same-clone push would freshen
  # that ref in a way production never does, and hide a missing fetch in the
  # classifier — the round-4 gap that printed "AHEAD by 0 commits" against a truth of
  # 13. Returns the true origin/accepted SHA after the push.
  def land_concurrent_merge_on_accepted(dir, origin, label:, files:)
    side = File.join(dir, "concurrent-#{label}")
    system("git", "clone", "-q", origin, side, out: File::NULL, err: File::NULL) || flunk("concurrent clone failed")
    run_git(side, "checkout", "-q", "accepted")
    files.each { |name, content| File.write(File.join(side, name), content) }
    run_git(side, "add", *files.keys)
    run_git(side, "commit", "-q", "-m", "review merge during the ship (#{label})")
    run_git(side, "push", "-q", "origin", "accepted")
    git_out(origin, "rev-parse", "accepted")
  end

  # [integration] BLOCKER (round 2). The DIVERGED reconcile advice must WORK on a
  # real primary — one that already has a STALE LOCAL `accepted` branch.
  #
  # The round-1 advice (`fetch && checkout accepted && merge origin/main && push
  # origin accepted`) failed exactly there, and NOT for want of a fetch: `git fetch`
  # moves the remote-tracking ref origin/accepted, but `git checkout accepted` lands
  # on the LOCAL branch, which the fetch never touches. The hub primary carries that
  # stale local ref (measured 45 commits behind), so the merge lands on a stale base
  # and the push is refused non-fast-forward. It only ever worked on a checkout with
  # NO local accepted, where `checkout accepted` DWIMs off the remote — which is why
  # it passed round-1 testing and would have failed the operator under ship pressure.
  #
  # This pins the stale-local case by RUNNING the printed command end to end.
  def test_printed_reconcile_command_works_against_a_stale_local_accepted_branch
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # The frozen SHA carries content accepted never absorbed.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # accepted diverges on its own line, and the checkout keeps a LOCAL accepted
      # pinned at that first commit — the operator's primary, exactly.
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "hotfix.txt"), "straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted")
      stale_local = git_out(clone, "rev-parse", "accepted")

      # origin/accepted then moves on WITHOUT the local ref following it.
      second = File.join(dir, "second")
      system("git", "clone", "-q", origin, second, out: File::NULL, err: File::NULL) || flunk("second clone failed")
      run_git(second, "checkout", "-q", "accepted")
      File.write(File.join(second, "review-merge.md"), "merged by review")
      run_git(second, "add", "review-merge.md")
      run_git(second, "commit", "-q", "-m", "review merge")
      run_git(second, "push", "-q", "origin", "accepted")
      run_git(clone, "fetch", "-q", "origin")
      run_git(clone, "checkout", "-q", "main")

      assert_equal stale_local, git_out(clone, "rev-parse", "accepted"),
                   "fixture precondition: the LOCAL accepted stayed put across the fetch"
      refute_equal stale_local, git_out(clone, "rev-parse", "origin/accepted"),
                   "fixture precondition: origin/accepted moved ahead of the stale local ref"

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "appears to be missing shipped content", "this fixture is a genuine divergence: #{out}"
      assert_match(/worktree add --detach \S+ origin\/accepted/, out,
                   "the merge must be based on the REMOTE-TRACKING ref, never the stale local branch: #{out}")

      ok, result, failed = run_printed_reconcile(out)
      assert ok, "the printed reconcile must SUCCEED on a stale local accepted (failed at #{failed}): #{result}"

      # The proof: origin/accepted actually moved, and holds BOTH sides.
      reconciled = git_out(origin, "rev-parse", "accepted")
      refute_equal stale_local, reconciled, "origin/accepted must actually advance"
      %w[shipped.rb hotfix.txt review-merge.md].each do |file|
        _, present = Open3.capture2e("git", "-C", origin, "cat-file", "-e", "accepted:#{file}")
        assert present.success?, "#{file} must survive the reconcile — nothing may be discarded"
      end
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the recovery must leave the primary back on main, not stranded on a reconcile branch"
    end
  end

  # [integration] The post-#588 GEM-CARRYING RELEASE. bump_consumer_locks_for_qa
  # commits consumer lockfile bumps onto `release` during prepare, so the frozen
  # tree legitimately differs from accepted's head tree — tree absorption is truly
  # REFUTED and the refusal lands on :diverged. That verdict is CORRECT (accepted
  # really is missing the lock bump), and #588 makes it the common path, so the
  # advice it prints has to work here too.
  def test_gem_carrying_release_reports_diverged_truthfully_with_working_advice
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")
      base   = git_out(clone, "rev-parse", "main")

      # accepted carries the work that ships.
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "work that ships")
      run_git(clone, "push", "-q", "origin", "accepted")

      # The sweep merges accepted into release...
      run_git(clone, "checkout", "-q", "release")
      run_git(clone, "merge", "-q", "--no-ff", "-m", "sweep: accepted → release", "accepted")
      # ...and then #588's prepare commits the consumer lock bump ON TOP, on release
      # only. From here the frozen tree can never equal any accepted tree.
      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.4.2)")
      run_git(clone, "add", "Gemfile.lock")
      run_git(clone, "commit", "-q", "-m", "bump consumer lock for QA")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      # A concurrent review merge lands on accepted from a SEPARATE clone, so the
      # advance is refused — and the ship's clone keeps a STALE origin/accepted, as
      # in production. (Round-4 sweep: this fixture pushed the concurrent merge from
      # the SAME clone, freshening the ref and masking the missing fetch.)
      run_git(clone, "checkout", "-q", "main")
      land_concurrent_merge_on_accepted(dir, origin, label: "gem",
                                        files: { "review-merge.md" => "merged by review" })

      refute_equal git_out(origin, "rev-parse", "#{frozen}^{tree}"),
                   git_out(origin, "rev-parse", "accepted^{tree}"),
                   "fixture precondition: the lock bump makes the frozen tree differ from the TRUE accepted's"

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "a gem-carrying release must not abort the ship: #{out}"
      assert_includes out, "appears to be missing shipped content",
                      "accepted genuinely lacks the lock bump — the missing-content verdict is TRUE here: #{out}"
      refute_includes out, "UNDETERMINED",
                      "the signals are readable — a true refutation is not an unknown: #{out}"

      ok, result, failed = run_printed_reconcile(out)
      assert ok, "the printed reconcile must work on the shape #588 made common (failed at #{failed}): #{result}"
      %w[shipped.rb Gemfile.lock review-merge.md].each do |file|
        _, present = Open3.capture2e("git", "-C", origin, "cat-file", "-e", "accepted:#{file}")
        assert present.success?, "#{file} must survive the reconcile — the lock bump is the point"
      end
    end
  end

  # [integration] BLOCKER (round 3). THE FAILING PATH. Every advice test before this
  # one executed the recipe against a fixture that merges CLEANLY — they prove the
  # advice works for shapes we already imagined. The invariant is stronger: the
  # printed advice must never STRAND the operator, for ANY merge outcome.
  #
  # This is not a corner. This PR's own docs declare :diverged the ROUTINE outcome on
  # a gem-carrying release, and the mechanism is a Gemfile.lock bump — the file most
  # likely to have been touched on accepted too. The routine path IS the conflict
  # path. The round-2 recipe was an && chain, so `git merge` exiting non-zero halted
  # it: no push, no `checkout main`, operator left on an unfamiliar branch mid-
  # conflict with a DIRTY primary — which on a gem repo also aborts the NEXT ship.
  #
  # So this asserts the operator is TOLD WHAT TO DO and left RECOVERABLE, not that
  # the chain succeeds. Both sides genuinely touch the same line of Gemfile.lock.
  def test_printed_reconcile_fails_safe_and_instructs_when_the_merge_conflicts
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      origin = File.join(dir, "origin.git")

      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.4.0)\n")
      run_git(clone, "add", "Gemfile.lock")
      run_git(clone, "commit", "-q", "-m", "lock 0.4.0")
      run_git(clone, "push", "-q", "origin", "main")
      # release must DESCEND from main, or the frozen SHA is not a fast-forward of it.
      run_git(clone, "branch", "-f", "release", "main")
      run_git(clone, "push", "-q", "-f", "origin", "release")
      base = git_out(clone, "rev-parse", "main")

      # accepted bumps the lock one way (a feature branch merged there)...
      run_git(clone, "checkout", "-q", "-b", "accepted", base)
      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.4.1)\n")
      run_git(clone, "add", "Gemfile.lock")
      run_git(clone, "commit", "-q", "-m", "accepted: lock 0.4.1")
      run_git(clone, "push", "-q", "origin", "accepted")
      accepted_head = git_out(origin, "rev-parse", "accepted")

      # ...and #588's prepare bumps the SAME line another way on the shipped side.
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "Gemfile.lock"), "studio-engine (0.5.0)\n")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "prepare: bump consumer lock for QA")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")
      run_git(clone, "checkout", "-q", "main")

      out = run_cli(["--yes"], setup: advance_setup(clone, dir),
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "a conflicting reconcile must not abort the ship: #{out}"

      # The recipe is NOT an && chain any more — a chain implies all-or-nothing.
      refute_match(/^ {6}git -C \S+ fetch origin &&/, out,
                   "the recipe must not be a single && chain: a conflict halts it silently: #{out}")

      # Follow it top to bottom, as an operator would. It STOPS at the merge...
      ok, result, failed = run_printed_reconcile(out)
      refute ok, "fixture precondition: this merge must genuinely conflict"
      assert_match(/merge origin\/main/, failed, "it must stop at the MERGE step, not earlier: #{failed}")
      assert_match(/CONFLICT|Automatic merge failed/, result, "the operator must see the conflict named: #{result}")

      # ...and THAT IS SAFE, which is the whole point. The primary never moved.
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary must still be on main — never stranded on a reconcile branch"
      assert_empty git_out(clone, "status", "--porcelain"),
                   "the primary must still be CLEAN — a dirty gem primary ABORTS the next ship"
      assert_equal accepted_head, git_out(origin, "rev-parse", "accepted"),
                   "origin/accepted must be untouched — no half-finished reconcile"

      # The operator is TOLD WHAT TO DO, both ways, rather than left to invent it.
      assert_match(/IF THE MERGE CONFLICTS/, out, "the conflict case must be named up front: #{out}")
      finish = printed_finish_command(out)
      bailout = printed_bailout_command(out)
      assert finish,  "a FINISH IT instruction must be printed: #{out}"
      assert bailout, "a BAIL OUT instruction must be printed: #{out}"

      # BAIL OUT genuinely restores a clean machine.
      _, bail_status = Open3.capture2e("bash", "-c", bailout)
      assert bail_status.success?, "the printed BAIL OUT must succeed"
      assert_empty git_out(clone, "status", "--porcelain"), "bailing out must leave the primary clean"
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"), "bailing out must leave main checked out"
      refute_match(/reconcile/, git_out(clone, "worktree", "list"),
                   "bailing out must leave NO worktree residue behind")

      # And FINISH IT genuinely completes the reconcile after a resolution.
      _, status = Open3.capture2e("bash", "-c", printed_reconcile_steps(out)[1])
      assert status.success?, "re-creating the scratch worktree must succeed after a bail out"
      scratch = File.join(dir, "scratch-reconcile")
      Open3.capture2e("bash", "-c", printed_reconcile_steps(out)[2])
      File.write(File.join(scratch, "Gemfile.lock"), "studio-engine (0.5.0)\n")
      _, finish_status = Open3.capture2e("bash", "-c", finish)
      assert finish_status.success?, "the printed FINISH IT must complete the reconcile after a resolution"

      %w[shipped.rb Gemfile.lock].each do |file|
        _, present = Open3.capture2e("git", "-C", origin, "cat-file", "-e", "accepted:#{file}")
        assert present.success?, "#{file} must be on accepted after finishing the reconcile"
      end
      assert_equal "main", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "finishing the reconcile must also leave the primary on main"
      assert_empty git_out(clone, "status", "--porcelain"), "finishing must leave the primary clean"
    end
  end

  # [integration] ABSENCE of signal is not a NEGATIVE signal. When the git reads
  # cannot resolve the relation, the ship must say UNDETERMINED and tell the
  # operator to check — never assert a confident DIVERGED it cannot support. This
  # is the same shape as the original defect, one layer down.
  def test_unreadable_relation_reports_undetermined_rather_than_guessing_diverged
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      base   = git_out(clone, "rev-parse", "main")

      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "shipped.rb"), "shipped")
      run_git(clone, "add", "shipped.rb")
      run_git(clone, "commit", "-q", "-m", "shipped")
      run_git(clone, "push", "-q", "origin", "release")
      frozen = git_out(clone, "rev-parse", "release")

      run_git(clone, "checkout", "-q", "-b", "accepted-work", base)
      File.write(File.join(clone, "hotfix.txt"), "straight to accepted")
      run_git(clone, "add", "hotfix.txt")
      run_git(clone, "commit", "-q", "-m", "diverged accepted")
      run_git(clone, "push", "-q", "origin", "accepted-work:accepted")

      # The relation becomes UNREADABLE: the remote-tracking ref will not resolve.
      setup = %(def repo_path(_repo) = #{clone.inspect}\n) +
              %(def rev_parse_ok?(_path, ref) = !ref.to_s.include?("origin/accepted")\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{push_frozen_main("sibling", #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "an unreadable relation must NOT abort the ship: #{out}"
      assert_includes out, "UNDETERMINED", "an unreadable relation must be reported as such: #{out}"
      refute_match(/appears to be missing shipped content/, out,
                   "an unreadable state must never be asserted as genuine divergence: #{out}")
      refute_includes out, "AHEAD of main",
                      "nor may it claim accepted is ahead — the point is that we do not know: #{out}"
      refute_match(/push origin \h+:refs\/heads\/accepted/, out,
                   "no bare ref push, in any state: #{out}")
    end
  end

  # [unit] The ship gate now mutates NOTHING. It used to fast-forward each app's
  # `main` in the primary (under the primary lock) before running the suite — but
  # the suite moved to the isolated gate workspace at the frozen SHA, so that ff fed
  # nothing and only flipped a shared checkout. With it gone, a red gate or a
  # declined ship-authority confirm leaves the machine exactly as it found it.
  def test_run_ship_gate_mutates_nothing_before_ship_authority
    Dir.mktmpdir do |dir|
      setup = %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def app_meta_for(_repo) = { "test_cmd" => "bin/ship-suite" }
        def with_primary_checkout(repo, wait: true)
          $stdout.puts("PRIMARY-LOCK-TAKEN #{repo}")
          yield
        end
        def sh(*a, **k)
          # Writes to the PRIMARY are what must not happen. The gate workspace's own
          # git (worktree/reset/clean, keyed on a[3]) is answered by gate_git below.
          $stdout.puts("PRIMARY-WRITE #{a[3]}") if a[0] == "git" && %w[checkout pull merge push].include?(a[3].to_s)
          $stdout.puts("SUITE") if a[0] == "bin/ship-suite"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{run_ship_gate([{ "repo" => "x" }], { "x" => #{GATE_SHA.inspect} }, {}); puts("PASSED")})

      # DevOps v2 Phase 3: the gate READS GitHub CI's verdict for the frozen SHA — the
      # local suite is demoted — but the invariant this test pins is unchanged: the gate
      # mutates NOTHING (no primary lock, no primary writes) before ship authority.
      assert_includes out, "GitHub CI verdict for frozen", "the gate reads the CI verdict on the frozen SHA: #{out}"
      refute_includes out, "SUITE", "the demoted local suite must NOT run — CI is the verdict"
      refute_includes out, "PRIMARY-LOCK-TAKEN",
                      "the gate has nothing to serialize against the primary any more — it must not take its lock"
      refute_includes out, "PRIMARY-WRITE",
                      "no checkout/pull/merge/push before ship authority — a declined confirm must change nothing"
      assert_includes out, "PASSED"
    end
  end

  # --- G4 self-gating: the ship gate skips ONLY on G3's OWN recorded verdict -----
  #
  # REGRESSION (the DISARM bug this change closes): the old skip predicate compared
  # the REGISTRY (test_cmd == qa_test_cmd) and the frozen SHA against
  # release.metadata["qa_shas"] — but qa_shas is stamped by the QA DEPLOY LOOP, not
  # by the gate. So a G3 that never ran (no qa_test_cmd registered), or that was
  # misconfigured, still produced a matching pair — and G4 SILENTLY SKIPPED the last
  # suite before an irreversible prod deploy. The ONLY evidence that may disarm G4
  # is now G3's own recorded verdict: release.metadata["qa_gates"][repo] =
  # {sha, cmd, ok: true}. Anything else FAILS OPEN (the suite runs).
  #
  # The pure predicate is unit-tested in Release::ShipSequence.ship_gate_skip?; this
  # is the WIRING — that test_gate consults it with the RIGHT record and honours
  # both verdicts.

  # The G4 skip matrix, driven through the real test_gate. Each case names the
  # qa_gates record present on the release when the ship gate runs.
  SHIP_GATE_SKIP_CASES = {
    "a matching green record" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true }, :skip],
    "no record at all (G3 never ran / was skipped)" =>
      [nil, :run],
    "a record for a DIFFERENT sha (a straggler / re-pinned RC)" =>
      [{ "sha" => "0" * 40, "cmd" => "bin/suite", "ok" => true }, :run],
    "a record for a DIFFERENT command (G3 certified a narrower tier)" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/rails test test/integration", "ok" => true }, :run],
    "a RED record (the gate ran and failed)" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => false }, :run],
    # The AUDITOR arms this gate (fail-open only). A green G3 whose CI cross-check
    # went RED for the SAME SHA is a certification GitHub CONTRADICTS: without this
    # the skip fired (frozen SHA == certified SHA) and G3's alarm was the ONLY thing
    # between a CI-red commit and prod — while the alarm claimed G4 would re-gate it.
    "a green record whose AUDITOR (GitHub CI) called that SHA red" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true,
         "ci" => { "state" => "red", "checks" => ["test:system"] } }, :run],
    # …and NO-DATA never arms it: silence is not a red, or every ship would pay for
    # a verdict nobody gave.
    "a green record whose auditor had NO DATA (no CI run for the SHA)" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true, "ci" => { "state" => "none" } }, :skip],
    "a green record whose auditor was still PENDING" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true, "ci" => { "state" => "pending" } }, :skip],
    "a green record whose auditor AGREED (CI green)" =>
      [{ "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true,
         "ci" => { "state" => "green", "count" => 4 } }, :skip]
  }.freeze

  # [unit] test_gate SKIPS only against a matching GREEN G3 record; in every other case
  # — absent, red, different SHA, different command — it RE-DERIVES the verdict from
  # GitHub CI on the frozen SHA (green injected here so a re-gate passes) instead of the
  # demoted local suite. The skip/run decision is UNCHANGED (ship_gate_skip?); what a
  # "run" means is now a CI read, not a suite run — so the local suite NEVER executes.
  def test_ship_test_gate_skips_only_against_a_matching_green_g3_record
    Dir.mktmpdir do |dir|
      SHIP_GATE_SKIP_CASES.each do |label, (record, expected)|
        setup = %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
                %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
          def app_meta_for(_repo) = { "test_cmd" => "bin/suite" }
          def sh(*a, **k)
            $stdout.puts("SUITE-RAN") if a[0] == "bin/suite"
            g = gate_git(a, k)
            return g if g
            ["", true]
          end
        RUBY
        out = run_cli(["--yes"], setup: setup,
                      call: %{test_gate("x", frozen_sha: #{GATE_SHA.inspect}, qa_gate: #{record.inspect}); puts("PASSED")})

        if expected == :skip
          assert_includes out, "already CERTIFIED green", "#{label}: the skip is a VISIBLE SOP, never silent"
          refute_includes out, "GitHub CI verdict for frozen", "#{label}: a self-skip does not re-read CI"
        else
          assert_includes out, "GitHub CI verdict for frozen",
                          "#{label}: G4 must NOT self-skip — it re-derives the verdict from CI on the frozen SHA " \
                          "(a skip here disarms the last gate before an irreversible prod deploy)"
          refute_includes out, "already CERTIFIED green", "#{label}: a re-gate is not a skip"
        end
        refute_includes out, "SUITE-RAN", "#{label}: the demoted local suite NEVER runs — CI is the verdict"
        assert_includes out, "PASSED", "#{label}: green CI (injected) → the gate passes either way"
      end
    end
  end

  # [integration] A G3 record whose recorded auditor went RED is a certification GitHub
  # CONTRADICTS, so G4 does NOT self-skip on it — it RE-DERIVES the verdict from GitHub
  # CI on the frozen SHA (which, unlike the demoted local suite, CAN see every lane). In
  # Phase 3 a red G3 auditor aborts prepare, so this record is DEFENSIVE — a stale or
  # hand-built record must still be re-gated, never trusted.
  def test_ship_test_gate_re_derives_from_ci_when_the_recorded_auditor_is_red
    Dir.mktmpdir do |dir|
      setup = %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def app_meta_for(_repo) = { "test_cmd" => "bin/suite" }
        def sh(*a, **k)
          $stdout.puts("SUITE-RAN") if a[0] == "bin/suite"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      record = { "sha" => GATE_SHA, "cmd" => "bin/suite", "ok" => true,
                 "ci" => { "state" => "red", "checks" => ["test:system"] } }
      out = run_cli(["--yes"], setup: setup,
                    call: %{test_gate("x", frozen_sha: #{GATE_SHA.inspect}, qa_gate: #{record.inspect}); puts("PASSED")})

      assert_includes out, "GitHub CI called that SHA RED", "the ship NAMES why it distrusts the record"
      assert_includes out, "RE-DERIVES the verdict from", "…and re-reads CI rather than self-skipping on it"
      assert_includes out, "GitHub CI verdict for frozen", "the re-derivation reads CI on the frozen SHA"
      refute_includes out, "SUITE-RAN", "the local suite is demoted — the re-derivation is a CI read, not a suite run"
      assert_includes out, "PASSED", "the re-derived CI verdict here is green → the gate passes"
    end
  end

  # --- G4 ship gate: GitHub CI is the verdict on the FROZEN SHA (DevOps v2 Phase 3) ---
  #
  # With no matching green G3 record to self-skip on (a straggler, a re-pin, or plain
  # drift), test_gate re-derives the verdict from GitHub CI for the FROZEN ship SHA —
  # ci_pass?, fail-closed — instead of re-running the demoted local suite. qa_gate: nil
  # forces the non-skip path so these exercise the CI verdict directly.
  def ship_ci_gate_stub(dir, ci_status)
    %(ENV["RELEASE_CI_STATUS"] = #{ci_status.inspect}\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def app_meta_for(_repo) = { "test_cmd" => "bin/suite" }
        def sh(*a, **k)
          $stdout.puts("SUITE-RAN") if a[0] == "bin/suite"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
  end

  # [integration] GREEN CI on the frozen SHA PASSES the ship gate, records the CI
  # conclusion as the ship_test_gate SOP, and NEVER runs the local suite.
  def test_ship_test_gate_passes_and_records_on_a_green_ci_verdict
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ship_ci_gate_stub(dir, "green"),
                    call: %{$gate_sops = []; test_gate("x", frozen_sha: #{GATE_SHA.inspect}, qa_gate: nil); puts("SOPS " + $gate_sops.inspect); puts("PASSED")})

      assert_includes out, "GitHub CI verdict for frozen #{GATE_SHA[0, 7]}", "the gate reads CI for the frozen SHA"
      refute_includes out, "SUITE-RAN", "the local suite is demoted — a green CI ships without it"
      sops = out.lines.find { |l| l.start_with?("SOPS") }
      assert sops, "the CI conclusion must be recorded as the gate SOP: #{out}"
      assert_includes sops, %("sop"=>"ship_test_gate")
      assert_includes sops, %("result"=>"pass")
      assert_includes sops, "GitHub CI GREEN", "…naming the Tier-3 Actions conclusion"
      assert_includes out, "PASSED"
    end
  end

  # [integration] RED CI on the frozen SHA FAILS the ship gate CLOSED — a red frozen
  # commit must not reach the irreversible prod deploy — and records a RED SOP.
  def test_ship_test_gate_fails_closed_on_a_red_ci_verdict
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ship_ci_gate_stub(dir, "red"),
                    call: %{$gate_sops = []; begin; test_gate("x", frozen_sha: #{GATE_SHA.inspect}, qa_gate: nil); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end; puts("SOPS " + $gate_sops.inspect)})

      assert_includes out, "ABORTED", "a red frozen SHA must abort BEFORE the prod deploy"
      assert_includes out, "RED", "…naming CI's red verdict"
      assert_includes out, "must not ship"
      refute_includes out, "SUITE-RAN", "no local suite runs — CI is the verdict"
      sops = out.lines.find { |l| l.start_with?("SOPS") }
      assert_includes sops, %("result"=>"fail"), "the red gate is recorded as a failed SOP"
      refute_includes out, "PASSED"
    end
  end

  # [integration] NO GREEN VERDICT FAILS CLOSED at G4 too: a pending/no-data verdict for
  # the frozen SHA (e.g. a just-pushed re-pin whose CI has not concluded) HOLDS the ship,
  # points at the --skip-test-gate override, and never reads as a pass.
  def test_ship_test_gate_fails_closed_on_a_pending_or_no_data_verdict
    %w[pending none unverified unreadable].each do |state|
      Dir.mktmpdir do |dir|
        out = run_cli(["--yes"], setup: ship_ci_gate_stub(dir, state),
                      call: %{begin; test_gate("x", frozen_sha: #{GATE_SHA.inspect}, qa_gate: nil); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

        assert_includes out, "ABORTED", "#{state}: an absent/unknown CI verdict must fail the ship gate closed"
        assert_includes out, "NO green verdict for frozen", "#{state}: names what it could not certify"
        assert_includes out, "FAILS CLOSED", "#{state}: says why it held"
        assert_includes out, "--skip-test-gate", "#{state}: points at the first-class override"
        refute_includes out, "SUITE-RAN", "#{state}: no local suite runs"
        refute_includes out, "PASSED"
      end
    end
  end

  # --- `ship --skip-test-gate`: the operator's FIRST-CLASS escape hatch ---------
  #
  # The old way to ship past a gate the operator believed was a false negative was to
  # BLANK the registry's test_cmd — which SILENTLY DISARMED the gate and left a record
  # reading "self-gates (no conductor test_cmd)". That trick is now closed (G4 skips
  # only on G3's own recorded verdict), and closing it WITHOUT a replacement would
  # wedge the operator: a G4 false negative with no clean override, and a config edit
  # is not one (ship's preflight refuses a dirty primary). So the override is
  # first-class — it DEMANDS a reason, it ASKS before it skips, and it records a RED
  # gate SOP. A skipped gate is now visible in the release record forever.

  # The ship-gate stub for the escape-hatch cases: the suite and the whole workspace
  # dance are marked, so a test can prove the skip ran NOTHING.
  SKIP_GATE_STUB = GATE_GIT_STUB + <<~'RUBY'
    def app_meta_for(_repo) = { "test_cmd" => "bin/suite" }
    def sh(*a, **k)
      $stdout.puts("SUITE") if a[0] == "bin/suite"
      $stdout.puts("WORKSPACE #{a[3]}") if a[0] == "git"
      $stdout.puts("DB-PREPARE") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
      g = gate_git(a, k)
      return g if g
      ["", true]
    end
  RUBY

  # [unit] No `--reason` → hard abort, and the suite is neither run NOR skipped. The
  # reason is the whole record: it is what a reader of the release sees next to a gate
  # that never ran, so an unexplained skip may not exist.
  def test_skip_test_gate_demands_a_reason
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + SKIP_GATE_STUB
      out = run_cli(["--yes", "--skip-test-gate"], setup: setup,
                    call: %{begin; test_gate("x", frozen_sha: #{GATE_SHA.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "an unexplained skip must not ship"
      assert_includes out, "--skip-test-gate requires --reason"
      assert_includes out, "recorded on the release as a red gate", "…and says what the reason is FOR"
      refute_includes out, "SUITE", "the abort runs nothing"
      refute_includes out, "PASSED"
    end
  end

  # [unit] With a reason (and --yes standing in for the confirm), the gate SKIPS: it
  # runs no suite, it does not even PIN the workspace — and it records a RED
  # ship_test_gate SOP carrying the reason and naming the SHA that shipped
  # uncertified. RED, not green: a gate that did not run is not a gate that passed,
  # and the old registry-blanking trick left a record that read "already green".
  def test_skip_test_gate_with_a_reason_records_a_red_gate_sop_and_runs_no_suite
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + SKIP_GATE_STUB
      out = run_cli(["--yes", "--skip-test-gate", "--reason", "gate host postgres is down"], setup: setup,
                    call: %{$gate_sops = []; test_gate("x", frozen_sha: #{GATE_SHA.inspect}); puts("SOPS " + $gate_sops.inspect); puts("PASSED")})

      assert_includes out, "SKIPPED BY OPERATOR", "the skip is LOUD in the run's own output"
      assert_includes out, "gate host postgres is down", "…carrying the operator's reason"

      sops = out.lines.find { |l| l.start_with?("SOPS") }
      assert sops, "the skip must record a gate SOP: #{out}"
      assert_includes sops, %("sop"=>"ship_test_gate"), "recorded against the gate it skipped"
      assert_includes sops, %("result"=>"fail"),
                      "RED — a gate that did NOT run is not a green gate; this is the record the old " \
                      "registry-blanking trick never left"
      assert_includes sops, "SKIPPED BY OPERATOR (--skip-test-gate): gate host postgres is down"
      assert_includes sops, %(did NOT run on #{GATE_SHA[0, 7]}), "…naming the SHA that ships uncertified"

      refute_includes out, "SUITE", "the suite must NOT run — that is what was asked for"
      refute_includes out, "DB-PREPARE", "…and nothing prepares a workspace that will never be used"
      refute_includes out, "WORKSPACE", "…the gate returns before it even pins one"
      assert_includes out, "PASSED", "the ship rides on (the operator owns this call)"
    end
  end

  # --- eject: block-on-regression (detach + block ONE offender, keep the rest) ---

  def test_eject_records_the_conductor_eject_and_prints_the_revert_guidance
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "slug" => "rel-active", "state" => "assembling" }   # the active RC to claim
        else
          $stdout.puts("EJECT-CALL " + ruby.gsub("\n", " "))
          { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
        end
      end
      def conductor_claim(*a) = ReleaseClaimCli::OK
    RUBY
    out = run_cli(["task-bad", "--feedback", "integration regression on release"], call: "eject", setup: setup)

    eject = out.lines.find { |l| l.start_with?("EJECT-CALL") }
    assert_includes eject, "Release::Conductor.eject!", "the record side detaches + blocks via eject!"
    assert_includes eject, "integration regression on release", "the feedback threads into the qa_feedback note"
    assert_includes out, "task-bad → blocked (rework)"
    assert_includes out, "git revert -m 1", "the git unwind guidance is printed"
    assert_includes out, "bin/release prepare", "…ending at the self-healing re-run"
  end

  # --- eject (FIX b): the assembler claim SERIALIZES the membership detach ------
  # eject! MUTATES release-candidate membership (release_slug + `merged` cleared) — the
  # SAME assembler-lane write prepare/merge guard. A concurrent eject during a prepare
  # sweep would race that write, so eject takes the per-release `assembler` claim first.
  # These drive bin/release IN A SUBPROCESS with conductor_claim STUBBED, proving the
  # runtime effect the source-ordering wiring test can only assert structurally.

  # HELD claim → eject stands DOWN before the detach: the observable effect is that the
  # membership mutation (EJECT-CALL) NEVER runs — eject refuses rather than racing.
  def test_eject_stands_down_before_the_membership_detach_when_the_assembler_claim_is_held
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "slug" => "rel-active", "state" => "assembling" }    # the active RC the claim keys on
        else
          $stdout.puts("EJECT-CALL " + ruby.gsub("\n", " "))     # the membership mutation — must NOT run
          { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
        end
      end
      def conductor_claim(*a); $stdout.puts("CLAIM-CHECK " + a.join(" ")); ReleaseClaimCli::STOOD_DOWN; end
    RUBY
    out = run_cli(["task-bad"], setup: setup,
                  call: "begin; eject; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "CLAIM-CHECK acquire rel-active --role assembler",
                     "eject resolves the active release, then CONSULTS the per-release assembler claim BEFORE mutating membership"
    assert_includes out, "ABORTED", "a held assembler claim (STOOD_DOWN) stands eject down"
    assert_includes out, "held by another live release conductor", "and names the stand-down cause"
    refute_includes out, "NO-ABORT", "eject must not fall through past the claim gate"
    refute_includes out, "EJECT-CALL",
                     "the membership detach (Release::Conductor.eject!) must NOT run — eject serializes BEFORE the write, never racing a concurrent sweep"
  end

  # OK claim → eject holds the claim ACROSS the detach and releases it AFTER: the
  # observable effect is the write-ordering acquire(assembler) → detach → release.
  def test_eject_holds_the_assembler_claim_across_the_detach_then_releases_it
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "slug" => "rel-active", "state" => "assembling" }
        else
          $stdout.puts("DETACH")                                  # the membership mutation
          { "slug" => "task-bad", "stage" => "blocked", "merged" => nil }
        end
      end
      def conductor_claim(op, *a); $stdout.puts("CLAIM-#{op.upcase} " + a.join(" ")); ReleaseClaimCli::OK; end
    RUBY
    out = run_cli(["task-bad"], call: "eject", setup: setup)

    seq     = out.lines.map(&:strip).select { |l| l.start_with?("CLAIM-", "DETACH") }
    acquire = seq.index { |l| l.start_with?("CLAIM-ACQUIRE") }
    detach  = seq.index("DETACH")
    release = seq.index { |l| l.start_with?("CLAIM-RELEASE") }

    assert [acquire, detach, release].all?, "acquire, detach, and release must all occur: got #{seq.inspect}"
    assert_includes seq[acquire], "--role assembler", "the claim taken is the per-release ASSEMBLER lane"
    assert acquire < detach, "the assembler claim is ACQUIRED before the membership detach"
    assert detach < release, "and RELEASED only AFTER the detach — the claim is held ACROSS the whole membership write"
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

  # --- status / the clean-LADDER GUARD (`deploy-with-task`'s first step) ----
  # `status` gathers FOUR signals — a board read and a git read on EACH rung of
  # the `accepted → release → main` ladder (the board via `conductor`, both git
  # counts via `ladder_ahead_states`) — then Release::CleanCheck decides clean vs
  # dirty. All reads are stubbed here so the guard is exercised with no
  # Rails/DB/git. `--clean-only` turns a dirty verdict into a non-zero abort
  # (rescued in-band so run_ruby sees a clean exit).

  # Stub the board read + git seam. `pending` = tasks riding `release`, `ahead` =
  # per-repo release-ahead-of-main counts, `accepted` = tasks parked on
  # `accepted`, `accepted_ahead` = per-repo accepted-ahead-of-release counts
  # (defaults to a measured-and-level mcritchie-studio, the normal state).
  def status_stub(pending:, ahead:, accepted: [],
                  accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                  unreadable: [])
    <<~RUBY
      def conductor(ruby, read_only: false)
        { "pending" => #{pending.inspect}, "accepted" => #{accepted.inspect},
          "release" => { "slug" => "rel-cli", "state" => "assembling" } }
      end
      def ladder_ahead_states
        { "release" => #{ahead.inspect}, "accepted" => #{accepted_ahead.inspect},
          "unreadable" => #{unreadable.inspect} }
      end
    RUBY
  end

  def test_status_clean_ladder_reports_both_rungs_level
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]),
                  call: "status")

    assert_includes out, "release == main", "a clean ladder reports release == main"
    assert_includes out, "accepted == release", "…and the rung beneath it"
    assert_includes out, "safe to expedite one task"
    assert_includes out, "deploy-with-task", "the hint names the registered launcher phrase"
    refute_includes out, "refused", "a genuinely clean ladder is NOT refused — the lane stays usable"
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

  # --- the SILENT drop: a repo with no local checkout -----------------------
  #
  # `ladder_ahead_states(require_checkout: false)` — the ecosystem guard's DEFAULT
  # — skips a repo whose checkout is missing, recording no state row on either
  # rung and NO `unreadable` row. Completeness derived from those two lists alone
  # therefore could not see it: the sets AGREED, the read graded `:complete`, and
  # the guard asserted an INTERRUPTED SHIP — "this code may ALREADY BE IN
  # PRODUCTION" — over a ladder holding a repo it had never opened.
  #
  # These drive the REAL `ladder_ahead_states` (only the git `sh` and the checkout
  # path are stubbed), so they cover the WIRING — the scope the reader hands back
  # and the verdict measuring against it — not just the pure rule.
  def uncloned_repo_stub(clone_rolio: false)
    <<~RUBY
      REAL_REPO = #{self.class.stub_repo.inspect}
      CLONE_ROLIO = #{clone_rolio.inspect}
      def release_repo_slugs
        ["mcritchie-studio", "rolio"]
      end
      def repo_path(repo)
        return REAL_REPO if repo == "mcritchie-studio" || CLONE_ROLIO
        File.join(REAL_REPO, "definitely-not-cloned")
      end
      def conductor(ruby, read_only: false)
        { "pending" => [{ "slug" => "riding-release", "title" => "Swept, QA in flight" }],
          "accepted" => [], "release" => { "slug" => "rel-cli", "state" => "assembling" } }
      end
      def sh(*a, **k)
        # Every rung level: release == main AND accepted == release. Board-dirty
        # + git-clean is exactly the interrupted-ship shape.
        return ["0", true] if a[0] == "git" && a.include?("rev-list")
        ["", true]
      end
    RUBY
  end

  def test_status_withholds_the_production_claim_when_a_repo_has_no_checkout
    out = run_cli(["status"], setup: uncloned_repo_stub, call: "status")

    refute_includes out, "ALREADY BE IN PRODUCTION",
                    "rolio produced no reading — the guard must not speak for the whole ladder"
    assert_includes out, "NOT verified: rolio", "…and it must name the repo it never opened"
  end

  # DIRECTION 2 — the one people skip. With every repo readable the sentence must
  # STILL fire. A fix that merely suppressed the claim, or that keyed off the
  # presence of a scope rather than a gap in it, passes the test above and quietly
  # destroys the most consequential finding this guard can report.
  def test_status_still_reports_the_interrupted_ship_when_every_repo_is_read
    out = run_cli(["status"], setup: uncloned_repo_stub(clone_rolio: true), call: "status")

    assert_includes out, "ALREADY BE IN PRODUCTION", "a COMPLETE read keeps its explanation"
    refute_includes out, "NOT verified", "nothing went unread, so nothing is disclaimed"
  end

  # --- the ACCEPTED rung, end to end through the CLI -----------------------
  # The hole: `status` read only the tasks riding `release`, so a task sitting
  # `reviewed` with merged:"accepted" was invisible — and the sweep promotes ALL
  # of `accepted`, so it rode to production alongside an expedite with the guard
  # GREEN. These prove the CLI now aborts on that state, and (the other half)
  # that a genuinely clean ladder still exits 0.

  def test_status_clean_only_refuses_a_task_parked_on_accepted
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted: [{ "slug" => "parked-work", "title" => "Reviewed, not swept" }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 3 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "parked on `accepted`", "the guard now SEES the accepted rung"
    assert_includes out, "parked-work"
    assert_includes out, "full-cycle"
    assert_includes out, "ABORTED", "a task parked on `accepted` aborts the expedite"
    refute_includes out, "NO-ABORT", "the expedite must not fall through past the guard"
  end

  def test_status_clean_only_refuses_when_accepted_is_ahead_with_no_stamp
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 2 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "mcritchie-studio (+2)", "git is PRIMARY on this rung — a missing stamp cannot pass"
    assert_includes out, "DISAGREE", "the board/git disagreement is itself reported"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  def test_status_clean_only_does_not_refuse_on_the_expedited_task_itself
    out = run_cli(["status", "--clean-only", "--task", "my-expedite"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted: [{ "slug" => "my-expedite", "title" => "The one task" }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 4 }]),
                  call: "status; puts('NO-ABORT')")

    assert_includes out, "NO-ABORT", "re-running the act after review merged YOUR task must still pass"
    assert_includes out, "attributed to the expedited task `my-expedite`",
                    "the tolerated count is stated, never silently swallowed"
    refute_includes out, "refused"
  end

  def test_status_clean_only_refuses_a_second_task_landed_beside_the_expedite
    out = run_cli(["status", "--clean-only", "--task", "my-expedite"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     accepted: [{ "slug" => "my-expedite", "title" => "" },
                                                { "slug" => "autopilot-landed", "title" => "Merged mid-review" }],
                                     accepted_ahead: [{ "repo" => "mcritchie-studio", "ahead" => 6 }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "autopilot-landed", "the autopilot race is named"
    refute_includes out, "my-expedite —", "the operator's own task is not listed against them"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  def test_status_clean_only_refuses_an_unreadable_rung
    out = run_cli(["status", "--clean-only"],
                  setup: status_stub(pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
                                     unreadable: [{ "repo" => "turf-monster", "rung" => "accepted" }]),
                  call: "begin; status; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "could NOT be read", "a failed read is not a read that came back clean"
    assert_includes out, "turf-monster/accepted"
    assert_includes out, "ABORTED"
    refute_includes out, "NO-ABORT"
  end

  # --- ship --dry-run: multi-repo, producer-first, hub-before-satellites ---

  # A mixed release: a gem (producer) + two apps with DIFFERENT prod adapters,
  # plus per-repo QA-frozen SHAs. turf-monster is listed BEFORE mcritchie-studio
  # on purpose so the dry-run proves ship reorders the hub to the front.
  SHIP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "slug" => "rel-ship" } if ruby.include?("last_shipped") # the minimal STABLE read (pre-claim)
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

    # hub: git_push_heroku is now a REF PUSH of the frozen SHA (no checkout, no
    # local branch) — the dry-run must show what actually runs.
    assert_includes out, "push heroku bbbbbbb:refs/heads/main"
    assert_includes out, "https://mcritchie.studio/up"
    # satellite: repo_script runs the repo's own deploy; the repo owns smoke/rollback
    assert_includes out, "bin/deploy --yes"
    assert_includes out, "repo owns its smoke + rollback"
  end

  def test_ship_dry_run_test_cmd_gate_hub_only
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    # hub carries a conductor test_cmd; satellites self-gate (skip it).
    assert_includes out, HUB_GATE_CMD, "the hub runs its conductor test_cmd before prod"
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
    hub_at = out.index("push heroku bbbbbbb:refs/heads/main")  # hub DEPLOY (the test gate runs up front, in run_ship_gate)
    sat_at = out.index("bin/deploy --yes")  # satellite's deploy

    assert gem_at && hub_at && sat_at, "all three phases must appear"
    assert_operator gem_at, :<, hub_at, "gems publish before the hub deploys"
    assert_operator hub_at, :<, sat_at, "the hub deploys before the satellites"
  end

  # --- Steffon ship gate: full e2e on the FROZEN SHA, THEN ship authority (§1.2) ---

  def test_ship_runs_the_steffon_e2e_gate_before_ship_authority_and_any_deploy
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gate_at   = out.index("Steffon ship gate")
    e2e_at    = out.index(HUB_GATE_CMD)                # the hub's highest-tier run on the frozen SHA
    ship_at   = out.index("confirming production deploy") # the ship-authority step (unique marker)
    deploy_at = out.index("push heroku bbbbbbb:refs/heads/main")

    assert gate_at && e2e_at && ship_at && deploy_at, "gate, e2e, ship authority, and a deploy must all appear"
    assert_operator gate_at, :<, ship_at, "the Steffon gate precedes ship authority"
    assert_operator e2e_at, :<, ship_at, "the full suite runs on the frozen SHA BEFORE ship authority"
    assert_operator ship_at, :<, deploy_at, "ship authority precedes any deploy"
  end

  def test_ship_steffon_gate_reads_the_ci_verdict_for_the_frozen_sha
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)
    # DevOps v2 Phase 3: the gate reads GitHub CI's verdict for the frozen hub SHA
    # (the local suite is demoted); the plan still names that frozen SHA.
    assert_includes out, "Steffon ship gate"
    assert_includes out, "FROZEN ship SHA"
    assert_includes out, "bbbbbbb", "the gate is judged on the hub's QA-frozen SHA"
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
      return { "slug" => "rel-pub" } if ruby.include?("last_shipped") # the minimal STABLE read (pre-claim)
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
    def repo_git_state(repo, _path)
      { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
    end
    def with_ship_workspace(repo) = yield
    def ship_workspace!(repo, _sha) = "/tmp/_ship/\#{repo}"
    def publish_gem(repo, version) = $stdout.puts("PUBLISH-CALLED " + repo + " " + version)
    def push_frozen_main(_repo, _sha); end
    def restore_gem_primary(_repo); end
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

  # [integration] publish-gems-before-qa's ship half: prepare already published
  # 0.11.0 BEFORE QA, so ship's publish is the idempotent VERIFY — it skips the
  # push (RubyGems forbids a re-push) and the train still completes the gem's
  # release → main collapse.
  def test_ship_publish_is_an_idempotent_skip_after_prepare_already_published
    setup = PUBLISH_DECISION_STUB.sub(
      '[{ "number" => "0.10.0" }] # 0.10.0 LIVE, 0.11.0 not yet',
      '[{ "number" => "0.10.0" }, { "number" => "0.11.0" }] # prepare already published 0.11.0'
    )
    out = run_cli(["--yes"], call: "ship", setup: setup)

    assert_includes out, "studio-engine 0.11.0: LIVE on RubyGems — will skip", "the pre-flight sees it live"
    assert_includes out, "already live on RubyGems — skip publish", "ship verifies, never re-pushes"
    refute_includes out, "PUBLISH-CALLED", "no second publish of a version prepare already pushed"
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
      # The bin/triage stub is not optional decoration: --followup drives retro
      # into its filing block, and unstubbed that block shelled out to the REAL
      # bin/triage against the production board — this exact test filed 39 live
      # "fix flake" findings into the operator's inbox, one per suite run.
      _log, sh_stub = retro_sh_stub(dir)
      setup = %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{capture}; #{sh_stub})
      run_cli(["rel-retro", "--yes", "--worked", "fast review", "--friction", "flaky e2e", "--followup", "fix flake"],
              call: "retro", setup: setup)

      answers = decode_retro_payload(File.read(File.join(dir, "snippet.txt")))
      assert_includes answers["worked"], "fast review", "--worked rides into the render payload"
      assert_includes answers["friction"], "flaky e2e", "--friction rides into the render payload"
      assert_includes answers["followups"], "fix flake", "--followup rides into the render payload"
    end
  end

  # --- retro follow-up identity + idempotency --------------------------------
  # 38 of 84 open findings were byte-identical "fix flake" entries: the title was
  # the follow-up's first 8 words (so every short follow-up collapsed to the same
  # title) AND every run refiled every follow-up. Both halves are pinned here,
  # and BOTH DIRECTIONS are pinned — under-filing (a duplicate) is visible at
  # /triage, but over-suppression silently loses a real finding, so the
  # "two different follow-ups both file" tests matter most.

  # [unit] a follow-up too short to identify itself carries its release slug, so
  # two REAL occurrences from different releases stay distinguishable.
  def test_unit_a_vague_retro_followup_title_carries_its_release_slug
    a = eval_helper(%(retro_followup_title("fix flake", "rel-a")))
    b = eval_helper(%(retro_followup_title("fix flake", "rel-b")))

    assert_includes a, "fix flake", "the operator's words survive"
    assert_includes a, "rel-a", "a vague title carries the release that raised it"
    refute_equal a, b, "the same vague text from two releases must NOT collapse to one title"
  end

  # [unit] …and a follow-up that already identifies itself is left alone, so the
  # slug tag stays a repair for generic text rather than noise on every title.
  def test_unit_an_identifying_retro_followup_title_is_not_slug_tagged
    title = eval_helper(%(retro_followup_title("board filter test reddens on a racing 404", "rel-a")))

    refute_includes title, "rel-a", "a self-identifying follow-up needs no slug crutch"
    assert_equal "board filter test reddens on a racing 404", title
  end

  # [unit] a truncated title SAYS it is truncated — the old code silently handed
  # back a prefix that read like the whole finding.
  def test_unit_a_long_retro_followup_title_is_marked_as_truncated
    long = (1..12).map { |i| "word#{i}" }.join(" ")
    title = eval_helper(%(retro_followup_title(#{long.inspect}, "rel-a")))

    assert_includes title, "word8", "the title keeps its leading words"
    refute_includes title, "word9", "…and stops at the window"
    assert_includes title, "…", "a truncated title must show that it is a prefix"
  end

  # [unit] the guard is VERBATIM on title AND body. Title-only or fuzzy matching
  # would swallow a genuinely distinct finding — worse than a duplicate, because
  # a duplicate is visible at /triage and a swallowed finding is not.
  def test_unit_the_duplicate_guard_matches_title_and_body_verbatim
    rows = [{ "title" => "t", "body" => "b" }]
    same  = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t", "b")))
    body  = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t", "b2")))
    title = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t2", "b")))
    near  = eval_helper(%(retro_finding_open?(#{rows.inspect}, "t", "b ")))

    assert_equal "true", same, "an exact title+body match is the duplicate"
    assert_equal "false", body, "same title, different body → a DIFFERENT finding, keep it"
    assert_equal "false", title, "same body, different title → a DIFFERENT finding, keep it"
    assert_equal "false", near, "a near-miss is not a match — the guard never matches fuzzily"
  end

  # Intercept the bin/triage seam so retro's filing loop runs with NO network:
  # `list --json` is answered from a fixture and every `file` invocation's argv is
  # appended to a log. Everything else (the doc-commit dance) delegates to the
  # real `sh`. Returns [log_path, setup_ruby].
  #
  # ANY test that reaches `retro`'s filing block needs this. Without it the block
  # shells out to the REAL bin/triage — which is how this suite filed 39 live
  # findings into the operator's production inbox. run_ruby's TASK_API_BASE pin is
  # the backstop; this is the stub that means the call is never attempted.
  def retro_sh_stub(dir, inbox: [], list_ok: true)
    log = File.join(dir, "filed.jsonl")
    inbox_path = File.join(dir, "inbox.json")
    File.write(inbox_path, JSON.generate(inbox))
    setup = <<~RUBY
      File.write(#{log.inspect}, "")
      alias real_sh sh
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0].to_s.end_with?("bin/triage")
          return [#{list_ok ? "File.read(#{inbox_path.inspect})" : '""'}, #{list_ok}] if cmd[1] == "list"
          if cmd[1] == "file"
            File.open(#{log.inspect}, "a") { |f| f.puts(JSON.generate(cmd)) }
            return ["", true]
          end
        end
        real_sh(*cmd, capture: capture, chdir: chdir, env: env)
      end
    RUBY
    [log, setup]
  end

  # retro_sh_stub plus the canned gather/render conductor and a tmpdir doc target
  # — the whole setup a filing-loop test needs.
  def retro_triage_stub(dir, inbox: [], list_ok: true)
    log, sh_stub = retro_sh_stub(dir, inbox: inbox, list_ok: list_ok)
    [log, %(ENV['RETRO_DOCS_DIR'] = #{dir.inspect}; #{RETRO_STUB}; #{sh_stub})]
  end

  # [unit] the pin that keeps this file off the production board, asserted rather
  # than trusted — a pin you have to remember is the bug it is closing.
  def test_unit_this_suites_subprocesses_never_point_at_the_production_board
    base = run_ruby(%(print(ENV.fetch("TASK_API_BASE", "UNSET"))))

    refute_includes base, "mcritchie.studio", "a subprocess of this suite must never resolve the LIVE board"
    assert_match(%r{\Ahttp://127\.0\.0\.1:}, base, "…it is pinned at an unroutable loopback base instead")
  end

  # Every `bin/triage file` the run made, as { title:, body: }.
  def filed_findings(log)
    File.read(log).lines.reject { |l| l.strip.empty? }.map do |line|
      argv = JSON.parse(line)
      { title: argv[argv.index("--title") + 1], body: argv[argv.index("--body") + 1] }
    end
  end

  # [integration] THE BUG: the same retro run twice refiled the same follow-up.
  # Run 1's REAL output is fed back as run 2's open inbox (rather than
  # re-deriving the title here, which would re-implement the helper under test),
  # so this is a true round-trip of what the CLI actually files.
  def test_integration_a_verbatim_identical_followup_files_once_not_twice
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)
      first = filed_findings(log)
      assert_equal 1, first.size, "the first run files the finding"

      inbox = first.map { |f| { "title" => f[:title], "body" => f[:body], "status" => "open" } }
      log2, setup2 = retro_triage_stub(dir, inbox: inbox)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup2)

      assert_empty filed_findings(log2), "a follow-up already open VERBATIM must not be filed again: #{out}"
      assert_includes out, "already open", "and the skip must SAY it skipped, not go quiet"
    end
  end

  # [integration] THE DIRECTION THAT MATTERS MOST — over-suppression loses real
  # findings silently. These two follow-ups share their first EIGHT words, so a
  # title-only (or fuzzy) guard would file one and swallow the other with no
  # trace. The body is what keeps them apart, and both must land.
  def test_integration_two_different_followups_both_file
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      out = run_cli(["rel-retro", "--yes",
                     "--followup", "fix the flaky board filter integration test in the hub suite",
                     "--followup", "fix the flaky board filter integration test in the engine suite"],
                    call: "retro", setup: setup)
      filed = filed_findings(log)

      assert_equal 1, filed.map { |f| f[:title] }.uniq.size,
                   "precondition: these follow-ups DO collide on title — that is the trap"
      assert_equal 2, filed.size, "two distinct follow-ups are two findings: #{out}"
      assert_equal 2, filed.map { |f| f[:body] }.uniq.size, "…and the bodies keep them distinct"
    end
  end

  # [integration] …including when one of them is ALREADY open: the open one is
  # skipped and the new one still lands. This is the guard being precise rather
  # than simply "file nothing when anything matches".
  def test_integration_a_new_followup_still_files_alongside_an_open_duplicate
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)
      inbox = filed_findings(log).map { |f| { "title" => f[:title], "body" => f[:body], "status" => "open" } }

      log2, setup2 = retro_triage_stub(dir, inbox: inbox)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake", "--followup", "adopt the crop guard harness"],
                    call: "retro", setup: setup2)
      filed = filed_findings(log2)

      assert_equal 1, filed.size, "exactly the NEW follow-up files: #{out}"
      assert_includes filed.first[:body], "crop guard", "and it is the new one, not the duplicate"
    end
  end

  # [integration] a repeat WITHIN one run files once — the pre-file read happens
  # before the loop, so the run must also count what it just filed.
  def test_integration_the_same_followup_repeated_in_one_run_files_once
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake", "--followup", "fix flake"],
                    call: "retro", setup: setup)

      assert_equal 1, filed_findings(log).size, "one run, one finding for the same text twice: #{out}"
    end
  end

  # [integration] the refuse-vs-warn call, pinned as BEHAVIOR: a follow-up too
  # short to identify itself WARNS and is still filed. Refusing would discard
  # text the operator just typed at the end of a ship, and the retro's own
  # contract is NON-BLOCKING.
  def test_integration_a_vague_followup_warns_but_is_still_filed
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)

      assert_match(/vague follow-up/i, out, "a follow-up too short to identify must be called out")
      assert_equal 1, filed_findings(log).size, "…and still filed — a warning never costs the operator their text"
      assert_includes out, "NON-BLOCKING", "the retro still ends non-blocking"
    end
  end

  # [integration] FAIL OPEN: if the inbox read fails, file anyway and say so. A
  # duplicate finding is cheaper than a lost one, and the retro must not start
  # failing a release over its own convenience read.
  def test_integration_an_unreadable_inbox_files_anyway_and_says_so
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log, setup = retro_triage_stub(dir, list_ok: false)
      out = run_cli(["rel-retro", "--yes", "--followup", "fix flake"], call: "retro", setup: setup)

      assert_equal 1, filed_findings(log).size, "an unreadable inbox must not silently drop the finding"
      assert_match(/could not read the open inbox/i, out, "…and the degraded check must be visible")
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
  # CI has no sibling repo checkouts, so the real repo_path → Dir.exist? guard in
  # `prepare` (bin/release: "app repo not found at #{path}") would abort before the
  # post-deploy/assemble step this test proves. Resolve the repo to a throwaway dir
  # (stub_repo — NOT Dir.pwd: the gate mkdir_p's a .worktrees/ under whatever
  # repo_path returns) — the git/qa-server I/O against it is fully stubbed by `sh`,
  # so the repo's identity on disk is irrelevant to what this test asserts.
  # RELEASE_CI_STATUS=green is the GATE precondition (DevOps v2 Phase 3): the G3 pre-QA
  # gate verdict is GitHub CI now, so a green CI is injected to let the gate pass and the
  # post-deploy/assemble path this stub exercises continue.
  PAREN_POST_DEPLOY_PREP_STUB = GATE_GIT_STUB + %(ENV["RELEASE_CI_STATUS"] = "green"\ndef repo_path(_repo) = #{stub_repo.inspect}\n) + <<~'RUBY'
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
    def sh(*a, **k)
      g = gate_git(a, k)
      return g if g
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
      return { "slug" => "rel-pd-ship" } if ruby.include?("last_shipped") # the minimal STABLE read (pre-claim)
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

  # --- post-ship agent-docs sync (the OWNED bin/install-agent-docs run) -------
  # Ship's step 7b runs bin/install-agent-docs AFTER the ship record + restored
  # primaries — post-SHIP, not post-merge, because the installer reads the LOCAL
  # hub checkout's docs and only then does the primary's `main` hold exactly what
  # shipped. NON-FATAL by construction: a docs sync must never abort a ship.

  def test_ship_dry_run_syncs_agent_docs_after_the_shipped_banner
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)

    shipped_at = out.index("Shipped rel-pd-ship")
    sync_at    = out.index("sync installed agent docs")
    assert shipped_at && sync_at, "both the shipped banner and the docs-sync step must appear"
    assert_operator shipped_at, :<, sync_at,
                    "the docs sync runs POST-ship (after the shipped record), never before"
    assert_includes out, "install-agent-docs", "the dry run prints the installer command"
  end

  # sync_agent_docs installs from the hub's SHIP WORKSPACE (the tree pinned at the
  # SHA that just shipped), falling back to the primary only when no such workspace
  # exists — see the method's comment. The branch is chosen by whether
  # `<ship-workspace>/bin/install-agent-docs` exists, and GateWorkspace.path is an
  # ABSOLUTE path, so a raw run's outcome depends on the HOST filesystem: CI (no
  # _ship) always hit the primary; a gate box that had materialized _ship hit the
  # ship-workspace branch. The old single test asserted the primary path + refuted
  # ".worktrees", so it FAILED on any host with a _ship workspace (env-divergence,
  # not a regression). These two stub GateWorkspace.path to fix the branch on every
  # host and assert the DESIGN: ship-workspace preferred, primary fallback.

  def test_sync_agent_docs_installs_from_the_shipped_ship_workspace
    setup = <<~RUBY
      require "tmpdir"; require "fileutils"
      WS = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(WS, "bin"))
      File.write(File.join(WS, "bin", "install-agent-docs"), "")
      Release::GateWorkspace.define_singleton_method(:path) { |*_| WS }
      $stdout.puts("WS " + WS)
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["installed-docs-output", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs")

    ws   = out[/^WS (.+)$/, 1]
    argv = out[/SH-ARGV (.*)/, 1].to_s
    assert ws, "sanity: the stub reported its ship-workspace path"
    assert_includes argv, File.join(ws, "bin", "install-agent-docs"),
                    "the sync shells the SHIP WORKSPACE's installer (the just-shipped tree), preferring it over the primary"
    assert_includes out, "installed-docs-output", "the installer's output is surfaced to the operator"
  end

  def test_sync_agent_docs_falls_back_to_the_primary_without_a_ship_workspace
    setup = <<~RUBY
      Release::GateWorkspace.define_singleton_method(:path) { |*_| "/no/such/ship/_ship" }
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["installed-docs-output", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs")

    argv = out[/SH-ARGV (.*)/, 1].to_s
    assert_includes argv, "bin/install-agent-docs", "the fallback still shells the hub's installer"
    refute_includes argv, "/no/such/ship/_ship", "a MISSING ship workspace must not be used — fall back to the primary"
    assert_includes out, "installed-docs-output", "the installer's output is surfaced"
  end

  def test_sync_agent_docs_failure_never_aborts_the_ship
    setup = <<~RUBY
      def sh(*_a, **_k) = ["boom", false]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs; puts('SHIP-CONTINUES')")

    assert_includes out, "agent-docs install failed", "a failed install warns with the by-hand fix"
    assert_includes out, "SHIP-CONTINUES", "a docs-sync failure never aborts the completed ship"
  end

  def test_sync_agent_docs_exception_never_aborts_the_ship
    setup = <<~RUBY
      def sh(*_a, **_k) = raise("no such installer")
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs; puts('SHIP-CONTINUES')")

    assert_includes out, "agent-docs install skipped (no such installer)",
                     "an installer exception is rescued and reported with the by-hand fix"
    assert_includes out, "SHIP-CONTINUES", "an installer exception never aborts the completed ship"
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

  # Shared promote plumbing: accepted 2 ahead of release, no existing batch PR, and
  # gh pr create/merge succeed (echoed so tests count them). repo_path → /tmp so the
  # missing-checkout guard passes.
  PROMOTE_SH = <<~'RUBY'
    def repo_path(_repo) = "/tmp"
    def sh(*a, **_k)
      return ["", true] if a[0] == "git" && a.include?("fetch")
      return ["2", true] if a[0] == "git" && a.include?("rev-list")
      return ["git@github.com:McRitchie-Studio/mcritchie-studio.git", true] if a[0] == "git" && a.include?("remote")
      return ["", true] if a[0] == "gh" && a[2] == "list"
      if a[0] == "gh" && a[2] == "create"
        $stdout.puts("PR-CREATE " + a.join(" "))
        return ["https://gh/pr/batch", true]
      end
      if a[0] == "gh" && a.include?("merge")
        $stdout.puts("PROMOTE-MERGE " + a.find { |x| x.to_s.start_with?("https") }.to_s)
        return ["", true]
      end
      ["", true]
    end
  RUBY

  # A stub that ECHOES the record vs resolve conductor calls so we can count them
  # and inspect the embedded slugs. The (read-only) resolve returns two reviewed
  # members already on accepted (merged:"accepted"); the (write) record returns the RC.
  MERGE_STUB = PROMOTE_SH + <<~'RUBY'
    def conductor(ruby, read_only: false)
      if read_only
        $stdout.puts("RESOLVE-CALL")
        { "tasks" => [
          { "slug" => "task-a", "merged" => "accepted", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" },
          { "slug" => "task-b", "merged" => "accepted", "pr_url" => "https://gh/pr/2", "repo" => "mcritchie-studio", "stage" => "reviewed" }
        ] }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
  RUBY

  def test_merge_promotes_accepted_and_records_all_named_slugs_in_one_run
    out = run_cli(%w[task-a task-b], call: "merge", setup: MERGE_STUB)

    assert_equal 1, out.scan("RESOLVE-CALL").size, "all slugs resolve in ONE read conductor call"
    # ONE accepted→release batch PR promotes the repo — NOT one merge per feat PR.
    assert_equal 1, out.scan("PROMOTE-MERGE").size, "one accepted→release batch PR per repo"
    assert_includes out, "PROMOTE-MERGE https://gh/pr/batch"
    refute_includes out, "PROMOTE-MERGE https://gh/pr/1", "no per-feat-PR merge — review already landed it on accepted"
    # ONE record write covers both named slugs (single dyno spin-up).
    assert_equal 1, out.scan("ADOPT-CALL").size, "all records run in ONE write conductor call"
    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "task-a"
    assert_includes adopt, "task-b"
    assert_includes adopt, "sweep!", "the batched call drives Release::Conductor.sweep!"
    assert_includes out, "Swept task-a"
  end

  def test_merge_promotes_once_per_distinct_repo_across_a_multi_repo_batch
    setup = PROMOTE_SH + <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "task-a", "merged" => "accepted", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" },
            { "slug" => "task-b", "merged" => "accepted", "pr_url" => "https://gh/pr/2", "repo" => "turf-monster", "stage" => "reviewed" }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
          { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
        end
      end
    RUBY
    out = run_cli(%w[task-a task-b], call: "merge", setup: setup)

    assert_equal 2, out.scan("PROMOTE-MERGE").size, "one accepted→release batch PR per DISTINCT repo, not per task"
    assert_includes out, "promote accepted → release in mcritchie-studio"
    assert_includes out, "promote accepted → release in turf-monster"
  end

  # --- merge: the MULTI-REPO task (the 2026-08-13 half-ship, through the OTHER door)
  #
  # `bin/release merge` is not a lesser path: prepare's own abort message ROUTES
  # operators here ("prepare has NO --override — use bin/release merge --override"),
  # so for a long stretch the documented escape hatch was the one that half-shipped.
  # It read the SINGULAR `repo` off each resolved task, and its resolve emitted no
  # `repos`/`pr_urls` at all — which meant SweepPlan's coverage rule saw a one-repo
  # row for every task and `plan["blocked"]` was structurally always empty. Three
  # guards, silent.
  def multi_repo_merge_stub(pr_urls:, repos: [ "mcritchie-studio", "turf-monster" ])
    PROMOTE_SH + <<~RUBY
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "land-rails-security-patch", "merged" => "accepted", "stage" => "reviewed",
              "pr_url" => "https://gh/pr/836", "repo" => "mcritchie-studio",
              "repos" => #{repos.inspect}, "pr_urls" => #{pr_urls.inspect} }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\\n", " "))
          { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
        end
      end
    RUBY
  end

  def test_merge_promotes_EVERY_repo_a_multi_repo_task_names
    out = run_cli(%w[land-rails-security-patch], call: "merge",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                          "turf-monster" => "https://gh/pr/305" }))

    assert_equal 2, out.scan("PROMOTE-MERGE").size,
                 "THE fix: one accepted→release batch PR per repo the TASK NAMES, not per pr_url"
    assert_includes out, "promote accepted → release in mcritchie-studio"
    assert_includes out, "promote accepted → release in turf-monster"
    assert_includes out, "ADOPT-CALL", "…and the membership still records"
  end

  def test_merge_refuses_a_multi_repo_task_whose_pr_record_is_incomplete
    out = run_cli(%w[land-rails-security-patch],
                  call: "begin; merge; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836" }))

    assert_includes out, "ABORTED", "a multi-repo task with one PR must not sweep through merge either"
    assert_includes out, "land-rails-security-patch", "the refusal names the task it refused…"
    assert_includes out, "turf-monster", "…and the repo with no PR url"
    assert_includes out, "NOTHING was promoted or recorded"
    refute_includes out, "NO-ABORT"
    refute_includes out, "PROMOTE-MERGE", "fail-closed BEFORE the irreversible promote"
    refute_includes out, "ADOPT-CALL", "and nothing may be recorded"
  end

  # The abort above must be an ABORT, never a silent drop: SweepPlan.compute removes
  # blocked rows before it splits record/held, so without the refusal the named task
  # would vanish from BOTH lists and merge would print a tick over a task it dropped.
  def test_merge_never_silently_drops_the_task_it_refuses
    out = run_cli(%w[land-rails-security-patch],
                  call: "begin; merge; rescue SystemExit => e; puts('ABORTED'); end",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836" }))

    refute_includes out, "✓ Swept", "a dropped task must never read as swept"
  end

  # The record write is the LAST line of defense, and merge's had none: it swept
  # straight into the release with no validate_members! behind it. Now it runs the
  # same validated, transactional write prepare's does.
  def test_merge_record_write_validates_members_inside_a_transaction
    out = run_cli(%w[task-a], call: "merge", setup: SINGLE_MERGE_STUB)

    adopt = out.lines.find { |l| l.start_with?("ADOPT-CALL") }
    assert_includes adopt, "Release.transaction", "a validate_members! raise must roll the sweep back"
    assert_includes adopt, "Release::Conductor.validate_members!",
                    "merge's record write runs the member backstop"
  end

  def test_merge_task_line_names_every_repo_a_multi_repo_task_carries
    out = run_cli(%w[land-rails-security-patch], call: "merge",
                  setup: multi_repo_merge_stub(pr_urls: { "mcritchie-studio" => "https://gh/pr/836",
                                                          "turf-monster" => "https://gh/pr/305" }))

    assert_includes out, "task land-rails-security-patch (reviewed · merged: accepted) · " \
                         "mcritchie-studio, turf-monster · https://gh/pr/836"
  end

  # A resolve that returns exactly ONE reviewed member on accepted — single-slug path.
  SINGLE_MERGE_STUB = PROMOTE_SH + <<~'RUBY'
    def conductor(ruby, read_only: false)
      if read_only
        { "tasks" => [
          { "slug" => "task-a", "merged" => "accepted", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
        ] }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
  RUBY

  def test_merge_single_slug_promotes_and_records
    out = run_cli(%w[task-a], call: "merge", setup: SINGLE_MERGE_STUB)
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

  # --- accepted-ladder: held abort + straggler skip ----------------------------
  # The retarget/base-guard/overlap machinery retired with the per-feat-PR sweep
  # (review merges feat→accepted; the sweep promotes ONE accepted→release batch PR).
  # What remains for the EXPLICIT `merge` command: a named task must have code on
  # `accepted`, and a straggler already on release is recorded without a re-promote.

  # A named task with NO code on accepted (merged:"") — review never landed its feat
  # PR — is a HARD abort: the operator named it and there is nothing to promote.
  def test_merge_aborts_on_a_named_task_with_no_code_on_accepted
    setup = PROMOTE_SH + <<~'RUBY'
      def conductor(ruby, read_only: false)
        read_only ? { "tasks" => [
          { "slug" => "task-a", "merged" => "", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
        ] } : { "slug" => "rel-batch", "state" => "assembling" }
      end
    RUBY
    out = run_cli(%w[task-a], call: "begin; merge; rescue SystemExit => e; puts('ABORTED: ' + e.message); end", setup: setup)

    assert_includes out, "ABORTED", "a named task with no code on accepted aborts the merge"
    assert_includes out, "no code on `accepted`"
    assert_includes out, "task-a"
    refute_includes out, "PROMOTE-MERGE", "nothing promotes when a named task is not on accepted"
  end

  # A straggler already on release (merged:release) records membership but is NOT
  # re-promoted — the crash-recovery skip.
  def test_merge_skips_promote_for_a_straggler_already_on_release
    setup = PROMOTE_SH + <<~'RUBY'
      def conductor(ruby, read_only: false)
        if read_only
          { "tasks" => [
            { "slug" => "task-a", "merged" => "release", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "reviewed" }
          ] }
        else
          $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
          { "slug" => "rel-batch", "state" => "assembling" }
        end
      end
    RUBY
    out = run_cli(%w[task-a], call: "merge", setup: setup)

    assert_includes out, "skip promote for task-a — already merged: release"
    refute_includes out, "PROMOTE-MERGE", "a straggler already on release is not re-promoted"
    assert_equal 1, out.scan("ADOPT-CALL").size, "…but it still records membership"
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

  # The same task, now with --override → the run proceeds past the review-gate SCREEN
  # and the bypass threads into the record snippet. NOTE (accepted-ladder): --override
  # bypasses the stage-based review GATE, not the held check — the task still needs its
  # code on `accepted` (merged:"accepted"), because the sweep promotes accepted→release
  # and no longer merges a feat PR itself.
  OVERRIDE_MERGE_STUB = PROMOTE_SH + <<~'RUBY'
    def conductor(ruby, read_only: false)
      if read_only
        { "tasks" => [
            { "slug" => "task-a", "merged" => "accepted", "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio", "stage" => "submitted" }
          ],
          "screen" => { "rows" => [{ "slug" => "task-a", "stage" => "submitted", "status" => "overridden" }],
                        "blocked" => [], "overridden" => ["task-a"], "missing" => [], "proceed" => true } }
      else
        $stdout.puts("ADOPT-CALL " + ruby.gsub("\n", " "))
        { "adopted" => [], "slug" => "rel-batch", "state" => "assembling" }
      end
    end
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

  # --- the per-release ASSEMBLER/DEPLOYER conductor claim, at RUNTIME -----------
  # These drive bin/release IN A SUBPROCESS with conductor_claim STUBBED, so they prove
  # the runtime stand-down the source-ordering wiring test can only assert structurally.

  # FIX 1 — `merge` runs the same assembler-lane promote+sweep prepare guards. A held
  # assembler claim must stand merge down BEFORE the (irreversible) promote runs.
  def test_merge_stands_down_before_the_promote_when_the_assembler_claim_is_held
    setup = MERGE_STUB + %(\ndef conductor_claim(*a) = ReleaseClaimCli::STOOD_DOWN\n)
    out = run_cli(%w[task-a], setup: setup,
                  call: "begin; merge; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a held assembler claim must stand merge down"
    assert_includes out, "held by another live release conductor", "and names the stand-down cause"
    refute_includes out, "NO-ABORT", "merge must not fall through past the claim gate"
    refute_includes out, "PROMOTE-MERGE",
                     "the accepted→release promote must NOT run — merge stands down BEFORE the irreversible mutation"
    refute_includes out, "ADOPT-CALL", "and sweep! (the record) must NOT run either"
  end

  # FIX 2(a) — BEHAVIORAL finalize snapshot-under-claim: finalize must stand down BEFORE
  # it reads its MUTABLE decision snapshot (state/sealed/… → finalize_pending?), or a
  # concurrent finalizer could complete the pending steps in the gap and leave us
  # replaying stale work. The minimal stable slug read (puts({slug: r.slug})) runs
  # pre-claim; the "sealed:" snapshot must NOT be read once we're stood down.
  def test_finalize_stands_down_before_reading_its_mutable_decision_snapshot
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("SNAPSHOT-READ") if ruby.include?("sealed:")            # the MUTABLE decision snapshot
        return { "slug" => "rel-x" } if ruby.include?("puts({slug: r.slug}") # the minimal STABLE read
        {}
      end
      def conductor_claim(*a) = ReleaseClaimCli::STOOD_DOWN
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; finalize('rel-x'); puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a held deployer claim must stand finalize down"
    assert_includes out, "held by another live release conductor", "and names the stand-down cause"
    refute_includes out, "NO-ABORT", "finalize must not fall through past the claim gate"
    refute_includes out, "SNAPSHOT-READ",
                     "finalize must stand down BEFORE reading its mutable decision snapshot — snapshot-under-claim at runtime"
  end

  # FIX B — BEHAVIORAL ship snapshot-under-claim: ship must stand down BEFORE it reads its
  # MUTABLE decision snapshot (repo_plan/state/qa_shas → resuming_member_ship + the assembled
  # gate), or a concurrent ship/finalize could change that state between the read and the
  # deploy. The minimal stable slug read (puts({slug: r.slug})) runs pre-claim; the
  # "repo_plan" snapshot must NOT be read once we're stood down.
  def test_ship_stands_down_before_reading_its_mutable_decision_snapshot
    # CLAIM-CHECK proves ship reached the acquire (PAST the minimal read); its args show the
    # claim is consulted on rel_slug BEFORE any repo_plan read. (ship's rescue re-exits, so
    # the stand-down MESSAGE lands on stderr — the behavioral proof is CLAIM-CHECK before,
    # SNAPSHOT-READ never, NO-ABORT never.)
    setup = <<~'RUBY'
      def conductor(ruby, read_only: false)
        $stdout.puts("SNAPSHOT-READ") if ruby.include?("repo_plan")   # the MUTABLE decision snapshot
        return { "slug" => "rel-x" } if ruby.include?("last_shipped") # the minimal STABLE read
        {}
      end
      def conductor_claim(*a); $stdout.puts("CLAIM-CHECK " + a.join(" ")); ReleaseClaimCli::STOOD_DOWN; end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship; puts('NO-ABORT'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "CLAIM-CHECK acquire rel-x --role deployer",
                     "ship resolves rel_slug via the minimal read, then CONSULTS the deployer claim"
    assert_includes out, "ABORTED", "a held deployer claim (STOOD_DOWN) stands ship down"
    refute_includes out, "NO-ABORT", "ship must not fall through past the claim gate"
    refute_includes out, "SNAPSHOT-READ",
                     "ship stands down BEFORE reading its mutable decision snapshot (repo_plan) — snapshot-under-claim at runtime"
  end

  # FIX 2(b) — the acquire_conductor_claim! BRANCH TABLE. This is the single runtime
  # hinge for finalize's snapshot-under-claim AND the prepare/merge exclusion; a
  # branch-inversion (swap the STOOD_DOWN/OK arms) or a dropped record would ship the
  # stale-replay / renewer-leak bug green. Pin all three arms behaviorally.
  def test_acquire_conductor_claim_stood_down_arm_aborts_and_records_nothing
    out = run_cli([], setup: %(def conductor_claim(*a) = ReleaseClaimCli::STOOD_DOWN),
                  call: %(begin; acquire_conductor_claim!("deployer", "rel-x"); ) +
                        %(puts("NO-ABORT COUNT=" + held_conductor_claims.size.to_s); ) +
                        %(rescue SystemExit; puts("ABORTED COUNT=" + held_conductor_claims.size.to_s); end))
    assert_includes out, "ABORTED COUNT=0",
                     "STOOD_DOWN must raise SystemExit (stand down) AND record nothing (no renewer to leak)"
    refute_includes out, "NO-ABORT", "the STOOD_DOWN arm must not fall through to recording a claim"
  end

  def test_acquire_conductor_claim_ok_arm_records_exactly_the_held_claim
    out = run_cli([], setup: %(def conductor_claim(*a) = ReleaseClaimCli::OK),
                  call: %(acquire_conductor_claim!("deployer", "rel-x"); c = held_conductor_claims; ) +
                        %(puts("COUNT=" + c.size.to_s); puts("SLUG=" + c.first[:slug].to_s); puts("ROLE=" + c.first[:role].to_s)))
    assert_includes out, "COUNT=1",
                     "an OK acquire records EXACTLY one held claim — a dropped record leaks the renewer (no release ever fires)"
    assert_includes out, "SLUG=rel-x"
    assert_includes out, "ROLE=deployer"
  end

  def test_acquire_conductor_claim_fail_open_arms_never_raise_and_hold_nothing
    [%(def conductor_claim(*a) = nil), %(def conductor_claim(*a) = ReleaseClaimCli::CANT_RUN)].each do |stub|
      out = run_cli([], setup: stub,
                    call: %(acquire_conductor_claim!("deployer", "rel-x"); ) +
                          %(puts("FAIL-OPEN COUNT=" + held_conductor_claims.size.to_s)))
      assert_includes out, "FAIL-OPEN COUNT=0",
                       "a fail-open acquire (nil/CANT_RUN) never raises and holds nothing — a claim outage never wedges a release"
    end
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

  # THE FIELDS WITHOUT WHICH MERGE'S GUARDS CANNOT FIRE. This snippet crosses a
  # process boundary (it runs on the board), so the string IS the interface — and
  # the whole blocker was an interface omission, not a logic error: with no
  # `repos`/`pr_urls` on the row, Release::SweepPlan.normalize falls back to
  # `[row["repo"]]`, repo_coverage_gap's `size < 2` guard passes every row, and
  # `plan["blocked"]` is structurally always empty however correct the guard is.
  def test_batch_resolve_ruby_emits_the_full_release_identity_per_task
    out = eval_helper(%(batch_resolve_ruby(["task-a"])))

    assert_includes out, "release_repos", "the resolve reads EVERY repo the task names"
    assert_includes out, "release_pr_urls", "…and the PR url recorded per repo"
    assert_includes out, "repos:", "both ride the emitted row"
    assert_includes out, "pr_urls:"
    assert_equal 1, out.scan("puts(").size, "still ONE JSON line for the batch"
  end

  def test_batch_sweep_ruby_validates_members_inside_a_transaction
    # merge's record write was the ONE sweep path with no member validation behind
    # it; prepare's twin (batch_sweep_with_plan_ruby) has always had both.
    out = eval_helper(%(batch_sweep_ruby(["task-a"])))

    assert_includes out, "Release::Conductor.validate_members!", "the backstop runs on merge's write too"
    assert_includes out, "Release.transaction", "a raise must roll the whole sweep back"
    assert_equal 1, out.scan("puts(").size, "still ONE JSON line for the batch"
  end

  def test_batch_resolve_ruby_runs_the_review_gate_screen
    out = eval_helper(%(batch_resolve_ruby(["task-a"], override: true)))
    assert_includes out, "screen_merge", "the resolve snippet runs the review-gate screen in the same read"
    assert_includes out, "override: true", "the override flag threads into the screen"
    assert_equal 1, out.scan("puts(").size, "resolve + screen still emit ONE JSON line"
  end

  def test_batch_resolve_ruby_also_reads_the_active_release_for_the_assembler_claim
    # merge takes the assembler claim on the active release slug (or the FORMING
    # sentinel) BEFORE its promote — so the batched resolve read carries Release.current.
    out = eval_helper(%(batch_resolve_ruby(["task-a"])))
    assert_includes out, "Release.current", "the resolve snippet reads the active release for merge's assembler claim"
    assert_includes out, "release:", "and emits it in the JSON so merge can key its claim on the active slug"
    assert_equal 1, out.scan("puts(").size, "still ONE JSON line (the release rides the same read)"
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
  # bin/release opens+closes an AgentActivity SPAN around its deploy phases stamped
  # with the ROLE soul the board already attributes them to — Steffon on prepare
  # (assemble → QA), Avi on ship (→ prod) — so the heartbeat's deploy spans match
  # the board's stage timeline. Best-effort + non-fatal: skipped under --dry-run
  # and when no conductor session is resolvable.

  # Capture the narration args instead of shelling out to the real bin/atomic-event.
  NARRATION_CAPTURE = <<~RUBY
    def agent_activity(*a) = $stdout.puts("ATOMIC " + a.join(" "))
  RUBY

  def test_narration_helpers_stamp_the_role_agent_and_close_with_an_outcome
    setup = <<~RUBY
      $events = []
      def agent_activity(*a) = ($events << a)
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

  def test_agent_activity_is_a_noop_under_dry_run
    setup = %(def conductor_session_id = "sess-x")
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(print(agent_activity("start", "--category", "Remote", "--reason", "x").inspect)))
    assert_equal "nil", out, "a dry-run narrates nothing (best-effort no-op)"
  end

  def test_agent_activity_is_a_noop_without_a_conductor_session
    # SessionEnv nulls the session vars → conductor_session_id is nil → no-op;
    # telemetry must never shell out (or fail) when there's no session to attribute.
    out = run_cli(["--yes"], setup: "",
                  call: %(print(agent_activity("start", "--category", "Remote", "--reason", "x").inspect)))
    assert_equal "nil", out, "no conductor session → nothing to narrate"
  end

  # [integration] prepare records an Avi deploy span end-to-end (the paren
  # post_deploy stub reaches assemble under --yes; narration is captured, not shelled).
  def test_prepare_narrates_an_avi_deploy_span
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB + NARRATION_CAPTURE)

    assert_includes out, "ATOMIC start --category Remote --reason sweep → deploy RC to QA --agent avi",
                     "prepare opens an Avi span"
    assert_match(/ATOMIC end --outcome assembled/, out, "and closes it once the RC is assembled")
  end

  # [integration] ship records a Steffon deploy span end-to-end (the publish-decision
  # stub runs the real ship flow under --yes with only the git/gem/heroku I/O stubbed).
  def test_ship_narrates_a_steffon_deploy_span
    out = run_cli(["--yes"], call: "ship", setup: PUBLISH_DECISION_STUB + NARRATION_CAPTURE)

    assert_includes out, "ATOMIC start --category Remote --reason ship → prod --agent steffon",
                     "ship opens a Steffon span after ship authority"
    assert_match(/ATOMIC end --outcome shipped/, out, "and closes it once shipped to prod")
  end

  # bin/release's real work (git / gh / heroku run) runs as SUBPROCESSES of one Bash
  # tool call, invisible to the PostToolUse capture hook — so its Remote deploy span
  # read "No raw actions attributed". step() now self-reports each in-span operation
  # as an AgentAction (bin/agent-activity action) so the span carries genuine rows.

  def test_step_self_reports_an_action_only_inside_a_role_span
    setup = <<~RUBY
      $events = []
      def agent_activity(*a) = ($events << a)
      def conductor_session_id = "sess-x"
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %(step("before span"); ) +
                        %(open_role_span("steffon", "sweep → deploy RC to QA"); ) +
                        %(step("qa deploy: bin/qa-server deploy foo"); ) +
                        %(close_role_span("assembled rel-x → QA"); ) +
                        %(step("after span"); print($events.inspect)))

    assert_includes out, %(["action", "--summary", "qa deploy: bin/qa-server deploy foo"]),
                     "a step INSIDE the role span self-reports an AgentAction"
    refute_includes out, %(["action", "--summary", "before span"]),
                     "a step BEFORE the span opens does not (nothing to attribute to)"
    refute_includes out, %(["action", "--summary", "after span"]),
                     "a step AFTER the span closes does not"
  end

  def test_agent_action_is_a_noop_under_dry_run
    # agent_action rides agent_activity, which no-ops under --dry-run — a preview
    # narrates and self-reports nothing.
    setup = %(def conductor_session_id = "sess-x")
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(print(agent_action("qa deploy: foo").inspect)))
    assert_equal "nil", out, "a dry-run self-reports no action"
  end

  # [integration] prepare's in-span steps self-report actions end-to-end (the paren
  # post_deploy stub reaches assemble under --yes; narration is captured, not shelled).
  def test_prepare_self_reports_step_actions_into_the_span
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB + NARRATION_CAPTURE)

    assert_match(/ATOMIC action --summary /, out,
                 "prepare's steps self-report actions into the open Remote span")
  end

  # --- test-scope telemetry: run_test_scope wraps every release gate ----------
  # Every gate the CLI runs (pre_qa_gate, the QA/prod /up smokes, post-deploy
  # hooks, the ship test gate, the prod smoke seal) goes through run_test_scope,
  # which emits one START + one COMPLETED/FAILED AgentAction per run — carrying
  # {scope key, host, pass|fail, parsed counts, duration, command} — through the
  # SAME self-report path step() uses (gated on $role_span_open, DRY-inert). The
  # emission is captured by stubbing agent_activity (never shelling out).

  # Give the wrapper a captured narration channel + an open role span so
  # scope_action fires (the exact gating step() rides).
  SCOPE_EMIT_STUB = <<~RUBY
    $events = []
    def agent_activity(*a) = ($events << a)
    def conductor_session_id = "sess-x"
    $role_span_open = true
  RUBY

  def test_run_test_scope_emits_start_and_completed_with_counts_on_success
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["141 runs, 320 assertions, 0 failures, 0 errors", true])
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("ship_test_gate", "bin/rails", "test", repo: "mcritchie-studio"); print($events.inspect)))

    assert_includes out, "test scope ship_test_gate START", "the wrapper emits a START action"
    assert_includes out, "test scope ship_test_gate COMPLETED", "…and a COMPLETED action on success"
    assert_includes out, "mcritchie-studio", "the emitted action carries the repo/host"
    assert_includes out, "141 runs, 320 assertions, 0 failures, 0 errors", "…the parsed minitest counts"
    assert_includes out, "pass", "…and the pass verdict"
  end

  def test_run_test_scope_emits_failed_and_returns_false_when_the_command_fails
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["3 runs, 3 assertions, 1 failures, 0 errors", false])
    out = run_cli(["--yes"], setup: setup,
                  call: %(_o, ok = run_test_scope("qa_post_deploy", "heroku", "run", repo: "turf-monster-qa"); ) +
                        %(print("OK=" + ok.inspect + " " + $events.inspect)))

    assert_includes out, "OK=false", "the wrapper returns the command's ok flag (false) unchanged"
    assert_includes out, "test scope qa_post_deploy FAILED", "a failed command emits a FAILED action"
    assert_includes out, "fail", "…with the fail verdict"
    assert_includes out, "1 failures", "…and the parsed counts"
  end

  def test_run_test_scope_emits_failed_then_reraises_when_the_command_raises
    # A raised SystemCallError (Open3 ENOENT on a bad path) must RE-RAISE so the
    # caller's rescue still fires — production_smoke_seal degrades it to a red
    # seal — but a FAILED action is emitted first.
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k); raise Errno::ENOENT, "bin/prod-smoke"; end)
    out = run_cli(["--yes"], setup: setup,
                  call: %(begin; run_test_scope("prod_smoke_seal", "bin/prod-smoke", "mcritchie-studio", repo: "mcritchie-studio"); ) +
                        %(puts("NO-RAISE"); rescue SystemCallError => e; puts("RAISED " + e.class.name); end; print($events.inspect)))

    assert_includes out, "RAISED Errno::ENOENT", "a raising command re-raises (the seal degradation depends on it)"
    refute_includes out, "NO-RAISE", "the wrapper does not swallow the raise"
    assert_includes out, "test scope prod_smoke_seal FAILED", "…but a FAILED action is emitted first"
    assert_includes out, "Errno::ENOENT", "…naming the error class"
  end

  def test_run_test_scope_emits_nothing_outside_a_role_span
    setup = <<~RUBY
      $events = []
      def agent_activity(*a) = ($events << a)
      def conductor_session_id = "sess-x"
      $role_span_open = false
      def sh(*_a, **_k) = ["7 runs, 7 assertions, 0 failures, 0 errors", true]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("pre_qa_gate", "bin/rails", "test", repo: "mcritchie-studio"); print($events.inspect)))

    assert_equal "[]", out, "no open role span → nothing to attribute → no telemetry (the step() gate)"
  end

  def test_run_test_scope_is_inert_under_dry_run
    # A dry-run executes NOTHING: sh short-circuits before its `system`, and the
    # telemetry rides agent_activity which is DRY-gated before its `system`. So
    # no shell-out fires at all — neither the command nor the narration.
    setup = <<~RUBY
      $syscalls = []
      def system(*a, **_k); $syscalls << a; true; end
      def conductor_session_id = "sess-x"
      $role_span_open = true
    RUBY
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(run_test_scope("ship_test_gate", "bin/rails", "test", repo: "mcritchie-studio"); ) +
                        %(print("SYSCALLS-EMPTY=" + $syscalls.empty?.to_s)))

    assert_includes out, "SYSCALLS-EMPTY=true",
                     "a dry-run wraps but executes nothing — command + telemetry both inert (no shell-out)"
  end

  # --- verdict tagging: the COMPLETED/FAILED emit is a GRADEABLE test_scope -----
  # A2: run_test_scope tags ONLY the verdict emit with the fields that make the run
  # a first-class gradeable unit in /alex/pipeline — kind=test_scope, event_slug=the
  # scope key, result_slug=pass|fail, duration_ms — while the START emit stays plain
  # (so the pipeline's `kind:test_scope AND result_slug present` filter skips it).

  def test_run_test_scope_tags_only_the_verdict_action_as_a_gradeable_test_scope
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["141 runs, 320 assertions, 0 failures, 0 errors", true])
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("ship_test_gate", "bin/rails", "test", repo: "mcritchie-studio"); ) +
                        %(start = $events.find { |e| e.join(" ").include?("START") }; ) +
                        %(done  = $events.find { |e| e.join(" ").include?("COMPLETED") }; ) +
                        %(print("START=" + start.inspect + "\\nDONE=" + done.inspect)))

    start_line, done_line = out.split("\nDONE=", 2)

    # The verdict emit carries every gradeable tag field.
    assert_includes done_line, "--kind",        "the verdict action is tagged with a kind"
    assert_includes done_line, "test_scope",    "…kind=test_scope so the pipeline can select it"
    assert_includes done_line, "--event-slug",  "…tagged with the scope key"
    assert_includes done_line, "ship_test_gate"
    assert_includes done_line, "--result-slug", "…tagged with the pass|fail verdict"
    assert_includes done_line, "pass"
    assert_includes done_line, "--duration-ms", "…and the wall-clock duration"

    # START stays plain — no tag fields — so it never lands in the pipeline band.
    refute_includes start_line, "--kind",        "the START emit stays untagged"
    refute_includes start_line, "test_scope"
    refute_includes start_line, "--result-slug"
  end

  def test_run_test_scope_tags_a_failed_verdict_with_result_slug_fail
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["3 runs, 3 assertions, 1 failures, 0 errors", false])
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("qa_post_deploy", "heroku", "run", repo: "turf-monster-qa"); ) +
                        %(done = $events.find { |e| e.join(" ").include?("FAILED") }; print(done.inspect)))

    assert_includes out, "--kind",        "a failed run is still a tagged, gradeable verdict"
    assert_includes out, "test_scope"
    assert_includes out, "--event-slug"
    assert_includes out, "qa_post_deploy"
    assert_includes out, "--result-slug"
    assert_includes out, "fail", "…with result_slug fail"
  end

  # --- parse_test_counts: lenient, nil when nothing recognizable --------------

  def test_parse_test_counts_sums_minitest_summary_lines
    assert_equal %("141 runs, 320 assertions, 0 failures, 0 errors"),
                 eval_helper(%q{parse_test_counts("141 runs, 320 assertions, 0 failures, 0 errors").inspect}),
                 "a single minitest summary line parses verbatim"
    # `rails test test:system` prints one summary line PER lane — they sum.
    assert_equal %("15 runs, 28 assertions, 1 failures, 2 errors"),
                 eval_helper(%q{parse_test_counts("10 runs, 20 assertions, 1 failures, 0 errors\n5 runs, 8 assertions, 0 failures, 2 errors").inspect}),
                 "multiple minitest summary lines are summed across lanes"
  end

  def test_parse_test_counts_reads_playwright_and_up_code_and_returns_nil_otherwise
    assert_equal %("12 passed"),
                 eval_helper(%q{parse_test_counts("Running 12 tests\n12 passed (3.2s)").inspect}),
                 "playwright's 'N passed' parses"
    assert_equal %("12 passed, 2 failed"),
                 eval_helper(%q{parse_test_counts("12 passed\n2 failed").inspect}),
                 "…with a failed count when present"
    assert_equal %("http 200"),
                 eval_helper(%q{parse_test_counts("200").inspect}),
                 "a bare 3-digit /up probe body parses as an http code"
    assert_equal "nil",
                 eval_helper(%q{parse_test_counts("some unrecognizable output").inspect}),
                 "nothing recognizable → nil (the summary just omits counts)"
  end

  # [integration] A REAL release gate (run_post_deploy) runs its command THROUGH
  # run_test_scope end-to-end: the hardened heroku argv still executes, and the
  # scope telemetry is emitted into the open span with the target-derived key.
  def test_post_deploy_runs_through_the_telemetry_wrapper_end_to_end
    setup = SCOPE_EMIT_STUB + <<~RUBY
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["1 runs, 1 assertions, 0 failures, 0 errors", true]
      end
      def conductor(*_a, **_k) = {}
      REPOS = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
                 "members" => [{ "slug" => "t-turf", "post_deploy_cmd" => "rake db:migrate" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "run_post_deploy(REPOS, target: :qa); print($events.inspect)")

    assert_includes out, "SH-ARGV", "the gate's heroku command still executes through the wrapper"
    assert_includes out, %q("--exit-code"), "…with its argv hardening intact"
    assert_includes out, "test scope qa_post_deploy START", "the QA post-deploy runs as a telemetered scope"
    assert_includes out, "test scope qa_post_deploy COMPLETED", "…emitting a COMPLETED action end-to-end"
  end

  # --- gem_release_check: a gem's own release-check is a telemetered ship scope --
  # publish_gem runs the gem's declared `release_check --build` before the push;
  # it now runs THROUGH run_test_scope (a `gem_release_check` release scope) so it
  # emits START + COMPLETED/FAILED like every other gate, while keeping its
  # abort-before-publish semantics. studio-engine declares `bin/release-check`.

  # A tmpdir hub whose bin/<script> exists so publish_gem's File.exist? guard fires.
  def with_release_check_repo(script = "bin/release-check")
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "bin"))
      File.write(File.join(dir, script), "#!/usr/bin/env sh\nexit 0\n")
      File.chmod(0o755, File.join(dir, script))
      yield dir
    end
  end

  def test_gem_release_check_runs_through_the_telemetry_wrapper
    with_release_check_repo do |dir|
      setup = SCOPE_EMIT_STUB + <<~RUBY
        def repo_path(_repo) = #{dir.inspect}
        def sh(*a, **_k)
          $stdout.puts("SH " + a.inspect)
          ["3 runs, 3 assertions, 0 failures, 0 errors", true]  # release-check green (and gem build/push/tag)
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %(publish_gem("studio-engine", "0.9.0"); print($events.inspect)))

      assert_includes out, %(SH ["bin/release-check", "--build"]),
                       "the release-check still executes with --build"
      assert_includes out, "test scope gem_release_check START", "…now wrapped: a START action is emitted"
      assert_includes out, "test scope gem_release_check COMPLETED", "…and a COMPLETED action on a green check"
      assert_includes out, "studio-engine", "the emitted action carries the gem repo/host"
    end
  end

  def test_gem_release_check_failure_emits_failed_and_aborts_before_publish
    with_release_check_repo do |dir|
      setup = SCOPE_EMIT_STUB + <<~RUBY
        def repo_path(_repo) = #{dir.inspect}
        def sh(*a, **_k)
          $stdout.puts("SH " + a.inspect)
          return ["1 runs, 1 assertions, 1 failures, 0 errors", false] if a[0] == "bin/release-check"
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %(begin; publish_gem("studio-engine", "0.9.0"); puts("NO-ABORT"); ) +
                          %(rescue SystemExit => e; puts("ABORTED: " + e.message); end; print($events.inspect)))

      assert_includes out, "test scope gem_release_check FAILED", "a red release-check emits a FAILED action"
      assert_includes out, "ABORTED", "…and still aborts before publishing (existing gate behavior preserved)"
      assert_includes out, "release-check failed"
      refute_includes out, "NO-ABORT", "the gem must not publish past a red release-check"
      refute_includes out, %(SH ["gem", "push"), "nothing is pushed after the red check aborts"
    end
  end

  # --- qa_smoke: `completed` only AFTER the blocking QA post-deploy hook passes --
  # The stage stamp must not go green prematurely: prepare records qa_smoke
  # `started` at the first QA deploy, `failed` on a boot failure, and `completed`
  # only once every app booted AND run_post_deploy (blocking, abort!s on failure)
  # returned green — the same "never a step early" rule 8b uses for deploy_qa.

  # Capture the qa_smoke ReleaseEvent stage stamps (step + status) without a board.
  RRE_ECHO = %(def record_release_event(_slug, step, status, *_a, **_k); $stdout.puts("RRE " + step.to_s + " " + status.to_s); end)

  def test_prepare_records_qa_smoke_completed_only_after_the_post_deploy_hook_passes
    out = run_cli(["--yes"], setup: SWEEP_FLOW_STUB + RRE_ECHO, call: "prepare")

    assert_includes out, "RRE qa_smoke started", "the QA smoke opens at the first QA deploy"
    assert_includes out, "RRE qa_smoke completed", "…and closes green once QA booted + post-deploy passed"
    refute_includes out, "RRE qa_smoke failed", "a green run never records a failed stamp"
    started_at   = out.index("RRE qa_smoke started")
    completed_at = out.index("RRE qa_smoke completed")
    assert_operator started_at, :<, completed_at, "completed lands after started"
  end

  def test_prepare_does_not_record_qa_smoke_completed_when_the_post_deploy_hook_aborts
    # A blocking QA post-deploy hook that aborts must leave qa_smoke NOT green —
    # the premature-green bug: the stamp used to land before this hook ran.
    setup = SWEEP_FLOW_STUB + RRE_ECHO + %(\ndef run_post_deploy(*_a, **_k); abort!("post-deploy boom"); end)
    out = run_cli(["--yes"], setup: setup,
                  call: %(begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end))

    assert_includes out, "RRE qa_smoke started", "the smoke still opens at the QA deploy"
    assert_includes out, "ABORTED", "the blocking post-deploy hook aborts prepare"
    refute_includes out, "RRE qa_smoke completed",
                     "qa_smoke must NOT be stamped completed when the blocking post-deploy hook aborts"
    refute_includes out, "NO-ABORT"
  end

  def test_prepare_records_qa_smoke_failed_on_a_boot_failure
    setup = SWEEP_FLOW_STUB + RRE_ECHO + %(\ndef wait_for_boot(_url) = false)
    out = run_cli(["--yes"], setup: setup, call: "prepare")

    assert_includes out, "RRE qa_smoke started", "the smoke opens at the QA deploy"
    assert_includes out, "RRE qa_smoke failed", "a boot failure closes the smoke as failed"
    refute_includes out, "RRE qa_smoke completed", "a boot failure never records a completed stamp"
  end

  # --- deploy_app: what the deploy actually needs ------------------------------

  # [integration] git_push_heroku (hub, rolio) needs NO working tree: "deploy" is
  # handing a commit to a git remote. It ref-pushes the FROZEN SHA BY VALUE, which
  # is stricter than the old `git push heroku main` (that shipped whatever the local
  # branch pointed at, in a checkout any session could disturb). Proven on real git:
  # the "heroku" remote's main lands on the frozen SHA while the primary sits dirty
  # on a feature branch.
  def test_deploy_app_git_push_heroku_ref_pushes_the_frozen_sha_from_a_dirty_primary
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      heroku = File.join(dir, "heroku.git")
      system("git", "init", "--bare", "-q", heroku, out: File::NULL, err: File::NULL) || flunk("bare init failed")
      run_git(clone, "remote", "add", "heroku", heroku)
      frozen = git_out(clone, "rev-parse", "release")

      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "git_push_heroku", "remote" => "heroku", "branch" => "main" } })
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(_s); end\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "the deploy must not care that the primary is dirty: #{out}"
      assert_equal frozen, git_out(heroku, "rev-parse", "main"),
                   "the Heroku remote's main must be the FROZEN SHA — that is what boots in prod"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main"),
                   "…and origin/main must have been advanced to it too"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary is never checked out"
      assert_includes git_out(clone, "status", "--porcelain"), "app.rb", "…and its dirt survives"
    end
  end

  # [integration] repo_script (turf-monster) is the one adapter that DOES need a
  # working tree — its bin/deploy runs the repo's suite, hashes the IDL, and pushes
  # from the checkout it runs in. It gets the SHIP WORKSPACE, detached at the frozen
  # SHA. This test stands in for turf's bin/deploy and asserts the three things that
  # script actually depends on, rather than assuming them:
  #   * cwd is the ship workspace (NOT the primary, NOT the gate workspace),
  #   * `git rev-parse HEAD` there is the FROZEN SHA,
  #   * `git rev-parse --abbrev-ref HEAD` is the literal "HEAD" (detached) — which is
  #     what makes turf's own `PUSH_SPEC="$BRANCH:main"` resolve to `HEAD:main` and
  #     push exactly the frozen commit,
  #   * the tree is CLEAN, so its `git diff-index --quiet HEAD` preflight passes even
  #     while the primary is filthy.
  def test_deploy_app_repo_script_runs_in_the_ship_workspace_at_the_frozen_sha
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")
      probe  = File.join(dir, "probe.sh")
      File.write(probe, <<~SH)
        #!/usr/bin/env sh
        echo "DEPLOY-CWD $(pwd)"
        echo "DEPLOY-HEAD $(git rev-parse HEAD)"
        echo "DEPLOY-BRANCH $(git rev-parse --abbrev-ref HEAD)"
        git diff-index --quiet HEAD -- && echo "DEPLOY-TREE-CLEAN" || echo "DEPLOY-TREE-DIRTY"
      SH
      File.chmod(0o755, probe)

      # The primary is a live session's floor: off main, dirty.
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "repo_script", "command" => #{probe.inspect}, "args" => ["--yes"] } })
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(_s); end\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "the satellite deploy must survive a dirty primary: #{out}"
      assert_includes out, ".worktrees/_ship",
                      "the repo's deploy script must run in the SHIP workspace, not the primary or the gate's"
      assert_includes out, "DEPLOY-HEAD #{frozen}",
                      "…pinned at the QA-frozen SHA — the exact commit that ships"
      assert_includes out, "DEPLOY-BRANCH HEAD",
                      "…detached, which is what makes turf's PUSH_SPEC resolve to `HEAD:main` (the frozen commit)"
      assert_includes out, "DEPLOY-TREE-CLEAN",
                      "…and clean, so the repo's own clean-tree preflight passes while the primary is dirty"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary is never checked out by the satellite deploy"
    end
  end

  # [integration] github_actions (the hub, DevOps v2 Phase 2) deploys by dispatching
  # a workflow, not by pushing itself. push_frozen_main still ref-advances origin/main
  # (the workflow deploys the FROZEN SHA it is handed, not origin/main — which is why
  # prod-deploy.yml is workflow_dispatch, not push:[main]); then the conductor
  # dispatches prod-deploy.yml at the frozen SHA and watches it. The workflow owns the
  # Heroku push AND the hard /up smoke, so there is NO conductor curl-smoke here.
  # dispatch_and_watch is stubbed to capture the call without shelling out to real gh.
  def test_deploy_app_github_actions_dispatches_the_prod_workflow_at_the_frozen_sha
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "github_actions", "workflow" => "prod-deploy.yml" } })
      setup = <<~RUBY
        def repo_path(_repo) = #{clone.inspect}
        def record_merged_main(_s); end
        def dispatch_and_watch(workflow, inputs = {}, chdir: nil)
          puts("DISPATCH \#{workflow} sha=\#{inputs['sha']}")
          true
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "the github_actions deploy must succeed: #{out}"
      assert_includes out, "DISPATCH prod-deploy.yml sha=#{frozen}",
                      "the hub deploy dispatches prod-deploy.yml at the FROZEN sha"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main"),
                   "push_frozen_main still ref-advances origin/main to the frozen SHA before the dispatch"
      refute_includes out, "smoke: GET",
                      "no conductor curl-smoke for github_actions — the workflow owns the /up smoke"
    end
  end

  # [integration] dispatch_and_watch's run-id selection is the correctness core of
  # the github_actions deploy: `gh workflow run` names no run, so it snapshots the
  # newest run id BEFORE dispatch and watches the first STRICTLY-greater one. These
  # stub `sh` (+ no-op `sleep`) to drive that wiring without real gh; the pure truth
  # table lives in Release::ShipSequenceTest#new_run_id.
  def test_dispatch_and_watch_aborts_when_the_pre_dispatch_snapshot_never_answers
    # A `gh run list` FAILURE must NOT read as before_id=0 — that would let the poll
    # latch a PRE-EXISTING run and false-green a prod deploy. When the snapshot never
    # answers, dispatch_and_watch returns false AND never dispatches the workflow.
    setup = <<~RUBY
      def sleep(*) = nil
      $dispatched = false
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        return ["", false] if cmd[0, 3] == ["gh", "run", "list"]   # snapshot always fails
        $dispatched = true if cmd[0, 3] == ["gh", "workflow", "run"]
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{r = dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }); } +
                        %{puts("RESULT \#{r}"); puts("DISPATCHED \#{$dispatched}")})

    assert_includes out, "RESULT false", "a snapshot that never answers must ABORT, not watch a stale run"
    assert_includes out, "DISPATCHED false", "and must not even dispatch the workflow without a baseline"
  end

  def test_dispatch_and_watch_watches_the_strictly_greater_run_it_created
    # before_id snapshot = 100 (a prior run). After dispatch a NEW run 101 appears;
    # dispatch_and_watch must watch 101 (strictly greater), never the pre-existing 100.
    setup = <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      $watched = nil
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]   # 1st = snapshot, then our new run
        end
        if cmd[0, 3] == ["gh", "run", "watch"]
          $watched = cmd[3]
          return ["", true]
        end
        ["", true]   # gh workflow run
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{r = dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }); } +
                        %{puts("RESULT \#{r} WATCHED \#{$watched}")})

    assert_includes out, "WATCHED 101", "must watch the strictly-greater run it created, not the pre-existing one"
    assert_includes out, "RESULT true", "a green watched run returns true"
  end

  # [integration] `gh run watch` is not a trustworthy verdict on its own. Seen LIVE
  # at Phase 2 validation: a transient GitHub HTTP 500 killed the watch mid-run
  # while the run SUCCEEDED (prod deployed, /up 200). dispatch_and_watch must not
  # abort a ship that actually shipped — on a failed watch it re-queries the run's
  # REAL conclusion (`gh run view`) and lets THAT decide. These stub the watch to
  # fail, then vary what the conclusion poll reports.
  #
  # A shared stub builder: watch always FAILS; `gh run view` returns `run_view`.
  def gha_watch_500_setup(run_view)
    <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]
        end
        return ["", false] if cmd[0, 3] == ["gh", "run", "watch"]   # transient HTTP 500 kills the watcher
        return [#{run_view.inspect}, true] if cmd[0, 3] == ["gh", "run", "view"]
        ["", true]   # gh workflow run
      end
    RUBY
  end

  def test_dispatch_and_watch_trusts_the_run_conclusion_when_the_watch_500s
    # The exact live scenario: watch dies, but `gh run view` reports completed/success.
    out = run_cli(["--yes"], setup: gha_watch_500_setup("completed\tsuccess"),
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "RESULT true",
                     "a watcher HTTP 500 must NOT abort a run that actually succeeded"
  end

  def test_dispatch_and_watch_fails_when_the_run_itself_concluded_failure
    out = run_cli(["--yes"], setup: gha_watch_500_setup("completed\tfailure"),
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "RESULT false",
                     "a genuinely failed run (watch failed AND conclusion=failure) fails closed"
  end

  # [integration] THE protection-pause regression (run 29450907913). A prod-deploy
  # run can sit in GitHub's `waiting` status — a deployment-protection gate holding
  # the deploy. (Historically this was the `production` Environment's required
  # reviewer, held `waiting` for as long as the operator took to click — 3h34m live —
  # before that approval was removed on 2026-07-20; a re-added protection rule would
  # produce it again.) If a transient blip kills `gh run watch` DURING that pause,
  # the fallback must HOLD on the still-live run — a `waiting`/`in_progress` read is
  # not a failed deploy — and only conclude when the run actually finishes. The old
  # fallback polled a 100s budget for `completed` and failed the ship CLOSED over a
  # run that was simply still live; this proves it now waits through the pause and
  # then succeeds. `sleep` is stubbed to a no-op so the "hold" costs no wall-clock.
  def test_dispatch_and_watch_holds_through_a_waiting_protection_pause_then_succeeds
    setup = <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      # The run sits WAITING on a protection gate, moves to in_progress, then completes.
      $views = ["waiting\\t", "waiting\\t", "in_progress\\t", "completed\\tsuccess"]
      $view_i = 0
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]
        end
        return ["", false] if cmd[0, 3] == ["gh", "run", "watch"]   # transient blip mid-hold
        if cmd[0, 3] == ["gh", "run", "view"]
          v = $views[$view_i] || $views.last
          $view_i += 1
          return [v, true]
        end
        ["", true]   # gh workflow run
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "WAITING on a deployment protection gate",
                     "the fallback must RECOGNIZE the protection pause and hold, not fail closed on it"
    assert_includes out, "RESULT true",
                     "a run that was merely paused on a protection gate and then succeeded must ship"
  end

  # [integration] The stuck-timeout / never-appearing run — the fail-closed case
  # that SURVIVES the fix. `gh run view` can never read the run (it keeps erroring),
  # so there is no state to observe: after unreadable_limit consecutive unobserved
  # polls the fallback fails closed. This is distinct from an OBSERVABLE live run
  # (waiting/in_progress) which now holds — only a genuinely UNOBSERVABLE run gives
  # up. A redundant re-verify beats a false-green prod deploy.
  def test_dispatch_and_watch_fails_closed_when_the_run_is_unobservable
    setup = <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]
        end
        return ["", false] if cmd[0, 3] == ["gh", "run", "watch"]
        return ["", false] if cmd[0, 3] == ["gh", "run", "view"]   # gh can NEVER read the run
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "RESULT false",
                     "an unobservable run (gh can't read it at all) must fail closed, not hang or false-green"
    assert_includes out, "unobservable",
                     "…and say WHY it failed closed — the stuck-timeout, not a false conclusion"
  end

  # [unit] The env contract for a repo's OWN deploy script. It gets the workspace's
  # private test DB (so the suite it runs pre-prod can't be poisoned by a concurrent
  # one) and NOTHING else. Emphatically NOT the gate overlay: that sets
  # RAILS_ENV=test, which is right for a gate and WRONG for a production deploy
  # script — the next repo_script app could precompile assets in its deploy, and
  # doing that in the test env would build the wrong artifact and ship it.
  def test_ship_deploy_env_gives_the_script_a_private_db_and_never_rails_env_test
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      setup = %(def repo_path(_repo) = #{dir.inspect})
      out = run_cli(["--yes"], setup: setup, call: %{print(ship_deploy_env("turf-monster").inspect)})

      env = eval(out) # rubocop:disable Security/Eval — the CLI printed its own Hash
      assert_equal "postgres:///turf_monster_ship_test", env["DATABASE_URL"],
                   "the script's suite must run on the ship workspace's PRIVATE DB"
      assert_nil env["RAILS_ENV"],
                 "a PRODUCTION deploy script must never inherit RAILS_ENV=test"
      assert_equal %w[DATABASE_URL], env.keys,
                   "exactly one var — the script's toolchain (PATH/ruby) is the script's business"
    end
  end

  # [unit] A SQLite app's test DB is a file INSIDE the workspace — already private.
  # Handing it a postgres URL would be a live trap, so the overlay is empty.
  def test_ship_deploy_env_is_empty_for_a_file_backed_test_db
    Dir.mktmpdir do |dir|
      plant_database_yml(dir, adapter: "sqlite3")
      setup = %(def repo_path(_repo) = #{dir.inspect})
      out = run_cli(["--yes"], setup: setup, call: %{print(ship_deploy_env("rolio").inspect)})

      assert_equal "{}", out, "a SQLite app needs no DB overlay — its test DB is already inside the workspace"
    end
  end

  # --- repin_consumers: the FROZEN TREE decides, never the primary -------------
  #
  # REGRESSION (carl, PR #517). The re-pin decision (`gems_to_repin`) used to read
  # the PRIMARY's Gemfile. That was safe only because of two invariants THIS BRANCH
  # REMOVED: ship ff'd the primary's `main` to the frozen SHA, and the preflight
  # refused a dirty/off-main primary. Without them the primary's `main` is one
  # release behind BY DEFINITION, and a primary read fails GREEN in the worst
  # direction: the frozen tree branch-refs a gem, the stale primary still shows the
  # old `~> x.y` pin, so the ship prints "already pinned" and DEPLOYS A FROZEN SHA
  # WHOSE GEMFILE POINTS AT A GIT BRANCH — prod building the gem from a branch
  # instead of the published version. The tree the re-pin is built ON is the only
  # tree entitled to decide whether it is needed.

  # A real-git consumer: `main` carries an OLD PINNED Gemfile; `release` (the frozen
  # tip) carries a BRANCH-REF'd one that must be re-pinned before prod.
  def build_repin_fixture(dir)
    clone = build_sibling_fixture(dir)
    File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.8"\n))
    File.write(File.join(clone, "Gemfile.lock"), "GEM\n  studio-engine (0.8.0)\n")
    run_git(clone, "add", "-A")
    run_git(clone, "commit", "-q", "-m", "main: previous release's pin")
    run_git(clone, "push", "-q", "origin", "main")
    run_git(clone, "checkout", "-q", "release")
    run_git(clone, "merge", "-q", "--ff-only", "main")
    File.write(File.join(clone, "Gemfile"),
               %(source "https://rubygems.org"\ngem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"\n))
    run_git(clone, "add", "-A")
    run_git(clone, "commit", "-q", "-m", "release: branch-ref the gem under test")
    run_git(clone, "push", "-q", "origin", "release")
    frozen = git_out(clone, "rev-parse", "HEAD")
    run_git(clone, "checkout", "-q", "main") # the primary sits on a STALE main, as it now always does
    [clone, frozen]
  end

  # [integration] THE regression: the primary's stale `main` says "already pinned",
  # the frozen tree says "branch-ref'd". The ship must believe the FROZEN TREE and
  # re-pin — never print "already pinned" and ship a branch-ref'd Gemfile to prod.
  def test_repin_decides_from_the_frozen_tree_not_the_stale_primary
    Dir.mktmpdir do |dir|
      clone, frozen = build_repin_fixture(dir)
      # Prove the trap is armed: read the PRIMARY and you conclude "nothing to do".
      assert_match(/~> 0\.8/, File.read(File.join(clone, "Gemfile")),
                   "the primary's main must look ALREADY PINNED — that is the lie the old code believed")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPING " + sha["sibling"])})

      refute_includes out, "already pinned",
                      "the stale primary must NOT be allowed to say 'nothing to do': #{out}"
      shipped = out[/SHIPPING (\h{40})/, 1]
      refute_nil shipped, "the re-pin must advance the ship SHA: #{out}"
      refute_equal frozen, shipped, "the ship SHA must move to the re-pin commit"

      # What actually ships: the re-pin commit, on top of frozen, with a REAL pin.
      gemfile = git_out(clone, "show", "#{shipped}:Gemfile")
      assert_match(/studio-engine.*~> 0\.9/, gemfile,
                   "prod must build the PUBLISHED gem — not a git branch")
      refute_match(/branch:/, gemfile, "no branch ref may reach production")
      assert_equal frozen, git_out(clone, "rev-parse", "#{shipped}^"),
                   "the re-pin must sit directly on the QA-frozen SHA — nothing else rides out with it"
      assert_equal shipped, git_out(File.join(dir, "origin.git"), "rev-parse", "release"),
                   "…and be pushed to origin/release"
    end
  end

  # [integration] The mirror: a DIRTY primary on a feature branch, whose Gemfile
  # branch-refs a gem the frozen tree already pinned. The old primary read would
  # decide "re-pin needed", find nothing to rewrite in the frozen tree, stage
  # nothing, and abort at the commit — AFTER THE GEMS PUBLISHED. The frozen tree
  # says "already pinned", so the ship correctly does nothing.
  # --- merge-forward guard: real repos, real merges -------------------------
  #
  # rel-20260809-3b8f3d, 2026-08-09. `main` carried an emergency hotfix pushed
  # outside the cycle; `release` did not contain it. The guard merged in the SHARED
  # PRIMARY, whose uncommitted ledger file made `git checkout release` refuse — and
  # the checkout's result was discarded, so the following `git merge origin/main`
  # ran against `main`, said "Already up to date", and the push sent a stale local
  # branch that origin rejected. Non-fatal, so the sweep assembled a candidate whose
  # release branch would have REVERTED a live production fix.

  # main one commit ahead of release, and the primary parked on a dirty feature
  # branch — the exact floor that defeated the old guard.
  def build_merge_forward_fixture(dir, conflicting: false)
    clone = build_sibling_fixture(dir)
    File.write(File.join(clone, "HOTFIX"), "auth-gate the feed\n")
    run_git(clone, "add", "-A")
    run_git(clone, "commit", "-q", "-m", "hotfix straight to main")
    run_git(clone, "push", "-q", "origin", "main")

    if conflicting
      run_git(clone, "checkout", "-q", "release")
      File.write(File.join(clone, "HOTFIX"), "a DIFFERENT edit to the same file\n")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "release edits the same file")
      run_git(clone, "push", "-q", "origin", "release")
    end

    # The primary is left off-branch and DIRTY, as a live session's desk would be.
    run_git(clone, "checkout", "-q", "-b", "feat/live-session")
    File.write(File.join(clone, "README"), "uncommitted work from another session\n")
    clone
  end

  def merge_forward_call
    %{begin; merge_forward_release_branches([{ "repo" => "sibling" }]); puts("PASSED"); } +
      %{rescue SystemExit => e; puts("ABORTED: " + e.message); end}
  end

  # [integration] THE regression: a dirty primary must NOT stop the merge-forward,
  # and the merge must actually land on origin/release.
  def test_merge_forward_lands_despite_a_dirty_primary_checkout
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir)
      origin = File.join(dir, "origin.git")
      refute_equal git_out(origin, "rev-parse", "main"), git_out(origin, "rev-parse", "release"),
                   "precondition: release must be BEHIND main"

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "PASSED", "a dirty primary must not defeat the guard: #{out}"
      assert system("git", "-C", origin, "merge-base", "--is-ancestor",
                    git_out(origin, "rev-parse", "main"), "release",
                    out: File::NULL, err: File::NULL),
             "origin/release must CONTAIN origin/main after the guard runs"

      # The primary is untouched: same branch, and the uncommitted work survives.
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the guard must never flip the primary's HEAD"
      assert_equal "uncommitted work from another session\n", File.read(File.join(clone, "README")),
                   "another session's uncommitted work must survive the merge-forward"
    end
  end

  # [integration] GEM repos ride the guard. A gem keeps the same release branch
  # and ship workspace as an app, and `bin/release ship` fast-forwards its main
  # via the same non-forced ref push — so a gem main hotfix left unmerged
  # dead-ends the ship at G4 exactly like an app's. A gem group ALONE must drive
  # the merge (the guard takes gem_groups alongside app_groups).
  def test_merge_forward_covers_gem_repos
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir)
      origin = File.join(dir, "origin.git")
      refute_equal git_out(origin, "rev-parse", "main"), git_out(origin, "rev-parse", "release"),
                   "precondition: the gem's release must be BEHIND its main"

      call = %{begin; merge_forward_release_branches([], gem_groups: [{ "repo" => "sibling" }]); } +
             %{puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end}
      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: call)

      assert_includes out, "PASSED", "a gem group alone must drive the guard: #{out}"
      assert system("git", "-C", origin, "merge-base", "--is-ancestor",
                    git_out(origin, "rev-parse", "main"), "release",
                    out: File::NULL, err: File::NULL),
             "the GEM repo's origin/release must CONTAIN origin/main after the guard runs"
    end
  end

  # [integration] Already contained → a clean no-op that pushes nothing.
  def test_merge_forward_is_a_no_op_when_release_already_contains_main
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir) # main == release out of the box
      origin = File.join(dir, "origin.git")
      before = git_out(origin, "rev-parse", "release")

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "PASSED"
      assert_equal before, git_out(origin, "rev-parse", "release"),
                   "nothing may be pushed when main is already contained"
      refute_includes out, "main moved ahead"
    end
  end

  # [integration] A CONFLICT must abort loudly, push nothing, and leave the
  # primary alone — the old guard's failure was continuing non-fatally.
  def test_merge_forward_aborts_on_a_conflict_and_pushes_nothing
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir, conflicting: true)
      origin = File.join(dir, "origin.git")
      before = git_out(origin, "rev-parse", "release")

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "ABORTED", "a conflicted merge-forward must abort, never continue: #{out}"
      assert_includes out, "merge-forward CONFLICT"
      assert_includes out, "no primary checkout was touched"
      # …and the claim is SCOPED: it speaks for this repo, not the whole sweep.
      assert_includes out, "Nothing was pushed FOR sibling",
                      "the abort must not claim the sweep left nothing behind"
      refute_includes out, "PASSED"

      assert_equal before, git_out(origin, "rev-parse", "release"),
                   "a conflicted merge must push NOTHING"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary stays where the operator left it"
    end
  end

  # [integration] A FAILED FETCH must fail CLOSED, not judge containment from a
  # stale ref. This is the clause guarding the very incident class: origin/main is
  # how we learn what production carries, so a fetch that did not run means the
  # answer describes an older world.
  def test_merge_forward_fails_closed_when_the_pre_check_fetch_fails
    Dir.mktmpdir do |dir|
      clone = build_merge_forward_fixture(dir)
      # Point origin at nothing: the fetch cannot succeed.
      run_git(clone, "remote", "set-url", "origin", File.join(dir, "no-such-origin.git"))

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "ABORTED", "a failed fetch must abort, not proceed on a stale ref: #{out}"
      assert_includes out, "refusing to judge merge-forward"
      refute_includes out, "PASSED"
    end
  end

  # [integration] A FAILED PUSH must abort. The merge succeeded locally, but the
  # branch never moved — proceeding would gate and deploy a tree that still lacks
  # the hotfix.
  def test_merge_forward_aborts_when_the_push_is_refused
    Dir.mktmpdir do |dir|
      clone  = build_merge_forward_fixture(dir)
      origin = File.join(dir, "origin.git")
      before = git_out(origin, "rev-parse", "release")
      # Refuse every push into the bare origin.
      hook = File.join(origin, "hooks", "pre-receive")
      FileUtils.mkdir_p(File.dirname(hook))
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)

      out = run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}), call: merge_forward_call)

      assert_includes out, "ABORTED", "a refused push must abort: #{out}"
      assert_includes out, "could not push the merge-forward"
      refute_includes out, "PASSED"
      assert_equal before, git_out(origin, "rev-parse", "release"), "release must not have moved"
    end
  end

  # [integration] MULTI-REPO: the guard runs per app, and one repo's success must
  # not mask another's failure. The second repo conflicts; the first has already
  # merged and pushed — which is exactly why the abort text must not claim
  # "nothing was pushed" at sweep grain.
  def test_merge_forward_across_two_repos_aborts_on_the_second_and_says_what_landed
    Dir.mktmpdir do |dir_a|
      Dir.mktmpdir do |dir_b|
        clone_a = build_merge_forward_fixture(dir_a)
        clone_b = build_merge_forward_fixture(dir_b, conflicting: true)
        origin_a = File.join(dir_a, "origin.git")

        setup = <<~RUBY
          PATHS = { "a" => #{clone_a.inspect}, "b" => #{clone_b.inspect} }
          def repo_path(repo) = PATHS.fetch(repo)
        RUBY
        out = run_cli(["--yes"], setup: setup,
                      call: %{begin; merge_forward_release_branches([{ "repo" => "a" }, { "repo" => "b" }]); } +
                            %{puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

        assert_includes out, "ABORTED", "the second repo's conflict must abort the sweep: #{out}"
        assert_includes out, "merge-forward CONFLICT in b"
        refute_includes out, "PASSED"

        # Repo A really did land, so the message must not imply a clean slate.
        assert system("git", "-C", origin_a, "merge-base", "--is-ancestor",
                      git_out(origin_a, "rev-parse", "main"), "release",
                      out: File::NULL, err: File::NULL),
               "repo a's merge-forward landed before b failed"
        assert_includes out, "earlier repo's merge-forward",
                        "the abort must warn that earlier work already landed"
        assert_includes out, "Do NOT `reset`",
                        "and must steer the operator off the destructive cleanup"
      end
    end
  end

  def test_a_dirty_primary_cannot_force_a_repin_the_frozen_tree_does_not_need
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.9"\n))
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "release: already pinned")
      run_git(clone, "push", "-q", "origin", "main")
      frozen = git_out(clone, "rev-parse", "HEAD")

      # A live session's floor: off main, and its Gemfile branch-refs the gem.
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "Gemfile"),
                 %(source "https://rubygems.org"\ngem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "wip"\n))

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("PASSED " + sha["sibling"]); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "PASSED", "a dirty primary must not abort the re-pin AFTER the gems published: #{out}"
      assert_includes out, "already pinned", "the FROZEN tree is already pinned — there is nothing to do"
      assert_includes out, "PASSED #{frozen}", "the ship SHA must not move"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary is never checked out"
    end
  end

  # --- partial-ship RETRY: the re-pin is idempotent BY IDENTITY ---------------
  #
  # REGRESSION (jasper, PR #517 — reproduced on real git before it was fixed).
  # Auto-re-pin mints a NEW commit on top of the frozen SHA and advances the ship
  # SHA to it, but `qa_shas` still holds the ORIGINAL frozen SHA and nothing rewrites
  # it. A ship that published the gems, pushed the re-pin, and THEN died left
  # origin/release = repin₁ with qa_shas = frozen — so the RETRY reset to frozen, saw
  # the branch-ref'd Gemfile, decided a re-pin was needed, and then read its OWN
  # re-pin commit as un-QA'd drift:
  #
  #   ✗ origin/release (912a444) drifted past the QA-frozen SHA (a3c1c92)
  #     — re-run `bin/release prepare` to re-QA before re-pinning
  #
  # AFTER the gems had published. The ship could not be resumed. Underneath that
  # guard sat a second failure: the retry would mint repin₂ — a distinct commit
  # object with an identical tree — whose push is non-fast-forward against repin₁.
  # Both are cured by never minting a rival: recognize the re-pin already on the
  # branch and SHIP IT.

  # A consumer mid-partial-ship: `release` already carries repin₁, `qa_shas` still
  # says frozen. Returns [clone, frozen, repin1].
  def build_partial_ship_fixture(dir)
    clone, frozen = build_repin_fixture(dir)
    run_git(clone, "checkout", "-q", "--detach", frozen)
    File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.9"\n))
    File.write(File.join(clone, "Gemfile.lock"), "GEM\n  studio-engine (0.9.0)\n")
    run_git(clone, "add", "-A")
    run_git(clone, "commit", "-q", "-m", "repin studio-engine ~> 0.9")
    repin1 = git_out(clone, "rev-parse", "HEAD")
    run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
    run_git(clone, "checkout", "-q", "main")
    [clone, frozen, repin1]
  end

  # The lock this writes must have BUNDLER'S REAL SHAPE, not a suggestive
  # approximation: the re-pin now reads the resolved version back out of it
  # (Release::ShipSequence.lock_bump_landed?) before committing, and a resolution
  # lives at a 4-space indent under `specs:`. The old two-space sketch parsed as
  # nothing at all, so a stub that kept it would have made the guard look broken
  # while the shipping code was correct.
  REPIN_LOCK_STUB = <<~'RUBY'
    def bundle_lock(path, gem, attempts: 3, conservative: false, expect: nil)
      File.write(File.join(path, "Gemfile.lock"),
                 "GEM\n  remote: https://rubygems.org/\n  specs:\n    #{gem} (0.9.0)\n")
    end
  RUBY

  # [integration] THE fix: the retry REUSES the re-pin already on origin/release,
  # mints no rival commit, and ships it. Before the fix this aborted.
  def test_a_partial_ship_retry_reuses_the_repin_already_on_release
    Dir.mktmpdir do |dir|
      clone, frozen, repin1 = build_partial_ship_fixture(dir)
      origin = File.join(dir, "origin.git")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPING " + sha["sibling"])})

      assert_includes out, "ALREADY on origin/release", "the retry must RECOGNIZE its own prior re-pin: #{out}"
      assert_includes out, "SHIPPING #{repin1}",
                       "…and ship THAT commit — the act is already done, not to be done twice"
      assert_equal repin1, git_out(origin, "rev-parse", "release"),
                   "no rival commit may be pushed — a second re-pin is a non-fast-forward that can never land"
    end
  end

  # [integration] FAILS CLOSED on genuine drift: a real CODE commit landed on
  # release after the freeze. That is exactly what the guard exists for — it must
  # still abort, and must not mistake a code commit for a mechanical re-pin.
  def test_a_retry_still_aborts_when_real_code_drifted_onto_release
    Dir.mktmpdir do |dir|
      clone, frozen, = build_partial_ship_fixture(dir)
      # …and someone merged real code on top of the re-pin, post-freeze.
      run_git(clone, "checkout", "-q", "--detach", git_out(clone, "rev-parse", "origin/release"))
      File.write(File.join(clone, "app.rb"), "un-QA'd feature")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "a feature that never went through QA")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
      drifted = git_out(clone, "rev-parse", "HEAD")
      run_git(clone, "checkout", "-q", "main")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPED " + sha["sibling"]); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "un-QA'd code on release must still abort the ship: #{out}"
      assert_includes out, "un-QA'd", "…and say why"
      refute_includes out, "REUSING", "a code commit is NOT a mechanical re-pin"
      assert_equal drifted, git_out(File.join(dir, "origin.git"), "rev-parse", "release"),
                   "the ship must not have pushed anything"
    end
  end

  # [integration] The IDENTITY check, not a "looks pinned" check. A Gemfile-only
  # commit on release that pins the WRONG version has no branch ref left — so a
  # weaker "nothing left to re-pin?" test would wave it through and prod would build
  # 0.7. Byte-identity to what THIS run would write is the only safe standard.
  def test_a_retry_aborts_when_release_pins_a_version_this_ship_did_not_publish
    Dir.mktmpdir do |dir|
      clone, frozen = build_repin_fixture(dir)
      run_git(clone, "checkout", "-q", "--detach", frozen)
      File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.7"\n))
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "pinned — but to a version this ship never published")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
      run_git(clone, "checkout", "-q", "main")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + REPIN_LOCK_STUB
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.9.0" }, sha); } +
                          %{puts("SHIPPED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED",
                      "a Gemfile pinned to a version this ship never published must NOT be reused: #{out}"
      refute_includes out, "REUSING", "'no branch ref left' is not the same as 'this is my re-pin'"
    end
  end

  # --- ship preflight: the dirty-primary ABORT CLASS is gone ------------------
  # It used to refuse any app primary that was dirty or off `main`, because the ship
  # ff'd + deployed from that tree. It aborted a REAL production ship (after the gems
  # published) over a concurrent session's staged work. The deploy now runs from its
  # own workspace, so an app primary is no longer input: the preflight PINS the ship
  # workspaces, GATES only the gem builds (which really are built from a primary),
  # and merely ADVISES on a dirty app primary. Drive ship_preflight directly with
  # the git seams stubbed (DRY=false via --yes) so no real sibling git runs.
  APP_GROUPS = %q([{ "repo" => "mcritchie-studio" }, { "repo" => "turf-monster" }])
  GEM_GROUPS = %q([{ "repo" => "studio-engine" }])
  SHIP_SHAS  = %q({ "mcritchie-studio" => "abc1234", "turf-monster" => "def5678", "studio-engine" => "aaa1111" })

  # The workspace pin is the preflight's own I/O; these tests are about the VERDICT,
  # so stub it out (its real behavior is proven on a live git fixture elsewhere).
  NO_WORKSPACE = <<~RUBY
    def with_ship_workspace(repo) = yield
    def ship_workspace!(repo, sha) = "/tmp/_ship/\#{repo}"
  RUBY

  # [integration] THE acceptance: a dirty, off-main app primary — a live feature
  # session's floor — must NOT abort the ship. It gets a note and the deploy rides on.
  def test_ship_preflight_does_not_abort_on_a_dirty_off_main_app_primary
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        if repo == "turf-monster"
          { "repo" => repo, "branch" => "feat/live-session", "dirty" => true,
            "dirty_files" => ["app/models/pick.rb"], "tracked_dirty" => ["app/models/pick.rb"] }
        else
          { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
        end
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, [], #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "PASSED", "a dirty app primary must never abort a production ship: #{out}"
    refute_includes out, "ABORTED"
    assert_includes out, "NOTE, not a blocker", "…it says so plainly"
    assert_includes out, "turf-monster", "the note names the repo"
    assert_includes out, "rescue/turf-monster-", "…and prints the labeled-branch rescue"
    assert_includes out, "Nothing here is discarded, and nothing is stashed",
                    "it must PROMISE the session's work survives — never offer a stash or a discard"
  end

  # [integration] The ONE primary-state hazard that survives: a gem is BUILT from its
  # primary (gem build packages what is on disk), so a modified TRACKED file there
  # would be PUBLISHED — irreversibly. That aborts, BEFORE anything is published, and
  # the abort hands over the rescue.
  def test_ship_preflight_aborts_on_a_gem_primary_with_modified_tracked_files
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => ["lib/studio/version.rb"], "tracked_dirty" => ["lib/studio/version.rb"] } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "uncommitted tracked code in a gem repo would be PUBLISHED — fail closed"
    refute_includes out, "PASSED"
    assert_includes out, "studio-engine",         "the abort names the gem"
    assert_includes out, "lib/studio/version.rb", "…and the file that would ship"
    assert_includes out, "BEFORE publishing",     "…and that nothing has been published yet"
    assert_includes out, "rescue/studio-engine-", "…and hands over the labeled-branch rescue"
    assert_includes out, "nothing is stashed and nothing is discarded",
                    "never tell an operator to stash or discard a live session's work"
  end

  # [integration] UNTRACKED files in a gem primary are NOT a publish hazard — the
  # gemspec's file list is `git ls-files`, so they cannot be packaged. They must not
  # gate a ship (that would just re-invent the abort class we removed).
  def test_ship_preflight_ignores_untracked_files_in_a_gem_primary
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => ["scratch.rb"], "tracked_dirty" => [] } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "PASSED", "an untracked scratch file in a gem repo is not packaged — it must not gate the ship"
    refute_includes out, "ABORTED"
  end

  # [integration] A generated artifact (a retro doc / the worktree ledger) routinely
  # sits uncommitted and must not gate a gem build either — the same narrow allowlist.
  def test_ship_preflight_ignores_generated_artifacts_in_a_gem_primary
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        files = ["docs/agents/maintenance/delete-later.md"]
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => files, "tracked_dirty" => files } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "PASSED", "a generated artifact is not real dirt"
    refute_includes out, "ABORTED"
  end

  # [integration] The preflight PINS each app's ship workspace at the frozen SHA
  # before anything is published — so a broken worktree aborts while the release is
  # still fully recoverable, never mid-train.
  def test_ship_preflight_pins_the_ship_workspaces_at_the_frozen_sha
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
      def with_ship_workspace(repo) = yield
      def ship_workspace!(repo, sha)
        $stdout.puts("PIN \#{repo} @ \#{sha}")
        "/tmp/_ship/\#{repo}"
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "ship_preflight(#{APP_GROUPS}, [], #{SHIP_SHAS}); puts('PASSED')")

    assert_includes out, "PIN mcritchie-studio @ abc1234", "the hub's ship workspace is pinned at its frozen SHA"
    assert_includes out, "PIN turf-monster @ def5678",     "…and the satellite's at its own"
    assert_includes out, "PASSED"
  end

  def test_ship_dry_run_previews_the_preflight_without_touching_git
    # In dry-run the preflight prints its plan and runs NO real git (so a dry-run
    # never aborts on a legitimately-dirty dev sibling). repo_git_state raises if
    # consulted, proving the DRY branch skips it.
    setup = SHIP_STUB + %(\ndef repo_git_state(*); raise "git consulted in dry-run preflight"; end)
    out = run_cli(["--dry-run"], call: "ship", setup: setup)
    assert_includes out, "ship preflight", "ship previews the preflight in dry-run"
    assert_includes out, "ship workspace", "…and previews the workspace pin the real run does"
  end

  # [integration] Real code dirt beside a generated artifact: in a GEM primary it
  # still gates (it would be published); in an APP primary it is only advised on.
  def test_ship_preflight_gem_gate_separates_real_dirt_from_a_generated_artifact
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        files = ["docs/agents/audits/retro-rel-1.md", "lib/studio/engine.rb"]
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => files, "tracked_dirty" => files } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "real code dirt in a gem repo would be published — it still gates"
    assert_includes out, "lib/studio/engine.rb", "the abort names the real dirty file"
    refute_includes out, "retro-rel-1.md", "the generated artifact is not named as dirt"
  end

  # --- production smoke seal: cwd-anchored + genuinely NON-BLOCKING ------------
  # rel-20260705-8fe04b partial ship: `bin/release ship` run from the projects
  # root (not the hub checkout) reached step 5c, where the seal invoked a bare
  # CWD-RELATIVE `bin/prod-smoke` — Open3.capture2e RAISES Errno::ENOENT on an
  # unresolvable path (it never returns ok=false), so the "non-blocking SEAL"
  # aborted the ship AFTER the prod deploy but BEFORE step 6's Conductor.ship!,
  # stranding the board at `assembled`. Two guarantees under test:
  #   1. the smoke invocation is ANCHORED to the hub checkout
  #      (chdir: repo_path(APP)) — cwd-independent, like every other
  #      repo-scoped command in this CLI;
  #   2. an unresolvable/missing script DEGRADES to a red seal (+ the recorded
  #      verdict + rollback guidance), never an uncaught exception — the
  #      documented "alerts but never aborts the ship" contract.

  # Inert record seam: seal/board writes are observed (SEAL-WRITE), never run
  # heroku. The REAL Release::SmokeSeal model is exercised (bin/release.rb
  # require_relatives it standalone).
  SEAL_STUB = <<~'RUBY'
    def record_release_event(*_a, **_k); end
    def conductor(ruby, read_only: false)
      $stdout.puts("SEAL-WRITE " + ruby.gsub("\n", " "))
      {}
    end
  RUBY

  # (app_groups, ship_sha, rel_slug) — the hub deployed on this ship.
  SEAL_ARGS = %q([{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => "cafebabe11111111111111111111111111111111" }, "rel-seal")

  def test_seal_anchors_prod_smoke_to_the_hub_checkout
    setup = SEAL_STUB + <<~'RUBY'
      def repo_path(_repo) = "/srv/projects/mcritchie-studio"
      def sh(*a, capture: false, chdir: nil)
        $stdout.puts("SMOKE-CHDIR #{chdir.inspect}") if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED')")

    assert_includes out, %(SMOKE-CHDIR "/srv/projects/mcritchie-studio"),
                     "the smoke invocation must anchor to repo_path(APP), never the caller's cwd"
    assert_includes out, "SEAL-RETURNED"
  end

  def test_seal_degrades_a_raising_smoke_invocation_to_a_red_seal_not_an_abort
    # `sh` raising SystemCallError is EXACTLY what the real helper does on an
    # unresolvable path — Open3.capture2e raises Errno::ENOENT, it never
    # returns ok=false.
    setup = SEAL_STUB + <<~'RUBY'
      def repo_path(_repo) = "/srv/projects/mcritchie-studio"
      def sh(*a, capture: false, chdir: nil)
        raise Errno::ENOENT, "bin/prod-smoke" if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED'); rescue SystemCallError => e; puts('RAISED: ' + e.class.name); end")

    assert_includes out, "SEAL-RETURNED",
                     "an unresolvable smoke script must degrade, never raise out of the seal"
    refute_includes out, "RAISED:", "the seal is non-blocking by contract — no uncaught SystemCallError"
    assert_includes out, "PRODUCTION SMOKE SEAL FAILED", "the degraded run is a RED seal with the alert"
    assert_includes out, "heroku rollback", "the rollback guidance still prints"
    seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") }
    assert seal_write, "the red seal is still recorded on the release"
    assert_includes seal_write, "passed: false"
    assert_includes seal_write, "bin/prod-smoke", "the seal summary carries the underlying error"
  end

  def test_seal_green_run_records_green_and_prints_no_rollback
    setup = SEAL_STUB + <<~'RUBY'
      def repo_path(_repo) = "/srv/projects/mcritchie-studio"
      def sh(*a, capture: false, chdir: nil)
        return ["1 spec, 0 failures\n", true] if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED')")

    seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") }
    assert seal_write, "a green run records the seal"
    assert_includes seal_write, "passed: true"
    assert_includes seal_write, "@qa-readonly green", "the green summary is unchanged"
    refute_includes out, "PRODUCTION SMOKE SEAL FAILED"
    refute_includes out, "heroku rollback", "no rollback guidance on a green seal"
    assert_includes out, "SEAL-RETURNED"
  end

  def test_seal_normal_red_run_still_records_red_and_prints_rollback_without_aborting
    # A smoke suite that RAN and failed (ok=false, no raise) keeps its existing
    # shape: red seal, "see ship log" summary, rollback guidance, normal return.
    setup = SEAL_STUB + <<~'RUBY'
      def repo_path(_repo) = "/srv/projects/mcritchie-studio"
      def sh(*a, capture: false, chdir: nil)
        return ["2 specs failed\n", false] if a[0] == "bin/prod-smoke"
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED')")

    seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") }
    assert seal_write
    assert_includes seal_write, "passed: false"
    assert_includes seal_write, "see ship log", "a normal red run keeps its summary"
    assert_includes out, "PRODUCTION SMOKE SEAL FAILED"
    assert_includes out, "heroku rollback"
    assert_includes out, "SEAL-RETURNED", "a red seal never aborts the ship"
  end

  # [integration] Across the REAL `sh` → Open3 boundary (no sh stub): the script
  # resolves via repo_path(APP) even when the process cwd is a foreign directory
  # — the exact incident shape (ship run from the projects root).
  def test_seal_integration_resolves_the_smoke_script_via_the_hub_checkout_not_the_cwd
    Dir.mktmpdir do |dir|
      hub = File.join(dir, "hub")
      Dir.mkdir(hub)
      Dir.mkdir(File.join(hub, "bin"))
      script = File.join(hub, "bin", "prod-smoke")
      File.write(script, "#!/usr/bin/env sh\necho SMOKE-RAN-FROM-HUB\nexit 0\n")
      File.chmod(0o755, script)
      elsewhere = File.join(dir, "elsewhere")
      Dir.mkdir(elsewhere)

      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %(Dir.chdir(#{elsewhere.inspect}); begin; production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED'); rescue SystemCallError => e; puts('RAISED: ' + e.class.name); end))

      assert_includes out, "SMOKE-RAN-FROM-HUB",
                      "the script must resolve via repo_path(APP) from a foreign cwd"
      refute_includes out, "RAISED:", "a foreign cwd must never ENOENT-abort the seal"
      assert_includes out, "SEAL-RETURNED"
      seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") }
      assert seal_write
      assert_includes seal_write, "passed: true"
    end
  end

  # [integration] A hub checkout genuinely MISSING the script: the real Open3
  # Errno::ENOENT degrades to a recorded red seal + rollback, returning normally.
  def test_seal_integration_missing_script_degrades_to_a_red_seal_across_the_real_sh_boundary
    Dir.mktmpdir do |dir|
      hub = File.join(dir, "hub") # exists, but has NO bin/prod-smoke
      Dir.mkdir(hub)

      setup = SEAL_STUB + %(def repo_path(_repo) = #{hub.inspect}\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %(Dir.chdir(#{hub.inspect}); begin; production_smoke_seal(#{SEAL_ARGS}); puts('SEAL-RETURNED'); rescue SystemCallError => e; puts('RAISED: ' + e.class.name); end))

      assert_includes out, "SEAL-RETURNED",
                      "a genuinely missing script degrades (real Open3 ENOENT), never raises out"
      refute_includes out, "RAISED:"
      assert_includes out, "PRODUCTION SMOKE SEAL FAILED"
      assert_includes out, "heroku rollback"
      seal_write = out.lines.find { |l| l.start_with?("SEAL-WRITE") }
      assert seal_write, "the red seal is recorded even when the script never ran"
      assert_includes seal_write, "passed: false"
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
  # `prepare` (Avi assembled QA intent) and `ship` (Steffon shipped intent) auto-record
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
      return { "slug" => "rel-ship" } if ruby.include?("last_shipped") # the minimal STABLE read (pre-claim)
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
    assert_includes out, "push heroku bbbbbbb:refs/heads/main",
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
