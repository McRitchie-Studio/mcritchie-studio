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
require "open3"
# Several payload tests decode/parse the runner snippet (JSON + url-safe Base64).
# Require both here so they don't depend on test seed order (a prior test having
# pulled them in first) — without this, a seed that runs a payload test before any
# json-requiring test errored with `uninitialized constant JSON`.
require "json"
require "base64"

class ReleaseCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/release", __dir__)

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
  def run_ruby(script)
    last = nil
    SUBPROCESS_ATTEMPTS.times do
      out, err, status = Open3.capture3("ruby", "-e", script)
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
                               "branch" => "main", "smoke_url" => "https://app.mcritchie.studio" } }
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
    assert_includes out, "https://app.mcritchie.studio/up"
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

  # --- Avi ship gate: full e2e on the FROZEN SHA, THEN the operator gate (§1.2) ---

  def test_ship_runs_the_avi_e2e_gate_before_the_operator_gate_and_any_deploy
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gate_at   = out.index("Avi ship gate")
    e2e_at    = out.index("bin/rails test")            # the hub's highest-tier run on the frozen SHA
    oper_at   = out.index("awaiting operator approval") # the operator gate step (unique marker)
    deploy_at = out.index("push heroku main")

    assert gate_at && e2e_at && oper_at && deploy_at, "gate, e2e, operator gate, and a deploy must all appear"
    assert_operator gate_at, :<, oper_at, "the Avi gate precedes the operator gate"
    assert_operator e2e_at, :<, oper_at, "the full suite runs on the frozen SHA BEFORE the operator approves"
    assert_operator oper_at, :<, deploy_at, "the operator gate precedes any deploy"
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
      if ruby.include?("repo_plan")
        { "slug" => "rel-paren", "state" => "assembling", "branch" => "release", "repos" => [
          { "repo" => "turf-monster", "kind" => "app", "release_branch" => "release",
            "qa_app" => "turf-monster",
            "members" => [{ "slug" => "t-turf", "branch" => "feat/turf",
              "post_deploy_cmd" => %q{bin/rails runner "load Rails.root.join(%q(db/seeds/54_demo.rb)).to_s"} }] }
        ] }
      elsif ruby.include?("assemble!")
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
    assert_includes adopt, "task-a", "the single adopt call covers task-a"
    assert_includes adopt, "task-b", "the single adopt call covers task-b"
    assert_includes adopt, "adopt!", "the batched call drives Release::Conductor.adopt!"
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
    assert_includes out, "Merged task-a"
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

  # --- batch_adopt_ruby / batch_resolve_ruby: pure snippet builders ---------
  # These build the ONE-shot conductor snippets the batched merge runs; unit-test
  # them directly (eval_helper) so the single-call guarantee + slug embedding are
  # pinned independent of the orchestration.

  def test_batch_adopt_ruby_embeds_every_slug_in_one_runner_snippet
    out = eval_helper(%(batch_adopt_ruby(["task-a", "task-b", "task-c"])))
    assert_includes out, "task-a"
    assert_includes out, "task-b"
    assert_includes out, "task-c"
    assert_includes out, "Release::Conductor.adopt!", "the snippet drives adopt!"
    assert_equal 1, out.scan("puts(").size, "the snippet emits exactly ONE JSON line for the whole batch"
  end

  def test_batch_resolve_ruby_embeds_every_slug_and_reads_one_line
    out = eval_helper(%(batch_resolve_ruby(["task-a", "task-b"])))
    assert_includes out, "task-a"
    assert_includes out, "task-b"
    assert_includes out, "devops_url", "the resolve snippet reads each task's PR url"
    assert_equal 1, out.scan("puts(").size, "the resolve snippet emits ONE JSON line for the batch"
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
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        files = repo == "mcritchie-studio" ? ["db/schema.rb"] : []
        { "repo" => repo, "branch" => "main", "dirty" => files.any?, "dirty_files" => files }
      end
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
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "real code dirt still gates the ship"
    assert_includes out, "db/schema.rb", "the abort names the real dirty file"
    refute_includes out, "retro-rel-1.md", "the generated artifact is not named as dirt"
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
