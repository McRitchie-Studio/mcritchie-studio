# frozen_string_literal: true

# THE SHARED HARNESS for the bin/release CLI tests, test/lib/release_cli_*_test.rb.
#
# Every constant, class method and helper the release CLI tests share lives here: the
# subprocess runner (run_ruby / run_cli / eval_helper, with its OutboundSeams env,
# isolated lock_dir and SUBPROCESS_ATTEMPTS retry), the git fixtures
# (build_sibling_fixture, run_git, git_out) and every stub constant. The tests sit one
# file per bin/release subcommand, and each file subclasses ReleaseCliHarness, so every
# test runs against this one harness, not a copy of it.
#
# Why one base class and not a module: the tests call `self.class.lock_dir` and
# `self.class.stub_repo`, and reach the stub constants by bare name. A subclass
# inherits both the singleton methods and the constant lookup with no edit to a test.
# Each subclass memoizes its own lock_dir and stub_repo, removed after the run.
#
# This file is not a test (no `_test.rb` suffix) and defines no test method, so it
# adds no runs. A new release CLI test goes in the file for its subcommand, or a new
# file that requires this one; never back into one shared bottom.

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
require "digest"
require "fileutils" # lock_dir cleanup (Minitest.after_run remove_entry)
require "English"   # $CHILD_STATUS — the gate-lock queue test reaps its own child
require_relative "release_cli_stubs"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/release_archive_seams"


class ReleaseCliHarness < Minitest::Test
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
    # OutboundSeams, not SessionEnv, and the difference is load-bearing.
    # SessionEnv scrubs the ambient AGENT-SESSION vars; it says nothing about the
    # child's ability to REACH THE OUTSIDE WORLD, and these children drive real
    # bin/release subcommands. This is DEFENCE IN DEPTH, not a bug fix: the cases
    # below stub `sh` per-case and those stubs hold today. What they do not give
    # is a floor — a future case that forgets a stub has nothing beneath it, and
    # `gh` / `heroku` / `op` / `ssh` would resolve to the REAL binaries with the
    # developer's own credentials. OutboundSeams.env wraps the same SessionEnv
    # scrub and then puts sealed stubs in FRONT of PATH, so such a call resolves
    # to a stub that LOGS its argv and exits non-zero with no output. Caller
    # overrides still win, and the whole file stays green (299 runs, 0 failures),
    # which is the point: it costs nothing and it cannot be forgotten.
    #
    # NOT a substitute for the per-case stubs. PATH sealing cannot catch a script
    # invoked by RELATIVE PATH (bin/prod-smoke, bin/clean-artifacts), which is why
    # ReleaseArchiveSeams exists for the archive path.
    env = OutboundSeams.env(
      "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir,
      "SEAL_RETRY_DELAY_SECONDS" => "0",
      "TASK_API_BASE" => UNROUTABLE_API_BASE, "GH_AUTH_TOKEN_BIN" => ReleaseCliStubs.token_broker
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

  # run_ruby, but with MCR_PRIMARY_LOCK_DIR explicitly UNSET — the fallback that
  # reaches the operator's real lock dir. (run_ruby pins it, which is the point of it.)
  def run_ruby_unpinned(script)
    env = OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => nil)
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
  # tag/ahead: what git describe and git log <tag>.. answer. A re-run AFTER a publish passes the published tag
  # and no commits: a live version whose tag trails is REFUSED (/tasks/untagged-gem-publish-strands-work).
  def gem_publish_stub(version: "1.0.0", live: [], lock_dirty: true, allocate: true, tag: "v0.10.0", ahead: "abc123 stranded engine commit")
    GATE_GIT_STUB +
      (allocate ? "" : %(def allocate_gem_versions!(_groups, label: nil) = nil\n)) +
      %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
      %(def repo_path(_repo) = #{self.class.stub_repo.inspect}\n) +
      %(def gem_version_from_ref(_repo, _ref) = #{version.inspect}\n) +
      %(def rubygems_versions(_gem) = #{live.inspect}\n) +
      %(LOCK_DIRTY = #{lock_dirty.inspect}\n) +
      %(PUBLISHED_VERSION = #{version.inspect}\n) +
      %(STALE_LOCK_VERSION = "0.10.0"\nDESCRIBED_TAG = #{tag.inspect}\nAHEAD_LOG = #{ahead.inspect}\n) + <<~'RUBY'
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
          return [DESCRIBED_TAG, true] if j.include?("describe")
          return [AHEAD_LOG, true] if j.include?("log --oneline")
          return [(LOCK_DIRTY ? " M Gemfile\n M Gemfile.lock" : ""), true] if j.include?("status --porcelain")
          # Phase 1's consumer-coverage read: the swept app's Gemfile AT origin/release.
          return [%(gem "studio-engine", "~> 0.10"\n), true] if j.include?(":Gemfile")
          return [GATE_SHA, true] if j.include?("rev-parse")
          ["", true]
        end
        def with_ship_workspace(_repo) = yield
        # A Gemfile.lock on the OLD version, and the gem's version file at the final.
        def gem_artifact_version(artifact) = File.basename(artifact, ".gem").split("-").last
        def ship_workspace!(repo, _sha)
          dir = File.join(Dir.tmpdir, "prep-ws-#{Process.pid}-#{repo}")
          FileUtils.mkdir_p(File.join(dir, "lib/studio"))
          File.write(File.join(dir, "lib/studio/version.rb"), %(VERSION = "#{PUBLISHED_VERSION}"\n))
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
        # full signature (including `expect:`); the LADDER itself is driven for
        # real in the tests that stub `sh` instead of this.
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
                                               "    #{gem} (#{expect || PUBLISHED_VERSION})"))
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


  # The gem repo's own fetch (`fetch origin --tags`) fails; the app fetches
  # (no --tags) stay healthy, so the failure is exactly the gem's stale-ref lane.
  GEM_FETCH_FAIL = <<~'RUBY'
    alias sh_before_fetch_fail sh
    def sh(*a, **k)
      return ["", false] if a[0] == "git" && a.include?("fetch") && a.include?("--tags")
      sh_before_fetch_fail(*a, **k)
    end
  RUBY


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

  # A gem-only candidate whose gem is NOT self-gated (ReleaseCliStubs makes it so).
  SOLANA_GEM_ONLY_CONDUCTOR = <<~'RUBY'
    def conductor(ruby, read_only: false)
      return { "tasks" => [], "release" => { "slug" => "rel-gemonly", "state" => "assembling" }, "screen" => {} } if ruby.include?("sweep_candidates")
      return { "state" => "assembled" } if ruby.include?("qa_green!")
      { "slug" => "rel-gemonly", "state" => "assembling", "branch" => "release", "repos" => [
        { "repo" => "solana-studio", "kind" => "gem", "members" => [{ "slug" => "t-gem", "branch" => nil }] }
      ] }
    end
  RUBY


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


  # --- prepare: the self-healing sweep (detect → merge/skip → record → flip) ---

  # Detection returns NOTHING and no release is active → the idempotent no-op.
  NOOP_PREP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      { "tasks" => [], "release" => nil, "screen" => {} }
    end
  RUBY


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

  # --- qa_test_cmd registry values + test_cmd_argv (Shellwords) parsing --------

  # The hub's registered gate command (G3 qa_test_cmd == G4 test_cmd) — ci.yml's
  # test command verbatim, INCLUDING the system tier. Named once so the CLI
  # assertions below don't each re-pin a literal that can drift; the registry
  # itself is held to ci.yml by Release::ReposTest's drift guard.
  HUB_GATE_CMD = "bin/rails db:test:prepare test test:system"

  # --- primary-checkout lock: who still holds it, and who no longer does -------
  #
  # REGRESSION (rel-20260708-496cd8, then rel-20260711-7f2913): the gates used to
  # run their multi-minute suite ON the primary after a transient `git checkout
  # release`, so a concurrent `bin/release archive`/`retro` artifact dance
  # (commit_artifact_to_accepted) — or any process the ADVISORY flock does not bind
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


  # wait_for_boot drives a REAL retry loop (DRY=false): poll /up until 200, with
  # `sh` (the curl) + `sleep` stubbed so the loop runs instantly.
  WAIT_BOOT_STUB = <<~RUBY
    $codes = ["000", "000", "200"]
    def sh(*_a, **_k)
      [($codes.shift || "200"), true]
    end
    def sleep(*_a); end
  RUBY


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
    #{ReleaseArchiveSeams::PRUNE_STUB}
  RUBY


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
    #{ReleaseArchiveSeams::ISOLATION_STUB}
  RUBY


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

  # Every `bin/triage file` the run made, as { title:, body: }.
  def filed_findings(log)
    File.read(log).lines.reject { |l| l.strip.empty? }.map do |line|
      argv = JSON.parse(line)
      { title: argv[argv.index("--title") + 1], body: argv[argv.index("--body") + 1] }
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
    #{ReleaseArchiveSeams::ISOLATION_STUB}
  RUBY


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


  # --- the rescue's by-hand path must be EXECUTABLE AS PRINTED ----------------
  # (rescue-warn-omits-installer-path)
  #
  # The rescue branch used to print a BARE `bin/install-agent-docs`. That resolves
  # against whatever directory the READER happens to be sitting in, and this installer
  # PUBLISHES GLOBALLY (projects-root AGENTS.md/CLAUDE.md, ~/.claude + ~/.codex skills,
  # ~/.claude/settings.json, /etc/codex/requirements.toml, an append to ~/.zprofile).
  # On 2026-09-08 that hand-run was done from a feature worktree and pushed unshipped
  # mid-branch text to every session on the machine.
  #
  # TWO raise sites, because `rescue` here is METHOD-LEVEL and they are NOT equivalent:
  #   * AFTER `installer` resolves (`sh` raises) — the easy half.
  #   * BEFORE it resolves (`GateWorkspace.path` raises) — `installer` is in LEXICAL
  #     scope (Ruby defines a local at the parser's first sight of the assignment) but
  #     still NIL. So the obvious "interpolate #{installer}" fix prints "run `` by hand",
  #     an empty backtick pair that is WORSE than the bare name it replaced. The seed at
  #     the top of sync_agent_docs exists for exactly this case, and a test that only
  #     stubs `sh` cannot see it.
  #
  # Neither test ever executes the real installer: the first raises inside the stubbed
  # `sh`, and the second raises before `sh` is reached — which it also ASSERTS, via the
  # SH-REACHED sentinel, so "the installer was not run" is a measured fact and not a
  # reading of the control flow.

  # The path the rescue hands over, or nil if the warn line stopped offering one.
  def skipped_installer_path(out)
    out[/agent-docs install skipped \([^)]*\) — run `([^`]*)` by hand/, 1]
  end

  def assert_absolute_installer(path, out, when_:)
    refute_nil path,
               "the rescue warn line no longer hands over a by-hand command in backticks (#{when_}). " \
               "That line is the operator's only recovery instruction when the sync is skipped:\n#{out}"
    refute_equal "", path,
                 "the rescue interpolated an EMPTY path (#{when_}) — it printed \"run `` by hand\". " \
                 "That is the nil-interpolation failure mode the seed in sync_agent_docs prevents, and " \
                 "it is strictly worse than the bare `bin/install-agent-docs` it replaced."
    assert path.start_with?("/"),
           "the rescue prescribed #{path.inspect} (#{when_}), which is NOT absolute. A relative command " \
           "resolves against the reader's cwd, and bin/install-agent-docs publishes GLOBALLY — that is " \
           "how unshipped worktree text reached every session on this machine on 2026-09-08."
    assert path.end_with?("bin/install-agent-docs"),
           "the rescue prescribed #{path.inspect} (#{when_}), which does not name the installer"
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


  # [integration] cyvasse through the REAL run_post_deploy, reading the REAL
  # config/release_repos.yml (qa_evidence: exempt + git_push_heroku prod_deploy) and
  # config/qa_environments.yml (no cyvasse entry). Before the fix both phases hit the
  # blank-app abort: prepare stuck `assembling` with every member held, and ship
  # aborting after cyvasse's push was already live.
  CYVASSE_POST_DEPLOY_REPOS = <<~RUBY
    REPOS = [{ "repo" => "cyvasse", "kind" => "app", "qa_app" => "cyvasse",
               "prod_deploy" => { "strategy" => "git_push_heroku",
                                  "remote" => "https://git.heroku.com/cyvasse.git", "branch" => "main" },
               "members" => [{ "slug" => "t-cyv", "post_deploy_cmd" => "bin/rails users:seed_identities" }] }]
  RUBY


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

  # --- qa_smoke: `completed` only AFTER the blocking QA post-deploy hook passes --
  # The stage stamp must not go green prematurely: prepare records qa_smoke
  # `started` at the first QA deploy, `failed` on a boot failure, and `completed`
  # only once every app booted AND run_post_deploy (blocking, abort!s on failure)
  # returned green — the same "never a step early" rule 8b uses for deploy_qa.

  # Capture the qa_smoke ReleaseEvent stage stamps (step + status) without a board.
  RRE_ECHO = %(def record_release_event(_slug, step, status, *_a, **_k); $stdout.puts("RRE " + step.to_s + " " + status.to_s); end)

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


  # --- release notes: the real error, and the repost command ------------------

  # rel-20260925-3b1f5c printed "not delivered (webhook unset?)" for what was an
  # HTTP 400 on a 2790-char message. The command must print the conductor's error.
  # argv is what `notes` sees AFTER the dispatcher shifted the subcommand off.
  NOTES_ERROR = "DeliveryError: Discord release notes notification failed: HTTP 400 " \
                '{"content": ["Must be 2000 or fewer in length."]}'

  def notes_stub(delivered:, error: nil)
    <<~RUBY
      $snippets = []
      def conductor(ruby, read_only: false)
        $snippets << [ruby, read_only]
        { "slug" => "rel-x", "message" => "the notes body", "notes_delivered" => #{delivered},
          "notes_error" => #{error.inspect}, "notes_messages" => 2,
          "messages" => [{ "content_chars" => 1990, "embeds" => 0, "embed_chars" => 0 },
                         { "content_chars" => 800, "embeds" => 0, "embed_chars" => 0 }] }
      end
      def warn_local!; end
    RUBY
  end
end
