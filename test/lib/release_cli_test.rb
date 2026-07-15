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

  def run_ruby(script)
    env = SessionEnv.neutralized("MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir)
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

  # --- system-tier browser guard (the hub's gate runs test:system) ------------

  def test_system_tier_is_detected_from_the_registered_gate_command
    # The hub's registered command carries the system tier; the satellites'
    # integration subset does not — so only the hub's gate host needs a browser.
    assert_equal "true", eval_helper(%(system_tier?("bin/rails db:test:prepare test test:system")))
    assert_equal "false", eval_helper(%(system_tier?("bin/rails test test/integration")))
    assert_equal "false", eval_helper(%(system_tier?("bin/rails test")))
  end

  def test_missing_chrome_aborts_in_the_ENV_class_not_as_a_red_suite
    # THE MISATTRIBUTION GUARD. Without Chrome, Selenium fails INSIDE the suite and
    # the gate would read a red suite -> eject/revert guidance -> a good PR ejected
    # for a missing browser. It must abort in the ENV class instead, with the same
    # "nothing to eject or revert" wording as the bundle/DB guards.
    out = guard_verdict("mcritchie-studio", "bin/rails db:test:prepare test test:system")

    assert out.start_with?("ABORTED"), "a system-tier gate on a browserless host must ABORT, not run the suite"
    assert_includes out, "NOT a release regression"
    assert_includes out, "nothing to eject or revert"
    assert_includes out, "NO Chrome"
  end

  def test_the_browser_guard_leaves_the_integration_subset_alone
    # Satellites gate on `bin/rails test test/integration` — no browser required,
    # so a browserless host must NOT be blocked from running their gate.
    out = guard_verdict("turf-monster", "bin/rails test test/integration")

    assert_equal "NO_ABORT", out, "the browser guard must only bind commands that run test:system"
  end

  # Run the browser guard with chrome_available? FORCED false, so the verdict is
  # deterministic on any host (this suite also runs on CI's Linux runner). abort!
  # -> Kernel#abort raises SystemExit carrying the message, so the guard's abort is
  # catchable and its wording assertable without a nonzero exit.
  def guard_verdict(repo, cmd)
    run_ruby(<<~RUBY)
      load #{BIN.inspect}
      def chrome_available? = false
      begin
        assert_system_test_browser!(#{repo.inspect}, #{cmd.inspect})
        print "NO_ABORT"
      rescue SystemExit => e
        print "ABORTED|" + e.message.to_s
      end
    RUBY
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
  # assertable in-process (the same trick guard_verdict uses).
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
  SWEEP_FLOW_STUB = GATE_GIT_STUB + %(def repo_path(_repo) = #{stub_repo.inspect}\n) + <<~'RUBY'
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
    def sh(*a, **k)
      g = gate_git(a, k)
      return g if g
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

    # The banner names what the step actually runs — each app's registered
    # qa_test_cmd (the old "integration + e2e-smoke" overstated this gate) — and
    # WHERE it runs it: the isolated gate workspace, never the shared primary.
    assert_includes out, "pre-QA gate: each app's registered qa_test_cmd on origin/release " \
                         "(isolated gate workspace, before any QA deploy)"
    # The preview names the WORKSPACE the suite would run in (…/.worktrees/_gate),
    # not the primary checkout — the plan matches what a real run executes.
    assert_includes out, "[dry-run] pre-QA gate mcritchie-studio: " \
                         "(cd #{gate_workspace_path('mcritchie-studio')}) bin/rails test:integration @ origin/release"
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
    # Per-test lock dir — NEVER the real one: a live conductor's lock file is not
    # this test's to flock (activity-1307). The gate no longer TAKES the lock at
    # all (its suite runs in the isolated workspace), but repo_path/lock resolution
    # still reads the env, so keep every child pointed at a throwaway dir.
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/failing-suite"
        def sh(*a, **k)
          $stdout.puts("GIT " + a.join(" ")) if a[0] == "git"
          g = gate_git(a, k)
          return g if g
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
      assert_includes out, "Bundler::GemNotFound",
                      "the abort distinguishes a boot-time GemNotFound (env) from a real regression"
      refute_includes out, "PASSED"
      # The old gate checked `release` out ON THE PRIMARY and restored `main` in an
      # ensure; both are GONE. Even on the red path the primary's HEAD is never
      # touched — there is nothing to restore, so nothing can be left flipped when
      # the gate aborts (a killed gate used to strand the shared checkout on
      # `release`).
      git_ops = out.lines.select { |l| l.start_with?("GIT ") }
      refute(git_ops.any? { |l| l.include?(" checkout ") },
             "the gate must never checkout ANYTHING on the primary: #{git_ops.inspect}")
    end
  end

  # --- gate isolation: the suite runs in a PRIVATE worktree, not the primary ---
  #
  # ROOT CAUSE (rel-20260711-7f2913): the gate ran its multi-minute suite on the
  # SHARED primary after a transient `git checkout release`. The test env autoloads
  # LAZILY (config.eager_load = ENV["CI"].present? → false locally), so ANY
  # concurrent `git checkout` in that primary — another agent session, a hand-run
  # command; the flock is ADVISORY and binds only other bin/release invocations —
  # tore the code snapshot mid-run and the gate FALSE-FAILED green code (a reviewer
  # nearly ejected a good PR on it). The fix is structural: pin a private detached
  # worktree at the SHA under test, with its own test DB, that no other process
  # knows exists. These tests pin the two halves of that contract — where the suite
  # runs, and that the primary is never flipped.

  # [unit] The gate resolves origin/release's SHA, pins the isolated workspace at
  # it, and runs the suite THERE (chdir = <repo>/.worktrees/_gate) — never a
  # `git checkout` of `release` (or anything else) on the primary.
  def test_pre_qa_gate_runs_the_suite_in_the_isolated_workspace_never_on_the_primary
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def sh(*a, **k)
          $stdout.puts("GIT #{a[3]} #{a[4]}") if a[0] == "git"
          $stdout.puts("SUITE-CHDIR #{k[:chdir]}") if a[0] == "bin/suite"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      workspace = File.join(dir, ".worktrees", "_gate")
      assert_includes out, "SUITE-CHDIR #{workspace}",
                      "the suite must run IN the isolated gate workspace, not the primary: #{out}"
      assert_includes out, "GIT rev-parse origin/release", "the gate resolves the SHA under test…"
      assert_includes out, "GIT worktree add", "…and pins a detached worktree at it"
      assert_includes out, GATE_SHA[0, 7], "the workspace is pinned at the resolved SHA"
      git_ops = out.lines.select { |l| l.start_with?("GIT ") }
      refute(git_ops.any? { |l| l.include?("checkout") },
             "NO `git checkout release` (or `checkout main` restore) on the primary — that transient " \
             "flip is exactly what tore the lazily-autoloaded suite: #{git_ops.inspect}")
      assert_includes out, "PASSED"
    end
  end

  # [unit] The gate suite is spawned under the GATE ENV OVERLAY (Release::GateEnv):
  # the agent-session ids are UNSET (nil ⇒ unset in the child, so every grandchild
  # the suite spawns is session-less exactly like CI), RAILS_ENV is pinned to test,
  # and BOTH DB seams point at the gate's PRIVATE test DB (never the primary's
  # shared <app>_test, which a concurrent suite can pollute mid-run).
  #
  # BOTH seams, because they are not equivalent: TEST_DATABASE_URL is HAND-ROLLED
  # (only an app whose database.yml renders it honours it — the hub does,
  # turf-monster does NOT), while DATABASE_URL is a Rails BUILTIN that every app
  # merges. Dropping either one re-opens the hole this closed: with TEST_DATABASE_URL
  # alone, turf's gate resolved the SHARED `turf_monster_test` and db:test:prepare
  # would have PURGED it.
  def test_pre_qa_gate_spawns_the_suite_under_the_gate_env_overlay
    Dir.mktmpdir do |dir|
      plant_database_yml(dir) # a postgres app → the gate overlays its private DB url
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def sh(*a, **k)
          $stdout.puts("SUITE-ENV #{k[:env].inspect}") if a[0] == "bin/suite"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      env_line = out.lines.find { |l| l.start_with?("SUITE-ENV") }
      assert env_line, "the suite must be spawned with an env overlay: #{out}"
      assert_includes env_line, %("CLAUDE_CODE_SESSION_ID"=>nil),
                      "the agent-session id is UNSET for the gate's whole process tree (CI names no session)"
      assert_includes env_line, %("CODEX_THREAD_ID"=>nil), "…the Codex twin too"
      assert_includes env_line, %("RAILS_ENV"=>"test"),
                      "every gate command is a TEST command — unpinned, db:test:prepare would merge the DB url " \
                      "into DEVELOPMENT's config"
      assert_includes env_line, %("DATABASE_URL"=>"postgres:///sibling_gate_test"),
                      "the Rails BUILTIN seam — the one that actually holds for an app whose database.yml " \
                      "never heard of TEST_DATABASE_URL (turf-monster)"
      assert_includes env_line, %("TEST_DATABASE_URL"=>"postgres:///sibling_gate_test"),
                      "…and the hand-rolled seam the hub's database.yml renders, naming the SAME gate DB"
      assert_includes out, "PASSED"
    end
  end

  # --- the PRIVATE-DB invariant: PROVE it, never assume it ---------------------
  #
  # BLOCKER (Avi, review of PR #511): the "private test DB" rested on an ENV overlay
  # alone — and an env var only lands if the app's config/database.yml actually reads
  # it. TEST_DATABASE_URL is a HAND-ROLLED seam: the hub renders it, turf-monster
  # does NOT (a bare `database: turf_monster_test`). So for turf the overlay was
  # INERT — the gate would have run its suite against the SHARED `turf_monster_test`,
  # and `db:test:prepare` would have PURGED it under whatever concurrent suite was
  # using it. The overlay now also carries DATABASE_URL (the Rails builtin EVERY app
  # merges), but a guarantee resting on every future app's config being right is a
  # CONVENTION, not an invariant.
  #
  # assert_private_gate_db! makes it an invariant: BOOT the app in the workspace, read
  # back the database it ACTUALLY connected to (`bin/rails runner` → `GATEDB=…`), and
  # REFUSE to run unless GateWorkspace.private_db? says it belongs to this gate. It
  # runs BEFORE db:test:prepare — assert first, destroy second.

  # A gate stub whose DB PROBE answers `resolved` (`%WORKSPACE%` ⇒ the workspace the
  # gate is probing; "" ⇒ a probe that fails to BOOT), and which prints each step it
  # is asked to run — PROBE / DB-PREPARE / SUITE — so a test can assert both the
  # verdict AND the order. The repo's own config/database.yml (planted by the caller)
  # still decides whether an overlay url reaches the probe at all.
  def db_probe_stub(dir, resolved)
    %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
      %(def repo_path(_repo) = #{dir.inspect}\n) +
      %(RESOLVED = #{resolved.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def sh(*a, **k)
          # The probe's ANSWER is the subject here, so it is served before the canned
          # plumbing (GATE_GIT_STUB) gets a look at the command.
          if a[0] == "bin/rails" && a[1] == "runner"
            $stdout.puts("PROBE")
            return ["could not connect", false] if RESOLVED.empty?
            return ["GATEDB=" + RESOLVED.sub("%WORKSPACE%", k[:chdir].to_s), true]
          end
          $stdout.puts("DB-PREPARE") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          if a[0] == "bin/suite"
            $stdout.puts("SUITE")
            $stdout.puts("SUITE-ENV #{k[:env].inspect}")
          end
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
  end

  # [unit] THE BLOCKER. The probe resolves the SHARED primary test DB (turf's
  # database.yml ignoring the overlay — the measured, real failure) → the gate
  # REFUSES, and it refuses BEFORE `db:test:prepare` ever runs. That ORDER is the
  # whole point: db:test:prepare PURGES the database it is pointed at, so a check
  # that ran after it would be an autopsy, not a guard — the concurrent suite's data
  # would already be gone.
  def test_pre_qa_gate_refuses_a_shared_test_db_before_db_test_prepare_can_purge_it
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      out = run_cli(["--yes"], setup: db_probe_stub(dir, "turf_monster_test"),
                    call: %{begin; pre_qa_gate([{ "repo" => "turf-monster" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      lines = out.lines.map(&:strip)
      assert_includes lines, "PROBE", "the guard BOOTS the app and reads the DB back — the name string proves nothing"
      assert_includes out, "ABORTED", "a SHARED test database must abort the gate"
      assert_includes out, "SHARED test database", "…naming what it refused"
      assert_includes out, "turf_monster_test", "…the database the suite would have run against"
      assert_includes out, "turf_monster_gate_test", "…and the gate's OWN database it expected"
      assert_includes out, "REFUSING"
      assert_includes out, "NOT a release regression", "an ENV/config abort never routes to the eject path"
      refute_includes lines, "DB-PREPARE",
                      "the refusal lands BEFORE db:test:prepare — that task PURGES the database it is pointed at, " \
                      "so a check running after it would already have destroyed the concurrent suite's data this " \
                      "guard exists to protect"
      refute_includes lines, "SUITE", "and nothing runs against a database that isn't ours"
      refute_includes out, "PASSED"
    end
  end

  # [unit] The green path: the probe resolves the gate's OWN postgres DB → the gate
  # states the verdict and rides on, probe → prepare → suite, in that order.
  def test_pre_qa_gate_runs_when_the_probe_resolves_the_gates_own_private_db
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      out = run_cli(["--yes"], setup: db_probe_stub(dir, "sibling_gate_test"),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      lines = out.lines.map(&:strip)
      probe = lines.index("PROBE")
      db    = lines.index("DB-PREPARE")
      suite = lines.index("SUITE")
      assert probe && db && suite, "the probe, the DB prepare, and the suite must all run: #{out}"
      assert_operator probe, :<, db, "assert first, destroy second"
      assert_operator db, :<, suite, "…and both before the suite boots"
      assert_includes out, "gate test DB sibling_gate_test (private to this gate)",
                      "the verdict is STATED — a convention nobody checks is a comment"
      assert_includes out, "PASSED"
    end
  end

  # [unit] A SQLite app (rolio): its test DB is a FILE inside the gate workspace, so
  # it is private by construction — the gate hands it NO postgres url (that would be
  # a live trap the moment it took effect) and the probe's file path still satisfies
  # the invariant.
  def test_pre_qa_gate_runs_a_sqlite_app_whose_test_db_is_a_file_inside_the_workspace
    Dir.mktmpdir do |dir|
      plant_database_yml(dir, adapter: "sqlite3")
      out = run_cli(["--yes"], setup: db_probe_stub(dir, "%WORKSPACE%/storage/test.sqlite3"),
                    call: %{pre_qa_gate([{ "repo" => "rolio" }]); puts("PASSED")})

      env_line = out.lines.find { |l| l.start_with?("SUITE-ENV") }
      assert env_line, "the suite must run: #{out}"
      refute_includes env_line, "DATABASE_URL",
                      "a SQLite app is handed NEITHER db url — its test DB is a file INSIDE the workspace " \
                      "(already private), and a postgres url would be a live trap"
      assert_includes out, "(private to this gate)", "…and the file-backed DB still PASSES the invariant"
      assert_includes out, "PASSED"
    end
  end

  # [unit] The other half of file_backed?: a SQLite path OUTSIDE the workspace (the
  # PRIMARY's storage/test.sqlite3) is NOT private — a workspace-relative resolve
  # would have waved it through, and the gate would purge the checkout's own test DB.
  def test_pre_qa_gate_refuses_a_sqlite_db_outside_the_gate_workspace
    Dir.mktmpdir do |dir|
      plant_database_yml(dir, adapter: "sqlite3")
      primary_db = File.join(dir, "storage", "test.sqlite3") # the PRIMARY's file, not the workspace's
      out = run_cli(["--yes"], setup: db_probe_stub(dir, primary_db),
                    call: %{begin; pre_qa_gate([{ "repo" => "rolio" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      lines = out.lines.map(&:strip)
      assert_includes out, "ABORTED", "a DB file outside the workspace is SHARED — refuse it"
      assert_includes out, "SHARED test database"
      refute_includes lines, "DB-PREPARE", "…before db:test:prepare could purge the primary's own test DB"
      refute_includes out, "PASSED"
    end
  end

  # [unit] A probe that cannot BOOT is an ENV abort, not a regression — and it stops
  # the gate rather than assuming the DB is fine (fail CLOSED: an unverifiable DB is
  # exactly the case where db:test:prepare must not fire).
  def test_pre_qa_gate_aborts_as_env_when_the_db_probe_cannot_boot
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      out = run_cli(["--yes"], setup: db_probe_stub(dir, ""),
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      lines = out.lines.map(&:strip)
      assert_includes out, "ABORTED"
      assert_includes out, "could not resolve the test database", "the abort names what it could not prove"
      assert_includes out, "NOT a release regression", "…as an ENV issue — nothing to eject or revert"
      refute_includes lines, "DB-PREPARE", "an unverifiable DB is never purged"
      refute_includes lines, "SUITE"
      refute_includes out, "PASSED"
    end
  end

  # --- G3's AUDITOR: the gate cross-checked against GitHub CI on the SAME SHA ----
  #
  # The local gate is the ONLY verdict on the release tip; nothing independent
  # checked it. Now every gated SHA is ALSO queried against GitHub CI
  # (CiStatus.for_sha → gh api …/commits/<sha>/check-runs), BOTH verdicts land on
  # the release, and a CONTRADICTION alarms. CI audits — it never blocks (a push CI
  # is asynchronous; blocking would make a local gate poll GitHub for minutes).
  #
  # RELEASE_CI_STATUS injects the verdict (a bare token, or a raw check-runs
  # payload), so these never touch the network — the DOR_CHECK_CI_STATUS seam,
  # reused. An injected verdict also skips the `git remote get-url` lookup.

  # A gate whose suite goes GREEN, with CI's verdict injected. `rel-cli` is passed
  # as the release slug so record_qa_gate actually fires (it no-ops on a blank slug).
  def ci_gate_stub(dir, ci_status)
    %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
      %(ENV["RELEASE_CI_STATUS"] = #{ci_status.inspect}\n) +
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

  # [integration] The happy audit: gate GREEN, CI GREEN for the same SHA. Both
  # verdicts are stated, and BOTH are recorded on the release — agreement is data
  # too (it is what would justify ever promoting the auditor to a blocker).
  def test_pre_qa_gate_records_cis_verdict_beside_its_own_when_they_agree
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, "green"),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "CI cross-check — GitHub CI AGREES (GREEN @ #{GATE_SHA[0, 7]})"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert record, "the gate must still record what it certified: #{out}"
      assert_includes record, "record_qa_gate", "…through the same conductor write as before"
      assert_match(/ci:\s*\{/, record, "…now carrying the AUDITOR's verdict for the same SHA")
      assert_match(/"state"\s*=>\s*"green"/, record)
      assert_includes out, "PASSED"
    end
  end

  # [integration] THE ALARM, direction 1: the gate says GREEN, GitHub says RED for
  # that exact SHA. CI runs a lane no local cert does (the browser test:system
  # suite), so this is probably real — but it does NOT block: QA still deploys, the
  # disagreement is screamed, and it is recorded on the release for the ship call.
  def test_pre_qa_gate_alarms_but_does_not_block_when_it_is_green_and_ci_is_red
    Dir.mktmpdir do |dir|
      # A RAW check-runs payload (not a token) — the mapping shim end-to-end:
      # status+conclusion → bucket → verdict, no network.
      payload = '{"total_count":2,"check_runs":[' \
                '{"name":"test","status":"completed","conclusion":"success"},' \
                '{"name":"test:system","status":"completed","conclusion":"failure"}]}'
      out = run_cli(["--yes"], setup: ci_gate_stub(dir, payload),
                    call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

      assert_includes out, "ALARM — the G3 gate and GitHub CI DISAGREE"
      assert_includes out, "local pre-QA gate: GREEN   ·   GitHub CI: RED (test:system)",
                      "the alarm NAMES the failing check, not just the fact of a disagreement"
      # THE ALARM MUST NOT CLAIM A BACKSTOP IT DOES NOT HAVE. It says what actually
      # happens at ship (G4 stops self-gating on this certification) AND what that
      # re-run does NOT prove: it re-runs the LOCAL suite — the one that already
      # passed — while the failing lane is one only CI can see. An alarm that
      # promises someone else will catch it is an alarm the operator learns to
      # dismiss.
      assert_includes out, "certification is now DISTRUSTED"
      assert_includes out, "NOT A BACKSTOP FOR THIS"
      assert_includes out, "NOTHING downstream will catch it for you"
      assert_includes out, "eject BEFORE the ship"
      assert_includes out, "PASSED",
                       "CI is the AUDITOR, not the verdict — a red audit never blocks prepare (a push CI is " \
                       "asynchronous; blocking would hand a LOCAL gate a hard GitHub dependency)"
      record = out.lines.find { |l| l.start_with?("CONDUCTOR") }
      assert_match(/"state"\s*=>\s*"red"/, record, "the disagreement is RECORDED, not just printed")
      assert_match(/"test:system"/, record)
    end
  end

  # [integration] THE ALARM, direction 2 — the valuable one. The gate says RED,
  # GitHub says GREEN: the GATE is the suspect, not the code (rel-20260711-7f2913,
  # where a false-negative gate nearly got a good PR ejected). The gate still
  # aborts — it IS the verdict — but the abort redirects the conductor away from
  # ejecting a task the gate may be lying about.
  def test_pre_qa_gate_red_beside_a_green_ci_tells_the_conductor_to_suspect_the_gate
    Dir.mktmpdir do |dir|
      setup = ci_gate_stub(dir, "green") + %(\ndef qa_gate_cmd(_repo) = "bin/failing-suite")
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ALARM — the G3 gate and GitHub CI DISAGREE"
      assert_includes out, "suspect the GATE, not the code"
      assert_includes out, "ABORTED", "the LOCAL gate is still the verdict — a green audit does not wave a red gate through"
      assert_includes out, "SUSPECT THE GATE FIRST", "…but the abort no longer sends the conductor straight to eject"
      assert_includes out, "bin/release eject", "the eject path is still there for a REAL regression"
      refute_includes out, "CONDUCTOR", "a RED gate certifies nothing — no record, so G4 fails open and re-runs"
      refute_includes out, "PASSED"
    end
  end

  # [integration] NO CI DATA IS NOT A FAILURE — the state of the world TODAY.
  # ci.yml triggers on pull_request + push:main, so a release-tip SHA has NO
  # check-runs at all until task run-ci-on-release-branch lands. That answer
  # (:none), a still-running push CI (:pending), and a gh/network error
  # (:unverified) are all SILENCE: informational, never an alarm, never a block.
  def test_pre_qa_gate_treats_a_missing_ci_run_as_no_data_not_a_disagreement
    %w[none pending unverified].each do |state|
      Dir.mktmpdir do |dir|
        out = run_cli(["--yes"], setup: ci_gate_stub(dir, state),
                      call: %{pre_qa_gate([{ "repo" => "sibling" }], "rel-cli"); puts("PASSED")})

        assert_includes out, "no GitHub verdict for #{GATE_SHA[0, 7]}",
                        "#{state} is GitHub having nothing to say about this SHA"
        assert_includes out, "informational only, the local gate stands"
        refute_includes out, "ALARM", "silence is not a contradiction (#{state})"
        assert_includes out, "PASSED", "…and it can never fail a green gate (#{state})"
      end
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
  # A GREEN gate stamps release.metadata["qa_gates"][repo] = {sha, cmd, ok: true}.
  # A red / skipped / misconfigured gate leaves NOTHING — which makes G4 FAIL OPEN
  # (it re-runs the suite on the frozen SHA). See the ship-gate skip matrix below
  # for why that asymmetry is load-bearing.

  # [unit] A green gate records what it CERTIFIED: this repo, this SHA, this cmd.
  def test_pre_qa_gate_records_the_g3_certification_on_a_green_suite
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
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
      assert cert, "a GREEN gate must record its certification: #{out}"
      assert_includes cert, "Release::Conductor.record_qa_gate", "the stamp rides the tested conductor primitive"
      assert_includes cert, %(slug: "rel-cert")
      assert_includes cert, %(repo: "sibling")
      assert_includes cert, %(sha: "#{GATE_SHA}"), "it certifies the SHA the suite actually ran on"
      assert_includes cert, %(cmd: "bin/suite"), "…and the command it actually ran"
      assert_includes cert, "ok: true"
      assert_includes out, "PASSED"
    end
  end

  # [unit] A RED gate records NOTHING — no half-certification, no "we ran it" stamp.
  # (The abort is the loud half; the SILENCE is what keeps G4 armed.)
  def test_pre_qa_gate_records_no_certification_when_the_suite_is_red
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/suite"
        def conductor(ruby, read_only: false)
          $stdout.puts("CERT-CALL " + ruby.gsub("\n", " "))
          {}
        end
        def sh(*a, **k)
          g = gate_git(a, k)
          return g if g
          return ["", false] if a[0] == "bin/suite" # RED
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }], "rel-cert"); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a red gate still aborts the prepare"
      refute_includes out, "CERT-CALL",
                      "a RED gate must certify NOTHING — a stamp here would let G4 self-skip on a failed suite"
      refute_includes out, "PASSED"
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

  # [unit] The gate bundle-checks via the workspace's bin/bundle binstub — the
  # same env-resolved ruby that boots the suite — AFTER the workspace is pinned at
  # the SHA under test (so it reads the RELEASE tree's Gemfile.lock) and BEFORE
  # the suite burns minutes. (The pin replaced the old primary `git checkout
  # release`; the ordering guarantee it anchors is unchanged.)
  def test_pre_qa_gate_bundle_checks_under_the_suite_ruby_before_the_suite
    Dir.mktmpdir do |dir|
      primary, = build_binstub_fixture(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test"
        def sh(*a, **k)
          $stdout.puts("GIT-OP #{a[3]}") if a[0] == "git"
          $stdout.puts("BUNDLE #{a[1]}") if a[0] == "bin/bundle"
          $stdout.puts("DB-PREPARE") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          $stdout.puts("SUITE") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      lines = out.lines.map(&:strip)
      pin   = lines.index("GIT-OP worktree") # the workspace is pinned at the SHA under test
      check = lines.index("BUNDLE check")
      db    = lines.index("DB-PREPARE")
      suite = lines.index("SUITE")
      assert check, "the gate must bundle-check via bin/bundle (the suite ruby): #{out}"
      assert pin && db && suite, "the workspace pin, the test DB, and the suite must all run: #{out}"
      assert_operator pin, :<, check, "the bundle check reads the pinned WORKSPACE tree (after the pin)"
      assert_operator check, :<, db, "…before the gate DB is prepared"
      assert_operator db, :<, suite, "…and both complete BEFORE the suite boots"
      refute_includes lines, "BUNDLE install", "a satisfied bundle must not install"
      assert_includes out, "PASSED"
    end
  end

  # [unit] An unsatisfied bundle self-heals: bin/bundle install (same suite
  # ruby → same gem home) runs before the suite, and a green install lets the
  # gate ride on.
  def test_pre_qa_gate_installs_the_bundle_when_the_check_fails
    Dir.mktmpdir do |dir|
      primary, = build_binstub_fixture(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test"
        def sh(*a, **k)
          $stdout.puts("BUNDLE #{a[1]}") if a[0] == "bin/bundle"
          $stdout.puts("SUITE") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          return ["", false] if a[0] == "bin/bundle" && a[1] == "check"
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      lines   = out.lines.map(&:strip)
      check   = lines.index("BUNDLE check")
      install = lines.index("BUNDLE install")
      suite   = lines.index("SUITE")
      assert check && install && suite, "check, install, and suite must all run: #{out}"
      assert_operator check, :<, install, "the failed check triggers the install"
      assert_operator install, :<, suite, "…which completes BEFORE the suite boots"
      assert_includes out, "PASSED", "a healed bundle lets the gate ride on"
    end
  end

  # [unit] When the bundle can't be healed, the abort is an ENV/toolchain
  # diagnosis: it names the suite ruby vs the conductor ruby (the brew-vs-mise
  # divergence) and NEVER routes to the eject/revert regression path — that
  # guidance burned two gate runs on rel-20260708-32701b.
  def test_pre_qa_gate_aborts_as_env_when_the_suite_bundle_cannot_be_fixed
    Dir.mktmpdir do |dir|
      primary, workspace = build_binstub_fixture(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test"
        def sh(*a, **k)
          $stdout.puts("GIT-OP #{a[3]}") if a[0] == "git"
          $stdout.puts("SUITE") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          return ["/opt/mise/rubies/3.3.11/bin/ruby", true] if a[0] == "ruby"
          return ["", false] if a[0] == "bin/bundle" # check AND install both fail
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "an unfixable bundle aborts the gate"
      assert_includes out, "NOT a release regression", "the abort frames the failure as env, not regression"
      assert_includes out, "/opt/mise/rubies/3.3.11/bin/ruby", "…naming the SUITE ruby"
      assert_includes out, "divergent gem homes", "…and the brew-vs-mise divergence"
      assert_includes out, "cd #{workspace}", "…and the fix runs in the WORKSPACE (the tree whose bundle is broken)"
      refute_includes out, "bin/release eject", "an env abort must NEVER route to the eject path"
      refute_includes out, "git revert", "…nor the merge-revert guidance"
      refute_includes out, "PASSED"
      lines = out.lines.map(&:strip)
      refute_includes lines, "SUITE", "the suite must not burn minutes on a broken bundle"
      # There is no `checkout main` restore to assert any more: the primary is never
      # flipped, so an env abort (like every other abort) leaves it exactly as it was.
      git_ops = lines.select { |l| l.start_with?("GIT-OP ") }
      refute_includes git_ops, "GIT-OP checkout", "the gate must not touch the primary's HEAD, even on the env abort"
    end
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

  # [unit] REGRESSION (carl + shannon request-changes on PR #480): a
  # qa-REGISTERED app that ships NO bin/bundle binstub must STILL bundle-check
  # under the suite ruby — via `ruby -S bundle` run from the repo dir (the mise
  # shim resolves the SAME directory-pinned ruby the suite's #!/usr/bin/env ruby
  # binstubs do), NEVER bare `bundle` (a shell PATH lookup that re-picks the
  # conductor ruby — the exact divergence the guard exists to close).
  def test_pre_qa_gate_bundle_checks_a_registered_app_without_a_binstub_under_the_suite_ruby
    Dir.mktmpdir do |dir|
      primary   = File.join(dir, "repo")
      workspace = File.join(primary, ".worktrees", "_gate") # a Gemfile but deliberately NO bin/bundle
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "Gemfile"), "source \"https://rubygems.org\"\n")
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test"
        def sh(*a, **k)
          $stdout.puts("BUNDLE-ARGV #{a[0..3].inspect} #{k[:chdir]}") if a[0] == "ruby" && a[1] == "-S"
          $stdout.puts("BARE-BUNDLE") if a[0] == "bundle"
          $stdout.puts("SUITE") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      argv_line = out.lines.find { |l| l.start_with?("BUNDLE-ARGV") }
      assert argv_line, "a no-binstub registered app must STILL bundle-check under the suite ruby: #{out}"
      assert_includes argv_line, %(["ruby", "-S", "bundle", "check"]),
                      "the check runs `ruby -S bundle` (suite ruby), closing the coverage gap"
      assert_includes argv_line, workspace,
                      "…from the WORKSPACE dir, so the mise shim resolves the same directory-pinned ruby the suite boots"
      refute_includes out, "BARE-BUNDLE", "it must NEVER fall back to bare `bundle` (shell-ruby PATH lookup)"
      assert_includes out, "PASSED"
    end
  end

  # [unit] A workspace with NO Gemfile has nothing bundler-managed to verify — the
  # guard self-gates (this also keeps the real-git fixtures in this file, which
  # carry no Gemfile, out of the guard's way).
  def test_pre_qa_gate_skips_the_bundle_guard_without_a_gemfile
    Dir.mktmpdir do |dir|
      fix = File.join(dir, "repo")
      FileUtils.mkdir_p(fix)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{fix.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test"
        def sh(*a, **k)
          $stdout.puts("BUNDLE #{a[1]}") if a[0].end_with?("bundle")
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      refute_includes out, "BUNDLE", "no Gemfile → no bundle check/install"
      assert_includes out, "PASSED"
    end
  end

  # --- the gate workspace PREPARES the test env (assets), not just the DB -------
  #
  # REGRESSION (2026-07-12, found reviewing PR #515): Rails runs `test:prepare` —
  # the hook `tailwindcss-rails` enhances to BUILD the gitignored
  # app/assets/builds/tailwind.css — only when NO argument looks like a PATH
  # (railties test_command.rb: `run_prepare_task if args.none?(EXACT_TEST_ARGUMENT_PATTERN)`).
  # `db:test:prepare` does NOT build it.
  #
  # The satellites register a PATH-ARG gate command (`bin/rails test test/integration`),
  # and the gate workspace is made by `git worktree add --detach`, which does NOT copy
  # gitignored files — so it is VIRGIN: no tailwind.css. The gate ran only
  # `db:test:prepare` → the asset was never built → every view-rendering test died with
  # `ActionView::Template::Error: The asset "tailwind.css" is not present in the asset
  # pipeline` → the gate went RED on GREEN code and handed out EJECT/REVERT guidance.
  # Driven on turf-monster before the fix: 86 runs, 43 errors, all that one error.
  #
  # The fix is in the GATE, not in each registry command: prepare the test env for ANY
  # registered command shape — argless or path-arg — so the next person to register a
  # lane cannot re-open this. A gate that only works for certain command shapes is a
  # trap.

  # [unit] The gate prepares the test env in ONE boot — `bin/rails db:test:prepare
  # test:prepare` — for a PATH-ARG lane (the satellites' registered shape, the one that
  # makes Rails skip its own run_prepare_task). Both tasks in ONE `bin/rails` invocation,
  # both BEFORE the suite: test:prepare is what builds the gitignored stylesheet the
  # virgin workspace lacks.
  def test_gate_workspace_prepares_the_test_env_for_a_path_arg_lane
    Dir.mktmpdir do |dir|
      primary, = build_binstub_fixture(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        # The satellites' registered gate command: a PATH ARG — so Rails itself will
        # NOT run test:prepare. The gate must do it.
        def qa_gate_cmd(_repo) = "bin/rails test test/integration"
        def sh(*a, **k)
          $stdout.puts("PREPARE #{a[1..].join(' ')}") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          $stdout.puts("SUITE") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      lines = out.lines.map(&:strip)
      prep  = lines.index { |l| l.start_with?("PREPARE") }
      suite = lines.index("SUITE")
      assert prep, "the gate must prepare the test env: #{out}"
      assert_equal "PREPARE db:test:prepare test:prepare", lines[prep],
                   "the gate must run `test:prepare` — the hook that BUILDS the gitignored stylesheet — " \
                   "in the SAME boot as db:test:prepare (one boot, not two), because a PATH-ARG lane " \
                   "makes Rails skip its own run_prepare_task and the workspace is virgin"
      assert_operator prep, :<, suite, "…and the assets must exist BEFORE the suite renders a view"
      assert_includes out, "PASSED"
    end
  end

  # [unit] Same for an ARGLESS lane (the hub's shape). The hub self-builds — Rails runs
  # run_prepare_task itself — but the gate preparing it too is IDEMPOTENT and keeps ONE
  # code path for every registered shape. Asserted so nobody "optimizes" the gate back
  # into being shape-aware, which is the trap this bug came from.
  def test_gate_workspace_prepares_the_test_env_for_an_argless_lane_too
    Dir.mktmpdir do |dir|
      primary, = build_binstub_fixture(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test"
        def sh(*a, **k)
          $stdout.puts("PREPARE #{a[1..].join(' ')}") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      assert_includes out, "PREPARE db:test:prepare test:prepare",
                      "the gate prepares the test env for EVERY shape — one path, no shape-awareness"
      assert_includes out, "PASSED"
    end
  end

  # [unit] A FAILED test-env prepare aborts in the ENV class — never as a red suite, and
  # never down the eject/revert path. This is the whole point: an unbuildable stylesheet
  # in a virgin workspace is not "a regression riding origin/release", and telling the
  # conductor to eject a task over it is how a good PR (#498) nearly got ejected.
  #
  # But the abort must be honest in BOTH directions (the calibration Carl forced onto
  # #515): `tailwindcss:build` ALSO fails on a broken stylesheet IN the release's own
  # diff — a bad @apply, an unknown utility, a malformed @theme. So the message must not
  # overclaim "this is definitely env" either. Say usually-env, but name the real other
  # cause. Do not ship a third lying gate.
  def test_a_failed_test_env_prepare_aborts_as_env_not_as_a_regression
    Dir.mktmpdir do |dir|
      primary, = build_binstub_fixture(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{primary.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = "bin/rails test test/integration"
        def sh(*a, **k)
          $stdout.puts("SUITE") if a[0] == "bin/rails" && a[1] == "test"
          # The test-env prepare FAILS (an unbuildable stylesheet), the DB half is fine.
          return ["Error: Unknown utility `bg-nope`", false] if a[0] == "bin/rails" && a[1] == "db:test:prepare"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{begin; pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "a broken test-env prepare must stop the gate"
      refute_includes out, "PASSED"
      refute_includes out, "SUITE",
                      "the suite must NOT run — it would render views with no stylesheet and go RED on " \
                      "green code, which is the false-red this whole guard exists to close"

      assert_includes out, "NOT a release regression",
                      "the abort must land in the ENV class, matching pre_qa_gate's existing convention"
      assert_includes out, "nothing to eject or revert",
                      "…and must NEVER hand out the eject/revert guidance: that is how a good PR gets ejected"
      refute_includes out, "a regression is riding",
                       "…so the red-suite abort message must not fire for an env/asset failure"

      # Honest in the OTHER direction too — do not overclaim "env".
      assert_match(/usually/i, out,
                   "the diagnosis is a LIKELIHOOD, not a certainty — tailwindcss:build fails on a broken " \
                   "stylesheet in the release's own diff too")
      assert_match(/stylesheet/i, out, "…and the message must NAME that other cause, not hide it")
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

  def test_pre_qa_gate_passes_a_quoted_spaced_arg_as_one_argv_element
    # Per-test lock dir + a throwaway repo dir — the gate mkdir_p's its workspace
    # under repo_path, so a test must never point that at a live checkout.
    Dir.mktmpdir do |dir|
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def qa_gate_cmd(_repo) = %q{bin/rails test "test/integration/a b_test.rb"}
        def sh(*a, **k)
          # a[1] guards the gate's OWN `bin/rails db:test:prepare` out of the way —
          # only the registered suite command is the subject here.
          $stdout.puts("GATE-ARGV #{a.length} #{a.inspect}") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "mcritchie-studio" }]); puts("PASSED")})

      argv_line = out.lines.find { |l| l.start_with?("GATE-ARGV") }
      assert argv_line, "the gate must exec the registered command"
      assert argv_line.start_with?("GATE-ARGV 3"), "3 argv elements — the spaced arg does not split: #{argv_line}"
      assert_includes argv_line, %("test/integration/a b_test.rb"), "the quoted spaced arg survives as ONE element"
      assert_includes out, "PASSED"
    end
  end

  def test_ship_test_gate_passes_a_quoted_spaced_arg_as_one_argv_element
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def app_meta_for(_repo) = { "test_cmd" => %q{bin/rails test "test/models/a b_test.rb"} }
        def sh(*a, **k)
          $stdout.puts("SHIP-ARGV #{a.length} #{a.inspect}") if a[0] == "bin/rails" && a[1] == "test"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      # frozen_sha: is REQUIRED now — the ship gate pins its isolated workspace at
      # the exact SHA that ships (there is no "current checkout" to lean on).
      out = run_cli(["--yes"], setup: setup,
                    call: %{test_gate("mcritchie-studio", frozen_sha: #{GATE_SHA.inspect}); puts("PASSED")})

      argv_line = out.lines.find { |l| l.start_with?("SHIP-ARGV") }
      assert argv_line, "the ship gate must exec the registered command"
      assert argv_line.start_with?("SHIP-ARGV 3"), "3 argv elements — the spaced arg does not split: #{argv_line}"
      assert_includes argv_line, %("test/models/a b_test.rb"), "the quoted spaced arg survives as ONE element"
      assert_includes out, "PASSED"
    end
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

  # [integration] The gate across its REAL I/O boundary: an actual git sibling
  # (bare origin + main/release branches), the REAL `sh`, a REAL `git worktree
  # add --detach`, and a REAL subprocess parsed via Shellwords — proving
  # resolve-SHA → pin the isolated workspace → prepare its DB → run the suite
  # THERE end-to-end, with a quoted spaced arg arriving intact and the PRIMARY
  # checkout never leaving `main`.
  def test_pre_qa_gate_integration_runs_a_real_suite_in_the_isolated_workspace
    Dir.mktmpdir do |dir|
      clone     = build_sibling_fixture(dir)
      workspace = File.join(clone, ".worktrees", "_gate")
      release_sha, = Open3.capture2("git", "-C", clone, "rev-parse", "release")

      # Per-test lock dir for concurrent-suite hygiene (activity-1307) — the
      # "sibling" lock can't deadlock the hub gate, but two suite runs of this
      # file must not contend on a shared real lock file either.
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect}\n) +
              %(def qa_gate_cmd(_repo) = %q{ruby -e "puts [:GATE_OK, Dir.pwd, ARGV].inspect" -- "a b"})
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      assert_includes out, %(:GATE_OK), "the real subprocess ran"
      assert_includes out, %(["a b"]), "…receiving the quoted arg as ONE element"
      assert_includes out, %(.worktrees/_gate"), "…with its cwd IN the isolated workspace, not the primary"
      assert_includes out, "PASSED", "a green gate lets prepare continue"

      head, = Open3.capture2("git", "-C", clone, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal "main", head.strip, "the PRIMARY checkout never leaves main (nothing to restore)"
      pinned, = Open3.capture2("git", "-C", workspace, "rev-parse", "HEAD")
      assert_equal release_sha.strip, pinned.strip, "the workspace is pinned at the SHA under test (origin/release)"
      branch, = Open3.capture2("git", "-C", workspace, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal "HEAD", branch.strip, "…detached, so it can never contend with the primary for a branch"
    end
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

  # [unit] The REPLACEMENT guarantee for the old "the gate holds the primary lock
  # for its whole checkout→suite→restore section". The gate no longer HAS such a
  # section: it runs the suite in its own worktree and never flips the primary, so
  # it takes NO primary-checkout lock — the probe (standing in for a concurrent
  # artifact dance / another bin/release) finds the lock FREE and the primary
  # sitting on `main` the whole time. That is strictly SAFER than the old
  # hold-it-for-six-minutes shape, which could not exclude the processes that
  # actually did the flipping (the flock is advisory) while it stalled the ones it
  # could.
  def test_pre_qa_gate_leaves_the_primary_free_while_the_suite_runs
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      probe = File.join(dir, "probe.rb")
      File.write(probe, <<~'PROBE')
        path = File.join(ENV.fetch("MCR_PRIMARY_LOCK_DIR"), "mcr-primary-checkout-sibling.lock")
        free = File.open(path, File::RDWR | File::CREAT, 0o644) { |f| f.flock(File::LOCK_EX | File::LOCK_NB) }
        puts(free ? "SUITE-SEES-LOCK-FREE" : "SUITE-SEES-LOCK-HELD")
        puts("SUITE-HEAD " + `git -C #{ENV.fetch('GATE_PRIMARY')} rev-parse --abbrev-ref HEAD`.strip)
      PROBE

      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(ENV["GATE_PRIMARY"] = #{clone.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect}\n) +
              %(def qa_gate_cmd(_repo) = %q{ruby #{probe}})
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      assert_includes out, "SUITE-SEES-LOCK-FREE",
                      "the gate suite must NOT hold the primary hostage — it doesn't touch the primary at all"
      assert_includes out, "SUITE-HEAD main",
                      "…and the primary sits on `main` WHILE the suite runs (the old gate had it on `release`)"
      assert_includes out, "PASSED", "a green gate lets prepare continue"
    end
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

  # A fresh fd on a lockfile sees exactly what a SECOND `bin/release` would: flock is
  # per open-file-description, so a new fd contends with the conductor's own even
  # in-process (with_primary_checkout documents the same non-re-entrancy). That makes
  # the lock state observable from INSIDE the run, at each step of the gate.
  GATE_LOCK_PROBE = <<~'RUBY'
    def locked?(name)
      File.open(File.join(ENV.fetch("MCR_PRIMARY_LOCK_DIR"), name), File::RDWR | File::CREAT, 0o644) do |f|
        !f.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end
    def locks
      "gate=#{locked?('mcr-gate-workspace-sibling.lock') ? 'HELD' : 'FREE'} " \
        "primary=#{locked?('mcr-primary-checkout-sibling.lock') ? 'HELD' : 'FREE'}"
    end
  RUBY

  # [unit] THE BLOCKER. The gate-workspace lock is HELD across the WHOLE window — the
  # workspace pin, the DB prepare, and the suite — because every one of the three is a
  # step a second conductor would corrupt (reset --hard the tree; purge the DB; tear
  # the lazily-autoloaded snapshot). And the PRIMARY-checkout lock is FREE at each of
  # those same moments: this is a NEW lock, not the old hold-the-primary-hostage shape
  # wearing a different name.
  def test_pre_qa_gate_holds_the_gate_workspace_lock_across_pin_prepare_and_suite
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + GATE_LOCK_PROBE + <<~'RUBY'
                def qa_gate_cmd(_repo) = "bin/suite"
                def sh(*a, **k)
                  $stdout.puts("PIN #{locks}") if a[0] == "git" && a[3] == "worktree"
                  $stdout.puts("DB-PREPARE #{locks}") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
                  $stdout.puts("SUITE #{locks}") if a[0] == "bin/suite"
                  g = gate_git(a, k)
                  return g if g
                  ["", true]
                end
              RUBY
      out = run_cli(["--yes"], setup: setup, call: %{pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED")})

      assert_includes out, "PIN gate=HELD primary=FREE",
                      "the workspace pin (`git worktree add` / `reset --hard`) runs UNDER the gate lock — " \
                      "a second conductor pinning a different SHA here is how the tree gets torn: #{out}"
      assert_includes out, "DB-PREPARE gate=HELD primary=FREE",
                      "…so does db:test:prepare, which PURGES the gate DB"
      assert_includes out, "SUITE gate=HELD primary=FREE",
                      "…and the suite itself — the multi-minute, lazily-autoloading window the whole gate exists " \
                      "to protect. The PRIMARY meanwhile stays FREE: this is the gate's own lock, not the old " \
                      "hold-the-shared-checkout-hostage shape renamed"
      assert_includes out, "PASSED"
    end
  end

  # [unit] Cross-process proof on a REAL flock: while conductor A holds the gate lock,
  # conductor B's gate QUEUES — it SAYS so, and it touches NOTHING (no pin, no purge,
  # no suite) until the lock is released. Queueing is the correct outcome: the
  # alternative to a queued gate is not two gates, it is two gates destroying each
  # other's tree and database.
  def test_a_second_gate_queues_behind_the_conductor_holding_the_gate_workspace_lock
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      marks = File.join(dir, "marks.log")
      log   = File.join(dir, "gate.log")
      setup = %(MARKS = #{marks.inspect}\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
                def qa_gate_cmd(_repo) = "bin/suite"
                def sh(*a, **k)
                  File.write(MARKS, "PIN\n", mode: "a") if a[0] == "git" && a[3] == "worktree"
                  File.write(MARKS, "DB-PREPARE\n", mode: "a") if a[0] == "bin/rails" && a[1] == "db:test:prepare"
                  File.write(MARKS, "SUITE\n", mode: "a") if a[0] == "bin/suite"
                  g = gate_git(a, k)
                  return g if g
                  ["", true]
                end
              RUBY
      # $stdout.sync so the "waiting…" line reaches the log FILE as it is printed
      # (stdout to a file is block-buffered) — the queue is only observable live.
      script = %(ARGV.replace(["--yes"]); $stdout.sync = true; load #{BIN.inspect}; #{setup}; ) +
               %(pre_qa_gate([{ "repo" => "sibling" }]); puts("PASSED"))
      env = SessionEnv.neutralized("MCR_PRIMARY_LOCK_DIR" => dir)

      lock = File.open(File.join(dir, "mcr-gate-workspace-sibling.lock"), File::RDWR | File::CREAT, 0o644)
      assert lock.flock(File::LOCK_EX | File::LOCK_NB), "test setup: conductor A takes the gate-workspace lock"

      pid = Process.spawn(env, "ruby", "-e", script, out: log, err: File::NULL)
      begin
        wait_until(20, "conductor B to report that it is queued") do
          file_text(log).include?("waiting on the sibling gate-workspace lock")
        end
        refute_mark marks, "PIN", "B must not reset --hard the tree A's suite is running from"
        refute_mark marks, "DB-PREPARE", "…nor PURGE the database A's suite is using"
        refute_mark marks, "SUITE", "…nor run its own suite in A's workspace"

        lock.flock(File::LOCK_UN) # conductor A's gate finishes
        wait_until(30, "conductor B to acquire the released lock and finish") { Process.wait(pid, Process::WNOHANG) }
        status = $CHILD_STATUS
        pid = nil

        assert status.success?, "conductor B must ride on cleanly once the lock is free: #{file_text(log)}"
        assert_includes file_text(log), "another bin/release is running its gate suite",
                        "the wait is EXPLAINED, not a silent stall"
        assert_includes file_text(log), "PASSED", "…and B rides on once the lock is free"
        assert_mark marks, "SUITE", "B runs its suite only AFTER it owns the workspace"
      ensure
        if pid
          Process.kill("KILL", pid)
          Process.wait(pid)
        end
      end
    ensure
      lock&.close
    end
  end

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

      setup = %(def repo_path(_repo) = #{clone.inspect})
      out = run_cli(["--yes"], setup: setup,
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

  # [unit] The ship gate now mutates NOTHING. It used to fast-forward each app's
  # `main` in the primary (under the primary lock) before running the suite — but
  # the suite moved to the isolated gate workspace at the frozen SHA, so that ff fed
  # nothing and only flipped a shared checkout. With it gone, a red gate or a
  # declined ship-authority confirm leaves the machine exactly as it found it.
  def test_avi_ship_gate_mutates_nothing_before_ship_authority
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
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
                    call: %{avi_ship_gate([{ "repo" => "x" }], { "x" => #{GATE_SHA.inspect} }, {}); puts("PASSED")})

      assert_includes out, "SUITE", "the gate must still RUN the suite on the frozen SHA: #{out}"
      refute_includes out, "PRIMARY-LOCK-TAKEN",
                      "the gate has nothing to serialize against the primary any more — it must not take its lock"
      refute_includes out, "PRIMARY-WRITE",
                      "no checkout/pull/merge/push before ship authority — a declined confirm must change nothing"
      assert_includes out, "PASSED"
    end
  end

  # [unit] Cross-process proof on a REAL flock. The ship gate's suite must find the
  # primary-checkout lock FREE (it runs in the isolated workspace and needs no
  # exclusion) — the mirror of the pre-QA gate proof. A HELD lock here would mean
  # the suite is back on the primary, holding the shared checkout for its whole run
  # while STILL not excluding the sessions that flip it.
  def test_avi_ship_gate_leaves_the_primary_free_while_the_suite_runs
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      sha, = Open3.capture2("git", "-C", clone, "rev-parse", "main")
      sha = sha.strip
      probe = File.join(dir, "probe.rb")
      File.write(probe, <<~'PROBE')
        path = File.join(ENV.fetch("MCR_PRIMARY_LOCK_DIR"), "mcr-primary-checkout-sibling.lock")
        free = File.open(path, File::RDWR | File::CREAT, 0o644) { |f| f.flock(File::LOCK_EX | File::LOCK_NB) }
        puts(free ? "SUITE-SEES-LOCK-FREE" : "SUITE-SEES-LOCK-HELD")
        puts("SUITE-CWD " + Dir.pwd)
      PROBE

      setup = %(ENV["MCR_PRIMARY_LOCK_DIR"] = #{dir.inspect}\n) +
              %(def repo_path(_repo) = #{clone.inspect}\n) +
              %(def app_meta_for(_repo) = { "test_cmd" => %q{ruby #{probe}} })
      out = run_cli(["--yes"], setup: setup,
                    call: %{avi_ship_gate([{ "repo" => "sibling" }], { "sibling" => #{sha.inspect} }, {}); puts("PASSED")})

      assert_includes out, "SUITE-SEES-LOCK-FREE",
                      "the ship gate's suite must not hold the primary-checkout lock — it doesn't run there"
      assert_includes out, ".worktrees/_gate", "…because it runs in the isolated workspace (SUITE-CWD)"
      assert_includes out, "PASSED", "a green ship gate rides on"
      File.open(File.join(dir, "mcr-primary-checkout-sibling.lock"), File::RDWR | File::CREAT, 0o644) do |f|
        assert f.flock(File::LOCK_EX | File::LOCK_NB), "the ff must RELEASE the lock when it's done"
      end
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

  # [unit] test_gate SKIPS only against a matching GREEN G3 record, and RUNS the
  # suite in every other case — absent, red, different SHA, different command.
  def test_ship_test_gate_skips_only_against_a_matching_green_g3_record
    Dir.mktmpdir do |dir|
      SHIP_GATE_SKIP_CASES.each do |label, (record, expected)|
        setup = %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
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
          refute_includes out, "SUITE-RAN", "#{label}: the suite must be SKIPPED (G3 already certified it)"
          assert_includes out, "already CERTIFIED green", "#{label}: the skip is a VISIBLE SOP, never silent"
        else
          assert_includes out, "SUITE-RAN",
                          "#{label}: G4 must FAIL OPEN and run the suite — a skip here disarms the last gate " \
                          "before an irreversible prod deploy"
        end
        assert_includes out, "PASSED", "#{label}: the gate itself is green either way"
      end
    end
  end

  # [integration] A gate that silently re-runs teaches the operator nothing. When
  # the auditor is what cost the certification its skip, the ship SAYS so — and it
  # is honest about what the re-run does NOT prove (it re-runs the LOCAL suite,
  # which is the very suite that already passed; only CI can see CI's lane).
  def test_ship_test_gate_names_the_red_auditor_as_the_reason_it_is_re_running
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
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

      assert_includes out, "GitHub CI called that SHA RED", "the ship NAMES why it distrusts the certification"
      assert_includes out, "fail-open"
      assert_includes out, "runs a lane no local gate does",
                      "…and does NOT let the operator read the re-run as a backstop for CI's lane"
      assert_includes out, "SUITE-RAN"
      assert_includes out, "PASSED", "fail-OPEN, never fail-closed: the auditor re-runs the gate, it never blocks"
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

  # --- status / the clean-release GUARD (`deploy-with-task`'s first step) ---
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
    assert_includes out, "deploy-with-task", "the hint names the registered launcher phrase"
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
    hub_at = out.index("push heroku bbbbbbb:refs/heads/main")  # hub DEPLOY (the test gate runs up front, in avi_ship_gate)
    sat_at = out.index("bin/deploy --yes")  # satellite's deploy

    assert gem_at && hub_at && sat_at, "all three phases must appear"
    assert_operator gem_at, :<, hub_at, "gems publish before the hub deploys"
    assert_operator hub_at, :<, sat_at, "the hub deploys before the satellites"
  end

  # --- Avi ship gate: full e2e on the FROZEN SHA, THEN ship authority (§1.2) ---

  def test_ship_runs_the_avi_e2e_gate_before_ship_authority_and_any_deploy
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gate_at   = out.index("Avi ship gate")
    e2e_at    = out.index(HUB_GATE_CMD)                # the hub's highest-tier run on the frozen SHA
    ship_at   = out.index("confirming production deploy") # the ship-authority step (unique marker)
    deploy_at = out.index("push heroku bbbbbbb:refs/heads/main")

    assert gate_at && e2e_at && ship_at && deploy_at, "gate, e2e, ship authority, and a deploy must all appear"
    assert_operator gate_at, :<, ship_at, "the Avi gate precedes ship authority"
    assert_operator e2e_at, :<, ship_at, "the full suite runs on the frozen SHA BEFORE ship authority"
    assert_operator ship_at, :<, deploy_at, "ship authority precedes any deploy"
  end

  def test_ship_avi_gate_runs_the_suite_on_the_frozen_sha
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)
    # The gate runs the suite in the isolated workspace pinned at the frozen hub SHA.
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
  # CI has no sibling repo checkouts, so the real repo_path → Dir.exist? guard in
  # `prepare` (bin/release: "app repo not found at #{path}") would abort before the
  # post-deploy/assemble step this test proves. Resolve the repo to a throwaway dir
  # (stub_repo — NOT Dir.pwd: the gate mkdir_p's a .worktrees/ under whatever
  # repo_path returns) — the git/qa-server I/O against it is fully stubbed by `sh`,
  # so the repo's identity on disk is irrelevant to what this test asserts.
  PAREN_POST_DEPLOY_PREP_STUB = GATE_GIT_STUB + %(def repo_path(_repo) = #{stub_repo.inspect}\n) + <<~'RUBY'
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
               %(source "https://rubygems.org"\ngem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"\n))
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

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) + <<~'RUBY'
        def bundle_lock(path, gem)
          File.write(File.join(path, "Gemfile.lock"), "GEM\n  #{gem} (0.9.0)\n")
        end
      RUBY
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
                 %(source "https://rubygems.org"\ngem "studio-engine", github: "amcritchie/studio-engine", branch: "wip"\n))

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

  REPIN_LOCK_STUB = <<~'RUBY'
    def bundle_lock(path, gem)
      File.write(File.join(path, "Gemfile.lock"), "GEM\n  #{gem} (0.9.0)\n")
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
